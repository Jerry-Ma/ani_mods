-- AniMods status/config panel. `/ani` toggles it.
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
local SIDEBAR_W = 156     -- module list column
local SIDEBAR_ROW_H = 24
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

-- Modules switched this session whose change has not taken effect yet, keyed
-- by module name. Keyed rather than kept on the tab's cache because the
-- switch now lives on the SIDEBAR row and the badge that reports it lives in
-- the tab header -- two different frames, and the tab may not even be built
-- when the row is clicked.
local pendingReload = {}

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

-- Sidebar order: by the module's `order` first, then title. Everything
-- defaults to order 100 and so sorts alphabetically; General claims 0 so the
-- addon's own settings head the list instead of landing between Chat Context
-- Switch and Group Roles.
local function SortedModuleNames()
    local names = {}
    for name in pairs(AniMods.status) do tinsert(names, name) end
    table.sort(names, function(a, b)
        local ea, eb = AniMods.status[a], AniMods.status[b]
        local oa, ob = ea.order or 100, eb.order or 100
        if oa ~= ob then return oa < ob end
        return (ea.title or a) < (eb.title or b)
    end)
    return names
end

-- ── Reload prompt ────────────────────────────────────────────────────────────

-- Asks whether to reload now, for the settings that cannot fully apply until
-- the UI restarts.
--
-- Deferred by a frame and guarded, so flipping several such settings in a row
-- -- switching three modules off, say -- asks once at the end rather than
-- stacking a dialog per click. `reason` names what is waiting, since by the
-- time the dialog appears the user may have clicked more than one thing.
local reloadPending, reloadReasons = false, {}

