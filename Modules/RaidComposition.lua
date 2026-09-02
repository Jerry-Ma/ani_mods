-- RaidComposition
-- Tank/Healer/DPS role counts, shown while in a group.
--
-- EllesmereUI's QoL Raid Tools panel (EllesmereUIQoL_RaidTools.lua) has ready
-- check, role check, pull timer, and markers, but no composition/role-count
-- display the way NDui's raid tool does (NDui/Modules/Misc/RaidTool.lua,
-- M:RaidTool_RoleCount). This docks a small count badge onto Raid Tools' own
-- collapsed-icon button (the global frame `EllesmereUIRaidToolsIcon`) so it
-- reads as part of that minimized display. Docking onto that icon is the
-- only display mode -- there's nothing sensible to show if the icon isn't
-- there yet (Raid Tools mode "never", EllesmereUIQoL's own default, builds no
-- Raid Tools frames at all); the module just waits and docks once it appears.
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
    description = "Tank/Healer/DPS role counts, docked onto EllesmereUI's Raid Tools icon.",
    dependencies = {
        { text = "EllesmereUIQoL loaded", met = function() return AniMods.IsAddOnLoaded("EllesmereUIQoL") end },
        { text = "NDui not loaded",       met = function() return not AniMods.IsAddOnLoaded("NDui") end },
    },
    condition = {
        requires = { "EllesmereUIQoL" },
        forbids = { "NDui" },
    },
}

local ROLES = { "TANK", "HEALER", "DAMAGER" }
local ROLE_COLOR = { TANK = "59c0ff", HEALER = "2ecc71", DAMAGER = "ff5555" }

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

