-- AutoCombatLog
-- Makes sure combat logging is running for the content worth logging.
--
-- Three addons in this folder already solve this, and the answer is not to be a
-- fourth: whoever the player already trusts with it should keep doing it, and
-- this only has to make sure the switch is ON. So it resolves a BACKEND and
-- defers to it, in the order the player would pick themselves:
--
--   EllesmereUI   EllesmereUIQoL_AutoLogging.lua, driven by
--                 EllesmereUIDB.autoLogging and re-synced through the global
--                 _EUI_AutoLogging_Check it publishes for its own options pane.
--   MRT           MRT/AutoLogging.lua, VMRT.Logging plus the module object at
--                 GMRT.A.AutoLogging (core.lua publishes GMRT/GExRT; the rest
--                 of the addon's table is private).
--   AniMods       The port below, used only when neither is there.
--
-- Exactly one of them may run, and that is ENFORCED rather than assumed. Two
-- owners both answering a zone change is not twice as reliable: MRT stops a log
-- whenever its own last decision was "log" and the new zone's is "don't", and
-- it neither knows nor cares who started the log it is stopping. Whichever
-- fires last wins, which is a coin toss rather than a setting.
--
-- So the port registers no events at all unless it is the chosen backend, AND
-- every other logger that is switched on gets switched off -- including one
-- this module never switched on, which is the case that matters, since these
-- are addons the player configured themselves. What was switched off is
-- remembered and put back when this module is disabled: turning off someone
-- else's setting is only defensible if it is undone the moment we stop being
-- responsible for the decision. Their own trigger settings are never touched,
-- only the master switch.
--
-- The port follows EllesmereUIQoL's version, which is itself the shape MRT
-- established. Its thresholds are the load-bearing part and are NOT guesses:
-- instance map IDs are not chronological, so a plain "newer than" cut wrongly
-- excludes current raids that reuse a low ID -- which is why there is a
-- whitelist beside the threshold rather than just a bigger number.

local AniMods = _G.AniMods

local AutoCombatLog = {
    title = "Auto Combat Log",
    description = "Keeps combat logging on for the content worth logging.",
    dbKey = "autoCombatLog",
    -- No conditions. The point is to work under whichever logger is present,
    -- including none; the backend is resolved at runtime instead.
}

local moduleEnabled = true

local function ModuleDB()
    AniModsDB.autoCombatLog = AniModsDB.autoCombatLog or {}
    return AniModsDB.autoCombatLog
end

-- ---------------------------------------------------------------------------
-- Advanced combat logging
-- ---------------------------------------------------------------------------

-- Every backend wants this, and none of them own it: it is a CVar, not a
-- setting of theirs. A log without it is missing the fields every analysis site
-- reads, so it is switched on whenever anything here runs.
local function AdvancedLoggingOn()
    return _G.C_CVar.GetCVar("advancedCombatLogging") == "1"
end

local function EnsureAdvancedLogging()
    if not AdvancedLoggingOn() then
        _G.C_CVar.SetCVar("advancedCombatLogging", "1")
    end
end

-- ---------------------------------------------------------------------------
-- The port
-- ---------------------------------------------------------------------------

-- Content below these is excluded unless it is named in one of the lists that
-- follow. Copied from EllesmereUIQoL, which has them from MRT.
local RETAIL_RAID_THRESHOLD    = 2657
local RETAIL_DUNGEON_THRESHOLD = 959

-- Old dungeons still in the Mythic+ pool, so still worth a log.
local LEGACY_DUNGEON_IDS = {
    [1594] = true, -- MOTHERLODE!!
    [1208] = true, -- Grimrail Depot
    [1195] = true, -- Iron Docks
    [1651] = true, -- Return to Karazhan
    [657]  = true, -- The Vortex Pinnacle
    [643]  = true, -- Throne of the Tides
    [670]  = true, -- Grim Batol
    [658]  = true, -- Pit of Saron
}

-- Current raids whose map ID falls BELOW the raid threshold. This list is the
-- reason the threshold works at all: IDs are reused, so Sporefall at 1592 sits
-- under legacy raids and the cut alone would drop the current tier.
local CURRENT_RAID_IDS = {
    [1592] = true, -- Sporefall
}

local LFR_DIFFICULTIES = { [7] = true, [17] = true }

-- 233 is the flexible Mythic id current raids use alongside the fixed-20 16.
local RAID_DIFF_KEYS = {
    [16]  = "logMythic",
    [233] = "logMythic",
    [15]  = "logHeroic",
    [14]  = "logNormal",
}

-- Everything but scenarios, matching EllesmereUIQoL's defaults.
local TRIGGER_DEFAULTS = {
    logMythic   = true,
    logHeroic   = true,
    logNormal   = true,
    logLFR      = true,
    log5pp      = true,
    logArena    = true,
    logScenario = false,
    delayStop   = true,
}

local TRIGGER_ROWS = {
    { key = "logMythic",   label = "Raid: Mythic" },
    { key = "logHeroic",   label = "Raid: Heroic" },
    { key = "logNormal",   label = "Raid: Normal" },
    { key = "logLFR",      label = "Raid: Looking For Raid" },
    { key = "log5pp",      label = "Mythic and Mythic+ dungeons" },
    { key = "logArena",    label = "Arenas" },
    { key = "logScenario", label = "Group scenarios" },
}

local function Trigger(key)
    local v = ModuleDB()[key]
    if v == nil then return TRIGGER_DEFAULTS[key] end
    return v and true or false
end

local function ZoneShouldBeLogged()
    local _, zoneType, rawDiff, _, playerCap, _, _, rawMapID = _G.GetInstanceInfo()
    local diff  = tonumber(rawDiff)
    local mapID = tonumber(rawMapID)
    if not diff or not mapID then return false end

    if LFR_DIFFICULTIES[diff] then
        return Trigger("logLFR")
    end

    if zoneType == "raid" and (mapID >= RETAIL_RAID_THRESHOLD or CURRENT_RAID_IDS[mapID]) then
        local key = RAID_DIFF_KEYS[diff]
        if key then return Trigger(key) end
        -- Timewalking and anything else unrecognised: log it. An unknown raid
        -- difficulty is far more likely to be new content than something not
        -- worth recording.
        return true
    end

    if Trigger("log5pp") then
        local isMythicDungeon = (diff == 23 or diff == 8) -- 23 = keystone, 8 = Mythic
        local isRetailDungeon = mapID >= RETAIL_DUNGEON_THRESHOLD or LEGACY_DUNGEON_IDS[mapID]
        if isMythicDungeon and isRetailDungeon then return true end
    end

    if Trigger("logScenario") and zoneType == "scenario"
       and (tonumber(playerCap) or 0) > 1
       and mapID >= RETAIL_DUNGEON_THRESHOLD then
        return true
    end

    if Trigger("logArena") and (zoneType == "arena" or zoneType == "ratedarena") then
        return true
    end

    return false
end

-- Stopping is delayed so the log keeps the tail of the fight: leaving the
-- instance is what ends the pull for the player, not for the encounter.
local STOP_DELAY_SECONDS = 30

local portWasLogging = false
local portStopTimer
local portFrame
local portArmed = false

local function CancelStopTimer()
    if portStopTimer then
        portStopTimer:Cancel()
        portStopTimer = nil
    end
end

local function ApplyPortState()
    if not portArmed then return end

    local shouldLog = ZoneShouldBeLogged()
    if shouldLog then
        CancelStopTimer()
        EnsureAdvancedLogging()
        _G.LoggingCombat(true)
    elseif portWasLogging and _G.LoggingCombat() then
        -- Only stops a log this module started. Someone who typed /combatlog
        -- themselves keeps it.
        if Trigger("delayStop") then
            if not portStopTimer then
                portStopTimer = _G.C_Timer.NewTimer(STOP_DELAY_SECONDS, function()
                    portStopTimer = nil
                    if _G.LoggingCombat() then _G.LoggingCombat(false) end
                end)
            end
        else
            _G.LoggingCombat(false)
        end
    end
    portWasLogging = shouldLog
end

-- Both delays are the source's. The zone is not settled the instant the event
-- fires -- GetInstanceInfo still answers for where you were -- and a keystone
-- starts faster than a zone change completes.
local PORT_EVENTS = {
    ZONE_CHANGED_NEW_AREA = 2,
    CHALLENGE_MODE_START  = 1,
    PLAYER_ENTERING_WORLD = 2,
}

local function ArmPort(on)
    if on == portArmed then return end
    portArmed = on

    if not on then
        CancelStopTimer()
        if portFrame then portFrame:UnregisterAllEvents() end
        portWasLogging = false
        return
    end

    if not portFrame then
        portFrame = _G.CreateFrame("Frame")
        portFrame:SetScript("OnEvent", function(_, event)
            local delay = PORT_EVENTS[event]
            if delay then _G.C_Timer.After(delay, ApplyPortState) end
        end)
    end
    for event in pairs(PORT_EVENTS) do portFrame:RegisterEvent(event) end
    _G.C_Timer.After(2, ApplyPortState)
end

-- ---------------------------------------------------------------------------
-- Backends
-- ---------------------------------------------------------------------------

local function EUIConfig()
    local db = _G.EllesmereUIDB
    if type(db) ~= "table" then return nil end
    if type(_G._EUI_AutoLogging_Check) ~= "function" then return nil end
    db.autoLogging = db.autoLogging or {}
    return db.autoLogging
end

local function MRTParts()
    local mrt = _G.GMRT
    if type(mrt) ~= "table" or type(mrt.A) ~= "table" then return nil end
    local mod = mrt.A.AutoLogging
    if type(mod) ~= "table" or type(mod.Enable) ~= "function" then return nil end
    local vmrt = _G.VMRT
    if type(vmrt) ~= "table" then return nil end
    vmrt.Logging = vmrt.Logging or {}
    return mod, vmrt.Logging
end

local BACKENDS = {
    {
        name = "EllesmereUI",
        detail = "EllesmereUIQoL's own auto-logging, switched on and re-synced "
              .. "through the check function it publishes for its options pane.",
        Available = function() return EUIConfig() ~= nil end,
        IsOn = function()
            local c = EUIConfig()
            return c and c.enabled and true or false
        end,
        SetOn = function(on)
            local c = EUIConfig()
            if not c then return false end
            c.enabled = on and true or false
            -- Re-syncs event registration AND applies the state immediately, so
            -- switching on mid-instance starts the log rather than waiting for
            -- the next zone.
            _G._EUI_AutoLogging_Check()
            return true
        end,
    },
    {
        name = "MRT",
        detail = "MRT's Logging module, switched on through VMRT.Logging and "
              .. "started through the module object MRT publishes as GMRT.",
        Available = function() return (MRTParts()) ~= nil end,
        IsOn = function()
            local _, cfg = MRTParts()
            return cfg and cfg.enabled and true or false
        end,
        SetOn = function(on)
            local mod, cfg = MRTParts()
            if not (mod and cfg) then return false end
            -- MRT reads this flag once, at its own ADDON_LOADED, which is long
            -- past by the time this runs -- so writing it is not enough on its
            -- own and the module has to be told. Enable() registers its zone
            -- events and evaluates the current zone straight away.
            if on then
                cfg.enabled = true
                mod:Enable()
            else
                cfg.enabled = nil
                if type(mod.Disable) == "function" then mod:Disable() end
            end
            return true
        end,
    },
    {
        name = "AniMods",
        detail = "The port in this module, used when no other logger is here to "
              .. "do it.",
        Available = function() return true end,
        IsOn = function() return portArmed end,
        SetOn = function(on) ArmPort(on) return true end,
    },
}

-- First available wins. The order is the point of the module: a logger the
-- player already configured knows which difficulties they care about, and
-- replacing that with our defaults would be a downgrade dressed as a feature.
local function ActiveBackend()
    for _, backend in ipairs(BACKENDS) do
        if backend.Available() then return backend end
    end
    return nil
end

local applied   -- the backend this module switched on
-- Backends this module switched OFF, by name. Recorded rather than forgotten
-- so switching this module off puts them back: turning off someone else's
-- setting is only defensible if it is undone when we stop being responsible
-- for the decision.
local standDown = {}

local function BackendByName(name)
    for _, b in ipairs(BACKENDS) do
        if b.name == name then return b end
    end
    return nil
end

local function RestoreStoodDown()
    for name in pairs(standDown) do
        local b = BackendByName(name)
        if b and b.Available() then b.SetOn(true) end
        standDown[name] = nil
    end
end

local function Apply()
    local backend = ActiveBackend()

    if not moduleEnabled then
        if applied then
            applied.SetOn(false)
            applied = nil
        end
        RestoreStoodDown()
        return
    end

    -- A backend that used to be the active one must be stood down before the
    -- new one starts, or both are armed at once.
    if applied and applied ~= backend then
        applied.SetOn(false)
        applied = nil
    end

    if not backend then return end

    -- Every OTHER logger is switched off, including one this module never
    -- turned on. That is the part the first version left out, and it made the
    -- module's own promise false: with MRT's auto-logging on beside
    -- EllesmereUI's, both answer ZONE_CHANGED_NEW_AREA, and MRT stops a log
    -- whenever its own last decision was "log" and the new zone's is "don't" --
    -- it does not know or care who started the one it is stopping. Two owners
    -- is not redundancy, it is whichever fires last, which is a coin toss
    -- rather than a setting. Being switched on is what has to be exclusive,
    -- not just being chosen.
    for _, b in ipairs(BACKENDS) do
        if b ~= backend and b.Available() and b.IsOn() then
            b.SetOn(false)
            standDown[b.name] = true
        end
    end
    -- The chosen one is not a stand-down candidate any more, whatever it was
    -- before -- otherwise disabling this module would switch it back on twice.
    standDown[backend.name] = nil

    EnsureAdvancedLogging()
    backend.SetOn(true)
    applied = backend
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function AutoCombatLog:GetInfoRows()
    local rows = {}
    local backend = ActiveBackend()

    rows[#rows + 1] = { section = "Backend" }
    rows[#rows + 1] = {
        label = "In use",
        value = backend and backend.name or "none",
        help  = backend and backend.detail or nil,
    }
    rows[#rows + 1] = {
        label = "Switched on",
        state = backend and backend.IsOn() or false,
        help  = "Whether the backend's own auto-logging setting is on. This "
             .. "module turns it on and keeps it there while it is enabled.",
    }

    rows[#rows + 1] = { section = "Right now" }
    rows[#rows + 1] = {
        label = "Logging",
        state = _G.LoggingCombat() and true or false,
        help  = "Whether the game is writing WoWCombatLog.txt this moment. Off "
             .. "outside the content you chose is the correct answer.",
    }
    rows[#rows + 1] = {
        label = "Advanced combat logging",
        state = AdvancedLoggingOn(),
        help  = "A CVar, not a setting of any logger -- without it the log is "
             .. "missing the fields every analysis site reads. Switched on "
             .. "whenever this module runs.",
    }

    -- Only the port's own triggers, and only when the port is what is running:
    -- these settings do nothing while EllesmereUI or MRT owns the decision, and
    -- a row that does nothing is worse than no row.
    if backend and backend.name == "AniMods" then
        rows[#rows + 1] = { section = "What to log" }
        for _, row in ipairs(TRIGGER_ROWS) do
            rows[#rows + 1] = {
                label = row.label,
                get   = function() return Trigger(row.key) end,
                set   = function(v) ModuleDB()[row.key] = v and true or false; ApplyPortState() end,
            }
        end
        rows[#rows + 1] = {
            label = "Keep logging for 30s after leaving",
            get   = function() return Trigger("delayStop") end,
            set   = function(v) ModuleDB().delayStop = v and true or false end,
            help  = "Leaving the instance ends the pull for you, not for the "
                 .. "encounter. The delay keeps the tail of the fight in the log.",
        }
    end

    -- What each logger IS DOING, not merely whether it exists. The first
    -- version reported availability here, which read as three reassuring
    -- "Yes" rows while a second logger was quietly armed beside the chosen
    -- one -- the exact state this section should have made obvious.
    rows[#rows + 1] = { section = "Loggers" }
    for _, b in ipairs(BACKENDS) do
        local value, help
        if not b.Available() then
            value = "not installed"
            help  = b.detail
        elseif b == backend then
            value = b.IsOn() and "in use" or "chosen, not yet on"
            help  = b.detail
        elseif standDown[b.name] then
            value = "switched off"
            help  = "Its auto-logging was on, and two loggers both answering a "
                 .. "zone change is whichever fires last rather than a setting "
                 .. "-- one of them will stop a log the other started. This "
                 .. "module switched it off and switches it back on if you "
                 .. "disable this module. Its own settings are untouched."
        else
            value = "off"
            help  = b.detail
        end
        rows[#rows + 1] = { label = b.name, value = value, help = help }
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AutoCombatLog:Enable()
    moduleEnabled = true
    -- Deferred: EllesmereUIQoL publishes _EUI_AutoLogging_Check and MRT builds
    -- GMRT.A during their own load, so asking at file scope answers "no logger
    -- here" and picks the port over an addon that is about to arrive.
    AniMods.W.OnReady(Apply)
end

-- Toggles live. Switching off hands the decision back: the backend's own
-- setting is turned off, so nothing here keeps logging running.
function AutoCombatLog:SetEnabled(on)
    moduleEnabled = on and true or false
    Apply()
    return true
end

AniMods.RegisterModule("AutoCombatLog", AutoCombatLog)
