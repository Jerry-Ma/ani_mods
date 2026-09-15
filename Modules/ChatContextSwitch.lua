-- ChatContextSwitch
-- Switches the chat input context (channel) by pressing Tab in the chat edit box.
-- Ported from NDui's chat module (NDui/Modules/Chat/Core.lua, module:UpdateTabChannelSwitch)
-- -- this is a faithful reimplementation of that logic, not the original file.
--
-- Behaviour:
--   Tab        -> cycle forward through active AND enabled chat types
--   Shift+Tab  -> cycle backward
--   Either one, from a context outside the cycle (whisper, BN whisper, yell,
--   emote) -> enter at the first eligible entry. NDui only escapes a whisper
--   on Shift+Tab; plain Tab there does nothing at all, which is a dead end.
--
-- The cycle: SAY -> PARTY -> RAID -> INSTANCE_CHAT -> GUILD -> OFFICER -> (CHANNEL if in world channel) -> SAY
-- Each entry can be individually enabled/disabled from the AniMods status panel
-- (see CYCLE_DEFS / GetInfoRows below) -- disabling one just removes it from the
-- cycle even when it would otherwise be eligible. OFFICER and CHANNEL default to
-- OFF (see DEFAULT_DISABLED): most players aren't guild officers or in a custom
-- world channel, so by default they'd just be two usually-dead stops every lap.
--
-- Compatibility: if the edit box text already starts with "/", the handler bails
-- out immediately and leaves Tab to Blizzard's default slash-command autocomplete
-- cycling (present regardless of chat addon) -- so this never interferes with that.
--
-- NOTE: half-baked / not fully tested, carried over as-is from the original
-- standalone ChatContextSwitch addon. Known-good enough for daily use, bugs may
-- remain.

local ChatContextSwitch = {
    title = "Chat Context Switch",
    description = "Tab/Shift+Tab cycles the chat channel.",
    dbKey = "chatContextSwitch",
    category = "At a Click",
}

