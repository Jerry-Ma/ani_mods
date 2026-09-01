-- AniMods status/config panel. `/animods` (or `/ani`) toggles it.
--
-- Built on AceGUI-3.0 (Frame + TabGroup + ScrollFrame/List, Heading/CheckBox/
-- Label/Button widgets) rather than a hand-rolled Blizzard-frame UI or
-- DetailsFramework -- both were tried first. DF gave a much fancier-looking
-- result on paper, but its declarative BuildMenu API has real undocumented
-- (to us) sharp edges -- e.g. a nil switch template silently aborts
-- BuildMenuVolatile partway through with no error visible until a widget
-- type is actually used, discovered only via live in-game testing, not code
-- review. AceGUI is the most mature, most thoroughly documented WoW UI
-- toolkit there is (unchanged for a decade-plus, embedded in dozens of
-- addons already in this folder), with a small, predictable widget-tree API
-- that's reliable to reason about correctly without a live client to test
-- against every change.
--
-- AceGUI-3.0 is bundled in Libs\AceGUI-3.0 (copied from HandyNotes' embed,
-- itself the standard Ace3 distribution, BSD-licensed) plus Libs\LibStub,
-- loaded via the .toc before Core.lua/UI.lua -- not relied on any other
-- addon's copy being installed/loaded.

local ADDON_NAME = "AniMods"
local AniMods = _G.AniMods
local AceGUI = LibStub("AceGUI-3.0")

local ACCENT_HEX = "ffd700" -- gold accent, matches the rest of the workspace's addon titles

local frame
local tabGroup
local currentTabName

local function ColorHex(r, g, b)
    return ("%02x%02x%02x"):format((r or 1) * 255, (g or 1) * 255, (b or 1) * 255)
end

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

local errorPopup

local function ShowCopyPopup(title, text)
    if not errorPopup then
        errorPopup = AceGUI:Create("Frame")
        errorPopup:SetLayout("Fill")
        errorPopup:SetWidth(560)
        errorPopup:SetHeight(340)
        errorPopup:EnableResize(false)
        errorPopup:SetCallback("OnClose", function(widget) widget:Hide() end)

        errorPopup.editBox = AceGUI:Create("MultiLineEditBox")
        errorPopup.editBox:SetLabel("Ctrl+A, Ctrl+C to copy")
        errorPopup.editBox:DisableButton(true)
        errorPopup.editBox:SetFullWidth(true)
        errorPopup.editBox:SetFullHeight(true)
        errorPopup:AddChild(errorPopup.editBox)
    end

    errorPopup:SetTitle(title)
    errorPopup.editBox:SetText(text or "")
    errorPopup:Show()
    errorPopup.editBox:SetFocus()
end

-- ── Info rows: each module's live "debug + options" readout ──────────────────
-- A module's GetInfoRows() (optional) returns an ordered list of rows:
--   { section = "Status" }                                            -- header
--   { label = "Tanks", value = "2" }                                  -- status
--   { label = "Party", get = fn, set = fn, note = "active now" }      -- toggle
-- A `section` becomes an AceGUI Heading (a real labeled divider widget);
-- anything with `get` becomes a CheckBox; everything else a plain Label.

local function AddInfoRows(container, rows)
    for _, descriptor in ipairs(rows or {}) do
        if descriptor.section then
            local heading = AceGUI:Create("Heading")
            heading:SetText(descriptor.section)
            heading:SetFullWidth(true)
            container:AddChild(heading)
        elseif descriptor.get then
            local label = descriptor.label
            if descriptor.note then
                label = label .. "  |cff59ff59" .. descriptor.note .. "|r"
            end
            local check = AceGUI:Create("CheckBox")
            check:SetLabel(label)
            check:SetValue(descriptor.get() and true or false)
            check:SetFullWidth(true)
            check:SetCallback("OnValueChanged", function(widget, event, value)
                descriptor.set(value)
                -- Rows can be part of a radio-style group (e.g. an icon
                -- style picker: many get/set pairs, only one true at a
                -- time) -- one click can change what every other row's
                -- get() now returns, so resync the whole tab immediately
                -- rather than waiting for the periodic refresh.
                if AniMods.RefreshUI then AniMods.RefreshUI() end
            end)
            container:AddChild(check)
        else
            local text = AceGUI:Create("Label")
            text:SetText(("%s:  |cffaaaaaa%s|r"):format(descriptor.label, tostring(descriptor.value or "")))
            text:SetFullWidth(true)
            container:AddChild(text)
        end
    end
end

-- ── Per-module tab content ────────────────────────────────────────────────────
-- Rebuilt from scratch on every tab select and on the periodic refresh --
-- ReleaseChildren()+rebuild is AceGUI's own standard idiom for dynamic
-- content, cheap enough at this scale (a couple dozen widgets at most).

