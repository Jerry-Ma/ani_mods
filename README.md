# AniMods

Ani's personal collection of small WoW UI patches and QoL tweaks — a "patch system":
a landing spot for one-off ideas cherry-picked from other addons (or written from
scratch) that don't warrant their own standalone addon, each gated behind a load
condition so it only activates when it actually applies.

Personal/local use — not published to CurseForge.

---

## Structure

Each patch is a self-contained module under `Modules\`, registered with `Core.lua`'s
module registry:

```lua
local MyFeature = {
    title        = "My Feature",              -- optional, defaults to the registered name
    description  = "One-line summary shown in the status panel.",
    -- Optional: an ordered checklist shown as an always-visible "Depends on:"
    -- block in the detail pane -- distinct from the condition table below,
    -- which is machine-checked and only surfaces a reason when it currently
    -- fails. `met` is an optional live predicate; a green/red dot reflects it
    -- each refresh; omit `met` for a purely informational line (e.g. "None").
    dependencies = {
        { text = "SomeAddon loaded", met = function() return AniMods.IsAddOnLoaded("SomeAddon") end },
    },

    -- Optional: gates whether Enable() runs at all. Evaluated once at PLAYER_LOGIN,
    -- so IsAddOnLoaded() checks against *other* addons are reliable no matter the
    -- load order.
    condition = {
        requires = { "SomeAddon", { name = "OtherAddon", minVersion = "2.0.0" } },
        forbids  = { "ConflictingAddon" },
        check    = function() return true end, -- arbitrary extra predicate, ANDed in
    },
}

function MyFeature:Enable()
    -- hook stuff, create frames, etc. Only called if condition passed AND the
    -- module is user-enabled.
end

AniMods.RegisterModule("MyFeature", MyFeature)
```

Add the new file to `AniMods.toc` (after `Core.lua`, `Broker.lua` and `UI.lua`) to load
it.

Modules are enabled by default (once `condition` passes). Most WoW UI hooks can't be
cleanly undone at runtime, so there's no `Disable()` contract — toggling a module off
in the status panel just skips its `Enable()` next login/reload.

### Shared broker helper (`Broker.lua`)

Any module publishing a LibDataBroker plugin uses `AniMods.Broker` rather than growing
its own copy of the same boilerplate (RaidComposition and SocialStatus had already
drifted to differently-named copies of the same getter before this was pulled out):

- `Broker.Register(objectName, spec)` — registers a data object, or returns `nil` if
  LibDataBroker isn't available. Fills in `type = "data source"` and an empty `text`.
- `Broker.BuildText(getDB, parts)` — renders the broker's `text` from an ordered list
  of `{ count, color, atlas | texture }` parts, honouring the module's own display-mode
  and colored-text settings. "Icon + Text" packs each icon directly against its count
  (inline `|A:name:h:w|a` for an atlas, `|Tpath:h|t` for a texture file) with no
  separator, since the icons already tell the parts apart; "Text Only" falls back to a
  `/` separator.
- `Broker.DisplayRows(getDB, onChange)` — the standard "Broker Display" section for
  `GetInfoRows()`: a Style dropdown (Icon + Text / Text Only) and a Colored text toggle.

`getDB` is the module's own lazy settings accessor (its `ModuleDB` function), so each
broker's settings live in that module's own saved-variables table — shared *behaviour*,
not shared state.

A module can optionally expose `GetInfoRows()`, returning an ordered list of rows
rendered in its detail pane — this is the "debug + options" section every module gets
for free:

```lua
function MyFeature:GetInfoRows()
    return {
        { section = "Status" },                                                  -- section header
        { label = "Some live value", value = tostring(someState) },              -- status
        { section = "Options" },
        { label = "Include X", get = GetX, set = SetX, note = "active now" },    -- checkbox (boolean)
        { label = "Style", options = { a = "Style A", b = "Style B" },
          order = { "a", "b" }, get = GetStyle, set = SetStyle,
          atlas = { "some-atlas-1", "some-atlas-2" } },                          -- dropdown, w/ optional icon preview(s)
    }
