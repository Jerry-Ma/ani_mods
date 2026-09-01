-- RaidComposition
-- Tank/Healer/DPS role counts, shown while in a group.
--
-- EllesmereUI's QoL Raid Tools panel (EllesmereUIQoL_RaidTools.lua) has ready
-- check, role check, pull timer, and markers, but no composition/role-count
-- display the way NDui's raid tool does (NDui/Modules/Misc/RaidTool.lua,
-- M:RaidTool_RoleCount). This docks a small count badge onto Raid Tools' own
-- collapsed-icon button (the global frame `EllesmereUIRaidToolsIcon`) so it
-- reads as part of that minimized display, with a movable standalone bar as
-- the fallback when that icon isn't available (e.g. Raid Tools mode is
-- "never", EllesmereUIQoL's default -- in that mode EUI builds no Raid Tools
-- frames at all).
--
-- Docking is done without touching EUI's secure frames in any way that could
-- taint them: our badge is our own separate frame, merely SetPoint-anchored
-- to theirs (anchoring reads their rect, it doesn't execute anything of
-- theirs), and we only ever *observe* iconBtn via hooksecurefunc(iconBtn,
-- "Show"/"Hide", ...) -- which taps the C-level implementation regardless of
-- whether Blizzard/EUI's own protected code called it, so it reliably fires
-- even though EUI's own visibility changes run through a secure
-- SecureHandlerStateTemplate "apply" attribute snippet, not plain Lua calls.
--
-- Data source is deliberately NOT a port of NDui's logic (GetRaidRosterInfo +
-- online/dead/subgroup<=maxgroup filtering to work out "who's actually
-- around"). UnitGroupRolesAssigned() per group-unit token is the more direct,
-- native way to ask Blizzard what role each current member is assigned —
-- no manual roster-filtering heuristics needed.
--
-- Only active when EllesmereUIQoL is loaded and NDui is not (NDui already
-- has this).

local RaidComposition = {
    title = "Raid Composition",
    description = "Tank/Healer/DPS role counts while in a group, styled to match EllesmereUI. Docks onto EllesmereUI's Raid Tools collapsed icon when available; otherwise a small movable bar.",
    condition = {
        requires = { "EllesmereUIQoL" },
        forbids = { "NDui" },
    },
}

local ROLES = { "TANK", "HEALER", "DAMAGER" }

local function ModuleDB()
    AniModsDB.raidComposition = AniModsDB.raidComposition or {}
    return AniModsDB.raidComposition
end

local function CountRoles()
    local counts = { TANK = 0, HEALER = 0, DAMAGER = 0 }

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local role = UnitGroupRolesAssigned("raid" .. i)
            if counts[role] then counts[role] = counts[role] + 1 end
        end
    else
        local role = UnitGroupRolesAssigned("player")
        if counts[role] then counts[role] = counts[role] + 1 end
        for i = 1, GetNumSubgroupMembers() do
            role = UnitGroupRolesAssigned("party" .. i)
            if counts[role] then counts[role] = counts[role] + 1 end
        end
    end

    return counts
end

