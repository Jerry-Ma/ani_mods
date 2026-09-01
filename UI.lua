-- AniMods status/config panel. `/animods` (or `/ani`) toggles it.
--
-- Built on DetailsFramework's own DF:CreateTabContainer -- one tab per
-- registered module, each tab's body showing that module's title/state/
-- description/dependencies/reason plus its GetInfoRows() content. This is a
-- genuinely DF-native widget (real selected-tab border glow, proper title/
-- button layout) rather than a hand-rolled sidebar imitating one: NSRT's own
-- polished look turned out to come from a large amount of custom styling on
-- top of DF (its own button/color helpers), not from DF itself, and
-- replicating that by hand wasn't worth it for what this panel needs. Using
-- DF's native tab widget directly gets a properly-DF-styled result for a
-- fraction of the code, at the cost of tabs being a horizontal
-- (wrapping) row rather than NSRT's vertical sidebar.
--
-- DetailsFramework is bundled in Libs\DF (from Details, LGPL-2.1-or-later)
-- plus Libs\LibStub, loaded via the .toc before Core.lua/UI.lua -- not
-- relied on from NSRT or Details being installed.

local ADDON_NAME = "AniMods"
local AniMods = _G.AniMods
local DF = _G.DetailsFramework

local ACCENT = { 1, 0.82, 0 } -- gold accent, matches the rest of the workspace's addon titles
local PANEL_WIDTH, PANEL_HEIGHT = 700, 500

-- Content clears the tab button band (DF/tabcontainer.md's documented
-- pitfall: content anchored above this offset visually fights the buttons,
-- which are siblings drawn on top, not children of the tab body).
local CONTENT_TOP = -60

local tabContainer
local tabFrameByName = {}
local moduleOrder = {} -- names, index-aligned with the tab list
local currentTabName

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
    f:SetFrameStrata("DIALOG") -- above the AniMods panel it's opened from
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    f:SetBackdropColor(0.07, 0.07, 0.08, 0.96)
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
--   { section = "Status" }                                            -- header
--   { label = "Tanks", value = "2" }                                  -- status
--   { label = "Party", get = fn, set = fn, note = "active now" }      -- toggle
-- Rendered via DF:BuildMenuVolatile -- real polished widgets (checkboxes,
-- section labels). Specifically the *Volatile* variant (DF's own pooled/
-- rebuild-friendly one) rather than plain BuildMenu, because a module's row
-- count can change between refreshes (e.g. RaidComposition shows fewer status
-- rows solo than grouped) -- BuildMenu is "set in stone" and doesn't support
-- that; BuildMenuVolatile is built exactly for menus that get rebuilt often.

local function BuildMenuOptionsFromInfoRows(rows)
    local menuOptions = {}
    for _, descriptor in ipairs(rows or {}) do
        if descriptor.section then
            if #menuOptions > 0 then
                tinsert(menuOptions, { type = "blank" })
            end
            tinsert(menuOptions, {
                type = "label",
                get = function() return descriptor.section end,
                text_template = DF:GetTemplate("font", "ORANGE_FONT_TEMPLATE"),
            })
        elseif descriptor.get then
            local name = descriptor.label
            if descriptor.note then
                name = name .. "  |cff59ff59" .. descriptor.note .. "|r"
            end
            tinsert(menuOptions, {
                type = "toggle",
                name = name,
                get = descriptor.get,
                set = function(_, _, value)
                    descriptor.set(value)
                    -- Rows can be part of a radio-style group (e.g. an icon
                    -- style picker: many get/set pairs, only one true at a
                    -- time) -- one click can change what every other row's
                    -- get() now returns, so resync the whole tab immediately
                    -- rather than waiting for the periodic refresh.
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end,
            })
        else
            tinsert(menuOptions, {
                type = "label",
                get = function()
                    return descriptor.label .. ":  |cffaaaaaa" .. tostring(descriptor.value or "") .. "|r"
                end,
            })
        end
    end
    return menuOptions
end

local function RefreshInfoRows(container, rows)
    if not container or not DF then return end
    local menuOptions = BuildMenuOptionsFromInfoRows(rows)
    DF:BuildMenuVolatile(container, menuOptions, 6, -6, container:GetHeight(), false, nil, nil, nil, true)
end

-- ── Per-module tab content ────────────────────────────────────────────────────

