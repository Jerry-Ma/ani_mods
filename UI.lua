-- AniMods status/config panel. `/animods` (or `/ani`) toggles it.
--
-- Drawn with AniMods.W (Widgets.lua) -- hand-rolled chrome matching
-- EllesmereUI's look, using EUI's own public primitives when it's loaded.
-- See Widgets.lua's header for why hand-rolled rather than a widget library.
--
-- The refresh model is the important part here, and it survived the switch
-- from AceGUI unchanged:
--   * Live data updates the TEXT of existing widgets in place. Nothing is
--     destroyed, so an open dropdown and the scroll position are never
--     disturbed by a counter ticking over.
--   * Each `{section=...}` block owns its own container. When a section's
--     row SHAPE changes (a row appearing/disappearing -- e.g.
--     GroupRoles' Status block going 1 row solo to 4 rows grouped)
--     only that section is rebuilt; other sections, and any dropdown in
--     them, are untouched.
--   * Nothing polls. Modules push AniMods.RefreshUI() when their data
--     actually changes.

local AniMods = _G.AniMods
local W = AniMods.W

local DOT = "\226\151\143" -- U+25CF, tab status glyph and dependency bullets

local PAD = 12            -- content inset
local ROW_GAP = 2
local BLOCK_GAP = 6
local CONTROL_WIDTH = 220 -- dropdowns/sliders: fixed, never full-width

local frame
local tabStrip
local tabButtons = {}
local scrollArea
local content
local currentTabName

-- Set while a dropdown's menu is open, to the index of the section holding
-- it. Only matters for the rare full-rebuild path -- in-place text updates
-- never disturb a dropdown, so they don't consult it.
local openDropdownSection = nil
local refreshPending = false

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

-- Whether entry has an error block, a plain reason block, or neither --
-- shared between BuildTabContent (which creates the block) and
-- TryRefreshTabInPlace (a change in which is structural, not a text update).
local function ClassifyReason(entry)
    local hasError = entry.errorTrace and true or false
    local hasReason = (not hasError) and entry.conditionReason and true or false
    return hasError, hasReason
end

local function SortedModuleNames()
    local names = {}
    for name in pairs(AniMods.status) do tinsert(names, name) end
    table.sort(names)
    return names
end

-- ── Copy-to-clipboard popup (for full Enable() error tracebacks) ─────────────

local errorPopup

local function ShowCopyPopup(titleText, text)
    if not errorPopup then
        errorPopup = W.Window("AniModsErrorPopup", "AniMods — Error", 560, 340)
        errorPopup:SetFrameStrata("FULLSCREEN_DIALOG")

        -- Everything goes on the window's `content` child, never the window
        -- itself: W.Window runs it through S.Shell, which enrols it in
        -- EllesmereUI's restrip registry (see Widgets.lua's header).
        local host = errorPopup.content

        local hint = W.Font(host, 11, nil, W.TEXT_DIM_A)
        hint:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -8)
        hint:SetText("Ctrl+A, Ctrl+C to copy")

        local box = W.Panel(host, { inset = true })
        box:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -28)
        box:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD, PAD)

        local scroll = CreateFrame("ScrollFrame", nil, box)
        scroll:SetPoint("TOPLEFT", 6, -6)
        scroll:SetPoint("BOTTOMRIGHT", -6, 6)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            self:SetVerticalScroll(math.max(0, self:GetVerticalScroll() - delta * 24))
        end)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(500)
        edit:SetScript("OnEscapePressed", function() errorPopup:Hide() end)
        scroll:SetScrollChild(edit)

        errorPopup.editBox = edit
    end

    errorPopup.editBox:SetText(text or "")
    errorPopup:Show()
    errorPopup.editBox:SetFocus()
    errorPopup.editBox:HighlightText()
end

