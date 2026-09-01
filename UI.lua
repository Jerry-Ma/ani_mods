-- AniMods status/config panel. `/animods` (or `/ani`) toggles it.
--
-- Two-pane layout: a left list of modules (status dot + name + a quick
-- enable/disable toggle right on the row) and a right detail pane showing
-- the selected module's full description/state/reason with room to actually
-- read it, instead of cramming everything into one narrow scrolling list.
--
-- Self-contained on purpose: plain CreateFrame + BackdropTemplate + standard
-- Blizzard XML templates (UIPanelScrollFrameTemplate, UIPanelButtonTemplate).
-- No embedded third-party UI library — nothing to go stale if another addon
-- that happened to ship one gets removed/updated by CurseForge.

local ADDON_NAME = "AniMods"
local AniMods = _G.AniMods

local ACCENT = { 1, 0.82, 0 }         -- gold accent, matches the rest of the workspace's addon titles
local PANEL_BG = { 0.07, 0.07, 0.08, 0.96 }
local PANE_BG = { 1, 1, 1, 0.03 }
local ROW_HOVER = { ACCENT[1], ACCENT[2], ACCENT[3], 0.10 }
local ROW_SELECTED = { ACCENT[1], ACCENT[2], ACCENT[3], 0.20 }

local PANEL_WIDTH, PANEL_HEIGHT = 640, 480
local LEFT_WIDTH = 200
local ROW_HEIGHT = 32

local frame
local rowPool = {}
local selectedModule

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

local function SortedModuleNames()
    local names = {}
    for name in pairs(AniMods.status) do tinsert(names, name) end
    table.sort(names)
    return names
end

-- ── Copy-to-clipboard popup (for full Enable() error tracebacks) ─────────────

local copyPopup

local function BuildCopyPopup()
    local f = CreateFrame("Frame", "AniModsCopyPopup", UIParent, "BackdropTemplate")
    f:SetSize(560, 340)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG") -- above the (non-DIALOG) AniMods panel it's opened from
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(unpack(PANEL_BG))
    f:SetBackdropBorderColor(1, 0.35, 0.35, 0.7)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(_G.UISpecialFrames, "AniModsCopyPopup")

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 14, -12)
    f.title:SetPoint("RIGHT", f, "RIGHT", -30, 0)
    f.title:SetJustifyH("LEFT")
    f.title:SetTextColor(1, 0.45, 0.45)

    f.closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.closeBtn:SetPoint("TOPRIGHT", -2, -2)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.hint:SetPoint("TOPLEFT", 14, -32)
    f.hint:SetText("Ctrl+A, Ctrl+C to copy. Esc to close.")

    local scrollBg = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    scrollBg:SetPoint("TOPLEFT", 10, -50)
    scrollBg:SetPoint("BOTTOMRIGHT", -10, 10)

    local scroll = CreateFrame("ScrollFrame", "AniModsCopyScroll", scrollBg, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(500)
    edit:SetHeight(800) -- generous fixed height; the scrollframe clips/scrolls it
    edit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        f:Hide()
    end)
    scroll:SetScrollChild(edit)
    f.edit = edit

    copyPopup = f
    return f
end

local function ShowCopyPopup(title, text)
    local f = copyPopup or BuildCopyPopup()
    f.title:SetText(title)
    f.edit:SetText(text or "")
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

-- ── Info rows: each module's live "debug + options" readout ──────────────────
-- A module's GetInfoRows() (optional) returns an ordered list of rows:
--   { label = "Tanks", value = "2" }                                  -- status
--   { label = "Party", get = fn, set = fn, note = "active now" }      -- toggle
-- Anything with `get` renders as a checkbox; everything else is a plain
-- label/value readout. This is deliberately the one generic row shape both
-- of AniMods' current modules need (a live status line, or a toggle with a
-- live annotation) rather than separate Status/Options mini-frameworks.

local INFO_ROW_HEIGHT = 22
local infoRowPool = {}

