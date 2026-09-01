-- ChatContextSwitch
-- Switches the chat input context (channel) by pressing Tab in the chat edit box.
-- Ported from NDui's chat module (NDui/Modules/Chat/Core.lua, module:UpdateTabChannelSwitch)
-- — this is a faithful reimplementation of that logic, not the original file.
--
-- Behaviour:
--   Tab        → cycle forward through active chat types
--   Shift+Tab  → cycle backward; from WHISPER/BN_WHISPER always jumps to SAY
--
-- The cycle: SAY → PARTY → RAID → INSTANCE_CHAT → GUILD → OFFICER → (CHANNEL if in world channel) → SAY
--
-- Only applies when NDui is not loaded — NDui already installs this exact behavior
-- itself, so hooking it again here would be redundant (see `condition` below).
-- Verified independent of the chat addon otherwise in use: EllesmereUIChat doesn't
-- implement Tab channel-cycling at all, so this fills the gap for it.
--
-- Compatibility: if the edit box text already starts with "/", the handler bails
-- out immediately and leaves Tab to Blizzard's default slash-command autocomplete
-- cycling (present regardless of chat addon) — so this never interferes with that.
--
-- NOTE: half-baked / not fully tested, carried over as-is from the original
-- standalone ChatContextSwitch addon. Known-good enough for daily use, bugs may
-- remain.

local ChatContextSwitch = {
    title = "Chat Context Switch",
    description = "Tab/Shift+Tab cycles the chat channel (SAY/PARTY/RAID/.../world CHANNEL). Only active when NDui is not loaded.",
    condition = {
        forbids = { "NDui" },
    },
}

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

local cycles = {
    { chatType = "SAY",           IsActive = function()           return true end },
    { chatType = "PARTY",         IsActive = function()           return IsInGroup() end },
    { chatType = "RAID",          IsActive = function()           return IsInRaid() end },
    { chatType = "INSTANCE_CHAT", IsActive = function()           return IsPartyLFG() or C_PartyInfo.IsPartyWalkIn() end },
    { chatType = "GUILD",         IsActive = function()           return IsInGuild() end },
    { chatType = "OFFICER",       IsActive = function()           return C_GuildInfo.IsGuildOfficer() end },
    { chatType = "CHANNEL",       IsActive = function(editbox)
        if inWorldChannel and worldChannelID then
            editbox:SetAttribute("channelTarget", worldChannelID)
            return true
        end
    end },
    -- sentinel: wraps back to SAY
    { chatType = "SAY",           IsActive = function()           return true end },
}

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

    -- Shift+Tab from a whisper context → jump straight to SAY
    if isShift and (currentType == "WHISPER" or currentType == "BN_WHISPER") then
        SwitchToChannel(self, "SAY")
        return
    end

    local numCycles = #cycles
    for i = 1, numCycles do
        if currentType == cycles[i].chatType then
            local from, to, step
            if isShift then
                from, to, step = i - 1, 1, -1
            else
                from, to, step = i + 1, numCycles, 1
            end
            for j = from, to, step do
                local next = cycles[j]
                if next:IsActive(self) then
                    SwitchToChannel(self, next.chatType)
                    return
                end
            end
            break
        end
    end
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------

function ChatContextSwitch:Enable()
    -- Detect CN portal for world-channel support
    if GetCVar("portal") == "CN" then
        worldChannelName = "大脚世界频道"
        C_Timer.After(0.2, UpdateWorldChannelInfo)
    end

    local channelFrame = CreateFrame("Frame")
    channelFrame:RegisterEvent("CHANNEL_UI_UPDATE")
    channelFrame:SetScript("OnEvent", function()
        C_Timer.After(0.2, UpdateWorldChannelInfo)
    end)

    -- The hook must be installed exactly once. hooksecurefunc appends to the
    -- secure call chain, so it is safe with both stock Blizzard chat frames
    -- and Chattynator's reskinned frames, which still delegate Tab handling
    -- through the same Blizzard function.
    hooksecurefunc("ChatEdit_CustomTabPressed", OnCustomTabPressed)
end

AniMods.RegisterModule("ChatContextSwitch", ChatContextSwitch)
