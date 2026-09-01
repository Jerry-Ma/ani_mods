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

A module can optionally expose `GetInfoRows()`, returning an ordered list of rows
rendered in its detail pane — this is the "debug + options" section every module gets
for free:

```lua
function MyFeature:GetInfoRows()
    return {
        { label = "Some live value", value = tostring(someState) },             -- status
        { label = "Include X",       get = GetX, set = SetX, note = "active now" }, -- toggle
    }
end
```

A row with `get`/`set` renders as a checkbox (for per-item options, e.g. which entries
participate in some cycle/list); anything else is a plain read-only label/value line
(for live internal state — "N/A" when not applicable is a normal `value`). Refreshed
every second while the panel is open, plus whenever a toggle changes, so it reflects
current reality, not what was true when the module loaded. This is deliberately the
one generic row shape rather than a full widget framework — extend it if a module ever
needs something `GetInfoRows()` can't express.

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
  truncating; below that, its `GetInfoRows()` (see above) in a scrollable area; at the
  bottom, an enabled checkbox mirroring the row one. If a module's `Enable()` threw an
  error (state "Failed"), a **Show Error** button appears and opens a popup with the
  full traceback (message + `debugstack()`) in a selectable text box (Ctrl+A/Ctrl+C) —
  not just the one-line `pcall` message. (WoW's addon sandbox doesn't expose the
  `debug` table at all — only specific whitelisted globals like `debugstack()`, which
  is what this actually uses.)

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
  from NDui's chat module (`NDui/Modules/Chat/Core.lua`). Each channel in the cycle can
  be individually enabled/disabled from its detail pane, which also shows which ones
  are eligible right now ("active now"). Only active when NDui is *not currently
  handling this itself* — NDui's own chat module installs the identical hook, but only
  when enabled (`C.db["Chat"]["Disable"]` is falsy); if NDui is installed with its chat
  module turned off, this still applies. Migrated from the standalone ChatContextSwitch
  addon (now removed). Half-baked / not fully tested — bugs may remain from the
  original.
- **RaidComposition** — Tank/Healer/DPS role counts while in a group; its detail pane
  shows the live counts (or "N/A" when solo). EllesmereUI's QoL Raid Tools panel has no
  composition display the way NDui's raid tool does, so this fills the gap; only active
  when EllesmereUIQoL is loaded and NDui is not.

  Docks a compact badge onto Raid Tools' own collapsed icon (the global frame
  `EllesmereUIRaidToolsIcon`) so it reads as part of that minimized display, rather
  than a separate floating thing — anchored to it (`SetPoint`, which just reads its
  rect) and synced via `hooksecurefunc(iconBtn, "Show"/"Hide", ...)`, which reliably
  fires even though EUI's own visibility runs through a secure
  `SecureHandlerStateTemplate` snippet, without touching any of EUI's secure frames
  directly (no taint risk). EllesmereUIQoL only builds that icon on first use of Raid
  Tools with a non-"never" mode ("never" is its own default), so this retries on a
  couple of login-delay timers and on `GROUP_ROSTER_UPDATE` in case it appears later;
  until/unless it does, a small movable standalone bar is the fallback. Its detail pane
  shows which mode is active ("Docked to EllesmereUI icon: Yes/No").

  Role icons use the modern `UI-LFG-RoleIcon-*-Micro` atlases by default (the legacy
  `GetTexCoordsForRoleSmallCircle()` helper no longer exists in this client), falling
  back to manual texcoords if the atlas isn't available. The detail pane also offers
  alternate icon styles borrowed from NDui_Plus's bundled media (LynUI, ElvUI-style,
  three ToxiUI variants) — read straight from NDui_Plus's texture files by path, which
  works whether or not NDui_Plus is actually enabled, so those options only appear when
  it's installed at all. Selecting one applies live, no reload needed.
