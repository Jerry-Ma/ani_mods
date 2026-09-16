-- PluginButtons
-- Addon minimap buttons, and your own slash commands, as data bar widgets.
--
-- The minimap ring is a bad place for these. Every addon draws its icon for a
-- 32px button sitting alone, so grouping them into a flyout puts a dozen
-- unrelated styles, crops and brightnesses in one grid -- and redrawing them as
-- their initial does not rescue it either, because first letters do not
-- identify addons: four Ms and three Ss in one panel is worse than the art was.
-- Text identifies addons. A data bar is made of text.
--
-- WHY A PROXY IS NEEDED AT ALL. Every LibDBIcon minimap button already comes
-- from a LibDataBroker object, so those objects are already registered and
-- already appear in any data bar's widget picker, including this addon's. They
-- render as nothing, because they are type "launcher": a launcher declares an
-- icon and an OnClick and has no `text` or `value` at all, and a bar showing
-- text has nothing to show. Selecting one gives a blank slot that takes no
-- width. So this publishes a second object -- type "data source", carrying a
-- label as its text -- and forwards every interaction to the original.
--
-- ONE WIDGET PER ENTRY, deliberately. A data bar widget is one block of text
-- with one OnClick; no display can tell which part of a widget's string was
-- clicked, so a single widget listing several addons could only ever open one
-- of them.
--
-- NOTHING IS PUBLISHED UNTIL YOU ASK FOR IT. An earlier version published a
-- proxy for every button it could find, which put twenty AniModsClick_ entries
-- into every data bar's widget picker to get the two or three anyone wanted.
-- Choosing happens here, in a list of what exists; the bar's own picker then
-- chooses among what you published, which is a much shorter list.
--
-- A published object is never removed, because LibDataBroker has no unregister
-- and a name can only be claimed once. Unpublishing blanks its text instead: a
-- bar lays out by measured width, so an empty widget takes no share and
-- disappears without being removed from anything.

local AniMods = _G.AniMods
local Broker = AniMods.Broker

local PluginButtons = {
    title = "Plugin Buttons",
    description = "Addon minimap buttons and slash commands as data bar widgets.",
    dbKey = "pluginButtons",
    category = "At a Click",
}

local OBJECT_PREFIX = "AniModsClick_"

-- key -> ldb object, for everything published this session.
local published = {}
local moduleEnabled = true

local function ModuleDB()
    AniModsDB.pluginButtons = AniModsDB.pluginButtons or {}
    local db = AniModsDB.pluginButtons
    db.publish = db.publish or {}
    db.labels = db.labels or {}
    db.custom = db.custom or {}
    return db
end

local function LDBIcon()
    return _G.LibStub and _G.LibStub("LibDBIcon-1.0", true) or nil
end

-- ---------------------------------------------------------------------------
-- Sources that are not LibDBIcon buttons
-- ---------------------------------------------------------------------------
-- LibDBIcon does not own every addon button on the minimap. AniMods' own is
-- hand-rolled (General.lua says why -- one button does not justify the library),
-- and EllesmereUI opens its options from its own chrome, so neither appears in
-- GetButtonList.
--
-- Curated rather than discovered. A generic sweep of Minimap's children would
-- find these two and also every piece of furniture around them -- the zoom
-- buttons, the tracking button, EllesmereUI's own flyout toggle and indicator
-- row -- and telling a plugin button from a decoration by shape is the kind of
-- guessing that produced the lettered-icon mess. A named list of two is honest
-- about being a list of two. Anything else you want is a custom command.
local BUILTIN_SOURCES = {
    {
        name = "AniMods",
        Available = function() return type(AniMods.ToggleUI) == "function" end,
        OnClick = function() AniMods.ToggleUI() end,
        tip = "Open the AniMods panel.",
    },
    {
        name = "EllesmereUI",
        Available = function() return AniMods.IsAddOnLoaded("EllesmereUI") end,
        OnClick = function()
            -- The function first: it is a direct call, where the slash command
            -- goes back through the chat parser to reach the same place.
            local eui = _G.EllesmereUI
            if eui and type(eui.OpenConfig) == "function" then
                eui.OpenConfig()
                return
            end
            local handler = _G.SlashCmdList and _G.SlashCmdList["EUIOPTIONS"]
            if type(handler) == "function" then handler("") end
        end,
        tip = "Open EllesmereUI's settings.",
    },
}

