---@meta
--
-- Foreign globals AniMods reads, declared for the Lua Language Server.
--
-- AniMods deliberately reaches into other addons' globals (that is most of
-- what it does), always through `_G.Name` and always guarded, so a missing
-- one degrades instead of erroring. LuaLS can't know those exist, so without
-- this file every such read is an "undefined field" warning -- and a checker
-- that cries wolf on the addon's core idiom is a checker nobody reads.
--
-- This file is NOT loaded by the game. It is a definitions-only stub
-- (`---@meta`), referenced via workspace.library in .luarc.json, and it is
-- excluded from the .toc.
--
-- Types are deliberately loose (`any`). These are foreign, undocumented,
-- version-dependent objects; pretending to know their shape would be
-- inventing a contract that nothing enforces. The point here is only "this
-- global legitimately exists at runtime", not "here is its API".

---EllesmereUI's main addon namespace. AniMods uses its exported UI
---primitives (MakeBorder, PanelPP, MakeFont, GetAccentColor, ...) via
---Widgets.lua, which is the single place allowed to touch it.
---@type any
EllesmereUI = nil

---EllesmereUIQoL's Raid Tools collapsed-icon button. GroupRoles docks its
---badge under this. Only exists once Raid Tools has been built with a
---non-"never" mode, so every use is nil-guarded.
---@type any
EllesmereUIRaidToolsIcon = nil

---Read-only getter EllesmereUIQoL_RaidTools.lua exposes for its own options
---panel; returns its DB table. Used to report the configured Raid Tools mode.
---@type any
_EUI_RaidTools_DB = nil

---EllesmereUIBlizzardSkin's own Equipment tab button on the character sheet.
---Its skin overlays Blizzard's EquipmentManagerPane with a gear-sets panel of
---its own, so clicking this button -- not PaperDollSidebarTab3 -- is what
---switches that sheet to the equipment view. GearSync's right-click uses it
---when the skin built one and Blizzard's tab when it did not.
---@type any
EUI_CharSheet_Equipment = nil

---EllesmereUI's SAVED VARIABLE table, not its namespace (that is
---`EllesmereUI`). AutoCombatLog reads and writes EllesmereUIDB.autoLogging to
---switch EllesmereUIQoL's own auto-logging on.
---@type any
EllesmereUIDB = nil

---Re-sync hook EllesmereUIQoL_AutoLogging.lua publishes for its own options
---pane: it re-registers the zone events and applies the logging state
---immediately. AutoCombatLog calls it after flipping the setting, which is what
---makes switching on mid-instance start the log rather than wait for a zone.
---@type any
_EUI_AutoLogging_Check = nil

---ElvUI's LibStub-style handle, which EllesmereUI and its plugins share:
---ElvUI[1] is the `E` namespace. ShiftFocus reads
---E.private.WT.unitFrames.quickFocus.enable to stand down when
---EllesmereUI_WindTools' Quick Focus is on -- the setting rather than the
---addon's presence, so WindTools installed with that feature off is fine.
---@type any
ElvUI = nil

---MRT's addon namespace, published by its core.lua as both GMRT and GExRT (the
---table itself is otherwise private). AutoCombatLog reaches GMRT.A.AutoLogging
---to start MRT's logging module, since MRT reads its own enable flag only once
---at ADDON_LOADED.
---@type any
GMRT = nil

---MRT's SAVED VARIABLE table, distinct from the GMRT namespace. AutoCombatLog
---sets VMRT.Logging.enabled so the choice survives a reload.
---@type any
VMRT = nil

---NDui's addon namespace. Several modules check it to stay out of NDui's way
---when it already provides the same behaviour.
---@type any
NDui = nil

---Northern Sky Raid Tools' SAVED VARIABLE table, not its addon namespace (that
---is `NorthernSkyRaidTools`). NSRTMisc walks NSRT.EncounterAlerts to batch-edit
---boss alert settings, and reads it defensively at every level: it is another
---addon's saved data, so it has to survive that addon's upgrades, migrations
---and profile imports.
---@type any
NSRT = nil

---BigWigs' addon namespace. NSRTMisc uses GetPlugin("Countdown") to read which
---countdown voice the player has selected.
---@type any
BigWigs = nil

---BigWigs' public API table, separate from its namespace. Colon-defined:
---BigWigsAPI:GetCountdownSound(id, n) returns the file a voice pack uses for n
---seconds, and a dot call silently returns nil instead.
---@type any
BigWigsAPI = nil

---EXBoss' addon namespace. NSRTMisc calls ExBoss.Voice.Countdown:TryPlayDigit,
---which plays a digit through whichever voice pack EXBoss currently has
---selected -- it resolves the pack, its per-digit switches and any
---LibSharedMedia override itself.
---@type any
ExBoss = nil

---Northern Sky Raid Tools' internal namespace, published by its own core as
---`_G.NorthernSkyRaidTools = NSI`. Distinct from both NSRT (its saved variable)
---and NSAPI (its public API). NSRTMisc hooks NSI:CountdownNoteFrame and
---NSI:UpdateNoteFrame to box the live reminder line, and reads the note frames
---it hangs off itself -- NorthernSkyRaidTools_UI hooks the same table the same
---way, so this is the addon's own idiom.
---@type any
NorthernSkyRaidTools = nil

---Northern Sky Raid Tools' public API table, distinct from its NSRT saved
---variable. NSRTMisc replaces NSAPI.TTSCountdown -- but only once a non-NSRT
---countdown voice has been chosen.
---@type any
NSAPI = nil

---Talent Loadout Manager's public API table. TalentLoadouts uses
---TalentLoadoutManagerAPI.GlobalAPI to enumerate loadouts, read Blizzard export
---strings for them and import them back. Deliberately the API rather than
---TalentLoadoutManagerDB: the API asserts its arguments and is a documented
---contract, while the saved table is private and reshapes between releases.
---@type any
TalentLoadoutManagerAPI = nil

---Not a Blizzard API: a convention that addons reshaping the minimap define,
---returning a shape name ("ROUND", "SQUARE", "TRICORNER-TOPLEFT", ...).
---LibDBIcon reads it and so does General's minimap button, both guarded --
---absent means round.
---@type any
GetMinimapShape = nil

-- ---------------------------------------------------------------------------
-- Superseded Blizzard globals, kept as guarded fallbacks
-- ---------------------------------------------------------------------------
-- These are NOT present on current retail -- that is why the WoW API
-- annotations, which are generated from a live retail client, don't carry
-- them. They are declared here only so the guarded fallback paths that call
-- them stop being flagged. Every one is behind an `if` or an `or`, with the
-- modern equivalent tried first, so their absence is the expected case.
--
-- If any of these ever becomes the ONLY path to something, that is a bug:
-- the modern call has been dropped and this addon is relying on a global the
-- client no longer defines.

---Pre-10.0 sound restart. SoundSwitch tries Sound_GameSystem_RestartSoundSystem
---first and only falls back to this.
---@type any
AudioOptionsFrame_AudioRestart = nil

---Pre-10.0 addon query. Core.lua prefers C_AddOns.IsAddOnLoaded.
---@type any
IsAddOnLoaded = nil

---Pre-10.0 addon metadata. Core.lua prefers C_AddOns.GetAddOnMetadata.
---@type any
GetAddOnMetadata = nil
