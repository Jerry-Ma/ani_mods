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

`/animods` opens the status panel: a two-pane layout, left list / right detail (same
idea as AutoItemMacro's preset editor).

- **Left** — every registered module, one row each: a colored status dot (active /
  inactive-by-condition / disabled / failed), the module name, and a checkbox to
  enable/disable it right there. Click a row to select it.
- **Right** — the selected module's full title, state badge, description, an
  always-visible "Depends on:" line (its `dependencies` field — what it needs,
  regardless of whether that's currently satisfied), and (if inactive) the reason why,
  with enough width to actually read it instead of truncating; below that, its
  `GetInfoRows()` (see above) in a scrollable, DetailsFramework-rendered area (see
  below); at the bottom, an enabled checkbox mirroring the row one. If a module's
  `Enable()` threw an error (state "Failed"), a **Show Error** button appears and opens
  a popup with the full traceback (message + `debugstack()`) in a selectable text box
  (Ctrl+A/Ctrl+C) — not just the one-line `pcall` message. (WoW's addon sandbox doesn't
  expose the `debug` table at all — only specific whitelisted globals like
  `debugstack()`, which is what this actually uses.)

The chrome (main panel, left module list, header, bottom controls, the copy-error
popup) is plain `CreateFrame` + standard Blizzard XML templates, styled with a flat
dark backdrop and a gold accent. That part matches how NorthernSkyRaidTools's own
options window builds its sidebar — hand-rolled, not a library widget.

The `GetInfoRows()` content area, though, is rendered with **DetailsFramework**
(`DF:BuildMenuVolatile`) — matching how NSRT builds its own *content* pages
(`DF:BuildMenu`). That's the part that had gotten genuinely cluttered as hand-rolled
22px rows once a module accumulated several sections' worth of status + options; real
DF widgets read cleaner at that density. `BuildMenuVolatile` specifically (not plain
`BuildMenu`, which is "set in stone") because a module's row count can change between
refreshes — e.g. RaidComposition shows fewer status rows solo than grouped —
and `BuildMenuVolatile` is DF's own pooled/rebuild-friendly variant for exactly that.

DetailsFramework is bundled in `Libs\DF` (copied from `Details/Libs/DF`,
LGPL-2.1-or-later — see `Libs\DF\LICENSE`) plus `Libs\LibStub`, loaded via the `.toc`
before `Core.lua`/`UI.lua` — **not** relied on from NSRT or Details being installed.
LibStub's own version-gated `NewLibrary` means this coexists safely if either of those
also happen to be installed (whichever copy loads first wins; the rest no-op), but
AniMods works without them.

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
    `SetPoint` (just reads its rect) and synced via `hooksecurefunc(iconBtn,
    "Show"/"Hide", ...)`, which reliably fires even though EUI's own visibility runs
    through a secure `SecureHandlerStateTemplate` snippet — plus a 1-second resync
    ticker as a belt-and-suspenders backstop, since a badge that silently stops
    tracking the icon's actual visibility is worse than one that costs an extra cheap
    `IsShown()` check every second. No taint risk (never touches EUI's secure frames,
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
