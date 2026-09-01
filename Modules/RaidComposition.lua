-- RaidComposition
-- Small Tank/Healer/DPS role-count bar, shown while in a group.
--
-- EllesmereUI's QoL Raid Tools panel (EllesmereUIQoL_RaidTools.lua) has ready
-- check, role check, pull timer, and markers, but no composition/role-count
-- display the way NDui's raid tool does (NDui/Modules/Misc/RaidTool.lua,
-- M:RaidTool_RoleCount). Rather than injecting into EUI's secure
-- SecureHandlerStateTemplate shells — fragile, taint risk, liable to break on
-- EUI updates — this is its own small standalone, movable, click-through-safe
-- frame. That's also how NDui itself does it: its role count lives in NDui's
-- own header button, not injected into any other addon's UI.
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
    description = "Small Tank/Healer/DPS count bar while in a group, since EllesmereUI's Raid Tools panel doesn't show one (NDui's does).",
    condition = {
        requires = { "EllesmereUIQoL" },
        forbids = { "NDui" },
    },
}

local ROLES = { "TANK", "HEALER", "DAMAGER" }

local frame

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

local function UpdateCounts()
    if not frame then return end
    local counts = CountRoles()
    for _, role in ipairs(ROLES) do
        frame.counts[role]:SetText(counts[role])
    end
end

local function UpdateVisibility()
    if not frame then return end
    frame:SetShown(IsInGroup())
end

local function CreateRoleIcon(parent, role)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
    icon:SetTexCoord(GetTexCoordsForRoleSmallCircle(role))
    return icon
end

local function SavePosition(self)
    local point, _, relPoint, x, y = self:GetPoint()
    AniModsDB.raidComposition = { point = point, relPoint = relPoint, x = x, y = y }
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
    for i, role in ipairs(ROLES) do
        local icon = CreateRoleIcon(f, role)
        icon:SetPoint("LEFT", 4 + (i - 1) * 38, 0)

        local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        text:SetText("0")
        f.counts[role] = text
    end

    local pos = AniModsDB.raidComposition
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 250, -250)
    end

    return f
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
        UpdateVisibility()
        UpdateCounts()
    end)
end

AniMods.RegisterModule("RaidComposition", RaidComposition)