local function BuildTabContent(container, name)
    container:ReleaseChildren()
    container:SetLayout("Fill")

    local entry = AniMods.status[name]
    if not entry then return end

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    container:AddChild(scroll)

    local stateLabel, r, g, b = GetStateInfo(entry)

    local titleLabel = AceGUI:Create("Label")
    titleLabel:SetText(("|cff%s%s|r  |cff%s[%s]|r"):format(ACCENT_HEX, entry.title, ColorHex(r, g, b), stateLabel))
    titleLabel:SetFontObject(GameFontNormalLarge)
    titleLabel:SetFullWidth(true)
    scroll:AddChild(titleLabel)

    local descLabel = AceGUI:Create("Label")
    descLabel:SetText(entry.description or "|cff888888(no description)|r")
    descLabel:SetFullWidth(true)
    scroll:AddChild(descLabel)

    -- Always visible (unlike the reason below, which only shows when
    -- something's wrong) -- what this module needs to even be considered,
    -- independent of whether that's currently satisfied.
    local depsLabel = AceGUI:Create("Label")
    depsLabel:SetText("Depends on: " .. (entry.dependencies or "(not documented)"))
    depsLabel:SetColor(0.6, 0.6, 0.6)
    depsLabel:SetFullWidth(true)
    scroll:AddChild(depsLabel)

    if entry.errorTrace then
        local reasonLabel = AceGUI:Create("Label")
        reasonLabel:SetText("|cffff4444" .. (entry.conditionReason or "error") .. "|r")
        reasonLabel:SetFullWidth(true)
        scroll:AddChild(reasonLabel)

        local errBtn = AceGUI:Create("Button")
        errBtn:SetText("Show Error")
        errBtn:SetWidth(140)
        errBtn:SetCallback("OnClick", function()
            ShowCopyPopup(entry.title .. " — Enable() error", entry.errorTrace)
        end)
        scroll:AddChild(errBtn)
    elseif entry.conditionReason then
        local reasonLabel = AceGUI:Create("Label")
        reasonLabel:SetText("|cffff9933" .. entry.conditionReason .. "|r")
        reasonLabel:SetFullWidth(true)
        scroll:AddChild(reasonLabel)
    end

    -- Defensive: a module's GetInfoRows() runs on our UI thread on a timer
    -- (see the periodic refresh in BuildUI) -- one buggy module's debug hook
    -- must never be able to break the whole panel.
    local rows
    if entry.module and entry.module.GetInfoRows then
        local ok, result = pcall(entry.module.GetInfoRows, entry.module)
        if ok then rows = result end
    end
    AddInfoRows(scroll, rows)

    local enabledCheck = AceGUI:Create("CheckBox")
    enabledCheck:SetLabel("Enabled  |cff888888(/reload to apply)|r")
    enabledCheck:SetValue(entry.userEnabled and true or false)
    enabledCheck:SetFullWidth(true)
    enabledCheck:SetCallback("OnValueChanged", function(widget, event, value)
        AniMods.SetModuleEnabled(name, value)
    end)
    scroll:AddChild(enabledCheck)

    local keyLabel = AceGUI:Create("Label")
    keyLabel:SetText("|cff555555" .. name .. "|r")
    keyLabel:SetFullWidth(true)
    scroll:AddChild(keyLabel)
end

local function RefreshCurrentTab()
    if not tabGroup or not currentTabName then return end
    BuildTabContent(tabGroup, currentTabName)
end

-- Called by Core.lua whenever module state changes (e.g. a toggle) so the
-- currently-open tab resyncs without waiting for the periodic refresh.
function AniMods.RefreshUI()
    RefreshCurrentTab()
end

-- ── Frame construction ────────────────────────────────────────────────────────

local function BuildUI()
    if frame then return end

    frame = AceGUI:Create("Frame")
    frame:SetTitle("AniMods")
    frame:SetLayout("Fill")
    frame:SetWidth(700)
    frame:SetHeight(500)
    frame:EnableResize(false)
    -- AceGUI Frame widgets auto-register for Esc-to-close; the close button
    -- just hides by default too, but explicit here so it's not left to
    -- chance if that default ever changes.
    frame:SetCallback("OnClose", function(widget) widget:Hide() end)

    tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("Fill")

    local names = SortedModuleNames()
    local tabs = {}
    for _, name in ipairs(names) do
        tabs[#tabs + 1] = { text = AniMods.status[name].title, value = name }
    end
    tabGroup:SetTabs(tabs)
    tabGroup:SetCallback("OnGroupSelected", function(container, event, name)
        currentTabName = name
        BuildTabContent(container, name)
    end)

    frame:AddChild(tabGroup)

    if names[1] then
        tabGroup:SelectTab(names[1])
    end

    frame:Hide()

    -- Keep the currently-open tab's info rows (live status/eligibility) fresh
    -- while the panel is open. OnUpdate doesn't fire on hidden frames, so
    -- this naturally stops costing anything once the panel is closed.
    local ticker = CreateFrame("Frame")
    ticker.elapsed = 0
    frame.frame:HookScript("OnHide", function() ticker:Hide() end)
    frame.frame:HookScript("OnShow", function() ticker:Show() end)
    ticker:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= 1.0 then
            self.elapsed = 0
            RefreshCurrentTab()
        end
    end)
    ticker:Hide()
end

function AniMods.ToggleUI()
    BuildUI()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end
