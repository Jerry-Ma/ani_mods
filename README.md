# AniMods

Ani's personal collection of small WoW UI patches and QoL tweaks — a "patch system":
a landing spot for one-off ideas cherry-picked from other addons (or written from
scratch) that don't warrant their own standalone addon, each gated behind a load
condition so it only activates when it actually applies.

Personal/local use — not published to CurseForge.

---

## Checks

```powershell
.\Tools\check.ps1             # all three layers
.\Tools\check.ps1 -Fast       # Lua 5.1 parse only, while iterating
.\Tools\check.ps1 -SkipTypes  # layers 1-2, if the VS Code extensions aren't installed
```

Three layers, because each catches what the previous cannot:

1. **`luac -p`** — a real **Lua 5.1** parse of every file `AniMods.toc` loads, in load
   order. WoW runs 5.1; luacheck's own bundled runtime is 5.4 and its parser accepts a
   syntax superset, so this is the only step that actually rejects what 5.1 can't
   compile. It also cross-checks the `.toc` against the files on disk in both directions
   — a file listed but missing is an error, a `.lua` on disk that nothing loads is
   reported as an orphan. A rename that updates one but not the other is otherwise a
   silent no-load in game.
2. **`luacheck`** — static analysis against the **full** Blizzard globals list: typo'd or
   undefined globals, accidental global writes, unused and shadowed locals.
