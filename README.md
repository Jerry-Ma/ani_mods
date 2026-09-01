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
    dependencies = "Plain-English summary of what this needs, shown as an always-visible" ..
                   " \"Depends on:\" line in the detail pane -- distinct from the condition" ..
                   " table below, which is machine-checked and only surfaces a reason when" ..
                   " it currently fails. Write \"None\" if there's nothing.",

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

Add the new file to `AniMods.toc` (after `Core.lua` and `UI.lua`) to load it.

Modules are enabled by default (once `condition` passes). Most WoW UI hooks can't be
cleanly undone at runtime, so there's no `Disable()` contract — toggling a module off
in the status panel just skips its `Enable()` next login/reload.

A module can optionally expose `GetInfoRows()`, returning an ordered list of rows
rendered in its detail pane — this is the "debug + options" section every module gets
for free:

```lua
function MyFeature:GetInfoRows()
    return {
        { section = "Status" },                                                  -- section header
        { label = "Some live value", value = tostring(someState) },              -- status
        { section = "Options" },
        { label = "Include X", get = GetX, set = SetX, note = "active now" },    -- toggle
    }
end
```

A row with `get`/`set` renders as a checkbox (for per-item options, e.g. which entries
participate in some cycle/list); a row with `section` renders as a divider header,
grouping an otherwise-flat scrolling list into skimmable chunks (a module with several
kinds of info — live status, integration facts, a style picker — should section them
rather than dumping everything in one list); anything else is a plain read-only
label/value line (for live internal state — "N/A" when not applicable is a normal
`value`). Refreshed every second while the panel is open, plus whenever a toggle
changes, so it reflects current reality, not what was true when the module loaded.
This is deliberately the one generic row shape rather than a full widget framework —
extend it if a module ever needs something `GetInfoRows()` can't express.

### Why conditions?