end
```

A row with `section` renders as a divider header, grouping an otherwise-flat scrolling
list into skimmable chunks (a module with several kinds of info — live status,
integration facts, a style picker — should section them rather than dumping everything
in one list). A row with `options` (+ `order`, mirroring AceGUI Dropdown's own
`SetList(list, order)` signature) renders as a real Dropdown/combobox — the right choice
once there are more than two or three mutually-exclusive options (a wall of radio-style
checkboxes doesn't scale); adding `atlas` (a single atlas name, or an array of them for
a role-icon-set style) puts small icon preview(s) of the *currently selected* option
next to it (resolved via `C_Texture.GetAtlasInfo()` since AceGUI's `Icon` widget only
takes a texture path, not an atlas name — there's no icon-aware dropdown item type in
the bundled AceGUI-3.0, so the preview lives outside the dropdown itself rather than
per-item inside it). A row with `min` renders as a Slider — for a setting that's
genuinely a number (e.g. a spacing amount) rather than a small set of named choices;
committed on mouse-up, not while dragging (no current module uses one — RaidComposition
tried a spacing slider and removed it once compact spacing (0) turned out to just always
be the right answer, leaving nothing to actually tune). A row with plain `get`/`set` (no
`options`/`min`) renders as a checkbox, for real booleans. Everything else is a plain
read-only label/value line (for live internal state — "N/A" when not applicable is a
normal `value`). Rebuilt whenever `AniMods.RefreshUI()` is called (a toggle, or a
module's own event handler noticing its live data changed) or the panel is reopened, so
it reflects current reality, not what was true when the module loaded — but *not* on a
fixed timer (a rebuild while, say, a Dropdown row is open would force-close it; see
`dropdownOpen` in `UI.lua`). This is deliberately the one generic row shape rather than
a full widget framework — extend it if a module ever needs something `GetInfoRows()`
can't express.

### Why conditions?

Some patches only make sense in the *absence* of another addon that already does the
same thing (e.g. ChatContextSwitch below only applies when NDui — which ships this
exact behavior itself — isn't loaded). Others might only make sense *with* a specific
addon present, or above/below a given version of it. `condition` makes that explicit
and inspectable instead of silently double-hooking or crashing on a missing global.

## UI

`/animods` opens the status panel: one tab per registered module, drawn with
`AniMods.W` (`Widgets.lua`) — hand-rolled chrome that matches EllesmereUI's look. Each
tab's title is prefixed with a colored status dot (green = active, gray = user-disabled,
orange = inactive/condition unmet, red = failed) so load state is visible without
opening the tab.

Each tab shows: the module's full title, state badge, description, an always-visible
"Depends on:" checklist (its `dependencies` field, each entry its own green/red-dotted
line reflecting whether it's currently satisfied — gray for a purely informational entry
with no live check), and (if inactive) the reason why; below that, its `GetInfoRows()`
(see above) — a `section` becomes an accent-colored heading with a hairline rule,
`options` a dropdown, `min` a slider, plain `get`/`set` a checkbox, everything else a
two-column value row with alternating stripes; at the bottom, an enabled checkbox. If a
module's `Enable()` threw an error (state "Failed"), a **Show Error** button opens a
popup with the full traceback (message + `debugstack()`) — not just the one-line `pcall`
message. (WoW's addon sandbox doesn't expose the `debug` table at all — only specific
whitelisted globals like `debugstack()`, which is what this actually uses.)

### Why hand-rolled

Every options panel in this install that reads as modern is hand-rolled —
EllesmereUIOptions, DandersFrames_Options, MidnightRoutine, ClickableRaidBuffs — and the
one that reads as dated (TwintopInsanityBar) uses stock Blizzard templates and a canvas
settings category. AceGUI's widgets are Blizzard-template-derived, which lands it much
closer to the second group; no amount of layout tuning changes that.

This addon used AceGUI before, partly on the stated grounds that ClickableRaidBuffs
"uses that exact library." **That was wrong.** ClickableRaidBuffs *ships* Ace3 including
AceGUI in its `Libs` folder and never references it — its panel is entirely hand-rolled
(`Options\Panel.lua`, `ToggleSwitch.lua`, …). The library is dead weight there.

The other stated reason — "a library is safer when there's no way to see the result" —
was also backwards. DetailsFramework (tried twice before AceGUI, backed out both times)
failed here precisely because its declarative `BuildMenu` API had behavior that couldn't
be verified by reading: a `nil` switch template silently aborted a whole menu build.
Plain `CreateFrame` + `SetBackdrop` + `SetColorTexture` with explicit colors is the most
verifiable code available — there's nothing hidden to get wrong.

### How `Widgets.lua` matches EllesmereUI

Two tiers. When EllesmereUI is loaded, its own public primitives do the drawing:
`MakeBorder` (1px pixel-snapped borders), `PanelPP` (pixel-perfect sizing), `MakeFont`
(the user's configured font), `MakeDropdownArrow`, and `RegAccent`, which registers this
panel's accent-colored regions for **live recoloring** when the user changes their
accent/class theme. When it isn't loaded, the fallbacks draw the same thing with the
same literal colors — copied from EllesmereUI's own palette block (`EllesmereUI.lua`
lines 72-208: `PANEL_BG 0.05/0.07/0.09`, checkbox box `0.10/0.12/0.16`, dropdown
`0.075/0.113/0.141`, row stripes at 0.1/0.2 black, border white @ 0.15). The panel looks
the same either way; what's lost without EUI is only pixel snapping and live accent
updates.

The widgets themselves are re-implemented rather than borrowed: EUI's
`BuildCheckboxControl`/`BuildSliderCore`/`BuildDropdownControl` are file-locals inside a
LoadOnDemand addon, so they can't be called from outside. They're short, though — EUI's
own checkbox is 33 lines — and the recipes are followed closely (checkbox = solid box +
1px border + inset accent fill; dropdown = solid bg + border + arrow with a shared popup
menu; slider = track + accent fill + square thumb).

Layout is a deliberate non-engine: `W.ResetStack`/`W.Stack` place children top-to-bottom
with a running cursor, which is all this panel needs and is far easier to verify than a
generic solver. Only `Libs\LibStub` remains bundled (for LibDataBroker lookups).

## Commands

`/animods` (or the shorter `/ani`):

- `/ani` — open the status panel
- `/ani list` — print module states to chat
- `/ani enable <name>` / `/ani disable <name>` — toggle a module (takes effect after
  `/reload`)

## Current modules

- **ChatContextSwitch** — cycle chat channel (SAY → PARTY → RAID → INSTANCE_CHAT →
  GUILD → OFFICER → world CHANNEL) with Tab / Shift+Tab in the chat edit box. Ported
  from NDui's chat module (`NDui/Modules/Chat/Core.lua`). Each channel in the cycle can
  be individually enabled/disabled from its detail pane ("Channels in the cycle"
  section), which also shows which ones are eligible right now ("active now"). OFFICER
  and the world CHANNEL default to off (most players aren't guild officers or in a
  custom world channel — by default they'd just be two usually-dead stops every lap);
  the rest default on. Only active when NDui is *not currently handling this itself* —
  NDui's own chat module installs the identical hook, but only when enabled
  (`C.db["Chat"]["Disable"]` is falsy); if NDui is installed with its chat module turned
  off, this still applies. Migrated from the standalone ChatContextSwitch addon (now
  removed). Half-baked / not fully tested — bugs may remain from the original.
- **RaidComposition** — Tank/Healer/DPS role counts while in a group; its detail pane
  ("Status" section) shows the live counts, or "N/A" when solo. EllesmereUI's QoL Raid
  Tools panel has no composition display the way NDui's raid tool does, so this fills
  the gap; only active when EllesmereUIQoL is loaded and NDui is not. Two display
  surfaces, both driven by the same counts:

  - **Docked badge** — a compact count badge anchored just below Raid Tools' own
    collapsed icon (the global frame `EllesmereUIRaidToolsIcon`), reading as part of
    that minimized display rather than a separate floating thing. Docking is the only
    display mode (no floating fallback window) — the detail pane's "Integration"
    section just reports whether it's docked yet as a plain status line, since
    EllesmereUIQoL only builds that icon on first use of Raid Tools with a non-"never"
    mode ("never" is its own default), so there may briefly (or permanently) be nothing
    to dock to. Anchored via `SetPoint` (just reads its rect) and synced three ways:
    `hooksecurefunc(iconBtn, "Show"/"Hide", ...)` (fires even though EUI's own
    visibility runs through a secure `SecureHandlerStateTemplate` snippet, not a plain
    Lua call); an `OnClick` hook on the icon itself for zero-latency feedback on the
    expand action specifically (`SecureHandlerClickTemplate`'s secure `_onclick`
    attribute is a separate execution path from the button's ordinary `OnClick`
    script, which still fires too); and a fast (0.15s) resync ticker as a
    belt-and-suspenders backstop for every other path that can hide/show the icon
    (driver transitions, the toggle keybind, a shell's own collapse button) that we
    don't have a direct handle on to hook. No taint risk (never touches EUI's secure
    frames, only observes and anchors to them). Can be hidden entirely (**"Show docked
    badge"**, on by default) while staying hooked/tracking underneath — useful together
    with the broker plugin below, so the same counts aren't shown twice (once docked,
    once in a databar) for anyone who'd rather rely on just the broker. No tooltip by default — a second popup
    fighting for the same screen space as EUI's own Raid Tools UI can be more annoying
    than useful — but opt-in via **"Show tooltip on docked badge"** in the "Integration"
    section, sharing the exact same tooltip as the broker plugin below, anchored via a
    **"Tooltip anchor"** `Dropdown` picking one of the 8 standard `GameTooltip` anchor
    points (`ANCHOR_TOP`/`ANCHOR_BOTTOMLEFT`/etc.) relative to the badge — defaults to
    Right so it doesn't pop out overlapping EUI's own icon sitting directly above the
    tiny (36x12) badge. The detail pane shows EUI's actual configured mode directly
    (`_G._EUI_RaidTools_DB()`, the plain read-only getter
    `EllesmereUIQoL_RaidTools.lua` exposes for its own options panel) as part of the
    dock-status line when not yet docked.
  - **Broker (LDB) plugin** — registers as a LibDataBroker data source ("AniMods: Raid
    Composition"), pickable as a widget in EllesmereUIDataBars (or any other
    LDB-consuming data bar). EUI ships LibStub + LibDataBroker-1.1 itself
    (`EllesmereUI/Libs/`) and `EllesmereUIDataBars` depends on `EllesmereUI`, so the
    library is guaranteed present whenever this module's own condition holds — no need
    to embed a copy. `text` goes empty — not "N/A" — when solo, so a
    transparent-background databar can just disappear. Otherwise built from two
    independent options in the "Broker Display" section: a `Dropdown` "Style" —
    **Icon + Text** (an inline texture escape — `|A:atlas:h:w|a` for an atlas style,
    `|Tpath:h|t` for a texture-file one — styled to match whichever icon style is
    selected, packed with no padding — the icon alone tells the three roles apart, so no
    separator either) or **Text Only** (falls back to a `/` separator between roles,
    since there's no icon to lean on there) — and colored text (role-tinted numbers,
    matching the docked badge's blue/green/red). Hovering shows a headcount-bearing
    header (e.g. "Raid (13)", not just "Raid"), a one-line composition summary ("2 Tank
    5 Healer  6 DPS"), and a per-role breakdown of class-colored squares (one per member
    in that role) below that. Left-clicking opens Blizzard's own raid roster/role/
    ready-check frame (`ToggleRaidFrame()`, the same global SavedInstances uses — lazy-
    loads `Blizzard_RaidUI`, guarded against combat lockdown) — the actual
    raid-management UI, not this module's settings; right- or middle-clicking opens the
    AniMods panel switched straight to this module's own tab
    (`AniMods.OpenModuleTab("RaidComposition")`), whether or not the panel was already
    open on a different one.

  Role icons ("Icon Style" section, a `Dropdown` with a live preview of the selected
  style's Tank/Healer/DPS icons via three AceGUI `Icon` widgets alongside it) default to
  matching EllesmereUI's own look, but other addons' looks are offered too since there's
  no reason to force just one. Each style is either `kind = "atlas"` (a plain Blizzard
  atlas name — nothing to embed, the art lives in the game client) or
  `kind = "texture"` (a bundled `.tga` file, an actual asset AniMods ships, rendered via
  `|Tpath:h|t` / a plain `Icon:SetImage(path)` rather than the atlas path):

  - *Atlas styles* — 5 of EllesmereUIRaidFrames's 7 `ROLE_ICON_STYLES` are plain
    Blizzard atlas name references (Modern Circle/Styled/Classic Circle/Classic/Blizzard
    Default) — no license concern, since the atlas art lives in the game client, not in
    any addon's files. Its other 2 styles ("modern", EUI's actual default, and
    "blizzLight") point at EUI's own custom PNGs, not reproduced here since EUI's
    license is all-rights-reserved. "NDui" uses the same atlas set NDui's own
    raid-frame/roster UI shows (`groupfinder-icon-role-micro-*`, from
    `B:ReskinSmallRole` in `NDui/Core/Functions.lua`) — again a plain Blizzard atlas
    reference, not a copy of an NDui-authored asset.
  - *Texture styles* — NDui_Plus overrides that same `B.ReskinSmallRole` with a choice
    of genuinely different custom icon art instead of the plain atlas
    (`NDui_Plus/Media/Media.lua`, `P.RoleList`, 5 sets). NDui_Plus is MIT-licensed
    (`Copyright (c) 2021 Witnesscm`), so its `.tga` files are copied into
    `Media\RoleIcons\` (with the license text alongside them,
    `Media\RoleIcons\LICENSE.txt`) rather than merely referenced — same as any other
    bundled Lib, this module doesn't depend on NDui_Plus being installed. Only 4 of
    NDui_Plus's 5 `RoleList` sets have real backing files in this install
    (`ToxiUI/Stylized*` is a dead reference with no texture behind it there), so only
    those 4 are offered: **NDui_Plus: LynUI**, **NDui_Plus: ElvUI**,
    **NDui_Plus: ToxiUI White**, **NDui_Plus: ToxiUI New**.

  Selecting a style applies live, no reload needed.
- **Skin** — re-skins extra Blizzard UI elements EllesmereUI doesn't skin itself; a
  landing spot for one-off "it should look like it belongs" fixes, each its own entry
  that can be independently enabled/disabled from the panel (unlike the rest of
  AniMods' modules, which are all-or-nothing) — its detail pane has one section per
  entry, each with its own "Enabled" checkbox, "Available" status (whether that
  entry's own prerequisites are currently met, independent of the toggle), and
  "Applied" status. Both entries below are cheap, genuinely reversible tweaks (unlike
  most of AniMods' other hooksecurefunc-based patches), so — unlike the framework's
  usual "no `Disable()` contract, toggle takes effect next reload" convention (see
  above) — these actually apply/revert live:

  - **TTS Button** — EllesmereUIChat hides several Blizzard chat chrome buttons it
    replaces with its own sidebar icons (`QuickJoinToastButton`, `ChatFrameMenuButton`,
    `ChatFrameChannelButton`, the voice mute/deafen buttons), but not
    `TextToSpeechButton` (Blizzard's built-in "read chat aloud" toggle), so it's
    normally left floating in its default position, disconnected from EUI's
    redesigned chat frame. This suppresses it the same way EUI suppresses the others
    (`SetAlpha(0)` + `EnableMouse(false)`, not `:Hide()` — Blizzard's own layout code
    can silently re-show a hidden frame, so alpha+mouse is the taint-free way to make
    a Blizzard-owned frame invisible and inert) and adds an equivalent button into
    EUI's sidebar icon chain, stacked directly above its always-present
    scroll-to-bottom icon (matching `EllesmereUIChat.lua`'s own `MakeSidebarIcon`
    constants — 22px, 10px spacing, desaturated with a 0.4→0.9 hover fade — since
    that function itself is private to EllesmereUIChat.lua, not something AniMods can
    call, only match). The button is a thin proxy rather than a reimplementation:
    clicking it calls the real `TextToSpeechButton:Click()`, and its icon is copied
    live from the real button's own texture/atlas (checked via
    `GetNormalTexture`/`GetCheckedTexture`/`GetPushedTexture`, falling back to
    scanning the button's regions for a plain child `Texture` if none of those are
    set — not every Blizzard icon button draws its icon the same way), so it shows
    whatever Blizzard is actually displaying (including any on/off state change)
    without AniMods needing to know what drives that state — nothing in this AddOns
    folder references the underlying CVar/API, so guessing at it would risk a button
    that silently does nothing. If no icon can be found at all, a plain "T" text
    label takes its place instead, so a mismatch in Blizzard's internal button
    structure degrades to a working-but-plain button rather than a silent,
    unexplained empty click zone. Reads EllesmereUIChat's exposed
    `EllesmereUI._chatCFD` (its internal per-chat-frame state accessor) to find the
    sidebar and scroll button, polling the same way RaidComposition waits for EUI's
    Raid Tools icon. Available only when EllesmereUIChat is loaded and its own chat
    module is enabled (`EllesmereUI._ModuleNS["EllesmereUIChat"].ECHAT.DB().enabled`)
    — installed but toggled off means none of this (the sidebar, TextToSpeechButton's
    default position) is EUI's to redesign in the first place.
  - **Minimap Addon Button Icon** — Blizzard's addon-button collector
    (`AddonCompartmentFrame`, the button near the minimap that groups addons with no
    dedicated minimap icon into a dropdown) keeps its default raised/colorful icon
    look even under EllesmereUIMinimap, which only repositions/reparents it (its
    "Addon Compartment" section — `_ParkAddonCompartment`/`_PositionAddonCompartment`/
    `_ApplyAddonCompartment`), never re-skinning the icon texture itself. This
    desaturates + tints it (`AddonCompartmentFrame.Icon`, or the first plain `Texture`
    region found on it if that field isn't there) to match, using the same treatment
    EllesmereUIMinimap's own neighboring addon-button-flyout toggle already uses
    (`CreateFlyoutToggle`: `SetDesaturated(true)` + `SetVertexColor(accent)`) — the
    closest visual sibling, since it's literally the other addon-button icon on the
    same minimap. Tints with the user's live EUI accent color
    (`EllesmereUI.RegAccent`) when available, a plain light gray otherwise. Available
    only when EllesmereUIMinimap is loaded.
- **SocialStatus** — online guild/friend counts as a broker (LDB) plugin, mirroring
  EllesmereUIMinimap's own "friends" button (the one in its minimap extra button group
  that shows online friends/guildies on hover). That button and its tooltip function
  are entirely unreachable from outside EllesmereUIMinimap.lua — the button has no
  name (`CreateIndicatorBtn` does `CreateFrame("Button", nil, parent)`), the table
  holding it is a plain `local`, and its tooltip is wired via `HookScript`, which isn't
  retrievable through `GetScript()` even if the frame could be found — so this is a
  **faithful port**, not a call into EUI's own code: `GatherOnlineFriends` and
  `ShowFriendsTooltip` are reproduced line-for-line where they call plain Blizzard
  APIs (`IsInGuild`/`GetNumGuildMembers`/`GetGuildRosterInfo` for guild;
  `BNGetNumFriends`/`C_BattleNet.GetFriendAccountInfo` filtered to `isOnline` and
  `clientProgram == "WoW"`, split into Battle.net favorites vs. regular friends, for
  Battle.net; `C_FriendList.GetNumFriends`/`GetFriendInfoByIndex` filtered to
  `connected`, deduplicated against Battle.net by character name, for character
  friends; guild members removed from both friend lists by name so nobody's counted
  twice) and its custom tooltip's layout is reproduced closely too (a real bordered
  popup frame — not the standard `GameTooltip`, which can't host this — two-column
  rows with class-colored names, a Battle.net tag prefix and level suffix where
  applicable, right-aligned zone, section headers reading "Title (count)" in EUI's own
  accent color when reachable, dividers between Favorites/Guild/Friends). Deliberately
  **not** ported: EUI's right-click whisper/invite row menu, its hover-stability grace
  timers, and its dev-mode/protected-instance whisper guards — interactive
  conveniences specific to living on the minimap, not part of "look and feel", and
  dependent on EUI-internal locals with no access path anyway.

  Two tooltip paths, matching what different LDB display addons support: EllesmereUIDataBars
  (confirmed in `EllesmereUIDataBars_Blocks.lua`'s `ShowTip`) calls a plugin's `OnEnter(anchorFrame)`
  instead of `OnTooltipShow` when both are defined, handing full control to the plugin
  — that's what makes the custom bordered popup possible, and is used for `OnEnter`/
  `OnLeave` here; `OnTooltipShow(tt)` stays as a fallback, rendering the same grouped
  data with plain `AddLine`/`AddDoubleLine` calls for any display that only supports
  that path.

  `text` is built the same shape as RaidComposition's broker (`BuildBrokerText`) — a
  `Dropdown` "Style" in the "Broker Display" section, **Icon + Text** (Guild's minimap
  guild-banner atlas + Friends' exact atlas EUI's own button uses,
  `housefinder_neighborhood-friends-icon`, packed against each count with no
  padding/separator — the icon tells them apart) or **Text Only** (falls back to a `/`
  separator), plus independent colored-text (gold/blue). Left-clicking opens
  Blizzard's own `ToggleFriendsFrame()` (same click action as EUI's button), guarded
  against combat lockdown. Refreshes on `GUILD_ROSTER_UPDATE`/`FRIENDLIST_UPDATE`/
  `BN_FRIEND_INFO_CHANGED`/`BN_FRIEND_ACCOUNT_ONLINE`/`BN_FRIEND_ACCOUNT_OFFLINE`.
  Available only when EllesmereUIMinimap is loaded — the counting logic itself needs
  nothing from EUI, but the whole point is to be the broker-shaped equivalent of a
  button that's specifically EUI's.

  Deliberately **not** a native EllesmereUIDataBars block type (which would come with
  its own dedicated settings page, matching the depth of its built-in blocks like Gold
  or Spec): EllesmereUIDataBars has no plugin/extension API for that — its block types
  are a fixed, hardcoded list (`ns.BLOCK_TYPES` in `EllesmereUIDataBars.lua`), each
  with its own builder inside `EllesmereUIDataBars_Blocks.lua`. Adding one natively
  would mean editing that (CurseForge-managed, otherwise-untouched-by-AniMods) addon's
  own files directly — silently wiped on its next update. Staying a plain LDB broker
  means it survives every EUI update untouched, at the cost of using EllesmereUIDataBars'
  generic "Broker Plugin" block type instead of a dedicated one.
- **SoundSwitch** — switch the game's sound output device from a databar.
  **Left-click** cycles to the next device; **right-click** opens this module's tab,
  where each detected device has an in-the-cycle checkbox (the current one is marked
  "current"), so you can skip outputs you never want to land on. The tooltip lists every
  device, highlighting the active one and dimming skipped ones.

  The core is lifted from **SoundManager** (by Zax), reduced to just the switching part —
  that addon also does per-device volume presets, its own movable frame and keybinds,
  none of which are wanted here. Only Blizzard API is used
  (`Sound_GameSystem_GetNumOutputDrivers` / `…GetOutputDriverNameByIndex`, the
  `Sound_OutputDriverIndex` CVar, and `Sound_GameSystem_RestartSoundSystem` with
  `AudioOptionsFrame_AudioRestart` as the pre-10.0 fallback), so nothing needs to be
  installed. Two non-obvious details are kept from SoundManager, both called out in its
  own comments: the **last** driver is a system-default pseudo-device rather than a real
  output and is left out of the cycle (its loop runs to `count - 1`), and driver
  **indices go stale** when the OS adds or removes an output — so settings are keyed by
  device *name* and indices are re-read fresh at the moment of switching, never stored.

  Refreshes on `CVAR_UPDATE`, which is how SoundManager notices the output being changed
  from outside (the OS, Blizzard's audio options, another addon); the handler re-reads
  the device and only pushes an update when it actually differs, so there's no polling.
