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

`/animods` opens the status panel: a list of every registered module, colored by
state (active / inactive-by-condition / disabled / failed), with the reason shown for
anything not active, and an enable/disable checkbox per module.

The panel is plain `CreateFrame` + standard Blizzard XML templates
(`UIPanelScrollFrameTemplate`, `UIPanelButtonTemplate`, `UIPanelCloseButton`) styled
with a flat dark backdrop and a gold accent — deliberately self-contained, no embedded
third-party UI library, so there's nothing to go stale if some other addon that
happened to ship one gets removed/updated by CurseForge.

## Commands

- `/animods` — open the status panel
- `/animods list` — print module states to chat
- `/animods enable <name>` / `/animods disable <name>` — toggle a module (takes effect
  after `/reload`)

## Current modules

- **ChatContextSwitch** — cycle chat channel (SAY → PARTY → RAID → INSTANCE_CHAT →
  GUILD → OFFICER → world CHANNEL) with Tab / Shift+Tab in the chat edit box. Ported
  from NDui's chat module (`NDui/Modules/Chat/Core.lua`); only active when NDui is not
  loaded, since NDui already provides this itself. Migrated from the standalone
  ChatContextSwitch addon (now removed). Half-baked / not fully tested — bugs may
  remain from the original.