function AniMods.PromptReload(reason)
    if reason then reloadReasons[reason] = true end
    if reloadPending then return end
    reloadPending = true

    C_Timer.After(0, function()
        reloadPending = false

        local names = {}
        for r in pairs(reloadReasons) do names[#names + 1] = r end
        reloadReasons = {}
        table.sort(names)

        local what = (#names > 0) and table.concat(names, ", ") or "This change"
        -- "Later" carries the reassurance that the change is kept, so the
        -- message does not have to.
        W.Confirm({
            message = ("Reload to apply:  %s"):format(what),
            confirmText = "Reload UI",
            cancelText  = "Later",
            onConfirm   = function() ReloadUI() end,
        })
    end)
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
--   { label = "Tanks", value = "2" }                                      -- status (a measurement)
--   { label = "In group", state = false, help = "why not" }               -- statement + Yes/No badge
--   { label = "Party", get = fn, set = fn, note = "Active" }              -- toggle, w/ status badge
--   { label = "Bar color", color = true, get = fn, set = fn, reset = fn } -- colour swatch (RGB + alpha)
--   { label = "Style", options = {k="Name",...}, order = {...},
--     get = fn, set = fn, atlas = "some-atlas" }                          -- dropdown, w/ optional icon preview
--   { label = "Style", ..., texture = "Interface\\...\\Some" }            -- dropdown, w/ texture-file preview
--   { label = "Spacing", min = 0, max = 4, step = 1, get = fn, set = fn } -- slider

--   { strip = {"a","b"}, labels = {...}, onReorder = fn, onDrop = fn }    -- draggable order preview
--   { label = "Widgets", picker = { {key=,text=}, {header=true,text=} },
--     isChecked = fn, onToggle = fn, summary = "2 of 7" }                 -- multi-select dropdown

local function RowKind(descriptor)
    if descriptor.section then return "section" end
    if descriptor.strip then return "strip" end
    if descriptor.picker then return "picker" end
    if descriptor.color then return "color" end
    -- `~= nil`, not truthiness: `state = false` is the whole point of the row.
    if descriptor.state ~= nil then return "state" end
    if descriptor.swatches then return "swatches" end
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
        local kind = RowKind(d)
        local sig = kind .. ":" .. tostring(d.section or d.label)
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
        -- Whether a row HAS a "?" is structural: the marker is created beside
        -- the label when the row is built, so a pooled row that gains or loses
        -- one cannot be updated in place -- it has to be rebuilt or it would
        -- keep (or keep lacking) a marker that no longer matches its content.
        --
        -- Statement rows are exempt: they always carry a marker and simply hide
        -- it when there is nothing to say, precisely because their reason comes
        -- and goes with the world and rebuilding on that would be constant.
        if d.help and kind ~= "state" then sig = sig .. ":?" end
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

-- A row's `note` is a live STATUS about that row -- "Active" for a chat channel
-- currently eligible, "Current" for the sound device in use -- not a qualifier
-- on its name.
--
-- One word, capitalised, matching the condition badges. "active now" was
-- written as prose to be read inline with the label it was glued to; as a badge
-- it is a state, and states here are single words.
--
-- So it renders as a badge, in the same green as every other affirmative state
-- in the panel, rather than as accent-coloured text appended to the label. The
-- accent belongs to the UI's own furniture (titles, card headers, the check
-- marks); using it for a status made the two indistinguishable, and made a
-- fact about the game look like part of the widget.
--
-- Always built, shown only when there is a note. Whether a row has one changes
-- with the world -- joining a party makes three channels eligible at once --
-- and treating that as a shape change would rebuild the section every time,
-- which is both wasteful and visibly disruptive.
local function ApplyNote(badge, descriptor)
    if not badge then return end
    if descriptor.note then
        badge:Set(descriptor.note, W.BADGE_OK)
        badge.frame:Show()
    else
        badge.frame:Hide()
    end
end

-- ── Statement rows ──────────────────────────────────────────────────────────
-- "<claim>  [Yes|No]  ?" -- ONE rendering for every yes/no fact in the panel.
--
-- The Conditions card and modules' own status rows both build with this, since
-- they ask the same kind of question. They used to answer it four different
-- ways: Met/Not met in the conditions card, Found/Not found in Skin,
-- "No (Raid Tools disabled, mode: never)" in GroupRoles, and "N/A" wherever the
-- question did not apply -- with the reason smuggled into the value as a
-- parenthetical, which is why those values kept growing into sentences.
--
-- The badge is the answer. The "?" carries the why.
--
-- It sits AFTER the badge here, which is the opposite of an option row. On an
-- option the marker explains the setting, so it belongs beside its name; on a
-- statement it explains the answer, so it belongs beside the answer.
--
-- A false is grey by default, red only when the caller says the answer matters
-- -- conditions do, because an unmet one stops the module. "In group: No" is
-- not a fault, and painting it red would spend the panel's only alarm colour on
-- a fact about the player's evening.
local function BuildStatementRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(18)

    local label = W.Font(row, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("LEFT", row, "LEFT", 8, 0)
    label:SetJustifyH("LEFT")

    local badge = W.Badge(row)
    badge.frame:SetPoint("LEFT", label, "RIGHT", 8, 0)

    -- Always built, shown only when there is something to explain. Whether a
    -- statement has a reason changes with the world -- "waiting for its icon"
    -- becomes docked -- and treating that as a shape change would rebuild the
    -- card under the cursor every time it flipped.
    local help = W.Help(row, nil)
    help.frame:SetPoint("LEFT", badge.frame, "RIGHT", 5, 0)

    return { frame = row, label = label, badge = badge, help = help }
end

local function ApplyStatement(built, descriptor, badWhenFalse)
    built.label:SetText(descriptor.label or "")
    if descriptor.state then
        built.badge:Set("Yes", W.BADGE_OK)
    else
        built.badge:Set("No", badWhenFalse and W.BADGE_BAD or W.BADGE_IDLE)
    end
    built.help:SetText(descriptor.help)
    built.help:SetShown(true)   -- W.Help hides itself when the text is empty
end

-- Attaches the "?" marker to a row when its descriptor carries `help`.
--
-- Right-aligned rather than tucked against the label, so the markers line up
-- in a column down the card and the eye can find "the one with an
-- explanation" without reading every label. `help` is for the reasoning
-- behind a setting; the short qualifier that belongs beside the label is
-- `note`.
-- Attaches the "?" marker directly after a row's label.
--
-- It used to be right-aligned, on the theory that a column of markers scans
-- better. In practice it separated the marker from the thing it explains by
-- the whole width of the row, so it read as belonging to the control on the
-- right rather than the label on the left.
local function AttachHelp(rowFrame, descriptor, anchorTo)
    if not descriptor.help then return nil end
    local help = W.Help(rowFrame, descriptor.help)
    if anchorTo then
        help.frame:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
    else
        help.frame:SetPoint("LEFT", rowFrame, "LEFT", 8, 0)
    end
    return help
end

-- Points a checkbox at a descriptor: label, state, AND the click handler.
--
-- The handler is the part that was missing. Row frames are pooled by position
-- and kind, so the checkbox at index 3 is routinely re-pointed at a different
-- setting than it held last time -- and the reuse path only refreshed the
-- label and the tick, leaving a closure still bound to the PREVIOUS
-- descriptor. The row then read one setting and wrote another: ticking the box
-- next to a broker's name toggled whichever broker used to occupy that slot,
-- which is what "the checkboxes do not work" was. Dropdowns and sliders
-- already avoided this by refusing to be reused at all; checkboxes take the
-- cheaper fix, since re-binding is all they need.
local function BindCheckbox(built, descriptor)
    local check = built.widget
    check:SetLabel(descriptor.label or "")
    check:SetChecked(descriptor.get())
    check:SetOnClick(function(value)
        descriptor.set(value)
        if descriptor.reload then AniMods.PromptReload(descriptor.label) end
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)
    ApplyNote(built.note, descriptor)
end

-- Builds one row into `parent`, returning { kind, widget } for later in-place
-- updates. `sectionIndex` tags a dropdown's open/close so a rebuild knows
-- whether it owns the currently-open menu.
local function BuildRow(parent, descriptor, sectionIndex, stripeIndex)
    local kind = RowKind(descriptor)

    if kind == "section" then
        -- The card's own header carries the title now (FillSection sets it),
        -- so the descriptor contributes no visible row -- but it still
        -- occupies its slot, because the pool and the shape signature are
        -- indexed 1:1 against the slice.
        local spacer = CreateFrame("Frame", nil, parent)
        spacer:SetHeight(1)
        return { kind = kind, widget = { SetText = function() end } }, spacer, 0

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
            if descriptor.reload then AniMods.PromptReload(descriptor.label) end
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

        AttachHelp(row, descriptor, label)
        return { kind = kind, widget = dd, icons = icons }, row, ROW_GAP

    elseif kind == "swatches" then
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(26)

        local label = W.Font(row, 12, nil, W.TEXT_DIM_A)
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetText(descriptor.label or "")

        local sw = W.Swatches(row, 14)
        sw.frame:SetPoint("LEFT", row, "LEFT", 150, 0)
        sw:SetList(descriptor.order, descriptor.swatches, descriptor.hollow, descriptor.disabled)
        sw:SetValue(descriptor.get())
        sw:SetOnChange(function(value)
            descriptor.set(value)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)

        AttachHelp(row, descriptor, label)
        return { kind = kind, widget = sw }, row, ROW_GAP

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
        AttachHelp(row, descriptor, slider.labelFS)
        return { kind = kind, widget = slider }, row, ROW_GAP

    elseif kind == "strip" then
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(24)

        local strip = W.OrderStrip(row)
        strip.frame:SetPoint("LEFT", row, "LEFT", 8, 0)
        strip.frame:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        strip:SetList(descriptor.strip, descriptor.labels, descriptor.tips)
        -- Two callbacks, because a drag has two different moments. Each swap
        -- applies to the data immediately so the real bar follows the cursor;
        -- only the drop refreshes the panel, which would otherwise rebuild
        -- this very widget while it is being dragged.
        strip:SetOnReorder(function(order)
            if descriptor.onReorder then descriptor.onReorder(order) end
        end)
        strip:SetOnDrop(function(order)
            if descriptor.onDrop then descriptor.onDrop(order) end
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
        return { kind = kind, widget = strip }, row, ROW_GAP

    elseif kind == "picker" then
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(26)

        local label = W.Font(row, 12, nil, W.TEXT_DIM_A)
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetText(descriptor.label or "")

        local picker = W.MultiSelect(row, CONTROL_WIDTH)
        picker.frame:SetPoint("LEFT", row, "LEFT", 150, 0)
        picker:SetItems(descriptor.picker)
        picker:SetIsChecked(descriptor.isChecked)
        picker:SetText(descriptor.summary or "")
        picker:SetOnToggle(function(key, on)
            descriptor.onToggle(key, on)
            -- The menu is still open and the summary is behind it, so this
            -- only has to be right by the time it closes -- but the sibling
            -- preview strip is NOT covered, and updating it as each widget is
            -- ticked is the point of having it there.
            if descriptor.summarize then picker:SetText(descriptor.summarize()) end
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
        picker:SetOnOpened(function() openDropdownSection = sectionIndex end)
        picker:SetOnClosed(function()
            openDropdownSection = nil
            if refreshPending then
                refreshPending = false
                C_Timer.After(0, function()
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end)
            end
        end)

        AttachHelp(row, descriptor, label)
        return { kind = kind, widget = picker }, row, ROW_GAP

    elseif kind == "state" then
        local built = BuildStatementRow(parent)
        ApplyStatement(built, descriptor)
        return { kind = kind, widget = built }, built.frame, ROW_GAP

    elseif kind == "color" then
        local row = CreateFrame("Frame", nil, parent)
        row:SetHeight(24)

        local label = W.Font(row, 12, nil, W.TEXT_DIM_A)
        label:SetPoint("LEFT", row, "LEFT", 8, 0)
        label:SetText(descriptor.label or "")

        local sw = W.ColorSwatch(row, 18)
        sw.frame:SetPoint("LEFT", row, "LEFT", 150, 0)
        sw:SetColor(descriptor.get())
        sw:SetOnChange(function(r, g, b, a)
            descriptor.set(r, g, b, a)
        end)
        sw:SetOnReset(function()
            if descriptor.reset then descriptor.reset() end
            sw:SetColor(descriptor.get())
        end)

        AttachHelp(row, descriptor, label)
        return { kind = kind, widget = sw }, row, ROW_GAP

    elseif kind == "checkbox" then
        local check = W.CheckBox(parent)
        local help = AttachHelp(check.frame, descriptor, check.labelFS)

        -- Immediately after the label -- or after its "?" when it has one --
        -- rather than against the row's right edge. The badge qualifies THIS
        -- row's label, and parked on the far side of the row it read as
        -- belonging to the column of controls instead. Same reasoning that
        -- moved the "?" marker back beside its label.
        local note = W.Badge(check.frame)
        note.frame:SetPoint("LEFT", help and help.frame or check.labelFS, "RIGHT", 6, 0)
        note.frame:Hide()

        local built = { kind = kind, widget = check, help = help, note = note }
        BindCheckbox(built, descriptor)
        return built, check.frame, ROW_GAP

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
            -- Re-bound, not just re-labelled. The shape matching here means the
            -- row is the same SETTING, so the old closure would usually still
            -- be correct -- but "usually" is what made the pooled-reuse version
            -- of this bug survive so long, and re-binding costs one closure.
            -- This is also what keeps the note badge live: "active now" comes
            -- and goes with the group, and nothing else repaints it.
            BindCheckbox(c, descriptor)
        elseif c and c.kind == "state" then
            ApplyStatement(c.widget, descriptor)
        elseif c and c.kind == "color" then
            -- Follows the theme until the user picks something, so it has to be
            -- re-read: the resolved colour can change without this row acting.
            c.widget:SetColor(descriptor.get())
        elseif c and c.kind == "strip" then
            -- Cells carry the widgets' LIVE text, so this is what keeps the
            -- preview matching the bar as the numbers on it change.
            c.widget:SetList(descriptor.strip, descriptor.labels, descriptor.tips)
        elseif c and c.kind == "picker" then
            -- Items as well as the summary: the menu lists every broker
            -- registered right now, and a LoadOnDemand addon can add one while
            -- the panel is open.
            c.widget:SetItems(descriptor.picker)
            c.widget:SetIsChecked(descriptor.isChecked)
            c.widget:SetText(descriptor.summary or "")
        elseif c and c.kind == "value" then
            c.widget:Set(descriptor.label, tostring(descriptor.value or ""))
        elseif c and c.kind == "swatches" then
            -- Re-push the colours as well as the selection: the "follow the
            -- theme" swatch renders whatever that currently resolves to, so
            -- it has to move when the theme does.
            c.widget:SetList(descriptor.order, descriptor.swatches, descriptor.hollow, descriptor.disabled)
            c.widget:SetValue(descriptor.get())
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
    local card = section.card
    local container = card.body
    W.ResetStack(container, 0)

    section.pool = section.pool or {}
    local pool = section.pool
    local cache = {}
    local stripe = 0

    for i, descriptor in ipairs(slice) do
        local kind = RowKind(descriptor)
        if kind == "value" then stripe = stripe + 1 end
        if kind == "section" then card:SetTitle(descriptor.section) end

        local entry = pool[i]
        if entry and entry.kind == kind then
            -- Reuse: refresh its content, re-show, re-stack below.
            if kind == "section" then
                entry.built.widget:SetText(descriptor.section)
            elseif kind == "value" then
                entry.built.widget:Set(descriptor.label, tostring(descriptor.value or ""))
                entry.built.widget:Stripe(stripe)
            elseif kind == "state" then
                ApplyStatement(entry.built.widget, descriptor)
            elseif kind == "checkbox" then
                BindCheckbox(entry.built, descriptor)
                -- The "?" text too. Whether a row HAS one is part of the shape
                -- signature, so a row that reaches this branch is guaranteed to
                -- have a marker to update.
                if entry.built.help then entry.built.help:SetText(descriptor.help) end
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

    -- The card wraps whatever the body ended up being. A slice always starts
    -- with its {section=...} descriptor when it has one, so that row's own
    -- widget is what names the card; an unnamed leading slice keeps the
    -- generic title set when the card was built.
    card:Finish()

    section.shape = BuildShape(slice)
    section.cache = cache
end

-- ── Per-module tab content ───────────────────────────────────────────────────

-- name -> { blocks, sections, titleFS, stateBadge, conditionBadges, ... }
local tabCache = {}
local scrollPos = {}   -- name -> saved scroll offset

-- Updates each requirement row's badge.
--
-- ONE vocabulary for every requirement, deliberately, and no per-entry
-- override. The badges previously said Loaded/Not loaded here,
-- Available/Missing there, None found/Already have one somewhere else -- four
-- phrasings for the single question every row asks, which made a column of
-- them read as unrelated facts instead of a checklist.
--
-- Yes/No, because each row is already phrased as a STATEMENT --
-- "EllesmereUI installed", "NDui chat module off" -- and the badge answers it.
-- Read together they form a question and its answer, which is how the rows are
-- written; Met/Not met made the reader translate the label into a requirement
-- first and then judge that. The label carries the specifics either way, which
-- is what lets one vocabulary serve rows about an addon being present, one
-- being switched off, and nothing else claiming the same job.
--
-- There is exactly one pair now. A second (In use / Not found) existed for
-- `optional` conditions, which is the vocabulary you need once a checklist
-- about "may this run" contains a row that never affects whether it runs. The
-- entries are gone rather than the words: per-feature availability is reported
-- beside the feature it governs, so every row here is once again a gate.
local function RefreshConditionRows(entry, cache)
    local builtRows = cache.conditionRows
    if not builtRows then return end
    local deps = entry.conditions
    if type(deps) ~= "table" then return end

    for i, dep in ipairs(deps) do
        local built = builtRows[i]
        if built then
            -- An entry with no `met` counts as satisfied, matching
            -- Core's EvaluateConditions. The two have to agree, or the
            -- panel would show "Not met" for something Core is happily
            -- treating as fine -- and pcall(nil) would silently produce
            -- exactly that.
            local satisfied = true
            if dep.met then
                local ok, result = pcall(dep.met)
                satisfied = (ok and result) and true or false
            end

            -- `true`: an unmet condition genuinely stops the module, so this is
            -- one of the few places a red answer is earned.
            ApplyStatement(built, { label = dep.text, state = satisfied, help = dep.help }, true)
        end
    end
end

-- Everything above the info-row sections whose content is live: the title's
-- state badge, the dependency checklist's dots, the reason line, and the
-- module switch.
-- Shared by both paths on purpose -- when only the refresh path applied
-- these, a freshly built tab showed an empty title and blank dependency
-- lines until something happened to trigger a refresh.
local function ApplyLiveValues(entry, cache)
    local stateLabel, r, g, b = GetStateInfo(entry)
    cache.stateBadge:Set(stateLabel, { r, g, b })

    if cache.pendingBadge then
        if pendingReload[cache.moduleName] then
            cache.pendingBadge:Set("Reload needed", W.BADGE_WARN)
            cache.pendingBadge.frame:Show()
        else
            cache.pendingBadge.frame:Hide()
        end
    end

    if cache.forceToggle then
        cache.forceToggle:SetChecked(entry.forced)
        -- Only usable when forcing would actually achieve something: every
        -- unmet requirement is soft. With a hard one missing the module cannot
        -- run regardless, so the switch stays visible but inert.
        cache.forceToggle:SetEnabled(entry.depsHardMet and not entry.depsAllMet)
        cache.forceLabel:SetTextColor(1, 1, 1,
            (entry.depsHardMet and not entry.depsAllMet) and W.TEXT_DIM_A or 0.25)
    end

    RefreshConditionRows(entry, cache)

    if cache.reasonText then
        if cache.hasError then
            cache.reasonText:SetText("|cffff4444" .. (entry.conditionReason or "error") .. "|r")
        elseif cache.hasReason then
            cache.reasonText:SetText("|cffff9933" .. entry.conditionReason .. "|r")
        end
    end

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

    -- Anything that divides the width it is given has to be told once the width
    -- is real. Rows built while the panel was hidden measured against zero.
    for _, section in ipairs(cache.sections or {}) do
        for _, built in pairs(section.cache or {}) do
            if built.kind == "strip" then built.widget:Relayout() end
        end
    end
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

    local cache = { blocks = {}, sections = {}, moduleName = name }
    tabCache[name] = cache

    -- Header: name, "?" for the full description, state badge, master switch.
    --
    -- One row carrying everything you need to know about the module as a
    -- whole. The description used to sit under it as a paragraph and the
    -- on/off control at the very bottom of the tab, which put the two most
    -- important things -- is it on, is it working -- at opposite ends of a
    -- scroll.
    local titleFrame = CreateFrame("Frame", nil, content)
    titleFrame:SetHeight(24)

    local titleFS = W.Font(titleFrame, 15, nil, 1)
    titleFS:SetPoint("LEFT")
    titleFS:SetText(entry.title)
    cache.titleFS = titleFS

    local titleHelp = W.Help(titleFrame, entry.description)
    titleHelp.frame:SetPoint("LEFT", titleFS, "RIGHT", 6, 0)

    local stateBadge = W.Badge(titleFrame)
    stateBadge.frame:SetPoint("LEFT", titleHelp.frame, "RIGHT", 8, 0)
    cache.stateBadge = stateBadge

    -- No on/off control here: the sidebar row owns it, so the whole set is
    -- switchable from the list without opening each tab in turn.
    --
    -- The header keeps the badge that reports the CONSEQUENCE, because that
    -- belongs with the module's state rather than with the control -- and the
    -- sidebar row has no room for it.
    local pendingBadge = W.Badge(titleFrame)
    pendingBadge.frame:SetPoint("RIGHT", titleFrame, "RIGHT", -4, 0)
    pendingBadge.frame:Hide()
    cache.pendingBadge = pendingBadge

    -- Force-active switch, for a module held back only by SOFT requirements.
    -- Sits next to the state badge because it is about that state.
    local forceToggle, forceLabel
    if entry.forceable then
        forceToggle = W.Toggle(titleFrame)
        forceToggle.frame:SetPoint("LEFT", stateBadge.frame, "RIGHT", 10, 0)
        forceToggle:SetOnClick(function(value)
            AniMods.SetModuleForced(name, value)
            AniMods.PromptReload(entry.title)
        end)

        forceLabel = W.Font(titleFrame, 11, nil, W.TEXT_DIM_A)
        forceLabel:SetPoint("LEFT", forceToggle.frame, "RIGHT", 5, 0)
        forceLabel:SetText("Run anyway")

        cache.forceToggle, cache.forceLabel = forceToggle, forceLabel
    end

    cache.blocks[#cache.blocks + 1] = { frame = titleFrame, gap = BLOCK_GAP }

    -- Conditions card: one row per condition, each with its own badge, so
    -- "why is this inactive" is answered by scanning a column of colours
    -- rather than by reading prose.
    --
    -- "Conditions" rather than "Dependencies" or "Requirements", because each
    -- row is a STATEMENT that is true or false -- "EllesmereUI installed",
    -- "NDui chat module off" -- not the name of a thing. A noun header over a
    -- column of statements reads as a mislabel.
    local deps = entry.conditions
    if type(deps) == "table" and deps[1] then
        local card = W.Card(content, "Conditions")
        cache.conditionRows = {}
        W.ResetStack(card.body, 0)

        -- The same builder the modules' own status rows use, so a condition and
        -- a module's "Docked to EllesmereUI icon" are the same object on screen
        -- rather than two things that merely resemble each other.
        for i in ipairs(deps) do
            local built = BuildStatementRow(card.body)
            cache.conditionRows[i] = built
            W.Stack(card.body, built.frame, 18, 2)
        end

        card:Finish()
        cache.conditionCard = card
        cache.blocks[#cache.blocks + 1] = { frame = card.frame, gap = BLOCK_GAP }
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
        -- "Settings" is the fallback title for a leading slice that has no
        -- {section=...} descriptor of its own.
        local card = W.Card(content, "Settings")
        local section = { card = card }
        cache.sections[gi] = section
        FillSection(section, slice, gi)
        cache.blocks[#cache.blocks + 1] = { frame = card.frame, gap = BLOCK_GAP }
    end

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

-- A sidebar row: status dot + module title, left-aligned, with an accent bar
-- down its left edge and a faint wash when selected.
--
-- This replaced a horizontal tab strip. The strip laid tabs out left to right
-- at their natural text width, so every module added made it wider, and at
-- six modules it already spanned most of a 700px panel with no room left --
-- there is no wrapping and no scrolling to fall back on. A vertical list
-- grows down a column that already scrolls, and is what EllesmereUI's own
-- options window uses, so the panel reads as part of the same suite.
local function CreateSidebarRow(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(SIDEBAR_ROW_H)
    f:RegisterForClicks("AnyUp")

    -- Selection wash, behind the text. Drawn on the row itself, which is ours
    -- and never went through S, so it is safe as a direct region.
    local wash = W.Tex(f, "BACKGROUND", 1, 1, 1, 0.06)
    wash:SetAllPoints()
    wash:Hide()

    local marker = W.Tex(f, "ARTWORK", W.Accent())
    marker:SetWidth(2)
    marker:SetPoint("TOPLEFT")
    marker:SetPoint("BOTTOMLEFT")
    marker:Hide()
    W.RegisterAccent(marker, "vertex")

    -- Power button on the right of the row, EllesmereUI's placement. Putting
    -- the on/off control in the LIST rather than inside each tab means the
    -- whole set is switchable without opening any of them, and the row's own
    -- dimming shows the result in place.
    local power = W.PowerButton(f)
    power.frame:SetPoint("RIGHT", f, "RIGHT", -8, 0)

    local fs = W.Font(f, 12, nil, W.TEXT_DIM_A)
    fs:SetPoint("LEFT", f, "LEFT", 10, 0)
    fs:SetPoint("RIGHT", power.frame, "LEFT", -6, 0)
    fs:SetJustifyH("LEFT")
    -- Long module titles get an ellipsis rather than widening the sidebar or
    -- spilling into the content pane.
    fs:SetWordWrap(false)

    local tab = { frame = f, fs = fs, power = power }

    -- Declared after `tab` so the handler can read the row's current module;
    -- rows are pooled and re-pointed at different modules as the list is
    -- rebuilt, so capturing a name here would go stale.
    power:SetOnClick(function(value)
        local name = tab.moduleName
        if not name then return end
        local applied = AniMods.SetModuleEnabled(name, value)
        pendingReload[name] = not applied
        if not applied then AniMods.PromptReload(AniMods.status[name].title) end
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)

    function tab:SetSelected(on)
        tab.selected = on
        marker:SetShown(on)
        wash:SetShown(on)
        fs:SetTextColor(1, 1, 1, on and 1 or W.TEXT_DIM_A)
    end
    function tab:SetText(text)
        fs:SetText(text)
    end
    -- Essential modules have no switch at all; the button is hidden rather
    -- than disabled, since there is no state to convey.
    function tab:SetPower(entry)
        if entry.essential then
            power.frame:Hide()
            return
        end
        power.frame:Show()
        power:SetLabel(entry.title)
        power:SetChecked(entry.userEnabled)
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

-- Rebuilds the sidebar: one row per module, title prefixed with a status dot
-- so load state is visible without opening it. Safe to call any time -- it
-- only touches the sidebar, never tab content.
local function RefreshTabs()
    local names = SortedModuleNames()

    local y = 0
    for i, name in ipairs(names) do
        local tab = tabButtons[i]
        if not tab then
            tab = CreateSidebarRow(tabStrip)
            tabButtons[i] = tab
        end
        tab.moduleName = name

        local _, r, g, b = GetStateInfo(AniMods.status[name])
        tab:SetText(("|cff%s%s|r %s"):format(ColorHex(r, g, b), DOT, AniMods.status[name].title))
        tab:SetSelected(name == currentTabName)
        tab:SetPower(AniMods.status[name])

        tab.frame:ClearAllPoints()
        tab.frame:SetPoint("TOPLEFT", tabStrip, "TOPLEFT", 0, -y)
        tab.frame:SetPoint("TOPRIGHT", tabStrip, "TOPRIGHT", 0, -y)
        tab.frame:Show()
        y = y + SIDEBAR_ROW_H
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

    frame = W.Window("AniModsPanel", "AniMods", 700, 500, {
        icon = "Interface\\AddOns\\AniMods\\Media\\icon.png",
        footer = true,
    })
    frame.footerLeft:SetText("/ani")
    frame.footerRight:SetText("v" .. (AniMods.GetAddOnVersion("AniMods") or "?"))

    -- `content` is the window's own child, below S.Shell's title band.
    -- Building on `frame` directly would put these regions in EllesmereUI's
    -- restrip registry, where they get alpha-zeroed the next time a Blizzard
    -- window repaints (see Widgets.lua's header).
    local host = frame.content

    -- Sidebar down the left, content to its right, a hairline between them.
    tabStrip = CreateFrame("Frame", nil, host)
    tabStrip:SetWidth(SIDEBAR_W)
    tabStrip:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD)
    tabStrip:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", PAD, PAD)

    local rule = W.Tex(host, "ARTWORK", 1, 1, 1, 0.15)
    rule:SetWidth(1)
    rule:SetPoint("TOPLEFT", tabStrip, "TOPRIGHT", PAD, 0)
    rule:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMRIGHT", PAD, 0)

    scrollArea = W.ScrollArea(host)
    scrollArea.frame:SetPoint("TOPLEFT", rule, "TOPRIGHT", PAD, 0)
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
