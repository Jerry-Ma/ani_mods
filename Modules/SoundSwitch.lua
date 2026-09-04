-- SoundSwitch
-- Switch the game's sound output device from a databar: left-click cycles to
-- the next device, right-click opens this module's tab to choose which
-- devices are in the cycle.
--
-- The core is lifted from SoundManager (by Zax), reduced to just the
-- switching part -- that addon also does per-device volume presets, its own
-- movable frame, and keybinds, none of which are wanted here. Only Blizzard
-- API is used, so this needs nothing installed:
--
--   Sound_GameSystem_GetNumOutputDrivers()            -- driver count
--   Sound_GameSystem_GetOutputDriverNameByIndex(i)    -- driver name
--   CVar Sound_OutputDriverIndex                      -- the active driver
--   Sound_GameSystem_RestartSoundSystem()             -- apply the change
--
-- Two details worth keeping from SoundManager, both of which its comments
-- call out and neither of which is obvious:
--   * The LAST driver is a "system default" pseudo-device rather than a real
--     output, so it is left out of the cycle (its loop runs to count-1).
--   * Driver INDICES go stale when the OS adds or removes an output, so
--     settings are keyed by device NAME and indices are re-read fresh at the
--     moment of switching, never stored.

local SoundSwitch = {
    title = "Sound Switch",
    description = "Switch sound output device from a databar. Left-click cycles, right-click opens this tab.",
    dependencies = {
        -- No `met`: purely informational, nothing to check.
        { text = "None -- uses Blizzard's own sound output API" },
    },
}

local Broker = AniMods.Broker

local ldbObject
local lastKnownDevice

local function ModuleDB()
    AniModsDB.soundSwitch = AniModsDB.soundSwitch or {}
    return AniModsDB.soundSwitch
end

local function DeviceDB()
    local db = ModuleDB()
    db.devices = db.devices or {}
    return db.devices
end

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

