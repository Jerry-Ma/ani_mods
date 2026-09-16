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
    db.accents = db.accents or {}
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
        label = "/ani",
        Available = function() return type(AniMods.ToggleUI) == "function" end,
        OnClick = function() AniMods.ToggleUI() end,
        tip = "Open the AniMods panel.",
    },
    {
        name = "EllesmereUI",
        label = "/eui",
        Available = function() return AniMods.IsAddOnLoaded("EllesmereUI") end,
        OnClick = function()
            -- EllesmereUI's own /eui handler, called directly. An earlier
            -- version preferred EllesmereUI.OpenConfig on the reasoning that a
            -- function call beats going through the chat parser -- but calling
            -- SlashCmdList.EUIOPTIONS is not going through the parser either,
            -- it is the same direct call to the same function, and OpenConfig
            -- is the wrong one: it only Shows, so it could not close the window
            -- and did nothing at all once it was already open. The handler
            -- Toggles, defers a frame to avoid tainting Blizzard's chat chain,
            -- and says something useful when you are in combat.
            local handler = _G.SlashCmdList and _G.SlashCmdList["EUIOPTIONS"]
            if type(handler) == "function" then
                handler("")
                return
            end
            local eui = _G.EllesmereUI
            if eui and type(eui.Toggle) == "function" then eui:Toggle() end
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

-- The slash command each addon registers for itself, from
-- Tools\scan-addon-meta.ps1. It makes a far better label than any abbreviation
-- we could invent: "/bw" and "/ns" are what you would TYPE to open the thing, so
-- they are already the name you know it by, and the leading slash says at a
-- glance that the widget is a way in rather than a readout.
--
-- Picked as the shortest command whose letters are a subsequence of the addon's
-- name AND which starts with the same letter. An addon registers several and
-- most are not its identity: MRT registers /rl for reload and /key for
-- keystones, and "rt" is a subsequence of "mrt" that would have beaten "/mrt"
-- on length alone.
local ADDON_SLASH = {
    ["!BugGrabber"] = "/buggrabber",
    ["!KalielsTracker"] = "/kt",
    ["AdvancedInterfaceOptions"] = "/aio",
    ["AniMods"] = "/ani",
    ["Auctionator"] = "/atr",
    ["AutoItemMacro"] = "/aim",
    ["AutoPotion"] = "/ap",
    ["BigWigs"] = "/bw",
    ["BugSack"] = "/bugsack",
    ["Capping"] = "/capping",
    ["Chattynator"] = "/ctnr",
    ["ClickableRaidBuffs"] = "/crb",
    ["CraftSim"] = "/cs",
    ["DandersFrames"] = "/df",
    ["Details"] = "/details",
    ["EllesmereUI"] = "/eui",
    ["EllesmereUIActionBars"] = "/eab",
    ["EllesmereUICooldownManager"] = "/ecme",
    ["EllesmereUIQuestTracker"] = "/eqt",
    ["EllesmereUIResourceBars"] = "/erb",
    ["EUI_Kogotool"] = "/euikogo",
    ["Glider"] = "/glider",
    ["GTFO"] = "/gtfo",
    ["HandyNotes_MapNotes"] = "/mn",
    ["HealerManaWatch"] = "/hmw",
    ["KeystoneLoot"] = "/ksl",
    ["LiteMount"] = "/lmt",
    ["MiniAuras"] = "/minia",
    ["MRT"] = "/mrt",
    ["Myslot"] = "/myslot",
    ["MythicDungeonTools"] = "/mdt",
    ["NDui"] = "/ndui",
    ["NDui_Plus"] = "/ndp",
    ["NorthernSkyRaidTools"] = "/ns",
    ["OPie"] = "/opie",
    ["Platynator"] = "/platy",
    ["Stats"] = "/st",
    ["STT"] = "/st",
    ["TomTom"] = "/tomtom",
    ["TwintopInsanityBar"] = "/tt",
    ["UltimateMouseCursor"] = "/umc",
    ["VoidShieldHelper"] = "/vsh",
    ["WorldQuestTracker"] = "/wqt",
}

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
    -- A builtin names its own, because the label has to match what clicking it
    -- does: EllesmereUI's shortest self-referential command is /ee, which opens
    -- its quick menu, while this widget opens its settings.
    local builtin = builtins[key]
    if builtin and builtin.label then return builtin.label end
    -- The addon's own slash command, then initials as the last resort.
    return ADDON_SLASH[key] or Abbreviate(key)
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

-- The SOURCE object, looked up live rather than captured. An addon can replace
-- its own OnClick after registering -- reloading a profile, enabling a feature
-- -- and a captured function would keep calling the old one.
--
-- Declared here rather than beside the other forwarding helpers because the
-- accent code below reads the same object for its declared colour, and a Lua
-- local only exists for closures written after it.
local function Source(sourceName)
    local libStub = _G.LibStub
    local ldb = libStub and libStub:GetLibrary("LibDataBroker-1.1", true)
    return ldb and ldb:GetDataObjectByName(sourceName) or nil
end

-- ---------------------------------------------------------------------------
-- Accent colour
-- ---------------------------------------------------------------------------
-- Two letters carry very little on their own, so colour does the rest of the
-- identifying. Each widget gets one, resolved in this order:
--
--   1. Yours, if you set one.
--   2. The addon's own, if it declared iconR/iconG/iconB on its LibDataBroker
--      object. That is the tint its author chose for its minimap icon, which is
--      the closest thing to a brand colour that exists as DATA rather than as
--      artwork.
--   3. A hue hashed from the name, so everything has one.
--
-- There is deliberately no shipped table of brand colours, and no script that
-- reads one out of addon source. Nothing in an addon declares "this is my
-- colour" in any common shape -- colours live in per-feature tables, hex
-- strings, class-colour lookups and textures, differently in every addon -- so
-- a scan would return hundreds of unrelated literals per addon and the result
-- would need checking by hand, which is a hand-made table with extra steps.
--
-- What IS extractable is (2), from the running client: "Dump colours" in the
-- panel writes out what every addon actually declares. That output is the data
-- table, built from the real source rather than guessed at, and anything it
-- cannot answer for is a line you can fill in yourself.

-- A hand-picked spread rather than evenly spaced hues, which produce muddy
-- olives and near-blacks that read as broken next to a declared colour.
local PALETTE = {
    { 0.90, 0.36, 0.33 }, { 0.95, 0.57, 0.20 }, { 0.94, 0.79, 0.27 },
    { 0.55, 0.80, 0.33 }, { 0.30, 0.78, 0.35 }, { 0.20, 0.80, 0.62 },
    { 0.20, 0.74, 0.89 }, { 0.32, 0.58, 0.92 }, { 0.51, 0.47, 0.92 },
    { 0.68, 0.42, 0.88 }, { 0.89, 0.40, 0.68 }, { 0.80, 0.55, 0.42 },
}

-- Position-weighted so shared prefixes land apart: a plain byte sum puts
-- "Details" and "Deadly" on neighbouring entries, and neighbours in a bar
-- matching is the one case that has to be avoided.
local function PaletteColor(name)
    local sum = 0
    for i = 1, #name do sum = sum + name:byte(i) * i end
    return PALETTE[(sum % #PALETTE) + 1]
end

local MIN_LUMA = 0.45

-- A declared colour was chosen to sit on a bright icon, not to be read as text
-- on a dark bar, so the whole colour is lifted until it clears a legibility
-- floor. Hue and balance are kept. An unreadable label is a bug, not fidelity.
local function Readable(r, g, b)
    local luma = 0.299 * r + 0.587 * g + 0.114 * b
    if luma >= MIN_LUMA or luma <= 0 then return r, g, b end
    local lift = MIN_LUMA / luma
    return math.min(1, r * lift), math.min(1, g * lift), math.min(1, b * lift)
end

local function ToHex(r, g, b)
    return ("%02x%02x%02x"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5)
end

-- The colour the addon declared, or nil. Custom commands have no author to ask.
local function DeclaredHex(key)
    if KeyIsCustom(key) or builtins[key] then return nil end
    local obj = Source(key)
    if type(obj) ~= "table" then return nil end
    if not (obj.iconR or obj.iconG or obj.iconB) then return nil end
    -- LibDBIcon's own defaulting: a partially declared colour fills the missing
    -- channels with white, exactly as its Icon_UpdateIcon does.
    return ToHex(Readable(obj.iconR or 1, obj.iconG or 1, obj.iconB or 1))
end

-- Sampled from each addon's own icon art by Tools\scan-addon-colors.ps1 -- the
-- dominant saturated hue, weighted by saturation and binned by hue so a
-- gradient stays one colour. Regenerate it by running that script; do not hand
-- edit, put your own choices in the panel's colour editor instead.
--
-- IT IS SHORT, AND THAT IS NOT A BUG IN THE SCRIPT. Sampling needs the art to
-- be a readable file in the AddOns folder, and for most addons it is not:
-- eleven ship their icon as BLP, Blizzard's own format, which System.Drawing
-- cannot read; and far more point their minimap icon at something like
-- Interface\Icons\INV_Misc_Book_09, which lives in the game's archive and is
-- not on disk at all. Nothing can sample a texture that is not a file. The
-- runtime sources below cover what this cannot.
local ADDON_ACCENTS = {
    ["AniMods"] = "a43d0e",
    ["EllesmereUI_WindTools"] = "62e6ef",
    ["EUI_Kogotool"] = "2175f2",
    ["STT"] = "af8b52",
}

-- A colour that is only correct while the game is running, so it cannot be a
-- table entry. EllesmereUI's accent is a live setting the player changes, and
-- AniMods already follows it everywhere else -- a widget opening EllesmereUI's
-- settings in last week's accent would be the one thing in the suite that did
-- not move with it.
local function DynamicHex(key)
    if key ~= "EllesmereUI" then return nil end
    if not AniMods.IsAddOnLoaded("EllesmereUI") then return nil end
    -- EllesmereUI's own accent, whatever it is set to right now. Asked for
    -- directly rather than through W.ProviderAccent, which answers "the accent
    -- AniMods is using" -- the same thing only while EllesmereUI is the
    -- provider, and AniMods' own colour otherwise.
    local eui = _G.EllesmereUI
    if eui and type(eui.GetAccentColor) == "function" then
        local ok, r, g, b = _G.pcall(eui.GetAccentColor)
        if ok and type(r) == "number" and type(g) == "number" and type(b) == "number" then
            return ToHex(Readable(r, g, b))
        end
    end
    return ToHex(Readable(AniMods.W.ProviderAccent()))
end

local function AccentHex(key)
    local own = ModuleDB().accents[key]
    if type(own) == "string" and own:match("^%x%x%x%x%x%x$") then return own end
    return DynamicHex(key)
        or ADDON_ACCENTS[key]
        or DeclaredHex(key)
        or ToHex(unpack(PaletteColor(key)))
end

local function SetAccent(key, hex)
    local db = ModuleDB()
    if type(hex) == "string" and hex:match("^%x%x%x%x%x%x$") then
        db.accents[key] = hex:lower()
    else
        db.accents[key] = nil
    end
end

local function ColoredLabels()
    return ModuleDB().colored ~= false
end

-- ---------------------------------------------------------------------------
-- Forwarding
-- ---------------------------------------------------------------------------

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
    local label = Label(key)
    if not ColoredLabels() then return label end
    return ("|cff%s%s|r"):format(AccentHex(key), label)
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

local function HexToRGB(hex)
    return tonumber(hex:sub(1, 2), 16) / 255,
           tonumber(hex:sub(3, 4), 16) / 255,
           tonumber(hex:sub(5, 6), 16) / 255
end

local function AddCustom()
    local db = ModuleDB()
    local entry = { id = NextCustomId(), label = "New", command = "/reload" }
    db.custom[#db.custom + 1] = entry
    -- Published on creation. A command you just wrote is one you want, and
    -- making you tick it in a list immediately afterwards is a step that asks a
    -- question you already answered.
    SetPublished(CustomKey(entry.id), true)
end

local function RemoveCustom(id)
    local db = ModuleDB()
    for i, entry in ipairs(db.custom) do
        if entry.id == id then
            table.remove(db.custom, i)
            break
        end
    end
    -- The widget cannot be taken back from LibDataBroker, so it is emptied, and
    -- its label and colour go with the entry that defined them.
    SetPublished(CustomKey(id), false)
    SetLabel(CustomKey(id), nil)
    SetAccent(CustomKey(id), nil)
end

-- One row per published widget: what it is, what it shows, what colour it shows
-- it in. Earlier versions put every label in one text box and every colour in
-- another -- editing one widget meant rewriting a list of all of them, and a
-- hex string typed into a text box is not a colour you can see. Then three
-- stacked rows each, which put a label and the colour that applies to it a
-- centimetre apart. Side by side they read as one setting, which is what
-- they are.
local function WidgetRow(source)
    local id = source.custom and CustomIdFromKey(source.key) or nil

    local row = {
        kind = "widget",
        get  = function() return Label(source.key) end,
        set  = function(text) SetLabel(source.key, text); RefreshText(source.key) end,

        colorGet = function() return HexToRGB(AccentHex(source.key)) end,
        colorSet = function(r, g, b)
            SetAccent(source.key,
                ("%02x%02x%02x"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5))
            RefreshText(source.key)
        end,
        colorReset = function() SetAccent(source.key, nil); RefreshText(source.key) end,
    }

    if source.custom then
        -- The command IS the identity of a custom entry -- there is no other
        -- name for it -- so it takes the column an addon spends on its name.
        row.nameGet = function()
            local entry = CustomById(id)
            return entry and entry.command or ""
        end
        row.nameSet = function(text)
            local entry = CustomById(id)
            if entry then entry.command = text end
        end
        row.onRemove = function()
            RemoveCustom(id)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end
    else
        row.name = source.key
    end

    return row
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
        -- The abbreviation in its colour, then the full name. Picking from a
        -- list of two-letter codes asks you to already know which is which; the
        -- code is there as a PREVIEW of what the bar will show, and the name is
        -- what you actually recognise.
        items[#items + 1] = {
            key  = source.key,
            text = ("|cff%s%s|r  %s"):format(AccentHex(source.key), Label(source.key), source.name),
        }
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
                 .. "Bar (or any other LDB display), and gets its own section "
                 .. "below to label and colour. Only what you pick appears "
                 .. "there, so the bar's own list stays short. Unpublishing "
                 .. "empties a widget rather than deleting it -- LibDataBroker "
                 .. "has no way to take a name back.",
    }
    rows[#rows + 1] = {
        label = "Colored labels",
        get   = ColoredLabels,
        set   = function(v) ModuleDB().colored = v and true or false; RefreshAll() end,
        help  = "Two letters carry very little on their own, so colour does the "
             .. "rest of the identifying.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Custom command", button = "Add",
        help = "A widget that runs a slash command -- a reload button, a "
            .. "toggle for something with no minimap icon of its own. It "
            .. "appears below, published and ready to name.",
        onClick = function()
            AddCustom()
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
    }

    -- Only what is published. An unpublished source has nothing to configure --
    -- it is not a widget yet -- and a row per available addon would be fourteen
    -- to find the two that matter.
    local any = false
    for _, source in ipairs(sources) do
        if IsPublished(source.key) then
            if not any then
                any = true
                -- The help lives on the section, said once, rather than as a
                -- "?" on every row -- one per row is a column of question marks
                -- down the middle of the list.
                rows[#rows + 1] = { section = "Published" }
                rows[#rows + 1] = {
                    label = "Name, label, color",
                    value = "",
                    help  = "The middle column is what the widget shows on the "
                         .. "bar; clear it to go back to the addon's own slash "
                         .. "command. Right-click a color to clear it and go "
                         .. "back to what it resolves to on its own: "
                         .. "EllesmereUI's live accent, the addon's declared "
                         .. "color, a hue sampled from its icon art, or a hue "
                         .. "from its name. A custom entry's first column is "
                         .. "its command, and it runs exactly as typed.",
                }
            end
            rows[#rows + 1] = WidgetRow(source)
        end
    end

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