Some patches only make sense in the *absence* of another addon that already does the
same thing (e.g. ChatContextSwitch below only applies when NDui — which ships this
exact behavior itself — isn't loaded). Others might only make sense *with* a specific
addon present, or above/below a given version of it. `condition` makes that explicit
and inspectable instead of silently double-hooking or crashing on a missing global.

## UI

`/animods` opens the status panel: one tab per registered module, built on
**AceGUI-3.0** (`Frame` + `TabGroup` + `ScrollFrame`/List, with `Heading`/`CheckBox`/
`Label`/`Button` widgets).

Each tab shows: the module's full title, state badge, description, an always-visible
"Depends on:" line (its `dependencies` field — what it needs, regardless of whether
that's currently satisfied), and (if inactive) the reason why; below that, its
`GetInfoRows()` (see above) rendered as AceGUI widgets (a `section` becomes a real
`Heading` divider widget, a `get`/`set` row becomes a `CheckBox`, everything else a
`Label`); at the bottom, an enabled checkbox. If a module's `Enable()` threw an error
(state "Failed"), a **Show Error** button appears and opens a popup (an AceGUI `Frame`
+ `MultiLineEditBox`) with the full traceback (message + `debugstack()`) — not just
the one-line `pcall` message. (WoW's addon sandbox doesn't expose the `debug` table at
all — only specific whitelisted globals like `debugstack()`, which is what this
actually uses.)

**Why AceGUI, after two other things were tried and backed out:** a plain hand-rolled
Blizzard-frame UI worked correctly every round but only ever drew a "too cluttered"
complaint once a module's row count grew. DetailsFramework was tried next, twice,
specifically to match NorthernSkyRaidTools's/EllesmereUI's polish — but DF's
declarative `BuildMenu`/`BuildMenuVolatile` API has real sharp edges that are invisible
from reading the code: a `nil` switch template silently aborted the whole menu build
partway through with a real Lua error, and there is no way to catch that kind of thing
without a live client to test against, which isn't available in this workflow. AceGUI
is the most mature, most thoroughly documented WoW UI toolkit there is (a stable API
since roughly Cataclysm, already embedded — and thus proven compatible in this exact
folder — in 20+ addons), with a small, predictable widget-tree API (`Create`,
`AddChild`, `SetCallback`) that's reliable to reason about correctly from the code
alone. Confirmed against real precedent here too: `ClickableRaidBuffs` (an addon the
user pointed to as looking good) uses this exact library
(`ClickableRaidBuffs\Libs\Ace3\AceGUI-3.0`); `TwintopInsanityBar` (pointed to as
looking bad) is fully custom hand-rolled, no AceGUI or DF — a reminder that "hand-built
from scratch" isn't automatically better or worse, and a well-established library is
the safer default.

AceGUI-3.0 is bundled in `Libs\AceGUI-3.0` (copied from HandyNotes's embed, itself the
standard Ace3 distribution, BSD-licensed) plus `Libs\LibStub`, loaded via the `.toc`
before `Core.lua`/`UI.lua` — not relied on any other addon's copy being
installed/loaded.

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
  the gap; only active when EllesmereUIQoL is loaded and NDui is not. Three independent
  display surfaces:

  - **Docked badge** — a compact count badge anchored just below Raid Tools' own
    collapsed icon (the global frame `EllesmereUIRaidToolsIcon`), reading as part of
    that minimized display rather than a separate floating thing. Anchored via
    `SetPoint` (just reads its rect) and synced three ways: `hooksecurefunc(iconBtn,
    "Show"/"Hide", ...)` (fires even though EUI's own visibility runs through a secure
    `SecureHandlerStateTemplate` snippet, not a plain Lua call); an `OnClick` hook on
    the icon itself for zero-latency feedback on the expand action specifically
    (`SecureHandlerClickTemplate`'s secure `_onclick` attribute is a separate execution
    path from the button's ordinary `OnClick` script, which still fires too); and a
    fast (0.15s) resync ticker as a belt-and-suspenders backstop for every other path
    that can hide/show the icon (driver transitions, the toggle keybind, a shell's own
    collapse button) that we don't have a direct handle on to hook. No taint risk (never
    touches EUI's secure frames,
    only observes and anchors to them), and no tooltip of its own — a second popup
    fighting for the same screen space as EUI's own Raid Tools UI would just be
    annoying. Optional (**"Dock to its icon"** toggle in the "Integration" section,
    live-reversible even though the underlying hook can't be un-hooked); when off, or
    while EllesmereUIQoL only builds that icon on first use of Raid Tools with a
    non-"never" mode ("never" is its own default — so nothing to dock to may not exist
    yet), a small movable standalone bar is the fallback. The detail pane shows EUI's
    actual configured mode directly (`_G._EUI_RaidTools_DB()`, the plain read-only
    getter `EllesmereUIQoL_RaidTools.lua` exposes for its own options panel) and
    whether docking has actually happened, as separate facts.
  - **Broker (LDB) plugin** — registers as a LibDataBroker data source ("AniMods: Raid
    Composition"), pickable as a widget in EllesmereUIDataBars (or any other
    LDB-consuming data bar). EUI ships LibStub + LibDataBroker-1.1 itself
    (`EllesmereUI/Libs/`) and `EllesmereUIDataBars` depends on `EllesmereUI`, so the
    library is guaranteed present whenever this module's own condition holds — no need
    to embed a copy. `text` carries all three role icons inline (`|A:atlas:h:w|a`,
    styled to match whichever icon style is selected) plus their counts, and goes empty
    — not "N/A" — when solo, so a transparent-background databar can just disappear.
    Hovering shows a per-role breakdown of class-colored squares (one per member in
    that role) rather than a bare count; clicking opens the AniMods panel.

  Role icons match EllesmereUI's own look ("Icon Style" section): 5 of
  EllesmereUIRaidFrames's 7 `ROLE_ICON_STYLES` are plain Blizzard atlas name references
  (Modern Circle/Styled/Classic Circle/Classic/Blizzard Default) — nothing to embed, no
  license concern, since the atlas art lives in the game client, not in any addon's
  files. Its other 2 styles ("modern", EUI's actual default, and "blizzLight") point at
  EUI's own custom PNGs, not reproduced here since EUI's license is all-rights-reserved
  (unlike NDui_Plus, whose MIT-licensed role-icon media was considered and dropped once
  this module started targeting EllesmereUI specifically rather than being
  addon-agnostic). Selecting a style applies live, no reload needed.
