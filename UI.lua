-- AniMods status/config panel. `/animods` toggles it. One row per registered
-- module: colored status dot, title, condition/failure reason (if any), and an
-- enable/disable checkbox.
--
-- Self-contained on purpose: plain CreateFrame + BackdropTemplate + standard
-- Blizzard XML templates (UIPanelScrollFrameTemplate, UIPanelButtonTemplate).
-- No embedded third-party UI library — nothing to go stale if another addon
-- that happened to ship one gets removed/updated by CurseForge.

local ADDON_NAME = "AniMods"
local AniMods = _G.AniMods

local ACCENT = { 1, 0.82, 0 }         -- gold accent, matches the rest of the workspace's addon titles
local PANEL_BG = { 0.07, 0.07, 0.08, 0.96 }
local ROW_BG = { 1, 1, 1, 0.03 }
local ROW_HOVER = { ACCENT[1], ACCENT[2], ACCENT[3], 0.08 }

local ROW_HEIGHT = 54
local PANEL_WIDTH, PANEL_HEIGHT = 460, 420

local frame
local rowPool = {}

-- Returns label, r, g, b for a module's current status entry.
local function GetStateInfo(entry)
    if entry.active then
        return "Active", 0.35, 1, 0.35
    elseif not entry.userEnabled then
        return "Disabled", 0.55, 0.55, 0.55
    elseif entry.conditionMet then
        return "Failed", 1, 0.35, 0.35
    else
        return "Inactive", 1, 0.75, 0.15
    end
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(PANEL_WIDTH - 20, ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 2, -(index - 1) * ROW_HEIGHT)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(unpack(ROW_BG))

    row.hover = row:CreateTexture(nil, "ARTWORK")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(unpack(ROW_HOVER))
    row.hover:Hide()

    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(9, 9)
    row.dot:SetPoint("TOPLEFT", 8, -8)
    row.dot:SetColorTexture(1, 1, 1)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.title:SetPoint("TOPLEFT", row.dot, "TOPRIGHT", 8, 2)
    row.title:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.state = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.state:SetPoint("LEFT", row.title, "RIGHT", 6, 0)

    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.note:SetPoint("TOPLEFT", row.dot, "BOTTOMRIGHT", 8, -6)
    row.note:SetPoint("RIGHT", row, "RIGHT", -60, 0)
    row.note:SetJustifyH("LEFT")
    row.note:SetWordWrap(true)
    row.note:SetHeight(28)

    row.toggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.toggle:SetSize(24, 24)
    row.toggle:SetPoint("TOPRIGHT", -4, -4)
    row.toggle:SetScript("OnClick", function(self)
        if row.moduleName then
            AniMods.SetModuleEnabled(row.moduleName, self:GetChecked())
        end
    end)

    row:EnableMouse(true)
    row:SetScript("OnEnter", function() row.hover:Show() end)
    row:SetScript("OnLeave", function() row.hover:Hide() end)

    return row
end

local function RefreshRows()
    if not frame then return end

    local names = {}
    for name in pairs(AniMods.status) do tinsert(names, name) end
    table.sort(names)

    for _, row in ipairs(rowPool) do row:Hide() end

    for i, name in ipairs(names) do
        local entry = AniMods.status[name]
        local row = rowPool[i]
        if not row then
            row = CreateRow(frame.content, i)
            rowPool[i] = row
        end

        row.moduleName = name
        row.title:SetText(entry.title)

        local stateLabel, r, g, b = GetStateInfo(entry)
        row.state:SetText("[" .. stateLabel .. "]")
        row.state:SetTextColor(r, g, b)
        row.dot:SetVertexColor(r, g, b)

        row.note:SetText(entry.conditionReason or entry.description or "")
        row.toggle:SetChecked(entry.userEnabled)

        row:Show()
    end

    frame.content:SetHeight(math.max(1, #names * ROW_HEIGHT))
    frame.hint:SetShown(#names > 0)
end

-- Called by Core.lua whenever module state changes (e.g. a toggle) so the
-- panel's rows resync without a full rebuild.
function AniMods.RefreshUI()
    RefreshRows()
end

local function BuildUI()
    if frame then return end

    local f = CreateFrame("Frame", "AniModsFrame", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(PANEL_BG))
    f:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.6)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(_G.UISpecialFrames, "AniModsFrame")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetText("AniMods")
    f.title:SetTextColor(unpack(ACCENT))

    f.closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.closeBtn:SetPoint("TOPRIGHT", -2, -2)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", 14, -34)
    f.hint:SetText("Toggling a module requires /reload to take effect.")

    local scrollBg = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    scrollBg:SetPoint("TOPLEFT", 10, -50)
    scrollBg:SetPoint("BOTTOMRIGHT", -10, 40)

    local scroll = CreateFrame("ScrollFrame", "AniModsScroll", scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    f.content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(f.content)
    f.content:SetWidth(PANEL_WIDTH - 40)
    f.content:SetHeight(1)

    f.reloadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.reloadBtn:SetSize(120, 22)
    f.reloadBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    f.reloadBtn:SetText("Reload UI")
    f.reloadBtn:SetScript("OnClick", function() ReloadUI() end)

    f:SetScript("OnShow", RefreshRows)

    frame = f
end

function AniMods.ToggleUI()
    BuildUI()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