-- ---------------------------------------------------------------------------
-- NDui chat-module awareness
-- ---------------------------------------------------------------------------
-- NDui installs this exact Tab-cycling behavior itself (Modules/Chat/Core.lua,
-- module:OnLogin -> hooksecurefunc("ChatEdit_CustomTabPressed", ...)) but only
-- when its own Chat module is enabled (guarded by `if C.db["Chat"]["Disable"]
-- then return end`). So: skip ourselves only when NDui is loaded AND its chat
-- module is actually active; if the user has NDui installed but its chat
-- module turned off (the original standalone addon's exact use case), we
-- still need to provide this.
--
-- NDui exposes its internals as `_G.NDui = {B, C, L, DB}` (NDui/Init.lua:
-- `_G[addonName] = ns`), populated at NDui's own ADDON_LOADED -- long before
-- any addon's PLAYER_LOGIN handler (when this condition is evaluated) fires,
-- so C.db is guaranteed to already be populated here regardless of load order
-- between AniMods and NDui.
local function NDuiChatModuleActive()
    local ns = _G.NDui
    if not ns then return false end
    local C = ns[2]
    return not (C and C.db and C.db["Chat"] and C.db["Chat"]["Disable"])
end

ChatContextSwitch.conditions = {
    { text = "NDui chat module off",
      help = "NDui's chat module installs the same Tab hook. Only one can own "
          .. "it, so this stands down while that is on.",
      met = function() return not NDuiChatModuleActive() end },
}

-- ---------------------------------------------------------------------------
-- Per-channel enable/disable (persisted, editable from the AniMods panel)
-- ---------------------------------------------------------------------------

local function ChannelDB()
    AniModsDB.chatContextSwitch = AniModsDB.chatContextSwitch or {}
    AniModsDB.chatContextSwitch.channels = AniModsDB.chatContextSwitch.channels or {}
    return AniModsDB.chatContextSwitch.channels
end

-- OFFICER and the world CHANNEL are off by default: most players aren't
-- guild officers and aren't in a custom world channel, so cycling through
-- them by default just adds two usually-dead stops to every lap.
local DEFAULT_DISABLED = { OFFICER = true, CHANNEL = true }

local function IsChannelEnabled(key)
    local v = ChannelDB()[key]
    if v == nil then return not DEFAULT_DISABLED[key] end
    return v
end

local function SetChannelEnabled(key, enabled)
    ChannelDB()[key] = enabled and true or false
end

-- ---------------------------------------------------------------------------
-- World-channel support (CN region only)
-- ---------------------------------------------------------------------------
-- Tracks whether the player is currently joined to a custom world channel so
-- that Tab can cycle into it. This mirrors the NDui chatbar behaviour.

local worldChannelName  -- set below if CN portal is detected
local inWorldChannel    = false
local worldChannelID    = nil

local function UpdateWorldChannelInfo()
    if not worldChannelName then return end
    local id = GetChannelName(worldChannelName)
    if id and id ~= 0 then
        inWorldChannel = true
        worldChannelID = id
    else
        inWorldChannel = false
        worldChannelID = nil
    end
end

-- ---------------------------------------------------------------------------
-- Channel cycle definition
-- ---------------------------------------------------------------------------
-- `key` is the persisted per-channel toggle id and the label shown in the
-- status panel. `IsActive` is the *live eligibility* check (unrelated to the
-- user's enable/disable choice) -- e.g. PARTY is only eligible while grouped.

local CYCLE_DEFS = {
    { key = "SAY",           chatType = "SAY",           label = "Say",           IsActive = function() return true end },
    { key = "PARTY",         chatType = "PARTY",         label = "Party",         IsActive = function() return IsInGroup() end },
    { key = "RAID",          chatType = "RAID",          label = "Raid",          IsActive = function() return IsInRaid() end },
    { key = "INSTANCE_CHAT", chatType = "INSTANCE_CHAT", label = "Instance",      IsActive = function() return IsPartyLFG() or C_PartyInfo.IsPartyWalkIn() end },
    { key = "GUILD",         chatType = "GUILD",         label = "Guild",         IsActive = function() return IsInGuild() end },
    { key = "OFFICER",       chatType = "OFFICER",       label = "Officer",       IsActive = function() return C_GuildInfo.IsGuildOfficer() end },
    { key = "CHANNEL",       chatType = "CHANNEL",       label = "World Channel", IsActive = function() return inWorldChannel and worldChannelID ~= nil end },
}

-- Live eligibility right now, ignoring the user's enable/disable choice --
-- used only for the status-panel "active now" indicator.
local function IsEligibleNow(def)
    return def.IsActive() and true or false
end

-- Builds the runtime cycle: each real entry gated by its enable toggle, plus
-- a trailing SAY sentinel (also gated by SAY's own toggle) that the wraparound
-- search below always lands on. Built fresh on every Tab press -- cheap (7
-- entries) and avoids trying to mutate a shared table when toggles change.
local function BuildCycles()
    local list = {}
    for _, def in ipairs(CYCLE_DEFS) do
        local chatType, isActive = def.chatType, def.IsActive
        list[#list + 1] = {
            chatType = chatType,
            -- Called as `next:IsActive(editbox)` below (colon syntax), which
            -- passes this very cycle-entry table as the implicit first arg
            -- and the real chat editbox as the *second* -- a `function(editbox)`
            -- single-param signature here would silently bind `editbox` to the
            -- wrong value (this table, not the editbox). That was a real,
            -- dormant bug inherited from the original standalone addon (only
            -- reachable for CHANNEL, and only on the CN portal).
            IsActive = function(_, editbox)
                if not IsChannelEnabled(def.key) then return false end
                local eligible = isActive()
                if chatType == "CHANNEL" and eligible then
                    editbox:SetAttribute("channelTarget", worldChannelID)
                end
                return eligible
            end,
        }
    end
    -- sentinel: wraps back to SAY
    local sayKey = CYCLE_DEFS[1].key
    list[#list + 1] = {
        chatType = "SAY",
        IsActive = function() return IsChannelEnabled(sayKey) end,
    }
    return list
end

-- ---------------------------------------------------------------------------
-- Switch helper
-- ---------------------------------------------------------------------------

local function SwitchToChannel(editbox, chatType)
    editbox:SetAttribute("chatType", chatType)
    ChatEdit_UpdateHeader(editbox)
end

-- ---------------------------------------------------------------------------
-- Core Tab handler – hooked onto ChatEdit_CustomTabPressed
-- `self` is the chat edit box frame (same contract as the Blizzard function).
-- ---------------------------------------------------------------------------

local function OnCustomTabPressed(self)
    -- If the text already starts with a slash command, leave it alone so that
    -- the default auto-complete logic can run.
    if strsub(self:GetText(), 1, 1) == "/" then return end

    local isShift       = IsShiftKeyDown()
    local currentType   = self:GetAttribute("chatType")

    local cycles = BuildCycles()
    local numCycles = #cycles
    for i = 1, numCycles do
        if currentType == cycles[i].chatType then
            -- Forward wraps via the trailing SAY sentinel BuildCycles adds.
            -- Backward has no such sentinel, so it wraps explicitly: without
            -- the second pass, Shift+Tab from SAY (i == 1) ran `for j = 0, 1,
            -- -1`, which is zero iterations -- it silently did nothing
            -- instead of going to the last enabled channel.
            local order = {}
            if isShift then
                for j = i - 1, 1, -1 do order[#order + 1] = j end
                for j = numCycles, i + 1, -1 do order[#order + 1] = j end
            else
                for j = i + 1, numCycles do order[#order + 1] = j end
                for j = 1, i - 1 do order[#order + 1] = j end
            end

            for _, j in ipairs(order) do
                local candidate = cycles[j]
                if candidate:IsActive(self) then
                    SwitchToChannel(self, candidate.chatType)
                    return
                end
            end
            break
        end
    end

    -- The current type is not in the cycle at all -- a whisper, a BN whisper,
    -- a yell, an emote. Enter the cycle at its first eligible entry instead of
    -- doing nothing.
    --
    -- This is a deliberate DIVERGENCE from NDui, which special-cases only
    -- Shift+Tab out of WHISPER/BN_WHISPER and hardcodes SAY. Plain Tab there
    -- falls through its `currentType == cycle.chatType` loop, matches nothing,
    -- and leaves you stuck in the whisper with no visible way out -- which is
    -- exactly the dead end that prompted this. Nothing is being overridden:
    -- plain Tab had no behaviour here to preserve.
    --
    -- First ELIGIBLE rather than SAY, because SAY can be switched off in the
    -- panel and jumping to a channel the player disabled would be its own bug.
    for i = 1, numCycles do
        local candidate = cycles[i]
        if candidate:IsActive(self) then
            SwitchToChannel(self, candidate.chatType)
            return
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status panel: live eligibility + per-channel toggles
-- ---------------------------------------------------------------------------

-- No Status section. It reported whether NDui's chat module was active, which
-- is exactly what this module's one condition already says, in the card
-- directly above and with a badge -- two readouts of the same fact, phrased
-- differently, that could only ever agree.
function ChatContextSwitch:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Channels in the cycle" }
    for _, def in ipairs(CYCLE_DEFS) do
        rows[#rows + 1] = {
            label = def.label,
            get   = function() return IsChannelEnabled(def.key) end,
            set   = function(v) SetChannelEnabled(def.key, v) end,
            note  = IsEligibleNow(def) and "Active" or nil,
        }
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------

function ChatContextSwitch:Enable()
    -- Detect CN portal for world-channel support. Everything below is only
    -- wired up on that portal: off it, worldChannelName stays nil,
    -- UpdateWorldChannelInfo returns immediately, and the CHANNEL_UI_UPDATE
    -- handler would just be spawning a 0.2s timer per event to call a
    -- guaranteed no-op, forever.
    local getCVar = (C_CVar and C_CVar.GetCVar) or GetCVar
    if getCVar and getCVar("portal") == "CN" then
        worldChannelName = "大脚世界频道"
        C_Timer.After(0.2, UpdateWorldChannelInfo)

        -- CHANNEL_UI_UPDATE arrives in bursts (joining/leaving channels,
        -- zone changes); debounced so a burst schedules one refresh rather
        -- than one timer per event.
        local pending = false
        local channelFrame = CreateFrame("Frame")
        channelFrame:RegisterEvent("CHANNEL_UI_UPDATE")
        channelFrame:SetScript("OnEvent", function()
            if pending then return end
            pending = true
            C_Timer.After(0.2, function()
                pending = false
                UpdateWorldChannelInfo()
            end)
        end)
    end

    -- The hook must be installed exactly once. hooksecurefunc appends to the
    -- secure call chain, so it is safe with both stock Blizzard chat frames
    -- and Chattynator's reskinned frames, which still delegate Tab handling
    -- through the same Blizzard function.
    hooksecurefunc("ChatEdit_CustomTabPressed", OnCustomTabPressed)
end

AniMods.RegisterModule("ChatContextSwitch", ChatContextSwitch)
