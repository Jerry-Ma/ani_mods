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
    description = "Switch your sound output device.",
    -- No conditions: Blizzard's own sound output API, nothing else.
}

local Broker = AniMods.Broker

local ldbObject

-- The cvar the whole module turns on, named once: it is both what gets written
-- when switching and what CVAR_UPDATE is filtered against.
local SOUND_CVAR = "Sound_OutputDriverIndex"

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
    local raw = C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(SOUND_CVAR)
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
    C_CVar.SetCVar(SOUND_CVAR, index)
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

-- Resolved against the client rather than hard-coded: an atlas that doesn't
-- exist draws nothing at all, with no error.
--
-- Atlas first, and EllesmereUIChat's sidebar PNG dropped entirely. That file
-- was preferred once on the theory that it "matches the flat line-art the rest
-- of the panel uses" -- but the IconProbe widget put the two side by side in
-- the data bar and the line-art loses badly at 14px: thin white strokes read
-- as a scratch, where the atlas is solid filled colour like every other icon
-- on the bar. Nothing was wrong with how it rendered; it was the wrong art.
--
-- Both atlases are Blizzard-provided and measured present (32x32 and 29x29),
-- so the second is a genuine alternative rather than dead weight.
-- No EllesmereUI silhouette here: its micromenu set has no speaker, so the Icon
-- style setting has nothing to switch to for this one and both settings land on
-- the same atlas. That is the fallthrough working as intended rather than a
-- gap -- an atlas is the one thing guaranteed present.
local ICON_CANDIDATES = {
    { atlas = "voicechat-icon-speaker" },
    { atlas = "chatframe-button-icon-voicechat" },
}

-- Keyed by style: the Icon style setting changes which candidate wins, so a
-- single cached value would outlive the switch.
local resolvedIcons = {}
local function SpeakerIcon()
    local style = Broker.GetIconStyle(ModuleDB)
    if resolvedIcons[style] == nil then
        resolvedIcons[style] = AniMods.W.ResolveIcon(ICON_CANDIDATES,
            Broker.PreferredIconKind(ModuleDB)) or false
    end
    return resolvedIcons[style] or nil
end

local function UpdateBroker()
    if not ldbObject then return end
    local name = CurrentDeviceName()
    local part = { text = name or "Unknown" }
    local icon = SpeakerIcon()
    if icon then
        part.atlas   = icon.atlas
        part.texture = icon.texture
        part.coords  = icon.coords
        part.canvas  = icon.canvas
    end

    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, { part }))
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

-- Renders into EITHER AniMods' own themed popup or a plain GameTooltip.
--
-- One function, because W.Tooltip deliberately mirrors GameTooltip's AddLine /
-- AddDoubleLine signatures. The second sink is not optional: a data bar that
-- does not support the OnEnter(anchor) contract calls OnTooltipShow with its own
-- tooltip, and writing this twice is how the two renderings would drift.
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

-- The themed popup, built on first hover.
local popup

local function ShowPopup(anchor)
    popup = popup or AniMods.W.Tooltip()
    popup:Clear()
    ShowTooltip(popup)
    popup:Show(anchor)
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsSoundSwitch", {
        label = "AniMods: Sound Switch",
        OnClick = function(_, button)
            if button == "LeftButton" then
                SwitchNext()
            elseif AniMods.OpenModuleTab then
                AniMods.OpenModuleTab("SoundSwitch")
            end
        end,
        -- OnEnter takes precedence in every data bar that supports it (EUI's
        -- and AniMods' own both do), so the themed popup is what is normally
        -- seen; OnTooltipShow remains for displays that only offer that path.
        OnEnter = ShowPopup,
        OnLeave = function() if popup then popup:Hide() end end,
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

    rows[#rows + 1] = { section = "Devices in the cycle" }
    local devices = GetDevices()
    if #devices == 0 then
        rows[#rows + 1] = {
            label = "Output devices found",
            state = false,
            help  = "The game reported no sound output devices to switch between.",
        }
    else
        local current = CurrentDeviceName()
        for _, device in ipairs(devices) do
            local name = device.name
            rows[#rows + 1] = {
                label = name,
                get   = function() return IsInCycle(name) end,
                set   = function(v) SetInCycle(name, v) end,
                note  = (name == current) and "Current" or nil,
            }
        end
    end

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsSoundSwitch")) do
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
    -- outside (the OS, Blizzard's own audio options, another addon). It is also
    -- the broadest registration in this addon -- it fires for EVERY cvar -- so
    -- the handler's first job is to establish that the event is not ours, as
    -- cheaply as possible.
    --
    -- strcmputf8i is a Blizzard C function that compares case-insensitively
    -- WITHOUT building a lowered copy. That matters: the payload's casing is
    -- not worth relying on, and the obvious `cvar:lower() == "..."` would
    -- allocate a string for every unrelated cvar change just to discard it.
    -- One C compare per event, no garbage, and no dependence on casing.
    --
    -- This replaced re-reading the sound device on every cvar change and
    -- comparing it to the last known one. That was allocation-free too, but it
    -- spent two API calls to answer a question the event's own payload answers.
    eventFrame:RegisterEvent("CVAR_UPDATE")
    eventFrame:SetScript("OnEvent", function(_, event, cvar)
        if event == "CVAR_UPDATE"
            and not (cvar and strcmputf8i(cvar, SOUND_CVAR) == 0) then
            return
        end
        -- No "did it actually change" guard: the event now only reaches here
        -- for our own cvar, and Broker.SetText already declines to assign an
        -- unchanged string.
        UpdateBroker()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)
end

AniMods.RegisterModule("SoundSwitch", SoundSwitch)