3. **`lua-language-server --check`** — type-aware diagnostics against the WoW API
   annotations from the [WoW API](https://marketplace.visualstudio.com/items?itemName=ketho.wow-api)
   VS Code extension. This is the only layer that knows what WoW functions *return*, so
   it's the only one that catches a possibly-nil value passed somewhere that can't take
   nil, a wrong argument type, or a call into an API the client no longer has. It earned
   its place on the first run by finding `badge.text:SetFont(badge.text:GetFont(), ...)`
   in `GroupRoles.lua` — `GetFont()` can return nil and `SetFont(nil, ...)` is a hard
   error. Neither of the layers above can see that.

   It uses the language server binary bundled with the `sumneko.lua` extension, so
   there's nothing extra to install. Both extensions are located by glob with the newest
   match winning, so upgrading either doesn't need an edit to the script.

Setup (one-off):

```powershell
scoop install lua-for-windows luacheck   # Lua 5.1.5 + luac, and the linter
.\Tools\update-luacheckrc.ps1            # generates .luacheckrc
```

Plus the two VS Code extensions for layer 3 (and for live in-editor diagnostics):
**Lua** (`sumneko.lua`) and **WoW API** (`ketho.wow-api`) — the latter ships LuaLS
annotations for ~8,000 functions with signatures and return types, 260 `C_` namespaces,
860+ widget types, 843 enums, and deprecated functions with their replacements. It
activates automatically on a folder containing a `.toc`.

`.luarc.json` configures LuaLS for both the editor and layer 3.
`Tools\meta\externals.lua` is a `---@meta` stub — not loaded by the game, not in the
`.toc` — declaring the foreign globals AniMods deliberately reaches for
(`EllesmereUI`, `NDui`, `EllesmereUIRaidToolsIcon`, `_EUI_RaidTools_DB`) plus the
superseded Blizzard ones kept as guarded fallbacks (`IsAddOnLoaded`,
`GetAddOnMetadata`, `AudioOptionsFrame_AudioRestart`). Without it, reaching into another
addon's globals — most of what this addon does — is an "undefined field" warning at
every site, and a checker that cries wolf on the core idiom is one nobody reads. Types
there are deliberately loose (`any`): these are foreign, undocumented, version-dependent
objects, and pretending to know their shape would invent a contract nothing enforces.
The one place a warning is suppressed inline rather than by configuration is
`Skin.lua`'s `FindFlyoutToggle`, where probing EUI's private `_norm`/`_pushed`/`_hl`
fields *is* the identification — suppressed at that single line, not loosened globally.

`.luacheckrc` is a **generated artifact and is gitignored** — it is the ~44,000-entry
Blizzard globals list from [Jayrgo/wow-luacheckrc](https://github.com/Jayrgo/wow-luacheckrc)
(branch `mainline`, itself parsed from
[Ketho/BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources))
with `Tools\luacheckrc.animods.lua` appended. Edit **that** file, never `.luacheckrc`.
Completeness is the point: with every Blizzard global known, an "undefined variable"
warning is a real finding rather than something to skim past — and the list is worth
regenerating rather than hand-extending, so the habit of silencing warnings by adding
globals never starts. The handful of genuinely-missing entries in
`luacheckrc.animods.lua` were each confirmed working in game first.

**What none of this catches.** It does not run the addon. A wrong event name, a
nonexistent atlas, a loop that iterates zero times — all invisible here, and all of them
have shipped in this addon at least once. Headless
runners exist ([wowless](https://github.com/wowless/wowless) is the serious one) but it
is pre-alpha and its own README says errors it reports are probably its own bugs, so it
isn't a gate. **A `/reload` is still the real test** — this only makes one worth doing.

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
its own copy of the same boilerplate (GroupRoles and SocialStatus had already
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
committed on mouse-up, not while dragging (no current module uses one — GroupRoles
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

### Doing nothing when nothing happened

The addon runs **no periodic work of any kind** — no `OnUpdate`, no `NewTicker`. Every
module is woken by an event, and the only `C_Timer` calls left are bounded one-shots
(the 2/5/10/20s retry ladders that wait for an EllesmereUI frame that is genuinely
created later, which stop once it appears) and next-frame deferrals. Load-order waiting
is not one of those cases any more — that goes through `W.OnReady`, see the UI section.
Three rules keep it that way, and all three were learned by getting them wrong first:

- **Register the event that means what you want.** GroupRoles listened on `UNIT_FLAGS`
  for role-count changes. `UNIT_FLAGS` fires when a unit's PvP / combat / AFK flags
  change, for any unit the client tracks — many times a second in a raid — and has
  nothing to do with `UnitGroupRolesAssigned`. Each firing paid for a full roster walk
  and a broker-text rebuild to arrive at identical numbers. The event that actually
  means "someone's assigned role changed" is `PLAYER_ROLES_ASSIGNED`.
- **Coalesce per-item event bursts.** `AniMods.Coalesce(fn)` (`Core.lua`) wraps a
  handler so a burst collapses into one deferred call on the next frame. Several of the
  events modules care about aren't "something changed" notifications but per-item ones:
  `BN_FRIEND_INFO_CHANGED` fires once per friend whose status, AFK flag or
  rich-presence text moves — dozens of times within a second or two at login — and
  `GUILD_ROSTER_UPDATE` fires repeatedly per roster query. Answering each separately
  redoes the same walk N times to reach the state the last one alone would have
  produced. This is a one-shot per burst, **not** a poll: nothing is scheduled while
  idle.
- **Compute what the caller actually needs.** SocialStatus' broker needs two integers,
  and recomputed them on every friend/guild event through the same
  `GatherOnlineFriends()` the tooltip uses — allocating a 7-field table per online guild
  member (700+ in a large guild), resolving each one's class through `C_CreatureInfo`,
  and running three `table.sort`s, only to call `#` on the results. `CountOnline()` does
  the same three walks and the same de-duplication without any of that; the full gather
  is now reached only from the two tooltip paths, on hover. The de-dup rules are
  deliberately duplicated between the two (sharing them would mean materialising the
  lists again, the exact cost being avoided) — which makes them the one thing that has
  to be kept in step, or the broker's numbers will silently disagree with its own
  tooltip.

Two smaller ones in the same spirit: hot loops reuse their scratch tables and their unit
tokens rather than rebuilding a set of 40 identical strings per walk (`RAID_UNITS` /
`PARTY_UNITS` in `GroupRoles.lua`, the `wipe()`d scratch sets in `SocialStatus.lua`);
and `Broker.SetText(obj, text)` assigns only on an actual change, because LDB data
objects are proxy tables whose `__newindex` fires
`LibDataBroker_AttributeChanged_<name>` unconditionally — it never compares against the
current value, so re-assigning an identical string still walks the callback list and
makes every subscribed databar repaint for nothing. Since most of what wakes these
modules leaves the displayed numbers unchanged, that no-op repaint was the common case.

## UI

`/animods` opens the status panel: one tab per registered module, drawn with
`AniMods.W` (`Widgets.lua`) on EllesmereUI's public skinning API, so it wears the same
window dress as the rest of the suite and follows the user's theme live. Each
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

### Built on EllesmereUI's public skinning API

`Widgets.lua` draws nothing itself. It registers once —

```lua
EllesmereUI.RegisterSkin("AniMods", function(S) ... end)
```

— and every surface is painted by `S`, the facade EllesmereUI hands third-party addons
over its window-skin engine (`EllesmereUIBlizzardSkin_SkinAPI.lua`). `S.Shell` dresses the
panel as a native EllesmereUI window, `S.Panel` / `S.Button` / `S.Checkbox` / `S.Dropdown`
paint the controls, and `S.GetFont` / `S.GetAccentColor` / `S.GetPanelColor` report the
live theme.

This replaced eight undocumented couplings into EllesmereUI internals — `MakeBorder`,
`PanelPP`, `RegAccent`, `DisablePixelSnap`, `MakeDropdownArrow`, `GetFontPath`,
`EXPRESSWAY`, plus a copied palette — with one published contract. The facade's own
header states the terms: it is the public surface (never raw `WSkin`), its entries are
late-bound pass-throughs so engine internals stay free to change, its signatures are
additive-only and versioned by `S.apiVersion`, and each callback is `pcall`-isolated so a
mistake here cannot break EllesmereUI or vice versa. One of the replaced internals,
`RegAccent`, had already crashed this addon on login because its shape was guessed wrong.

What that buys beyond safety: the panel now **live-follows the user's window style**.
`S.Shell` registers it with the engine, so switching between the "eui" atlas look and the
flat "modern" colour — and editing the Modern colour — applies with no reload. Accent
changes propagate through `S.OnLooksChanged` into a weak-keyed registry of the few things
AniMods still colours by hand (the slider fill, headings, the window title).

**There is no provider test anywhere in `Widgets.lua`.** `Compat.lua` picks one at load —
EllesmereUI's facade when it's there, an AniMods-owned implementation of the same
interface when it isn't — and every constructor just calls `S`. That's what keeps this
from being the fallback pattern it replaced: the old code asked "is EllesmereUI loaded?"
at eight call sites and carried a hand-drawn branch behind each, so every widget had two
renderings to keep looking alike.

The second rendering does still exist — a stock Blizzard UI needs one — and it's worth
naming rather than glossing. The difference is that it's one file behind one boundary,
implementing someone else's published contract, instead of a branch inside every widget.

**Consequence: AniMods has no hard dependency on EllesmereUI.** The panel, the brokers and
every module work on a stock UI. `Compat.lua` implements only the members `Widgets.lua`
actually calls (`Shell`, `Panel`, `Button`, `Checkbox`, `Dropdown`, `Font`, and the five
theme getters) — implementing the rest of EllesmereUI's facade unused would be inventing a
contract nothing exercises. Its accent colour is the player's class colour, the one piece
of live theming a stock UI has.

#### The restrip rule

This applies to EllesmereUI's provider; `Compat.lua` has no such registry. `Widgets.lua`
follows the rule unconditionally anyway, which is what lets one set of constructors serve
both providers — don't "optimise" it away for the stock path.

`S.Panel` and `S.Shell` enrol their frame in the engine's **restrip registry**.
`WSkin.Restrip()` is a global sweep — called from ~20 places whenever a Blizzard window
repaints (Collections, Spellbook, Guild, Calendar, Loot, Item Upgrade, …) — and it
alpha-zeroes every direct texture region on every registered frame except the engine's own
protected keys.

So **never add a texture directly to a frame passed to `S.Panel` or `S.Shell`**; it
silently vanishes the first time the player opens their collections. Our art goes on a
child frame instead. That is why `W.Window` returns `.content` rather than letting callers
draw on the window, why `W.Dropdown` and `W.Button` hold their label on an `inner` child,
and why `SocialStatus`'s popup parents its rows and dividers to `TTInner()`. This is the
one non-obvious part of the contract, and the API's developer guide (`SKINNING_API.md`) is
referenced by the source but not shipped in the addon folders — the engine is the spec.

#### Sequencing, not polling

`W.OnReady(fn)` runs `fn` when the facade arrives, or immediately if it already has.
EllesmereUI dispatches at `PLAYER_LOGIN` *after its own boot*, so that callback is the
first moment both the skin engine and EllesmereUI's frames are guaranteed to exist —
which is why `Skin:Enable()` now hangs its first pass off `OnReady` instead of firing
during `PLAYER_LOGIN` and relying on a retry ladder to catch up. The ladder that remains
covers only what EllesmereUI genuinely creates later.

Layout stays a deliberate non-engine: `W.ResetStack`/`W.Stack` place children
top-to-bottom with a running cursor, which is all this panel needs and is far easier to
verify than a generic solver. `Widgets.lua` keeps only alpha and metric tokens — every
colour now comes from the theme, so there is no copied palette left to drift. Only
`Libs\LibStub` remains bundled (for LibDataBroker lookups).

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
- **GroupRoles** — Tank/Healer/DPS role counts while in a group; its detail pane
  ("Status" section) shows the live counts, or "N/A" when solo. EllesmereUI's QoL Raid
  Tools panel has no composition display the way NDui's raid tool does, so this fills
  the gap; only active when EllesmereUIQoL is loaded and NDui is not. Named for what it
  reports — assigned *roles*, in a party as well as a raid; it was called
  `RaidComposition` until the rename, which was wrong twice over (it works in 5-mans,
  and "composition" normally means the class/spec makeup rather than the role split).
  `Core.lua`'s `MODULE_RENAMES` migrates the old saved-variable keys
  (`db.modules.RaidComposition`, `db.raidComposition`) on first login after the rename,
  so no setting is lost; the LDB object name changed too, which does orphan an existing
  databar block (see below). Two display surfaces, both driven by the same counts:

  - **Docked badge** — a compact count badge anchored just below Raid Tools' own
    collapsed icon (the global frame `EllesmereUIRaidToolsIcon`), reading as part of
    that minimized display rather than a separate floating thing. Docking is the only
    display mode (no floating fallback window) — the detail pane's "Integration"
    section just reports whether it's docked yet as a plain status line, since
    EllesmereUIQoL only builds that icon on first use of Raid Tools with a non-"never"
    mode ("never" is its own default), so there may briefly (or permanently) be nothing
    to dock to. Anchored via `SetPoint` (just reads its rect) and synced two ways:
    `HookScript("OnShow"/"OnHide", ...)` on the icon, and an `OnClick` hook on it for
    zero-latency feedback on the expand action specifically
    (`SecureHandlerClickTemplate`'s secure `_onclick` attribute is a separate execution
    path from the button's ordinary `OnClick` script, which still fires too).

    The `OnShow`/`OnHide` **scripts** are load-bearing here, as opposed to
    `hooksecurefunc(iconBtn, "Show"/"Hide", ...)` — which is what this used to do. Both
    see EUI's own visibility changes even though those run through a secure
    `SecureHandlerStateTemplate` snippet rather than a plain Lua call, but only the
    script handlers fire on *effective* visibility changes, i.e. when the icon is
    hidden or shown because an **ancestor** was. A parent's `Hide()` never calls the
    child's, so the method hooks silently missed that whole class of transition —
    which is exactly why a permanent `C_Timer.NewTicker(0.15, ...)` used to sit here as
    a backstop, waking ~7 times a second for the entire session to poll `IsShown()`.
    The script hooks close the gap properly and the ticker is gone; this module now
    does no periodic work at all. (The visibility check is `IsVisible()`, not
    `IsShown()`, for the same reason: `IsShown()` reports only the button's own flag
    and stays true under a hidden ancestor.) No taint risk (never touches EUI's secure
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
  - **Broker (LDB) plugin** — registers as a LibDataBroker data source
    (`AniModsGroupRoles`, labelled "AniMods: Group Roles"), pickable as a widget in
    EllesmereUIDataBars (or any other LDB-consuming data bar). **The object name is an
    ID, not a label**: EllesmereUIDataBars stores it verbatim in its own saved variables
    as the block's `source` and shows it in the data-source picker, so the rename from
    `AniModsRaidComposition` orphans any databar block that already pointed at the old
    name — re-pick it once from the picker. That's also why it shouldn't be renamed
    again casually. EUI ships LibStub + LibDataBroker-1.1 itself
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
    (`AniMods.OpenModuleTab("GroupRoles")`), whether or not the panel was already
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
    sidebar and scroll button, polling the same way GroupRoles waits for EUI's
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

  `text` is built the same shape as GroupRoles' broker (`BuildBrokerText`) — a
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