local function RefreshModuleTab(name)
    local tabFrame = name and tabFrameByName[name]
    local entry = name and AniMods.status[name]
    if not tabFrame or not entry then return end

    local stateLabel, r, g, b = GetStateInfo(entry)
    tabFrame.stateText:SetText("[" .. stateLabel .. "]")
    tabFrame.stateText:SetTextColor(r, g, b)
    tabFrame.descText:SetText(entry.description or "|cff888888(no description)|r")
    tabFrame.depsText:SetText("Depends on: " .. (entry.dependencies or "(not documented)"))

    if entry.errorTrace then
        tabFrame.reasonText:SetText("|cffff4444" .. (entry.conditionReason or "error") .. "|r")
    elseif entry.conditionReason then
        tabFrame.reasonText:SetText("|cffff9933" .. entry.conditionReason .. "|r")
    else
        tabFrame.reasonText:SetText("")
    end

    tabFrame.enableCheck:SetChecked(entry.userEnabled)
    tabFrame.copyBtn:SetShown(entry.errorTrace ~= nil)

    -- Defensive: a module's GetInfoRows() runs on our UI thread on a timer
    -- (see the OnUpdate refresh below) -- one buggy module's debug hook must
    -- never be able to break the whole panel.
    local rows
    if entry.module and entry.module.GetInfoRows then
        local ok, result = pcall(entry.module.GetInfoRows, entry.module)
        if ok then rows = result end
    end
    RefreshInfoRows(tabFrame.infoContent, rows)
end

-- Called by Core.lua whenever module state changes (e.g. a toggle) so the
-- currently-open tab resyncs without waiting for the periodic refresh.
function AniMods.RefreshUI()
    if currentTabName then RefreshModuleTab(currentTabName) end
end