local function GetDevices()
    local out = {}
    local count = Sound_GameSystem_GetNumOutputDrivers and Sound_GameSystem_GetNumOutputDrivers() or 0
    -- count - 1: the final entry is the system-default pseudo-device.
    for i = 1, count - 1 do
        local name = Sound_GameSystem_GetOutputDriverNameByIndex(i)
        if name and name ~= "" then
            out[#out + 1] = { index = i, name = name }
        end
    end
    return out
end

local function CurrentDeviceName()
    local raw = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar("Sound_OutputDriverIndex")
    local idx = tonumber(raw)
    if not idx or not Sound_GameSystem_GetOutputDriverNameByIndex then return nil end
    return Sound_GameSystem_GetOutputDriverNameByIndex(idx)
end

-- Keyed by name, not index, and defaulting to in-cycle so a newly plugged-in
-- device participates without needing to be found in the options first.
local function IsInCycle(name)
    local v = DeviceDB()[name]
    if v == nil then return true end
    return v
end

local function SetInCycle(name, enabled)
    DeviceDB()[name] = enabled and true or false
end

local function SwitchToIndex(index)
    C_CVar.SetCVar("Sound_OutputDriverIndex", index)
    -- RestartSoundSystem is the modern call; AudioOptionsFrame_AudioRestart
    -- is the pre-10.0 one SoundManager still falls back to.
    if not pcall(Sound_GameSystem_RestartSoundSystem) then
        if AudioOptionsFrame_AudioRestart then AudioOptionsFrame_AudioRestart() end
    end
end

-- Returns the next in-cycle device after the current one, wrapping; or nil
-- plus a reason.
local function NextDevice()
    local cycle = {}
    for _, device in ipairs(GetDevices()) do
        if IsInCycle(device.name) then cycle[#cycle + 1] = device end
    end
    if #cycle == 0 then
        return nil, "every device is excluded from the cycle"
    end

    local current = CurrentDeviceName()
    local at = 0
    for i, device in ipairs(cycle) do
        if device.name == current then at = i break end
    end
    -- at == 0 (current device not in the cycle) lands on the first entry;
    -- at == #cycle wraps back to it.
    return cycle[(at % #cycle) + 1]
end

-- ---------------------------------------------------------------------------
-- Broker
-- ---------------------------------------------------------------------------

-- Verified present in DandersFrames_Options' atlas browser list; the
-- chatframe-button-icon-speaker name that reads as the obvious guess does
-- not exist.
local SPEAKER_ATLAS = "voicechat-icon-speaker"

local function UpdateBroker()
    if not ldbObject then return end
    local name = CurrentDeviceName()
    lastKnownDevice = name
    ldbObject.text = Broker.BuildText(ModuleDB, {
        { text = name or "Unknown", atlas = SPEAKER_ATLAS },
    })
end

local function SwitchNext()
    local device, reason = NextDevice()
    if not device then
        UIErrorsFrame:AddMessage("AniMods: " .. (reason or "no device to switch to"), 1, 0.3, 0.3, 1)
        return
    end
    SwitchToIndex(device.index)
    UpdateBroker()
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

local function ShowTooltip(tt)
    local current = CurrentDeviceName()
    tt:AddLine("Sound Output", 1, 0.82, 0)

    local devices = GetDevices()
    if #devices == 0 then
        tt:AddLine("No output devices reported", 0.6, 0.6, 0.6)
        return
    end

    for _, device in ipairs(devices) do
        local isCurrent = (device.name == current)
        local inCycle = IsInCycle(device.name)
        local mark = isCurrent and "> " or "   "
        local r, g, b
        if isCurrent then
            r, g, b = 0.35, 1, 0.35
        elseif inCycle then
            r, g, b = 1, 1, 1
        else
            r, g, b = 0.5, 0.5, 0.5
        end
        tt:AddDoubleLine(mark .. device.name, inCycle and "" or "skipped", r, g, b, 0.5, 0.5, 0.5)
    end

    tt:AddLine(" ")
    tt:AddLine("Left-click: next device", 0.6, 0.6, 0.6)
    tt:AddLine("Right-click: settings", 0.6, 0.6, 0.6)
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsSoundSwitch", {
        label = "AniMods: Sound Switch",
        OnClick = function(frame, button)
            if button == "LeftButton" then
                SwitchNext()
            elseif AniMods.OpenModuleTab then
                AniMods.OpenModuleTab("SoundSwitch")
            end
        end,
        OnTooltipShow = ShowTooltip,
    })
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function SoundSwitch:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = { label = "Current device", value = CurrentDeviceName() or "Unknown" }
    rows[#rows + 1] = { label = "Broker (LDB) plugin", value = ldbObject and "Registered" or "Not available" }

    rows[#rows + 1] = { section = "Devices in the cycle" }
    local devices = GetDevices()
    if #devices == 0 then
        rows[#rows + 1] = { label = "Devices", value = "None reported" }
    else
        local current = CurrentDeviceName()
        for _, device in ipairs(devices) do
            local name = device.name
            rows[#rows + 1] = {
                label = name,
                get   = function() return IsInCycle(name) end,
                set   = function(v) SetInCycle(name, v) end,
                note  = (name == current) and "current" or nil,
            }
        end
    end

    for _, row in ipairs(Broker.DisplayRows(ModuleDB, UpdateBroker)) do
        rows[#rows + 1] = row
    end

    return rows
end

function SoundSwitch:Enable()
    InitLDB()
    UpdateBroker()

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- CVAR_UPDATE is how SoundManager notices the output being changed from
    -- outside (the OS, Blizzard's own audio options, another addon). Cheaper
    -- than matching the cvar name, whose casing in the payload isn't worth
    -- relying on: re-read the device and only push an update when it actually
    -- differs from what's displayed.
    eventFrame:RegisterEvent("CVAR_UPDATE")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "CVAR_UPDATE" and CurrentDeviceName() == lastKnownDevice then return end
        UpdateBroker()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)
end

AniMods.RegisterModule("SoundSwitch", SoundSwitch)