-- Per-role list of class tokens for the broker tooltip's class-colored-square
-- breakdown (see InitLDB) -- same roster walk as CountRoles, but keeping the
-- class of each member instead of just a running total.
local function CollectRoleClasses()
    local byRole = { TANK = {}, HEALER = {}, DAMAGER = {} }

    local function Add(unit)
        local role = UnitGroupRolesAssigned(unit)
        local list = byRole[role]
        if not list then return end
        local _, class = UnitClass(unit)
        list[#list + 1] = class
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            Add("raid" .. i)
        end
    else
        Add("player")
        for i = 1, GetNumSubgroupMembers() do
            Add("party" .. i)
        end
    end

    return byRole
end

-- Shared tooltip body -- a per-role breakdown of class-colored squares (one
-- per member in that role) rather than a bare count -- used by both the
-- broker (LDB) plugin's tooltip (always on) and the docked badge's tooltip
-- (optional, see "Show tooltip on docked badge" in GetInfoRows).
local function ShowCompositionTooltip(tt)
    if not IsInGroup() then
        tt:AddLine("Not in a group", 0.6, 0.6, 0.6)
        return
    end
    local byRole = CollectRoleClasses()
    local ROLE_LABEL = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
    local total = #byRole.TANK + #byRole.HEALER + #byRole.DAMAGER

    -- Header carries the actual headcount instead of just naming the group
    -- type, and a one-line composition summary (e.g. "2 Tank  5 Healer  13
    -- DPS") sits above the per-role breakdown so the shape of the group is
    -- readable at a glance before the squares.
    tt:AddLine(("%s (%d)"):format(IsInRaid() and "Raid" or "Party", total), 1, 0.82, 0)
    tt:AddLine(("%d Tank  %d Healer  %d DPS"):format(#byRole.TANK, #byRole.HEALER, #byRole.DAMAGER), 0.8, 0.8, 0.8)

    for _, role in ipairs(ROLES) do
        local squares = {}
        for _, class in ipairs(byRole[role]) do
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
            squares[#squares + 1] = "|c" .. (c and c.colorStr or "ffffffff") .. "\226\150\160|r"
        end
        tt:AddDoubleLine(ROLE_LABEL[role], #squares > 0 and table.concat(squares, " ") or "-",
            1, 1, 1, 1, 1, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Role icon styles
-- ---------------------------------------------------------------------------
-- Since this module docks onto EllesmereUI's own Raid Tools icon, its default
-- style should look like EllesmereUI's, not some other addon's -- but the
-- other styles here are offered too since there's no reason to force just
-- one. Each style is `kind = "atlas"` (a plain Blizzard atlas name, nothing
-- to embed -- the art lives in the game client) or `kind = "texture"` (a
-- bundled .tga file under Media\RoleIcons\, an actual asset we ship).
--
-- atlas styles: the first 5 are sourced from EllesmereUIRaidFrames.lua's own
-- ROLE_ICON_STYLES table (7 variants there); its other 2 styles ("modern",
-- the actual EUI default, and "blizzLight") point at EUI's own custom PNGs
-- under EllesmereUIRaidFrames\Media\ -- deliberately NOT reproduced here:
-- EUI's license.txt is "all rights reserved" (no redistribution permission),
-- so we stick to what's safe to reference. "NDui" is what NDui's own
-- raid-frame UI actually shows (B:ReskinSmallRole in
-- NDui/Core/Functions.lua) -- also a plain Blizzard atlas reference, not a
-- copy of an NDui-authored asset.
--
-- texture styles: NDui_Plus overrides NDui's B.ReskinSmallRole with a choice
-- of custom icon sets (NDui_Plus/Media/Media.lua, P.RoleList) instead of the
-- plain atlas -- genuinely different art, and the reason it's said to look
-- better. NDui_Plus is MIT-licensed (Media\RoleIcons\LICENSE.txt has the
-- full text), so its .tga files are copied here rather than just referenced,
-- same as any other bundled Lib -- this module doesn't depend on NDui_Plus
-- being installed. Only 4 of NDui_Plus's 5 RoleList entries have real files
-- in this install (`ToxiUI/Stylized*` is a dead reference with no backing
-- texture there), so only those 4 are offered.
local ROLE_ICON_MEDIA = "Interface\\AddOns\\AniMods\\Media\\RoleIcons\\"
local ICON_STYLES = {
    moderncircle = {
        name = "Modern Circle",
        kind = "atlas",
        icons = { TANK = "UI-LFG-RoleIcon-Tank", HEALER = "UI-LFG-RoleIcon-Healer", DAMAGER = "UI-LFG-RoleIcon-DPS" },
    },
    styled = {
        name = "Styled",
        kind = "atlas",
        icons = { TANK = "UI-LFG-RoleIcon-Tank-Background", HEALER = "UI-LFG-RoleIcon-Healer-Background", DAMAGER = "UI-LFG-RoleIcon-DPS-Background" },
    },
    classiccircle = {
        name = "Classic Circle",
        kind = "atlas",
        icons = { TANK = "UI-LFG-RoleIcon-Tank-Micro-GroupFinder", HEALER = "UI-LFG-RoleIcon-Healer-Micro-GroupFinder", DAMAGER = "UI-LFG-RoleIcon-DPS-Micro-GroupFinder" },
    },
    classic = {
        name = "Classic",
        kind = "atlas",
        icons = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" },
    },
    blizzdefault = {
        name = "Blizzard Default",
        kind = "atlas",
        icons = { TANK = "GM-icon-role-tank", HEALER = "GM-icon-role-healer", DAMAGER = "GM-icon-role-dps" },
    },
    ndui = {
        name = "NDui",
        kind = "atlas",
        icons = { TANK = "groupfinder-icon-role-micro-tank", HEALER = "groupfinder-icon-role-micro-heal", DAMAGER = "groupfinder-icon-role-micro-dps" },
    },
    nduiplus_lyn = {
        name = "NDui_Plus: LynUI",
        kind = "texture",
        icons = { TANK = ROLE_ICON_MEDIA .. "LynUI\\Tank", HEALER = ROLE_ICON_MEDIA .. "LynUI\\Healer", DAMAGER = ROLE_ICON_MEDIA .. "LynUI\\DPS" },
    },
    nduiplus_elv = {
        name = "NDui_Plus: ElvUI",
        kind = "texture",
        icons = { TANK = ROLE_ICON_MEDIA .. "ElvUI\\Tank", HEALER = ROLE_ICON_MEDIA .. "ElvUI\\Healer", DAMAGER = ROLE_ICON_MEDIA .. "ElvUI\\DPS" },
    },
    nduiplus_toxiwhite = {
        name = "NDui_Plus: ToxiUI White",
        kind = "texture",
        icons = { TANK = ROLE_ICON_MEDIA .. "ToxiUI\\WhiteTank", HEALER = ROLE_ICON_MEDIA .. "ToxiUI\\WhiteHeal", DAMAGER = ROLE_ICON_MEDIA .. "ToxiUI\\WhiteDPS" },
    },
    nduiplus_toxinew = {
        name = "NDui_Plus: ToxiUI New",
        kind = "texture",
        icons = { TANK = ROLE_ICON_MEDIA .. "ToxiUI\\NewTank", HEALER = ROLE_ICON_MEDIA .. "ToxiUI\\NewHeal", DAMAGER = ROLE_ICON_MEDIA .. "ToxiUI\\NewDPS" },
    },
}

local ICON_STYLE_ORDER = {
    "moderncircle", "styled", "classiccircle", "classic", "blizzdefault", "ndui",
    "nduiplus_lyn", "nduiplus_elv", "nduiplus_toxiwhite", "nduiplus_toxinew",
}

local function GetIconStyle()
    local key = ModuleDB().iconStyle
    if key and ICON_STYLES[key] then return key end
    return "moderncircle"
end

-- ---------------------------------------------------------------------------
-- Displays: a badge docked to EUI's icon, and a LibDataBroker data source
-- (pick it as a widget in EllesmereUIDataBars, or any other LDB-consuming
-- data bar)
-- ---------------------------------------------------------------------------

local Broker = AniMods.Broker

local dockedBadge  -- compact badge anchored to EllesmereUIRaidToolsIcon
local docked = false -- true once EUI's icon has been found and the badge wired to it
local ldbObject    -- LibDataBroker data source, if LDB is available

local function InitLDB()
    ldbObject = Broker.Register("AniModsRaidComposition", {
        label = "AniMods: Raid Composition",
        -- Left click: Blizzard's own raid roster/role/ready-check frame --
        -- the actual raid-management UI, not this module's settings.
        -- ToggleRaidFrame is the standard global for it (same one
        -- SavedInstances uses), lazy-loading Blizzard_RaidUI on first call;
        -- guarded against combat lockdown the same way that addon does,
        -- since it can touch protected frames. Right (or middle) click:
        -- straight to this module's own tab in the AniMods panel.
        OnClick = function(frame, button)
            if button == "LeftButton" then
                if ToggleRaidFrame and not InCombatLockdown() then
                    ToggleRaidFrame()
                end
            elseif AniMods.OpenModuleTab then
                AniMods.OpenModuleTab("RaidComposition")
            end
        end,
        -- No self-titled header line -- the tooltip already only ever shows
        -- up when hovering this exact plugin, so "AniMods: Raid Composition"
        -- was just noise.
        OnTooltipShow = ShowCompositionTooltip,
    })
end

-- The shared builder (AniMods.Broker) owns the icon/text formatting and the
-- display-mode setting; this only has to say what the parts ARE -- one per
-- role, carrying its count, its color, and its icon from whichever style is
-- currently selected (an atlas name or a bundled texture path, depending on
-- that style's `kind`).
local function BuildBrokerText(counts)
    local style = ICON_STYLES[GetIconStyle()] or ICON_STYLES.moderncircle
    local parts = {}
    for i, role in ipairs(ROLES) do
        local part = { count = counts[role], color = ROLE_COLOR[role] }
        if style.kind == "atlas" then
            part.atlas = style.icons[role]
        else
            part.texture = style.icons[role]
        end
        parts[i] = part
    end
    return Broker.BuildText(ModuleDB, parts)
end

local function UpdateCounts()
    local counts = CountRoles()
    local inGroup = IsInGroup()

    if dockedBadge then
        dockedBadge.text:SetFormattedText(
            "|cff%s%d|r/|cff%s%d|r/|cff%s%d|r",
            ROLE_COLOR.TANK, counts.TANK, ROLE_COLOR.HEALER, counts.HEALER, ROLE_COLOR.DAMAGER, counts.DAMAGER)
    end

    if ldbObject then
        -- Empty (not "N/A") when not in a group, on request: with a
        -- transparent databar background, an empty-text block just
        -- disappears instead of leaving "N/A" sitting there.
        ldbObject.text = inGroup and BuildBrokerText(counts) or ""
    end
end

local function SetIconStyle(key)
    ModuleDB().iconStyle = key
    UpdateCounts() -- broker text embeds the icon style too
end

-- The 8 standard GameTooltip anchor points -- badge is tiny (36x12) and sits
-- right below EUI's own Raid Tools icon, so where the tooltip pops out
-- relative to it matters (e.g. straight up overlaps the icon above it);
-- letting it be picked beats guessing one default that won't suit every
-- setup.
local TOOLTIP_ANCHOR_LABEL = {
    TOP = "Top", BOTTOM = "Bottom", LEFT = "Left", RIGHT = "Right",
    TOPLEFT = "Top Left", TOPRIGHT = "Top Right", BOTTOMLEFT = "Bottom Left", BOTTOMRIGHT = "Bottom Right",
}
local TOOLTIP_ANCHOR_ORDER = { "TOP", "BOTTOM", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

local function GetTooltipAnchor()
    local key = ModuleDB().dockedTooltipAnchor
    if key and TOOLTIP_ANCHOR_LABEL[key] then return key end
    return "RIGHT" -- doesn't overlap the EUI icon sitting directly above the badge
end

-- Small text-only badge (an icon row doesn't fit under a 30x30 button) docked
-- just below EUI's collapsed Raid Tools icon. No tooltip by default -- it's
-- sitting right on top of EUI's own Raid Tools UI, and a second popup
-- fighting for the same screen space can be more annoying than useful -- but
-- opt-in via "Show tooltip on docked badge" in GetInfoRows for anyone who
-- wants the same per-role breakdown here that the broker (LDB) plugin always
-- shows. Checked live inside OnEnter rather than toggling EnableMouse/the
-- scripts themselves, so flipping the option takes effect immediately.
local function BuildDockedBadge(iconBtn)
    local badge = CreateFrame("Frame", "AniModsRaidCompositionDocked", UIParent)
    badge:SetSize(36, 12)
    badge:SetFrameStrata(iconBtn:GetFrameStrata())
    badge:SetFrameLevel(iconBtn:GetFrameLevel() + 5)
    badge:SetPoint("TOP", iconBtn, "BOTTOM", 0, -1)
    badge:Hide()

    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge.text:SetAllPoints()
    badge.text:SetJustifyH("CENTER")
    local fontPath = badge.text:GetFont()
    badge.text:SetFont(fontPath, 9, "OUTLINE")

    badge:EnableMouse(true)
    badge:SetScript("OnEnter", function(self)
        if not ModuleDB().dockedTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_" .. GetTooltipAnchor())
        ShowCompositionTooltip(GameTooltip)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return badge
end

-- EllesmereUIQoL_RaidTools.lua exposes `_G._EUI_RaidTools_DB = function()
-- return db end` for its own options panel -- a plain read-only getter, safe
-- to call from outside. db.profile.raidTools.mode is "never" (QoL's own
-- default -- Raid Tools built/shown nowhere at all), or "raid"/"group"/
-- "always". This is the authoritative answer to "is Raid Tools even on",
-- independent of (and available before) whether we've actually found/docked
-- to its icon yet.
local function GetEUIRaidToolsMode()
    local getDB = _G._EUI_RaidTools_DB
    local db = getDB and getDB()
    return db and db.profile and db.profile.raidTools and db.profile.raidTools.mode
end

-- Whether the docked badge should actually be visible -- distinct from
-- `docked` (which just means "hooked up and tracking"). Off is useful
-- together with the broker (LDB) plugin: same counts shown twice (once
-- docked under the icon, once in a databar) can be redundant, so this lets
-- the docked badge stay hooked (still cheap to keep resyncing) but hidden.
local function ShowDockedBadge()
    return ModuleDB().showDockedBadge ~= false -- default: on
end

-- Set inside TryDockToEUIIcon once the badge/icon are known; re-invoked by
-- the "Show docked badge" toggle so flipping it applies immediately without
-- waiting for the icon's own Show/Hide/OnClick/ticker triggers.
local resyncDockedBadge

-- EllesmereUIQoL only builds its Raid Tools frames (including the collapsed
-- icon) on first Apply with a non-"never" mode -- in other words, we can only
-- ever dock while GetEUIRaidToolsMode() ~= "never". "never" is QoL's own
-- default, meaning the icon frame may not exist yet (or ever) at our own
-- Enable() time. Called from Enable() and re-checked on a few login-delay
-- timers plus GROUP_ROSTER_UPDATE so we still dock if it appears later.
-- Docking is the only display mode -- once found, this runs at most once
-- ever (hooksecurefunc can't be un-hooked, so there's nothing to undo).
local function TryDockToEUIIcon()
    if docked then return end
    local iconBtn = _G.EllesmereUIRaidToolsIcon
    if not iconBtn then return end

    docked = true
    dockedBadge = BuildDockedBadge(iconBtn)

    -- Split on purpose: visibility sync (cheap -- one IsShown() check) vs.
    -- a full resync (also recomputes counts -- a roster walk + broker text
    -- rebuild, not free). Real state-change moments (Show/Hide/OnClick, the
    -- "Show docked badge" toggle) get the full resync; the backstop ticker
    -- below gets only the cheap half. Bundling both into one function that
    -- a 0.15s ticker called forever -- the original shape here -- meant
    -- redoing the roster walk ~7 times a second for the entire session
    -- regardless of whether anything changed, the same category of mistake
    -- as the AniMods panel's old rebuild-every-second ticker (see UI.lua's
    -- history): a timer standing in for real event coverage.
    local function ResyncVisibility()
        dockedBadge:SetShown(ShowDockedBadge() and iconBtn:IsShown())
    end

    resyncDockedBadge = function()
        ResyncVisibility()
        UpdateCounts()
    end

    hooksecurefunc(iconBtn, "Show", resyncDockedBadge)
    hooksecurefunc(iconBtn, "Hide", resyncDockedBadge)
    -- Clicking the icon expands it (collapsed -> windows) via EUI's secure
    -- "_onclick" attribute snippet, a separate execution path from the
    -- button's ordinary OnClick script -- but the button still fires its
    -- normal OnClick too (SecureHandlerClickTemplate adds the secure path,
    -- it doesn't remove the standard one), so this observes the click
    -- itself rather than waiting on Show/Hide to have actually propagated
    -- yet, for zero added latency on this specific transition.
    iconBtn:HookScript("OnClick", resyncDockedBadge)
    resyncDockedBadge()

    -- Belt-and-suspenders for every OTHER path that hides/shows the icon
    -- (driver transitions, the toggle keybind, a shell's own collapse
    -- button -- none of which we have a direct handle on to hook their
    -- click, and none of which route through iconBtn's own Show/Hide if
    -- what actually changed was a PARENT frame's visibility): genuinely
    -- cheap now that it's just the IsShown() check, not a roster walk.
    -- GROUP_ROSTER_UPDATE/UNIT_FLAGS/PLAYER_ENTERING_WORLD (see Enable())
    -- are what actually drive count freshness.
    C_Timer.NewTicker(0.15, ResyncVisibility)
end

-- ---------------------------------------------------------------------------
-- Status panel: live composition + display options
-- ---------------------------------------------------------------------------

function RaidComposition:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    if not IsInGroup() then
        rows[#rows + 1] = { label = "Status", value = "N/A (not in a group)" }
    else
        local counts = CountRoles()
        rows[#rows + 1] = { label = "Group type", value = IsInRaid() and "Raid" or "Party" }
        rows[#rows + 1] = { label = "Tanks",      value = tostring(counts.TANK) }
        rows[#rows + 1] = { label = "Healers",    value = tostring(counts.HEALER) }
        rows[#rows + 1] = { label = "DPS",        value = tostring(counts.DAMAGER) }
    end

    rows[#rows + 1] = { section = "Integration" }
    local dockStatus
    if docked then
        dockStatus = "Yes"
    else
        local mode = GetEUIRaidToolsMode()
        if mode == "never" then
            dockStatus = "No (Raid Tools disabled, mode: never)"
        elseif not mode then
            dockStatus = "No (Raid Tools not configured yet)"
        else
            dockStatus = "No (waiting for its icon to appear)"
        end
    end
    rows[#rows + 1] = { label = "Docked to EllesmereUI icon", value = dockStatus }
    rows[#rows + 1] = {
        label = "Show docked badge",
        get   = ShowDockedBadge,
        set   = function(v)
            ModuleDB().showDockedBadge = v
            if resyncDockedBadge then resyncDockedBadge() end
        end,
    }
    rows[#rows + 1] = {
        label = "Show tooltip on docked badge",
        get   = function() return ModuleDB().dockedTooltip == true end,
        set   = function(v) ModuleDB().dockedTooltip = v end,
    }
    rows[#rows + 1] = {
        label   = "Tooltip anchor",
        options = TOOLTIP_ANCHOR_LABEL,
        order   = TOOLTIP_ANCHOR_ORDER,
        get     = GetTooltipAnchor,
        set     = function(v) ModuleDB().dockedTooltipAnchor = v end,
    }
    rows[#rows + 1] = { label = "Broker (LDB) plugin", value = ldbObject and "Registered" or "Not available" }

    for _, row in ipairs(Broker.DisplayRows(ModuleDB, UpdateCounts)) do
        rows[#rows + 1] = row
    end

    rows[#rows + 1] = { section = "Icon Style" }
    local styleOptions, styleOrder = {}, {}
    for _, key in ipairs(ICON_STYLE_ORDER) do
        styleOptions[key] = ICON_STYLES[key].name
        styleOrder[#styleOrder + 1] = key
    end
    local currentStyle = ICON_STYLES[GetIconStyle()]
    local previewIcons = { currentStyle.icons.TANK, currentStyle.icons.HEALER, currentStyle.icons.DAMAGER }
    local styleRow = {
        label   = "Style",
        options = styleOptions,
        order   = styleOrder,
        get     = GetIconStyle,
        set     = SetIconStyle,
    }
    if currentStyle.kind == "atlas" then
        styleRow.atlas = previewIcons
    else
        styleRow.texture = previewIcons
    end
    rows[#rows + 1] = styleRow

    return rows
end

function RaidComposition:Enable()
    InitLDB()
    UpdateCounts()

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("UNIT_FLAGS")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:SetScript("OnEvent", function()
        TryDockToEUIIcon()
        UpdateCounts()
        -- Nudge the AniMods panel too, if it's open on this tab -- the
        -- "Status" section's live Tanks/Healers/DPS counts have no other way
        -- to notice a roster change (the panel no longer polls; see UI.lua).
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)

    TryDockToEUIIcon()
    for _, delay in ipairs({ 2, 5, 10, 20 }) do
        C_Timer.After(delay, TryDockToEUIIcon)
    end
end

AniMods.RegisterModule("RaidComposition", RaidComposition)