-- ── Info rows ────────────────────────────────────────────────────────────────
-- A module's GetInfoRows() (optional) returns an ordered list of rows:
--   { section = "Status" }                                                -- header, starts a new section
--   { label = "Tanks", value = "2" }                                      -- status
--   { label = "Party", get = fn, set = fn, note = "active now" }          -- toggle
--   { label = "Style", options = {k="Name",...}, order = {...},
--     get = fn, set = fn, atlas = "some-atlas" }                          -- dropdown, w/ optional icon preview
--   { label = "Style", ..., texture = "Interface\\...\\Some" }            -- dropdown, w/ texture-file preview
--   { label = "Spacing", min = 0, max = 4, step = 1, get = fn, set = fn } -- slider

local function RowKind(descriptor)
    if descriptor.section then return "section" end
    if descriptor.options then return "options" end
    if descriptor.min then return "min" end
    if descriptor.get then return "checkbox" end
    return "value"
end

-- Structural signature: row count + kind + label at each position. Rows are
-- built the same declarative way every time a code path runs, so these only
-- differ when a row genuinely appeared, disappeared or was replaced -- never
-- because a value changed.
local function BuildShape(rows)
    local shape = {}
    for i, d in ipairs(rows or {}) do
        local sig = RowKind(d) .. ":" .. tostring(d.section or d.label)
        -- How MANY preview icons a dropdown row has is structural (there's
        -- one widget each), so a change in count has to rebuild the section.
        -- Whether they're atlases or texture files is NOT: swapping between
        -- an atlas style and a bundled-texture one retargets the same
        -- widgets in place, which is the common case and mustn't close an
        -- open dropdown to do it.
        local previews = d.atlas or d.texture
        if previews then
            sig = sig .. ":" .. (type(previews) == "table" and #previews or 1)
        end
        shape[i] = sig
    end
    return shape
end

local function ShapesMatch(a, b)
    if not a or not b or #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- Splits a flat row list into one slice per {section=...} marker, each slice
-- starting with its own section row (rows before the first marker form a
-- leading unnamed slice). Each slice gets its own container frame, which is
-- what keeps a shape change in one section from touching any other.
local function SplitIntoSections(rows)
    local groups, current = {}, nil
    for _, d in ipairs(rows or {}) do
        if d.section or not current then
            current = {}
            groups[#groups + 1] = current
        end
        current[#current + 1] = d
    end
    return groups
end

local function CheckboxLabel(descriptor)
    local label = descriptor.label
    if descriptor.note then
        label = label .. "  |cff59ff59" .. descriptor.note .. "|r"
    end
    return label
end

-- Builds one row into `parent`, returning { kind, widget } for later in-place
-- updates. `sectionIndex` tags a dropdown's open/close so a rebuild knows
-- whether it owns the currently-open menu.
local function BuildRow(parent, descriptor, sectionIndex, stripeIndex)
    local kind = RowKind(descriptor)

    if kind == "section" then
        local heading = W.Heading(parent)
        heading:SetText(descriptor.section)
        return { kind = kind, widget = heading }, heading.frame, 4

    elseif kind == "options" then
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(26)

        local label = W.Font(row, 12, nil, W.TEXT_DIM_A)
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetText(descriptor.label or "")

        local dd = W.Dropdown(row, CONTROL_WIDTH)
        dd.frame:SetPoint("LEFT", row, "LEFT", 150, 0)
        dd:SetList(descriptor.options, descriptor.order)
        dd:SetValue(descriptor.get())
        dd:SetOnChange(function(value)
            descriptor.set(value)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
        dd:SetOnOpened(function() openDropdownSection = sectionIndex end)
        dd:SetOnClosed(function()
            openDropdownSection = nil
            if refreshPending then
                refreshPending = false
                -- Next frame, not inline: closing one dropdown to open
                -- another runs this mid-open, and a deferred rebuild firing
                -- synchronously there could tear down the dropdown that's in
                -- the middle of opening. One-shot, not a poll.
                C_Timer.After(0, function()
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end)
            end
        end)

        -- Preview icons for the currently-selected option: one for a single
        -- representative icon, several for a whole set (e.g. Tank/Healer/DPS)
        -- so the choice is judged by the set rather than one member. Kept in
        -- the row's cache entry so picking a different option can retarget
        -- them in place -- they show the SELECTED style, so they're live
        -- content, not fixed decoration.
        local icons = {}
        local previews = descriptor.atlas or descriptor.texture
        if previews then
            local isAtlas = descriptor.atlas ~= nil
            local list = type(previews) == "table" and previews or { previews }
            local anchor = dd.frame
            for _, ref in ipairs(list) do
                local icon = W.Icon(row, 20)
                icon.frame:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
                if isAtlas then icon:SetAtlas(ref) else icon:SetTexture(ref) end
                icons[#icons + 1] = icon
                anchor = icon.frame
            end
        end

        return { kind = kind, widget = dd, icons = icons }, row, ROW_GAP

    elseif kind == "min" then
        -- Wrapped in a full-width row so the slider itself keeps
        -- CONTROL_WIDTH: stacking it directly would anchor it left AND
        -- right, stretching the track across the whole panel.
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(30)

        local slider = W.Slider(row, CONTROL_WIDTH)
        slider.frame:SetPoint("LEFT", row, "LEFT", 8, 0)
        slider:SetLabel(descriptor.label)
        slider:SetRange(descriptor.min, descriptor.max, descriptor.step)
        slider:SetValue(descriptor.get())
        slider:SetOnChange(function(value)
            descriptor.set(value)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
        return { kind = kind, widget = slider }, row, ROW_GAP

    elseif kind == "checkbox" then
        local check = W.CheckBox(parent)
        check:SetLabel(CheckboxLabel(descriptor))
        check:SetChecked(descriptor.get())
        check:SetOnClick(function(value)
            descriptor.set(value)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
        return { kind = kind, widget = check }, check.frame, ROW_GAP

    else
        local row = W.ValueRow(parent)
        row:Set(descriptor.label, tostring(descriptor.value or ""))
        row:Stripe(stripeIndex or 1)
        return { kind = kind, widget = row }, row.frame, 0
    end
end

-- Updates only the live-changing text of already-built rows: a checkbox's
-- label (its `note` suffix) or a value row's text. Never touches a
-- Dropdown/Slider/Heading -- nothing about their display changes without the
-- user acting on that exact widget, which already refreshes inline -- nor a
-- checkbox's checked state, which no current module changes from outside.
local function RefreshRowsInPlace(rows, cache)
    for i, descriptor in ipairs(rows or {}) do
        local c = cache[i]
        if c and c.kind == "checkbox" then
            c.widget:SetLabel(CheckboxLabel(descriptor))
        elseif c and c.kind == "value" then
            c.widget:Set(descriptor.label, tostring(descriptor.value or ""))
        elseif c and c.kind == "options" then
            -- The selection itself (in case something changed it from
            -- outside this dropdown) and, more importantly, the preview
            -- icons: those show the CURRENTLY SELECTED style, so they go
            -- stale the moment a different one is picked.
            c.widget:SetValue(descriptor.get())
            local previews = descriptor.atlas or descriptor.texture
            if previews and c.icons then
                local isAtlas = descriptor.atlas ~= nil
                local list = type(previews) == "table" and previews or { previews }
                for n, icon in ipairs(c.icons) do
                    local ref = list[n]
                    if ref then
                        if isAtlas then icon:SetAtlas(ref) else icon:SetTexture(ref) end
                    end
                end
            end
        end
    end
end

-- Builds a section's rows into its container, stacking them and sizing the
-- container to fit. Frames are pooled per (index, kind) so a section that
-- flips between shapes -- 1 row solo, 4 rows grouped, back again -- reuses
-- what it already made instead of leaking a new set every time.
local function FillSection(section, slice, sectionIndex)
    local container = section.container
    W.ResetStack(container, 0)

    section.pool = section.pool or {}
    local pool = section.pool
    local cache = {}
    local stripe = 0

    for i, descriptor in ipairs(slice) do
        local kind = RowKind(descriptor)
        if kind == "value" then stripe = stripe + 1 end

        local entry = pool[i]
        if entry and entry.kind == kind then
            -- Reuse: refresh its content, re-show, re-stack below.
            if kind == "section" then
                entry.built.widget:SetText(descriptor.section)
            elseif kind == "value" then
                entry.built.widget:Set(descriptor.label, tostring(descriptor.value or ""))
                entry.built.widget:Stripe(stripe)
            elseif kind == "checkbox" then
                entry.built.widget:SetLabel(CheckboxLabel(descriptor))
                entry.built.widget:SetChecked(descriptor.get())
            else
                -- Dropdown/slider carry live callbacks bound to this exact
                -- descriptor; rebuild rather than risk a stale closure.
                entry.frame:Hide()
                entry = nil
            end
        elseif entry then
            entry.frame:Hide()
            entry = nil
        end

        if not entry then
            local built, rowFrame, gap = BuildRow(container, descriptor, sectionIndex, stripe)
            entry = { kind = kind, built = built, frame = rowFrame, gap = gap }
            pool[i] = entry
        end

        entry.frame:Show()
        W.Stack(container, entry.frame, nil, entry.gap)
        cache[i] = entry.built
    end

    for i = #slice + 1, #pool do
        if pool[i] then pool[i].frame:Hide() end
    end

    section.shape = BuildShape(slice)
    section.cache = cache
end

-- ── Per-module tab content ───────────────────────────────────────────────────

-- name -> { blocks, sections, titleFS, depRows, reasonText, enabledCheck, ... }
local tabCache = {}
local scrollPos = {}   -- name -> saved scroll offset

local function RefreshDepRows(entry, cache)
    local deps = entry.dependencies
    if type(deps) ~= "table" or not deps[1] then return end
    for i, dep in ipairs(deps) do
        local line = cache.depRows[i]
        if line then
            local dotColor
            if dep.met then
                local ok, result = pcall(dep.met)
                dotColor = (ok and result) and "59ff59" or "ff5555"
            else
                dotColor = "888888"
            end
            line:SetText(("  |cff%s%s|r %s"):format(dotColor, DOT, dep.text))
        end
    end
end

-- Everything above the info-row sections whose content is live: the title's
-- state badge, the dependency checklist's dots, the reason line, and the
-- Enabled checkbox (which `/ani enable` can change from outside the panel).
-- Shared by both paths on purpose -- when only the refresh path applied
-- these, a freshly built tab showed an empty title and blank dependency
-- lines until something happened to trigger a refresh.
local function ApplyLiveValues(entry, cache)
    local stateLabel, r, g, b = GetStateInfo(entry)
    cache.titleFS:SetText(("%s  |cff%s[%s]|r"):format(entry.title, ColorHex(r, g, b), stateLabel))

    RefreshDepRows(entry, cache)

    if cache.reasonText then
        if cache.hasError then
            cache.reasonText:SetText("|cffff4444" .. (entry.conditionReason or "error") .. "|r")
        elseif cache.hasReason then
            cache.reasonText:SetText("|cffff9933" .. entry.conditionReason .. "|r")
        end
    end

    cache.enabledCheck:SetChecked(entry.userEnabled)
end

-- Re-anchors every top-level block in the content frame and resizes the
-- scroll child. Cheap (a dozen frames) and the only thing that has to run
-- when a section's height changes. Wrapped-text blocks are re-measured first
-- against the width actually available, since their height depends on it.
local function RelayoutContent(cache)
    if not cache then return end

    local avail = (scrollArea.scroll:GetWidth() or 0) - PAD * 2
    for _, block in ipairs(cache.blocks) do
        if block.text then block.text:Resize(avail) end
    end

    W.ResetStack(content, PAD)
    for _, block in ipairs(cache.blocks) do
        if block.frame:IsShown() then
            W.Stack(content, block.frame, nil, block.gap or BLOCK_GAP, PAD)
        end
    end
    content:SetHeight(content._cursor + PAD)
    scrollArea:Update()
end

local function BuildTabContent(name)
    -- Everything is about to be re-anchored (and any open dropdown belongs
    -- to widgets that are going away), so the open-menu marker can't survive.
    openDropdownSection = nil
    W.CloseDropdownMenu()

    local old = tabCache[name]
    if old then
        for _, block in ipairs(old.blocks) do block.frame:Hide() end
    end

    local entry = AniMods.status[name]
    if not entry then
        tabCache[name] = nil
        return
    end

    local cache = { blocks = {}, sections = {}, depRows = {} }
    tabCache[name] = cache

    -- Title + state badge.
    local titleFrame = CreateFrame("Frame", nil, content)
    titleFrame:SetHeight(22)
    local titleFS = W.Font(titleFrame, 15, nil, 1)
    titleFS:SetPoint("LEFT")
    cache.titleFS = titleFS
    cache.blocks[#cache.blocks + 1] = { frame = titleFrame, gap = 2 }

    -- Description.
    local desc = W.Text(content, 12, W.TEXT_DIM_A)
    desc:SetText(entry.description or "|cff888888(no description)|r")
    cache.blocks[#cache.blocks + 1] = { frame = desc.frame, text = desc, gap = BLOCK_GAP }

    -- "Depends on:" checklist.
    local depHeader = W.Text(content, 12, W.TEXT_SECTION_A)
    depHeader:SetText("Depends on:")
    cache.blocks[#cache.blocks + 1] = { frame = depHeader.frame, text = depHeader, gap = 1 }

    local deps = entry.dependencies
    if type(deps) == "table" and deps[1] then
        for i in ipairs(deps) do
            local line = W.Text(content, 12, W.TEXT_DIM_A)
            cache.depRows[i] = line
            cache.blocks[#cache.blocks + 1] = { frame = line.frame, text = line, gap = 1 }
        end
    else
        local line = W.Text(content, 12, W.TEXT_DIM_A)
        line:SetText("  |cff888888(not documented)|r")
        cache.blocks[#cache.blocks + 1] = { frame = line.frame, text = line, gap = BLOCK_GAP }
    end

    -- Error / reason block.
    local hasError, hasReason = ClassifyReason(entry)
    cache.hasError, cache.hasReason = hasError, hasReason
    if hasError or hasReason then
        local reason = W.Text(content, 12, 1)
        cache.reasonText = reason
        cache.blocks[#cache.blocks + 1] = { frame = reason.frame, text = reason, gap = BLOCK_GAP }

        if hasError then
            local btn = W.Button(content, 140, 22)
            btn:SetText("Show Error")
            btn:SetOnClick(function()
                ShowCopyPopup(entry.title, entry.errorTrace)
            end)
            cache.blocks[#cache.blocks + 1] = { frame = btn.frame, gap = BLOCK_GAP }
        end
    end

    -- Defensive: a module's GetInfoRows() can run from that module's own
    -- event handlers, not just clicks in this panel -- one buggy module's
    -- debug hook must never break the whole panel.
    local rows
    if entry.module and entry.module.GetInfoRows then
        local ok, result = pcall(entry.module.GetInfoRows, entry.module)
        if ok then rows = result end
    end

    local groups = SplitIntoSections(rows)
    cache.groupCount = #groups
    for gi, slice in ipairs(groups) do
        local container = CreateFrame("Frame", nil, content)
        local section = { container = container }
        cache.sections[gi] = section
        FillSection(section, slice, gi)
        cache.blocks[#cache.blocks + 1] = { frame = container, gap = BLOCK_GAP }
    end

    -- Enabled toggle.
    local enabledCheck = W.CheckBox(content)
    enabledCheck:SetLabel("Enabled  |cff888888(/reload to apply)|r")
    enabledCheck:SetChecked(entry.userEnabled)
    enabledCheck:SetOnClick(function(value)
        AniMods.SetModuleEnabled(name, value)
    end)
    cache.enabledCheck = enabledCheck
    cache.blocks[#cache.blocks + 1] = { frame = enabledCheck.frame, gap = BLOCK_GAP }

    ApplyLiveValues(entry, cache)
    RelayoutContent(cache)
end

-- Brings a tab's existing widgets up to date without destroying anything.
-- Returns false only when nothing is built yet, the error/reason block's
-- presence changed, or the module's section COUNT changed -- all of which
-- need a full rebuild.
local function TryRefreshTabInPlace(name)
    local cache = tabCache[name]
    if not cache then return false end

    local entry = AniMods.status[name]
    if not entry then return false end

    local rows
    if entry.module and entry.module.GetInfoRows then
        local ok, result = pcall(entry.module.GetInfoRows, entry.module)
        if ok then rows = result end
    end

    local hasError, hasReason = ClassifyReason(entry)
    if cache.hasError ~= hasError or cache.hasReason ~= hasReason then
        return false
    end

    local groups = SplitIntoSections(rows)
    if #groups ~= cache.groupCount then return false end

    ApplyLiveValues(entry, cache)

    -- Per section: update text in place where the shape is unchanged, rebuild
    -- only the section(s) that aren't. A section is skipped (left stale until
    -- its menu closes) only if it's the exact one holding the open dropdown.
    local rebuilt = false
    for gi, slice in ipairs(groups) do
        local section = cache.sections[gi]
        if ShapesMatch(section.shape, BuildShape(slice)) then
            RefreshRowsInPlace(slice, section.cache)
        elseif openDropdownSection == gi then
            refreshPending = true
        else
            FillSection(section, slice, gi)
            rebuilt = true
        end
    end

    -- A rebuilt section can be a different height, so everything below it has
    -- to be re-anchored. Plain text updates never change layout.
    if rebuilt then RelayoutContent(cache) end

    return true
end

local function RefreshCurrentTab()
    if not currentTabName or not content then return end
    if TryRefreshTabInPlace(currentTabName) then return end
    if openDropdownSection then
        refreshPending = true
        return
    end
    BuildTabContent(currentTabName)
end

-- ── Tabs ─────────────────────────────────────────────────────────────────────

local function SelectTab(name)
    if currentTabName and scrollArea then
        scrollPos[currentTabName] = scrollArea:GetScroll()
    end

    -- Each tab keeps its own widgets alive and just hides them when it isn't
    -- the active one. Rebuilding on every switch would instead create a whole
    -- fresh set of frames each time (nothing here is pooled the way AceGUI's
    -- widget registry was), so switching back and forth would leak steadily.
    local prev = currentTabName and tabCache[currentTabName]
    if prev and currentTabName ~= name then
        for _, block in ipairs(prev.blocks) do block.frame:Hide() end
    end

    currentTabName = name

    local cache = tabCache[name]
    if cache then
        for _, block in ipairs(cache.blocks) do block.frame:Show() end
        -- Pick up anything that changed while this tab was hidden.
        RefreshCurrentTab()
        RelayoutContent(tabCache[name])
    else
        BuildTabContent(name)
    end

    scrollArea:SetScroll(scrollPos[name] or 0)

    for _, tab in ipairs(tabButtons) do
        tab:SetSelected(tab.moduleName == name)
    end
end

-- A tab: status dot + module title, with an accent underline when selected.
local function CreateTabButton(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(24)
    f:RegisterForClicks("AnyUp")

    local fs = W.Font(f, 12, nil, W.TEXT_DIM_A)
    fs:SetPoint("LEFT", f, "LEFT", 8, 0)
    fs:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    fs:SetJustifyH("CENTER")

    local underline = W.Tex(f, "ARTWORK", W.Accent())
    underline:SetHeight(2)
    underline:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 0)
    underline:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 0)
    underline:Hide()
    W.RegisterAccent(underline, "vertex")

    local tab = { frame = f, fs = fs }

    function tab:SetSelected(on)
        tab.selected = on
        underline:SetShown(on)
        fs:SetTextColor(1, 1, 1, on and 1 or W.TEXT_DIM_A)
    end
    function tab:SetText(text)
        fs:SetText(text)
        f:SetWidth((fs:GetStringWidth() or 60) + 24)
    end

    f:SetScript("OnEnter", function()
        if not tab.selected then fs:SetTextColor(1, 1, 1, 0.8) end
    end)
    f:SetScript("OnLeave", function()
        if not tab.selected then fs:SetTextColor(1, 1, 1, W.TEXT_DIM_A) end
    end)
    f:SetScript("OnClick", function() SelectTab(tab.moduleName) end)

    return tab
end

-- Rebuilds the tab strip: one tab per module, title prefixed with a status
-- dot so load state is visible without opening the tab. Safe to call any
-- time -- it only touches the strip, never tab content.
local function RefreshTabs()
    local names = SortedModuleNames()

    local x = 0
    for i, name in ipairs(names) do
        local tab = tabButtons[i]
        if not tab then
            tab = CreateTabButton(tabStrip)
            tabButtons[i] = tab
        end
        tab.moduleName = name

        local _, r, g, b = GetStateInfo(AniMods.status[name])
        tab:SetText(("|cff%s%s|r %s"):format(ColorHex(r, g, b), DOT, AniMods.status[name].title))
        tab:SetSelected(name == currentTabName)

        tab.frame:ClearAllPoints()
        tab.frame:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMLEFT", x, 0)
        tab.frame:Show()
        x = x + tab.frame:GetWidth()
    end

    for i = #names + 1, #tabButtons do
        tabButtons[i].frame:Hide()
    end

    return names
end

-- Called whenever module state changes -- a toggle, or a module's own event
-- handler noticing its live data changed. Safe to call from anywhere.
function AniMods.RefreshUI()
    -- Nothing to do while the panel doesn't exist yet or is closed: module
    -- events fire far more often than the panel is open, and OnShow resyncs
    -- whatever was missed.
    if not frame or not frame:IsShown() then return end
    RefreshTabs()
    RefreshCurrentTab()
end

-- ── Frame construction ───────────────────────────────────────────────────────

local function BuildUI()
    if frame then return end

    frame = W.Window("AniModsPanel", "AniMods", 700, 500)

    -- `content` is the window's own child, below S.Shell's title band.
    -- Building on `frame` directly would put these regions in EllesmereUI's
    -- restrip registry, where they get alpha-zeroed the next time a Blizzard
    -- window repaints (see Widgets.lua's header).
    local host = frame.content

    tabStrip = CreateFrame("Frame", nil, host)
    tabStrip:SetHeight(24)
    tabStrip:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -8)
    tabStrip:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, -8)

    local rule = W.Tex(host, "ARTWORK", 1, 1, 1, 0.15)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", tabStrip, "BOTTOMLEFT")
    rule:SetPoint("TOPRIGHT", tabStrip, "BOTTOMRIGHT")

    scrollArea = W.ScrollArea(host)
    scrollArea.frame:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -4)
    scrollArea.frame:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD, PAD)
    content = scrollArea.content

    local names = RefreshTabs()
    if names[1] then SelectTab(names[1]) end

    -- Resync once whenever the panel is (re)shown, covering anything that
    -- changed while it was closed. The relayout matters on the FIRST show in
    -- particular: content built while the panel was hidden measured its
    -- wrapped text against a width that hadn't resolved yet, and only a
    -- relayout (not an in-place text update) re-measures it.
    frame:HookScript("OnShow", function()
        RefreshTabs()
        RefreshCurrentTab()
        RelayoutContent(tabCache[currentTabName])
    end)
    frame:HookScript("OnHide", function()
        W.CloseDropdownMenu()
        if currentTabName and scrollArea then
            scrollPos[currentTabName] = scrollArea:GetScroll()
        end
    end)
end

function AniMods.ToggleUI()
    BuildUI()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Opens the panel already switched to a specific module's tab (e.g. a broker
-- plugin's right-click going straight to its own settings). Toggles closed on
-- a second call only if already open on that exact tab -- otherwise it
-- (re)shows and switches, so it reliably lands you there.
function AniMods.OpenModuleTab(name)
    BuildUI()
    if frame:IsShown() and currentTabName == name then
        frame:Hide()
        return
    end
    frame:Show()
    if AniMods.status[name] then SelectTab(name) end
end