local function GetInfoRow(parent, index)
    local row = infoRowPool[index]
    if row then return row end

    row = CreateFrame("Frame", nil, parent)
    row:SetHeight(INFO_ROW_HEIGHT)

    row.checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.checkbox:SetSize(18, 18)
    row.checkbox:SetPoint("LEFT", 0, 0)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetJustifyH("LEFT")

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT", 0, 0)
    row.value:SetJustifyH("RIGHT")

    infoRowPool[index] = row
    return row
end

local function RefreshInfoRows(container, rows)
    for _, row in ipairs(infoRowPool) do row:Hide() end
    if not container then return end

    local y = 0
    for i, descriptor in ipairs(rows or {}) do
        local row = GetInfoRow(container, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", container, "RIGHT", 0, 0)

        if descriptor.get then
            row.checkbox:Show()
            row.checkbox:SetChecked(descriptor.get())
            row.checkbox:SetScript("OnClick", function(self)
                descriptor.set(self:GetChecked())
                -- Rows can be part of a radio-style group (e.g. an icon style
                -- picker: many get/set pairs, only one true at a time) -- one
                -- click can change what every other row's get() now returns,
                -- so resync the whole list immediately rather than waiting
                -- for the periodic refresh.
                if AniMods.RefreshUI then AniMods.RefreshUI() end
            end)
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", row.checkbox, "RIGHT", 4, 0)
            row.label:SetText(descriptor.label)
            row.value:SetText(descriptor.note and ("|cff59ff59" .. descriptor.note .. "|r") or "")
        else
            row.checkbox:Hide()
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", 0, 0)
            row.label:SetText(descriptor.label)
            row.value:SetText(descriptor.value or "")
        end

        row:Show()
        y = y + INFO_ROW_HEIGHT
    end

    container:SetHeight(math.max(1, y))
end

-- ── Right pane: detail view for the selected module ──────────────────────────

local function RefreshDetail()
    local right = frame.right
    local name = selectedModule
    local entry = name and AniMods.status[name]

    if not entry then
        right.title:SetText("")
        right.state:SetText("")
        right.desc:SetText("|cff888888Select a module on the left.|r")
        right.reason:SetText("")
        right.toggle:Hide()
        right.copyBtn:Hide()
        right.key:SetText("")
        RefreshInfoRows(right.infoContent, nil)
        return
    end

    local stateLabel, r, g, b = GetStateInfo(entry)
    right.title:SetText(entry.title)
    right.state:SetText("[" .. stateLabel .. "]")
    right.state:SetTextColor(r, g, b)
    right.desc:SetText(entry.description or "|cff888888(no description)|r")

    if entry.errorTrace then
        right.reason:SetText("|cffff4444" .. (entry.conditionReason or "error") .. "|r")
    elseif entry.conditionReason then
        right.reason:SetText("|cffff9933" .. entry.conditionReason .. "|r")
    else
        right.reason:SetText("")
    end

    right.toggle:Show()
    right.toggle:SetChecked(entry.userEnabled)
    right.copyBtn:SetShown(entry.errorTrace ~= nil)
    right.key:SetText("|cff555555" .. name .. "|r")

    -- Defensive: a module's GetInfoRows() runs on our UI thread on a timer
    -- (see the OnUpdate refresh in BuildUI) -- one buggy module's debug hook
    -- must never be able to break the whole panel.
    local rows
    if entry.module and entry.module.GetInfoRows then
        local ok, result = pcall(entry.module.GetInfoRows, entry.module)
        if ok then rows = result end
    end
    RefreshInfoRows(right.infoContent, rows)
end

-- ── Left pane: module list ────────────────────────────────────────────────────

local function SelectModule(name)
    selectedModule = name
    for _, row in ipairs(rowPool) do
        row.selectedBg:SetShown(row.moduleName == name)
    end
    RefreshDetail()
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(LEFT_WIDTH - 10, ROW_HEIGHT - 2)
    row:SetPoint("TOPLEFT", 2, -(index - 1) * ROW_HEIGHT)

    row.hoverBg = row:CreateTexture(nil, "BACKGROUND")
    row.hoverBg:SetAllPoints()
    row.hoverBg:SetColorTexture(unpack(ROW_HOVER))
    row.hoverBg:Hide()

    row.selectedBg = row:CreateTexture(nil, "BACKGROUND")
    row.selectedBg:SetAllPoints()
    row.selectedBg:SetColorTexture(unpack(ROW_SELECTED))
    row.selectedBg:Hide()

    row.dot = row:CreateTexture(nil, "OVERLAY")
    row.dot:SetSize(8, 8)
    row.dot:SetPoint("LEFT", 4, 0)
    row.dot:SetColorTexture(1, 1, 1)

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.title:SetPoint("LEFT", row.dot, "RIGHT", 6, 0)
    row.title:SetPoint("RIGHT", row, "RIGHT", -26, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    row.toggle = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.toggle:SetSize(18, 18)
    row.toggle:SetPoint("RIGHT", -2, 0)
    row.toggle:SetScript("OnClick", function(self)
        if row.moduleName then
            AniMods.SetModuleEnabled(row.moduleName, self:GetChecked())
        end
    end)

    row:SetScript("OnClick", function() SelectModule(row.moduleName) end)
    row:SetScript("OnEnter", function() row.hoverBg:Show() end)
    row:SetScript("OnLeave", function() row.hoverBg:Hide() end)

    return row
end

local function RefreshList()
    local names = SortedModuleNames()

    for _, row in ipairs(rowPool) do row:Hide() end

    for i, name in ipairs(names) do
        local entry = AniMods.status[name]
        local row = rowPool[i]
        if not row then
            row = CreateRow(frame.left.content, i)
            rowPool[i] = row
        end

        row.moduleName = name
        row.title:SetText(entry.title)

        local _, r, g, b = GetStateInfo(entry)
        row.dot:SetVertexColor(r, g, b)
        row.selectedBg:SetShown(name == selectedModule)
        row.toggle:SetChecked(entry.userEnabled)

        row:Show()
    end

    frame.left.content:SetHeight(math.max(1, #names * ROW_HEIGHT))

    if not selectedModule and names[1] then
        SelectModule(names[1])
    end
end

-- Called by Core.lua whenever module state changes (e.g. a toggle) so the
-- panel resyncs without a full rebuild.
function AniMods.RefreshUI()
    if not frame then return end
    RefreshList()
    RefreshDetail()
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildLeftPane(parent)
    local left = CreateFrame("Frame", nil, parent)
    left:SetPoint("TOPLEFT", 10, -50)
    left:SetPoint("BOTTOMLEFT", 10, 40)
    left:SetWidth(LEFT_WIDTH)

    local bg = left:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(PANE_BG))

    local inset = CreateFrame("Frame", nil, left, "InsetFrameTemplate")
    inset:SetAllPoints()

    local scroll = CreateFrame("ScrollFrame", "AniModsListScroll", left, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -22, 4)

    left.content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(left.content)
    left.content:SetWidth(LEFT_WIDTH - 26)
    left.content:SetHeight(1)

    return left
end

local function BuildRightPane(parent, leftPane)
    local right = CreateFrame("Frame", nil, parent)
    right:SetPoint("TOPLEFT", leftPane, "TOPRIGHT", 12, 0)
    right:SetPoint("BOTTOMRIGHT", -10, 40)

    local bg = right:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(PANE_BG))

    local inset = CreateFrame("Frame", nil, right, "InsetFrameTemplate")
    inset:SetAllPoints()

    right.state = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    right.state:SetPoint("TOPRIGHT", -14, -17)

    right.title = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    right.title:SetPoint("TOPLEFT", 14, -14)
    right.title:SetPoint("RIGHT", right.state, "LEFT", -8, 0)
    right.title:SetJustifyH("LEFT")
    right.title:SetWordWrap(false)
    right.title:SetTextColor(unpack(ACCENT))

    right.desc = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    right.desc:SetPoint("TOPLEFT", right.title, "BOTTOMLEFT", 0, -12)
    right.desc:SetPoint("RIGHT", right, "RIGHT", -14, 0)
    right.desc:SetJustifyH("LEFT")
    right.desc:SetWordWrap(true)
    right.desc:SetSpacing(3)

    right.reason = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    right.reason:SetPoint("TOPLEFT", right.desc, "BOTTOMLEFT", 0, -10)
    right.reason:SetPoint("RIGHT", right, "RIGHT", -14, 0)
    right.reason:SetJustifyH("LEFT")
    right.reason:SetWordWrap(true)
    right.reason:SetSpacing(3)

    -- Live status + per-item options (GetInfoRows()), scrollable since content
    -- length varies per module.
    local infoBg = CreateFrame("Frame", nil, right, "InsetFrameTemplate")
    infoBg:SetPoint("TOPLEFT", right.reason, "BOTTOMLEFT", -4, -10)
    infoBg:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    infoBg:SetPoint("BOTTOM", right, "BOTTOM", 0, 62)

    local infoScroll = CreateFrame("ScrollFrame", "AniModsInfoScroll", infoBg, "UIPanelScrollFrameTemplate")
    infoScroll:SetPoint("TOPLEFT", 4, -4)
    infoScroll:SetPoint("BOTTOMRIGHT", -22, 4)

    right.infoContent = CreateFrame("Frame", nil, infoScroll)
    infoScroll:SetScrollChild(right.infoContent)
    right.infoContent:SetHeight(1)
    infoScroll:SetScript("OnSizeChanged", function(self, w)
        right.infoContent:SetWidth(w)
    end)

    right.toggle = CreateFrame("CheckButton", nil, right, "UICheckButtonTemplate")
    right.toggle:SetSize(24, 24)
    right.toggle:SetPoint("BOTTOMLEFT", 10, 10)
    right.toggle:SetScript("OnClick", function(self)
        if selectedModule then
            AniMods.SetModuleEnabled(selectedModule, self:GetChecked())
        end
    end)

    right.toggleLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    right.toggleLabel:SetPoint("LEFT", right.toggle, "RIGHT", 4, 0)
    right.toggleLabel:SetText("Enabled  |cff888888(/reload to apply)|r")

    right.copyBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
    right.copyBtn:SetSize(110, 20)
    right.copyBtn:SetPoint("BOTTOMRIGHT", -10, 40)
    right.copyBtn:SetText("Show Error")
    right.copyBtn:SetScript("OnClick", function()
        local entry = selectedModule and AniMods.status[selectedModule]
        if entry and entry.errorTrace then
            ShowCopyPopup(entry.title .. " — Enable() error", entry.errorTrace)
        end
    end)
    right.copyBtn:Hide()

    right.key = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    right.key:SetPoint("BOTTOMRIGHT", -10, 14)

    return right
end

local function BuildUI()
    if frame then return end

    local f = CreateFrame("Frame", "AniModsFrame", UIParent, "BackdropTemplate")
    f:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    f:SetPoint("CENTER")
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
    f.hint:SetText("Left: modules (click to select, checkbox to toggle). Right: details for the selected module.")

    f.left = BuildLeftPane(f)
    f.right = BuildRightPane(f, f.left)

    f.reloadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.reloadBtn:SetSize(120, 22)
    f.reloadBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    f.reloadBtn:SetText("Reload UI")
    f.reloadBtn:SetScript("OnClick", function() ReloadUI() end)

    f:SetScript("OnShow", function()
        RefreshList()
        RefreshDetail()
    end)

    -- Keep the selected module's info rows (live status/eligibility) fresh
    -- while the panel is open. OnUpdate doesn't fire on hidden frames, so
    -- this naturally stops costing anything once the panel is closed.
    local INFO_REFRESH_INTERVAL = 1.0
    f.infoRefreshElapsed = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self.infoRefreshElapsed = self.infoRefreshElapsed + elapsed
        if self.infoRefreshElapsed >= INFO_REFRESH_INTERVAL then
            self.infoRefreshElapsed = 0
            RefreshDetail()
        end
    end)

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
