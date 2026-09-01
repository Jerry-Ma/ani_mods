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
    title       = "My Feature",              -- optional, defaults to the registered name
    description = "One-line summary shown in the status panel.",

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

If a module needs its own configurable options beyond the standard enable/disable
toggle, just build them the normal way inside `Enable()` (its own mini settings frame,
a slash command, whatever fits) — there's no generic options-widget framework here on
purpose. For one addon with one module so far, that would be indirection with no
payoff; add one if/when a module actually needs it.

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
- **Right** — the selected module's full title, state badge, description, and (if
  inactive) the reason why, with enough width to actually read it instead of
  truncating. A second enabled checkbox here mirrors the row one for convenience. If a
  module's `Enable()` threw an error (state "Failed"), a **Copy Error** button appears
  and opens a popup with the full `debug.traceback()` in a selectable text box
  (Ctrl+A/Ctrl+C) — not just the one-line `pcall` message.

The panel is plain `CreateFrame` + standard Blizzard XML templates
(`UIPanelScrollFrameTemplate`, `UIPanelButtonTemplate`, `UIPanelCloseButton`) styled
with a flat dark backdrop and a gold accent — deliberately self-contained, no embedded
third-party UI library, so there's nothing to go stale if some other addon that
happened to ship one gets removed/updated by CurseForge.

## Commands

`/animods` (or the shorter `/ani`):

- `/ani` — open the status panel
- `/ani list` — print module states to chat
- `/ani enable <name>` / `/ani disable <name>` — toggle a module (takes effect after
  `/reload`)

## Current modules

- **ChatContextSwitch** — cycle chat channel (SAY → PARTY → RAID → INSTANCE_CHAT →
  GUILD → OFFICER → world CHANNEL) with Tab / Shift+Tab in the chat edit box. Ported
  from NDui's chat module (`NDui/Modules/Chat/Core.lua`); only active when NDui is not
  loaded, since NDui already provides this itself. Migrated from the standalone
  ChatContextSwitch addon (now removed). Half-baked / not fully tested — bugs may
  remain from the original.
- **RaidComposition** — small movable Tank/Healer/DPS count bar, shown while in a
  group. EllesmereUI's QoL Raid Tools panel has no composition display the way NDui's
  raid tool does, so this fills the gap; only active when EllesmereUIQoL is loaded and
  NDui is not. A standalone frame rather than something injected into EllesmereUI's
  secure Raid Tools shells (taint risk, fragile across EUI updates) — same approach
  NDui itself uses. Counts via `UnitGroupRolesAssigned()` per group-unit token, not a
  port of NDui's `GetRaidRosterInfo` roster-scanning logic — more direct/native, no
  manual online/dead/subgroup filtering needed.