local builtins = {}
for _, spec in ipairs(BUILTIN_SOURCES) do builtins[spec.name] = spec end

-- ---------------------------------------------------------------------------
-- Custom commands
-- ---------------------------------------------------------------------------

local CUSTOM_PREFIX = "#"

-- Ids, not labels, are what an object is named after. Renaming an entry has to
-- keep the widget you already placed on the bar, and a name derived from the
-- label would orphan it the moment you changed the text.
local function NextCustomId()
    local db = ModuleDB()
    db.nextId = (db.nextId or 0) + 1
    return db.nextId
end

local function CustomById(id)
    for _, entry in ipairs(ModuleDB().custom) do
        if entry.id == id then return entry end
    end
    return nil
end

local function CustomKey(id) return CUSTOM_PREFIX .. id end

local function KeyIsCustom(key) return key:sub(1, 1) == CUSTOM_PREFIX end

local function CustomIdFromKey(key) return tonumber(key:sub(2)) end

-- Run through the chat edit box rather than through RunMacroText or a direct
-- SlashCmdList lookup. It is the path Blizzard's own UI uses for a typed
-- command, so it resolves aliases and argument parsing exactly the way typing
-- it would -- a direct lookup would have to reimplement which of the SLASH_X1..n
-- aliases maps to which handler.
local function RunCommand(command)
    if type(command) ~= "string" or command == "" then return end
    -- Guarded rather than assumed: without the slash this sends the text to
    -- whatever channel the edit box is on, which is a very loud way to find out
    -- a setting was wrong.
    if command:sub(1, 1) ~= "/" then
        AniMods.Print(("%q is not a slash command -- it has to start with /."):format(command))
        return
    end
    local editBox = _G.ChatFrame1EditBox
    if not editBox then return end
    editBox:SetText(command)
    _G.ChatEdit_SendText(editBox, 0)
    editBox:SetText("")
end

-- ---------------------------------------------------------------------------
-- The source list
-- ---------------------------------------------------------------------------

