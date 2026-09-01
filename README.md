# AniMods

Ani's personal collection of small WoW UI patches and QoL tweaks. This is the landing
spot for one-off ideas cherry-picked from other addons (or written from scratch) that
don't warrant their own standalone addon.

Personal/local use — not published to CurseForge.

---

## Structure

Each feature is a self-contained module under `Modules\`, registered with
`Core.lua`'s tiny module registry:

```lua
local MyFeature = {}

function MyFeature:Enable()
    -- hook stuff, create frames, etc.
end

AniMods.RegisterModule("MyFeature", MyFeature)
```

Add the new file to `AniMods.toc` (after `Core.lua`) to load it.

Modules are enabled by default. Most WoW UI hooks can't be cleanly undone at runtime,
so there's no `Disable()` — toggling a module off just skips its `Enable()` next
login/reload.

## Commands

- `/animods` or `/animods list` — list modules and their enabled state
- `/animods enable <name>` / `/animods disable <name>` — toggle a module (takes effect
  after `/reload`)

## Current modules

- **ChatContextSwitch** — cycle chat channel (SAY → PARTY → RAID → INSTANCE_CHAT →
  GUILD → OFFICER → world CHANNEL) with Tab / Shift+Tab in the chat edit box. Migrated
  from the standalone ChatContextSwitch addon. Half-baked / not fully tested — bugs may
  remain from the original.