local function BuildModuleTabContent(tabFrame, name)
    -- Per-tab titleText dangles off the container's main title, not the tab
    -- body (documented DF pitfall) -- redundant anyway since the selected tab
    -- button already shows the module name.
    if tabFrame.titleText then tabFrame.titleText:Hide() end

    tabFrame.stateText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tabFrame.stateText:SetPoint("TOPRIGHT", -16, CONTENT_TOP)

    tabFrame.nameText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tabFrame.nameText:SetPoint("TOPLEFT", 16, CONTENT_TOP)
    tabFrame.nameText:SetPoint("RIGHT", tabFrame.stateText, "LEFT", -8, 0)
    tabFrame.nameText:SetJustifyH("LEFT")
    tabFrame.nameText:SetWordWrap(false)
    tabFrame.nameText:SetTextColor(unpack(ACCENT))
    tabFrame.nameText:SetText(AniMods.status[name].title)

    tabFrame.descText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tabFrame.descText:SetPoint("TOPLEFT", tabFrame.nameText, "BOTTOMLEFT", 0, -10)
    tabFrame.descText:SetPoint("RIGHT", tabFrame, "RIGHT", -16, 0)
    tabFrame.descText:SetJustifyH("LEFT")
    tabFrame.descText:SetWordWrap(true)
    tabFrame.descText:SetSpacing(3)

    tabFrame.depsText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tabFrame.depsText:SetPoint("TOPLEFT", tabFrame.descText, "BOTTOMLEFT", 0, -8)
    tabFrame.depsText:SetPoint("RIGHT", tabFrame, "RIGHT", -16, 0)
    tabFrame.depsText:SetJustifyH("LEFT")
    tabFrame.depsText:SetWordWrap(true)
    tabFrame.depsText:SetSpacing(3)

    tabFrame.reasonText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tabFrame.reasonText:SetPoint("TOPLEFT", tabFrame.depsText, "BOTTOMLEFT", 0, -8)
    tabFrame.reasonText:SetPoint("RIGHT", tabFrame, "RIGHT", -16, 0)
    tabFrame.reasonText:SetJustifyH("LEFT")
    tabFrame.reasonText:SetWordWrap(true)
    tabFrame.reasonText:SetSpacing(3)

    -- Scrollable GetInfoRows() area.
    local infoBg = CreateFrame("Frame", nil, tabFrame, "InsetFrameTemplate")
    infoBg:SetPoint("TOPLEFT", tabFrame.reasonText, "BOTTOMLEFT", -4, -10)
    infoBg:SetPoint("RIGHT", tabFrame, "RIGHT", -12, 0)
    infoBg:SetPoint("BOTTOM", tabFrame, "BOTTOM", 0, 52)

    local infoScroll = CreateFrame("ScrollFrame", "AniModsTab" .. name .. "Scroll", infoBg, "UIPanelScrollFrameTemplate")
    infoScroll:SetPoint("TOPLEFT", 4, -4)
    infoScroll:SetPoint("BOTTOMRIGHT", -22, 4)

    -- Named (not anonymous): DF's widget creation builds default child widget
    -- names via "$parent..." substitution, which needs this frame's own
    -- GetName() to resolve -- an anonymous parent throws "called $parent but
    -- parent was no name" from deep inside DF.
    tabFrame.infoContent = CreateFrame("Frame", "AniModsTab" .. name .. "Content", infoScroll)
    infoScroll:SetScrollChild(tabFrame.infoContent)
    -- Generous fixed height rather than measuring DF's laid-out rows: content
    -- shorter than this just leaves blank space at the bottom, which is
    -- harmless.
    tabFrame.infoContent:SetHeight(1000)
    infoScroll:SetScript("OnSizeChanged", function(self, w)
        tabFrame.infoContent:SetWidth(w)
    end)

    tabFrame.enableCheck = CreateFrame("CheckButton", nil, tabFrame, "UICheckButtonTemplate")
    tabFrame.enableCheck:SetSize(22, 22)
    tabFrame.enableCheck:SetPoint("BOTTOMLEFT", 12, 10)
    tabFrame.enableCheck:SetScript("OnClick", function(self)
        AniMods.SetModuleEnabled(name, self:GetChecked())
    end)

    tabFrame.enableLabel = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tabFrame.enableLabel:SetPoint("LEFT", tabFrame.enableCheck, "RIGHT", 4, 0)
    tabFrame.enableLabel:SetText("Enabled  |cff888888(/reload to apply)|r")

    tabFrame.copyBtn = CreateFrame("Button", nil, tabFrame, "UIPanelButtonTemplate")
    tabFrame.copyBtn:SetSize(110, 20)
    tabFrame.copyBtn:SetPoint("BOTTOMRIGHT", -12, 38)
    tabFrame.copyBtn:SetText("Show Error")
    tabFrame.copyBtn:SetScript("OnClick", function()
        local entry = AniMods.status[name]
        if entry and entry.errorTrace then
            ShowCopyPopup(entry.title .. " — Enable() error", entry.errorTrace)
        end
    end)
    tabFrame.copyBtn:Hide()

    tabFrame.keyText = tabFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tabFrame.keyText:SetPoint("BOTTOMRIGHT", -12, 12)
    tabFrame.keyText:SetText("|cff555555" .. name .. "|r")

    tabFrameByName[name] = tabFrame
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildUI()
    if tabContainer then return end

    moduleOrder = SortedModuleNames()
    local tabList = {}
    for _, name in ipairs(moduleOrder) do
        tabList[#tabList + 1] = { name = name, text = AniMods.status[name].title }
    end

    tabContainer = DF:CreateTabContainer(UIParent, "AniMods", "AniModsFrame", tabList, {
        width = PANEL_WIDTH,
        height = PANEL_HEIGHT,
        button_width = 150,
        button_selected_border_color = { ACCENT[1], ACCENT[2], ACCENT[3], 1 },
    }, {
        OnSelectIndex = function(container)
            currentTabName = moduleOrder[container.CurrentIndex]
            RefreshModuleTab(currentTabName)
        end,
    })
    tabContainer:SetPoint("CENTER")
    tabContainer:SetFrameStrata("MEDIUM")
    tinsert(_G.UISpecialFrames, "AniModsFrame")

    for i, name in ipairs(moduleOrder) do
        BuildModuleTabContent(tabContainer:GetTabFrameByIndex(i), name)
    end

    currentTabName = moduleOrder[1]
    RefreshModuleTab(currentTabName)

    -- Keep the currently-open tab's info rows (live status/eligibility) fresh
    -- while the panel is open. OnUpdate doesn't fire on hidden frames, so
    -- this naturally stops costing anything once the panel is closed.
    local ticker = CreateFrame("Frame")
    ticker.elapsed = 0
    tabContainer:HookScript("OnHide", function() ticker:Hide() end)
    tabContainer:HookScript("OnShow", function() ticker:Show() end)
    ticker:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 1.0 then
            self.elapsed = 0
            if currentTabName then RefreshModuleTab(currentTabName) end
        end
    end)

    -- DF doesn't guarantee a freshly-built container starts hidden; force it
    -- so the very first /ani reliably *opens* the panel instead of closing
    -- one the user never saw.
    tabContainer:Hide()
    ticker:Hide()
end

function AniMods.ToggleUI()
    BuildUI()
    if tabContainer:IsShown() then
        tabContainer:Hide()
    else
        tabContainer:Show()
    end
end