-- Every entry offered in the picker: the two named sources, every LibDBIcon
-- button, and every custom command. Deduplicated by name, because an addon
-- could be both a named source and a LibDBIcon button of its own, and a second
-- proxy would only be a second name for one widget.
--
-- Sorted within each group but grouped in a fixed order, so the list reads the
-- same every time it is opened -- LibDBIcon builds its own list by walking a
-- hash and hands back a different order on every call.
local function AllSources()
    local seen, addons = {}, {}

    for _, spec in ipairs(BUILTIN_SOURCES) do
        if spec.Available() then
            seen[spec.name] = true
            addons[#addons + 1] = spec.name
        end
    end

    local icons = LDBIcon()
    if icons then
        for _, name in ipairs(icons:GetButtonList()) do
            if not seen[name] then
                seen[name] = true
                addons[#addons + 1] = name
            end
        end
    end
    table.sort(addons)

    local out = {}
    for _, name in ipairs(addons) do
        out[#out + 1] = { key = name, name = name, custom = false }
    end
    for _, entry in ipairs(ModuleDB().custom) do
        out[#out + 1] = { key = CustomKey(entry.id), name = entry.label or "?", custom = true }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

local ABBREV_LEN = 2

-- A data bar is a tight horizontal row, so a widget spends its width badly on
-- "NorthernSkyRaidTools" when "NS" identifies it just as well and the tooltip
-- carries the full name anyway.
--
-- Initials of the first two words, where a word is a CamelCase hump or a
-- separator-delimited chunk: BigWigs -> BW, NorthernSkyRaidTools -> NS,
-- KeystoneLoot -> KL, !KalielsTracker -> KT (leading punctuation is sort-order
-- decoration, not identity).
--
-- Two names CAN abbreviate the same. That is left alone deliberately: resolving
-- it would mean extending whichever came second, and "second" depends on addon
-- load order, so the same widget would be labelled differently between logins.
-- A stable wrong-looking label you can rename beats a label that moves.
local function Abbreviate(name)
    local words = {}
    for chunk in name:gmatch("[%a%d]+") do
        -- The only reliable CamelCase boundary is lowercase followed by
        -- uppercase. Splitting runs of capitals as well would turn "UI" into
        -- two words and EllesmereUI into "EU" by a different route, but would
        -- also break every acronym in half.
        local spaced = (chunk:gsub("(%l)(%u)", "%1 %2"))
        for word in spaced:gmatch("%S+") do words[#words + 1] = word end
    end

    if #words == 0 then return name:sub(1, ABBREV_LEN):upper() end

    -- An acronym is already an abbreviation. Shortening MRT to MR reads as a
    -- truncation of nothing.
    if #words == 1 and words[1] == words[1]:upper() and #words[1] <= 3 then
        return words[1]
    end

    if #words >= ABBREV_LEN then
        local out = ""
        for i = 1, ABBREV_LEN do out = out .. words[i]:sub(1, 1):upper() end
        return out
    end

    -- One word, so its own first letters -- which is what anyone shortening it
    -- by hand would write. "Details" -> "De".
    local word = words[1]
    return word:sub(1, 1):upper() .. word:sub(2, ABBREV_LEN):lower()
end

local function DefaultLabel(key)
    if KeyIsCustom(key) then
        -- Not abbreviated: you typed this label, so it is already the short
        -- form you wanted.
        local entry = CustomById(CustomIdFromKey(key))
        return entry and entry.label or "?"
    end
    return Abbreviate(key)
end

local function Label(key)
    local custom = ModuleDB().labels[key]
    if type(custom) == "string" and custom ~= "" then return custom end
    return DefaultLabel(key)
end

local function SetLabel(key, text)
    local db = ModuleDB()
    if text == nil or text == "" or text == DefaultLabel(key) then
        db.labels[key] = nil
    else
        db.labels[key] = text
    end
end

-- ---------------------------------------------------------------------------
-- Forwarding
-- ---------------------------------------------------------------------------

-- The SOURCE object, looked up live rather than captured. An addon can replace
-- its own OnClick after registering -- reloading a profile, enabling a feature
-- -- and a captured function would keep calling the old one.
local function Source(sourceName)
    local libStub = _G.LibStub
    local ldb = libStub and libStub:GetLibrary("LibDataBroker-1.1", true)
    return ldb and ldb:GetDataObjectByName(sourceName) or nil
end

-- `frame` is the display's own anchor -- the bar's widget frame, not ours. It
-- is passed straight through so the addon's dropdown or tooltip opens against
-- the thing that was clicked, which is the whole point of a proxy.
local function ForwardClick(key, frame, mouseButton)
    if KeyIsCustom(key) then
        local entry = CustomById(CustomIdFromKey(key))
        if entry then RunCommand(entry.command) end
        return
    end

    local builtin = builtins[key]
    if builtin then
        -- xpcall, not a bare call: this runs from inside the data bar's own
        -- click path, and an error escaping would read as the bar being broken.
        _G.xpcall(builtin.OnClick, _G.geterrorhandler())
        return
    end

    local obj = Source(key)
    if not (obj and type(obj.OnClick) == "function") then return end
    _G.xpcall(obj.OnClick, _G.geterrorhandler(), frame, mouseButton or "LeftButton")
end

local function PlainTooltip(frame, title, line)
    _G.GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    _G.GameTooltip:SetPoint("BOTTOM", frame, "TOP", 0, 6)
    _G.GameTooltip:AddLine(title, 1, 1, 1)
    if line then _G.GameTooltip:AddLine(line, 0.7, 0.7, 0.7) end
    _G.GameTooltip:Show()
end

-- LibDataBroker has two tooltip conventions and addons use both: OnEnter/OnLeave
-- for an addon that draws its own, OnTooltipShow for one that just fills
-- GameTooltip. Whichever the source has is the one forwarded; a source with
-- neither gets a plain line naming it, so the widget is never silent on hover.
local function ForwardEnter(key, frame)
    if KeyIsCustom(key) then
        local entry = CustomById(CustomIdFromKey(key))
        PlainTooltip(frame, Label(key), entry and entry.command or nil)
        return
    end

    local builtin = builtins[key]
    if builtin then
        PlainTooltip(frame, key, builtin.tip)
        return
    end

    local obj = Source(key)
    if obj and type(obj.OnEnter) == "function" then
        _G.xpcall(obj.OnEnter, _G.geterrorhandler(), frame)
        return
    end
    _G.GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    _G.GameTooltip:SetPoint("BOTTOM", frame, "TOP", 0, 6)
    if obj and type(obj.OnTooltipShow) == "function" then
        _G.xpcall(obj.OnTooltipShow, _G.geterrorhandler(), _G.GameTooltip)
    else
        _G.GameTooltip:AddLine(key, 1, 1, 1)
    end
    _G.GameTooltip:Show()
end

local function ForwardLeave(key, frame)
    if KeyIsCustom(key) or builtins[key] then
        _G.GameTooltip:Hide()
        return
    end
    local obj = Source(key)
    if obj and type(obj.OnLeave) == "function" then
        _G.xpcall(obj.OnLeave, _G.geterrorhandler(), frame)
        return
    end
    _G.GameTooltip:Hide()
end

-- ---------------------------------------------------------------------------
-- Publishing
-- ---------------------------------------------------------------------------

local function ObjectName(key)
    if KeyIsCustom(key) then return OBJECT_PREFIX .. "Cmd" .. CustomIdFromKey(key) end
    return OBJECT_PREFIX .. key
end

local function IsPublished(key)
    return ModuleDB().publish[key] and true or false
end

local function TextFor(key)
    if not (moduleEnabled and IsPublished(key)) then return "" end
    return Label(key)
end

local function RefreshText(key)
    local object = published[key]
    if object then Broker.SetText(object, TextFor(key)) end
end

local function Publish(key)
    if published[key] then
        RefreshText(key)
        return
    end
    local object = Broker.Register(ObjectName(key), {
        -- Shown in grey beside the object name in a widget picker, which is how
        -- you find "AniModsClick_BigWigs" by looking for "BigWigs".
        label   = DefaultLabel(key),
        text    = TextFor(key),
        OnClick = function(frame, mouseButton) ForwardClick(key, frame, mouseButton) end,
        OnEnter = function(frame) ForwardEnter(key, frame) end,
        OnLeave = function(frame) ForwardLeave(key, frame) end,
    })
    if object then published[key] = object end
end

local function SetPublished(key, on)
    ModuleDB().publish[key] = on and true or nil
    if on then
        Publish(key)
    else
        RefreshText(key)
    end
end

-- Only what was asked for, and only once. Runs at login for everything already
-- marked, and again for a custom entry the moment it is created.
local function PublishMarked()
    for _, source in ipairs(AllSources()) do
        if IsPublished(source.key) then Publish(source.key) end
    end
end

local function RefreshAll()
    for key in pairs(published) do RefreshText(key) end
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function CustomReport()
    local lines = {}
    for _, entry in ipairs(ModuleDB().custom) do
        lines[#lines + 1] = (entry.label or "?") .. " = " .. (entry.command or "")
    end
    return table.concat(lines, "\n")
end

-- One line per entry, "Label = /command". Rewritten wholesale rather than
-- edited row by row: the list is short, and a text box is the only editor that
-- lets you reorder, retitle and delete in one pass without a row of buttons per
-- entry.
local function ApplyCustomReport(input)
    local db = ModuleDB()
    local byLabel = {}
    for _, entry in ipairs(db.custom) do byLabel[entry.label] = entry end

    local kept = {}
    for line in (input or ""):gmatch("[^\n]+") do
        local label, command = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if label and label ~= "" and command and command ~= "" then
            -- Matched by label so an unchanged line keeps its id, and with it
            -- the widget already placed on your bar.
            local existing = byLabel[label]
            if existing then
                existing.command = command
                kept[#kept + 1] = existing
            else
                kept[#kept + 1] = { id = NextCustomId(), label = label, command = command }
            end
        end
    end
    db.custom = kept

    for _, entry in ipairs(kept) do
        if IsPublished(CustomKey(entry.id)) then Publish(CustomKey(entry.id)) end
    end
    RefreshAll()
end

function PluginButtons:GetInfoRows()
    local rows = {}
    local sources = AllSources()

    local items, count = {}, 0
    local addonHeader, customHeader = false, false
    for _, source in ipairs(sources) do
        if source.custom and not customHeader then
            customHeader = true
            items[#items + 1] = { header = true, text = "Custom commands" }
        elseif not source.custom and not addonHeader then
            addonHeader = true
            items[#items + 1] = { header = true, text = "Addons" }
        end
        items[#items + 1] = { key = source.key, text = Label(source.key) }
        if IsPublished(source.key) then count = count + 1 end
    end

    rows[#rows + 1] = { section = "Widgets" }
    rows[#rows + 1] = {
        label     = "Publish",
        picker    = items,
        isChecked = IsPublished,
        onToggle  = function(key) SetPublished(key, not IsPublished(key)) end,
        summary   = ("%d of %d"):format(count, #sources),
        help      = "Each one published becomes a widget you can add in Data "
                 .. "Bar (or any other LDB display). Only what you pick appears "
                 .. "there, so the bar's own list stays short. Unpublishing "
                 .. "empties a widget rather than deleting it -- LibDataBroker "
                 .. "has no way to take a name back.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Rename", button = "Edit",
        help = "One line per widget, as \"Source = Label\". Set a label back to "
            .. "the source's own name to clear the override.",
        onClick = function()
            local lines = {}
            for _, source in ipairs(sources) do
                lines[#lines + 1] = source.key .. " = " .. Label(source.key)
            end
            AniMods.W.TextBox({
                title    = "Widget labels",
                action   = "Save",
                text     = table.concat(lines, "\n"),
                onAction = function(input)
                    for line in (input or ""):gmatch("[^\n]+") do
                        local key, label = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
                        if key and key ~= "" then SetLabel(key, label) end
                    end
                    RefreshAll()
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end,
            })
        end,
    }

    rows[#rows + 1] = { section = "Custom commands" }
    rows[#rows + 1] = {
        kind = "button", label = "Edit the list", button = "Edit",
        help = "One line per entry, as \"Label = /command\". Anything you can "
            .. "type in chat works, and it runs exactly as if you had typed it. "
            .. "A line whose label you leave alone keeps the widget you already "
            .. "placed on the bar; delete the line to retire it.",
        onClick = function()
            AniMods.W.TextBox({
                title    = "Custom command widgets",
                action   = "Save",
                text     = CustomReport(),
                onAction = function(input)
                    ApplyCustomReport(input)
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end,
            })
        end,
    }
    rows[#rows + 1] = {
        label = "Defined",
        value = tostring(#ModuleDB().custom),
        help  = "Each becomes a widget once you publish it above.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function PluginButtons:Enable()
    moduleEnabled = true
    -- Deferred, and with a ladder: LibDBIcon buttons appear as their owning
    -- addons initialise, which for a load-on-demand addon can be long after
    -- login. A source marked for publishing that is not there yet is simply
    -- picked up on a later pass.
    AniMods.W.OnReady(function()
        PublishMarked()
        for _, delay in ipairs({ 2, 5, 10 }) do
            _G.C_Timer.After(delay, PublishMarked)
        end
    end)
end

-- Toggles live. The objects stay registered -- LibDataBroker has no unregister
-- -- so switching off blanks their text, which is how a widget takes no width
-- and disappears from the bar without being removed from it.
function PluginButtons:SetEnabled(on)
    moduleEnabled = on and true or false
    RefreshAll()
    return true
end

AniMods.RegisterModule("PluginButtons", PluginButtons)
