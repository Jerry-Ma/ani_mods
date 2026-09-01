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
    description = "Tank/Healer/DPS role counts while in a group. Docks onto EllesmereUI's Raid Tools collapsed icon when available; otherwise a small movable bar.",
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
-- "blizzard" needs nothing else installed. The rest reuse NDui_Plus's bundled
-- role-icon media (Media/Texture/<style>/<Tank|Healer|DPS>) -- texture files
-- are read straight off disk by path, independent of whether NDui_Plus is
-- currently enabled/loaded, so this works even if NDui_Plus is only present
-- (not necessarily active) alongside EllesmereUI/AniMods.

local NDUI_PLUS_TEX = "Interface\\AddOns\\NDui_Plus\\Media\\Texture\\"

local ICON_STYLES = {
    blizzard = {
        name = "Blizzard (default)",
        -- GetTexCoordsForRoleSmallCircle() no longer exists in this client
        -- (confirmed via a real "attempt to call a nil value" crash) --
        -- Blizzard evidently dropped it. Prefer the modern per-role atlas
        -- (sharper, and the thing that replaced the old function), falling
        -- back to a manual texcoord crop of the legacy sprite sheet only if
        -- that atlas isn't available (mirrors DandersFrames/Frames/Core.lua).
        atlas = {
            TANK    = "UI-LFG-RoleIcon-Tank-Micro",
            HEALER  = "UI-LFG-RoleIcon-Healer-Micro",
            DAMAGER = "UI-LFG-RoleIcon-DPS-Micro",
        },
        legacyTexture = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES",
        legacyTexCoord = {
            TANK    = { 0, 0.296875, 0.296875, 0.65 },
            HEALER  = { 0.296875, 0.59375, 0, 0.296875 },
            DAMAGER = { 0.296875, 0.59375, 0.296875, 0.65 },
        },
    },
    lynui = {
        name = "NDui_Plus: LynUI",
        texture = {
            TANK = NDUI_PLUS_TEX .. "LynUI\\Tank", HEALER = NDUI_PLUS_TEX .. "LynUI\\Healer", DAMAGER = NDUI_PLUS_TEX .. "LynUI\\DPS",
        },
    },
    elvui = {
        name = "NDui_Plus: ElvUI",
        texture = {
            TANK = NDUI_PLUS_TEX .. "ElvUI\\Tank", HEALER = NDUI_PLUS_TEX .. "ElvUI\\Healer", DAMAGER = NDUI_PLUS_TEX .. "ElvUI\\DPS",
        },
    },
    toxiui_white = {
        name = "NDui_Plus: ToxiUI White",
        texture = {
            TANK = NDUI_PLUS_TEX .. "ToxiUI\\WhiteTank", HEALER = NDUI_PLUS_TEX .. "ToxiUI\\WhiteHeal", DAMAGER = NDUI_PLUS_TEX .. "ToxiUI\\WhiteDPS",
        },
    },
    toxiui_new = {
        name = "NDui_Plus: ToxiUI New",
        texture = {
            TANK = NDUI_PLUS_TEX .. "ToxiUI\\NewTank", HEALER = NDUI_PLUS_TEX .. "ToxiUI\\NewHeal", DAMAGER = NDUI_PLUS_TEX .. "ToxiUI\\NewDPS",
        },
    },
    toxiui_stylized = {
        name = "NDui_Plus: ToxiUI Stylized",
        texture = {
            TANK = NDUI_PLUS_TEX .. "ToxiUI\\StylizedTank", HEALER = NDUI_PLUS_TEX .. "ToxiUI\\StylizedHeal", DAMAGER = NDUI_PLUS_TEX .. "ToxiUI\\StylizedDPS",
        },
    },
}

local ICON_STYLE_ORDER = { "blizzard", "lynui", "elvui", "toxiui_white", "toxiui_new", "toxiui_stylized" }

local function NDuiPlusInstalled()
    local getMeta = (_G.C_AddOns and _G.C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    -- Works for an addon that's merely present on disk, not just loaded --
    -- exactly what we need since we're reading its texture files by path,
    -- not calling into its Lua.
    return getMeta and getMeta("NDui_Plus", "Title") ~= nil
end

local function GetIconStyle()
    local key = ModuleDB().iconStyle
    if key and ICON_STYLES[key] then return key end
    return "blizzard"
end

-- Applies a style to an existing icon texture object -- used both when a
-- role icon is first created and to live-restyle it when the option changes.
local function ApplyRoleIcon(icon, role, styleKey)
    local style = ICON_STYLES[styleKey] or ICON_STYLES.blizzard

    if style.texture and style.texture[role] then
        icon:SetTexture(style.texture[role])
        icon:SetTexCoord(0, 1, 0, 1)
        return
    end

    local atlas = style.atlas and style.atlas[role]
    if atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        icon:SetAtlas(atlas)
        return
    end

    icon:SetTexture(style.legacyTexture or "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
    local c = style.legacyTexCoord and style.legacyTexCoord[role]
    if c then icon:SetTexCoord(c[1], c[2], c[3], c[4]) else icon:SetTexCoord(0, 1, 0, 1) end
end

-- ---------------------------------------------------------------------------
-- Displays: a standalone bar (fallback) and a badge docked to EUI's icon
-- ---------------------------------------------------------------------------

local frame          -- standalone bar (built always; fallback display)
local dockedBadge     -- compact badge anchored to EllesmereUIRaidToolsIcon
local usingDockedMode = false

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

    local hasNDuiPlus = NDuiPlusInstalled()
    local currentStyle = GetIconStyle()
    for _, key in ipairs(ICON_STYLE_ORDER) do
        if key == "blizzard" or hasNDuiPlus then
            rows[#rows + 1] = {
                label = "Icon style: " .. ICON_STYLES[key].name,
                get   = function() return GetIconStyle() == key end,
                set   = function(v) if v then SetIconStyle(key) end end,
                note  = (currentStyle == key) and "selected" or nil,
            }
        end
    end

    return rows
end

function RaidComposition:Enable()
    frame = BuildFrame()
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