-- ---------------------------------------------------------------------------
-- Role icon styles
-- ---------------------------------------------------------------------------
-- Since this module docks onto EllesmereUI's own Raid Tools icon, its role
-- icons should look like EllesmereUI's, not some other addon's. Sourced from
-- EllesmereUIRaidFrames.lua's own ROLE_ICON_STYLES table (7 variants there).
-- These 5 are pure Blizzard atlas name references -- no EUI-owned asset
-- involved, just the same public atlas API anyone can use, so nothing needs
-- copying and there's no license concern reusing them. Its other 2 styles
-- ("modern", the actual EUI default, and "blizzLight") point at EUI's own
-- custom PNGs under EllesmereUIRaidFrames\Media\ -- deliberately NOT
-- reproduced here: EUI's license.txt is "all rights reserved" (no
-- redistribution permission), so we stick to what's safe to reference.
local ICON_STYLES = {
    moderncircle = {
        name = "Modern Circle",
        atlas = { TANK = "UI-LFG-RoleIcon-Tank", HEALER = "UI-LFG-RoleIcon-Healer", DAMAGER = "UI-LFG-RoleIcon-DPS" },
    },
    styled = {
        name = "Styled",
        atlas = { TANK = "UI-LFG-RoleIcon-Tank-Background", HEALER = "UI-LFG-RoleIcon-Healer-Background", DAMAGER = "UI-LFG-RoleIcon-DPS-Background" },
    },
    classiccircle = {
        name = "Classic Circle",
        atlas = { TANK = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder", HEALER = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder", DAMAGER = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder" },
    },
    classic = {
        name = "Classic",
        atlas = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" },
    },
    blizzdefault = {
        name = "Blizzard Default",
        atlas = { TANK = "GM-icon-role-tank", HEALER = "GM-icon-role-healer", DAMAGER = "GM-icon-role-dps" },
    },
}

local ICON_STYLE_ORDER = { "moderncircle", "styled", "classiccircle", "classic", "blizzdefault" }

local function GetIconStyle()
    local key = ModuleDB().iconStyle
    if key and ICON_STYLES[key] then return key end
    return "moderncircle"
end

-- Applies a style to an existing icon texture object -- used both when a
-- role icon is first created and to live-restyle it when the option changes.
local function ApplyRoleIcon(icon, role, styleKey)
    local style = ICON_STYLES[styleKey] or ICON_STYLES.moderncircle
    icon:SetAtlas(style.atlas[role])
end

-- ---------------------------------------------------------------------------
-- Displays: a standalone bar (fallback), a badge docked to EUI's icon, and a
-- LibDataBroker data source (pick it as a widget in EllesmereUIDataBars, or
-- any other LDB-consuming data bar)
-- ---------------------------------------------------------------------------

local frame          -- standalone bar (built always; fallback display)
local dockedBadge     -- compact badge anchored to EllesmereUIRaidToolsIcon
local usingDockedMode = false
local ldbObject       -- LibDataBroker data source, if LDB is available

-- EllesmereUI ships LibStub + LibDataBroker-1.1 itself (EllesmereUI/Libs/),
-- and EllesmereUIDataBars depends on EllesmereUI, so LibStub is guaranteed
-- present whenever this module's own condition (EllesmereUIQoL loaded) holds.
-- Guarded anyway, silently: GetLibrary(..., true) never errors on a miss.
local function InitLDB()
    local libStub = _G.LibStub
    local ldb = libStub and libStub:GetLibrary("LibDataBroker-1.1", true)
    if not ldb then return end

    ldbObject = ldb:NewDataObject("AniModsRaidComposition", {
        type = "data source",
        label = "AniMods: Raid Composition",
        text = "N/A",
        OnClick = function() if AniMods.ToggleUI then AniMods.ToggleUI() end end,
        OnTooltipShow = function(tt)
            tt:AddLine("AniMods: Raid Composition")
            if not IsInGroup() then
                tt:AddLine("Not in a group", 0.6, 0.6, 0.6)
                return
            end
            local counts = CountRoles()
            tt:AddLine(IsInRaid() and "Raid" or "Party", 0.6, 0.6, 0.6)
            tt:AddDoubleLine("Tanks", tostring(counts.TANK), 1, 1, 1, 0.35, 1, 0.35)
            tt:AddDoubleLine("Healers", tostring(counts.HEALER), 1, 1, 1, 0.35, 1, 0.35)
            tt:AddDoubleLine("DPS", tostring(counts.DAMAGER), 1, 1, 1, 1, 0.35, 0.35)
        end,
    })
end

local function SetIconStyle(key)
    ModuleDB().iconStyle = key
    if frame and frame.icons then
        for role, icon in pairs(frame.icons) do
            ApplyRoleIcon(icon, role, key)
        end
    end
end

local function UpdateCounts()
    local counts = CountRoles()

    if frame and frame.counts then
        for _, role in ipairs(ROLES) do
            frame.counts[role]:SetText(counts[role])
        end
    end

    if dockedBadge then
        dockedBadge.text:SetFormattedText(
            "|cff59c0ff%d|r/|cff2ecc71%d|r/|cffff5555%d|r", counts.TANK, counts.HEALER, counts.DAMAGER)
    end

    if ldbObject then
        ldbObject.text = IsInGroup()
            and ("%d/%d/%d"):format(counts.TANK, counts.HEALER, counts.DAMAGER)
            or "N/A"
    end
end

local function UpdateVisibility()
    if not frame then return end
    -- Once docked, the standalone bar retires -- the icon's own Show/Hide
    -- drives the docked badge instead (see TryDockToEUIIcon).
    frame:SetShown(IsInGroup() and not usingDockedMode)
end

local function SavePosition(self)
    local point, _, relPoint, x, y = self:GetPoint()
    local db = ModuleDB()
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function CreateRoleIcon(parent, role)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    ApplyRoleIcon(icon, role, GetIconStyle())
    return icon
end

local function BuildFrame()
    local f = CreateFrame("Frame", "AniModsRaidComposition", UIParent, "BackdropTemplate")
    f:SetSize(118, 24)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.75)
    f:SetBackdropBorderColor(0, 0, 0, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("AniMods: Raid Composition")
        GameTooltip:AddLine("Drag to move.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.counts = {}
    f.icons = {}
    for i, role in ipairs(ROLES) do
        local icon = CreateRoleIcon(f, role)
        icon:SetPoint("LEFT", 4 + (i - 1) * 38, 0)
        f.icons[role] = icon

        local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        text:SetText("0")
        f.counts[role] = text
    end

    local db = ModuleDB()
    if db.point then
        f:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 250, -250)
    end

    return f
end

-- Small text-only badge (an icon row doesn't fit under a 30x30 button) docked
-- just below EUI's collapsed Raid Tools icon.
local function BuildDockedBadge(iconBtn)
    local badge = CreateFrame("Frame", "AniModsRaidCompositionDocked", UIParent)
    badge:SetSize(36, 12)
    badge:SetFrameStrata(iconBtn:GetFrameStrata())
    badge:SetFrameLevel(iconBtn:GetFrameLevel() + 5)
    badge:SetPoint("TOP", iconBtn, "BOTTOM", 0, -1)
    badge:EnableMouse(true)
    badge:Hide()

    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge.text:SetAllPoints()
    badge.text:SetJustifyH("CENTER")
    local fontPath = badge.text:GetFont()
    badge.text:SetFont(fontPath, 9, "OUTLINE")

    badge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("AniMods: Raid Composition")
        GameTooltip:AddLine("Tank / Healer / DPS", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return badge
end

-- EllesmereUIQoL only builds its Raid Tools frames (including the collapsed
-- icon) on first Apply with a non-"never" mode -- "never" is QoL's own
-- default, meaning the icon frame may not exist yet (or ever) at our own
-- Enable() time. Called from Enable() and re-checked on a few login-delay
-- timers plus GROUP_ROSTER_UPDATE so we still dock if it appears later.
local function TryDockToEUIIcon()
    if usingDockedMode then return end
    local iconBtn = _G.EllesmereUIRaidToolsIcon
    if not iconBtn then return end

    usingDockedMode = true
    UpdateVisibility() -- retires the standalone bar

    dockedBadge = BuildDockedBadge(iconBtn)
    hooksecurefunc(iconBtn, "Show", function()
        dockedBadge:Show()
        UpdateCounts()
    end)
    hooksecurefunc(iconBtn, "Hide", function()
        dockedBadge:Hide()
    end)
    dockedBadge:SetShown(iconBtn:IsShown())
    UpdateCounts()
end

-- ---------------------------------------------------------------------------
-- Status panel: live composition + icon style picker
-- ---------------------------------------------------------------------------

function RaidComposition:GetInfoRows()
    local rows = {}

    if not IsInGroup() then
        rows[#rows + 1] = { label = "Status", value = "N/A (not in a group)" }
    else
        local counts = CountRoles()
        rows[#rows + 1] = { label = "Group type", value = IsInRaid() and "Raid" or "Party" }
        rows[#rows + 1] = { label = "Tanks",      value = tostring(counts.TANK) }
        rows[#rows + 1] = { label = "Healers",    value = tostring(counts.HEALER) }
        rows[#rows + 1] = { label = "DPS",        value = tostring(counts.DAMAGER) }
    end

    rows[#rows + 1] = {
        label = "Docked to EllesmereUI icon",
        value = usingDockedMode and "Yes" or "No (standalone bar; Raid Tools icon not found)",
    }
    rows[#rows + 1] = {
        label = "Broker (LDB) plugin",
        value = ldbObject and "Registered as \"AniMods: Raid Composition\" -- pick it in a databar"
            or "Not registered (LibDataBroker-1.1 not found)",
    }

    local currentStyle = GetIconStyle()
    for _, key in ipairs(ICON_STYLE_ORDER) do
        rows[#rows + 1] = {
            label = "Icon style: " .. ICON_STYLES[key].name,
            get   = function() return GetIconStyle() == key end,
            set   = function(v) if v then SetIconStyle(key) end end,
            note  = (currentStyle == key) and "selected" or nil,
        }
    end

    return rows
end

function RaidComposition:Enable()
    frame = BuildFrame()
    InitLDB()
    UpdateVisibility()
    UpdateCounts()

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("UNIT_FLAGS")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function()
        TryDockToEUIIcon()
        UpdateVisibility()
        UpdateCounts()
    end)

    TryDockToEUIIcon()
    for _, delay in ipairs({ 2, 5, 10, 20 }) do
        C_Timer.After(delay, TryDockToEUIIcon)
    end
end

AniMods.RegisterModule("RaidComposition", RaidComposition)
