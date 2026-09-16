-- PluginButtons
-- Addon minimap buttons, as data bar widgets you can click.
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
-- text has nothing to show. Selecting one today gives a blank slot that takes no
-- width. So this publishes a second object per launcher -- type "data source",
-- carrying the addon's name as its text -- and forwards every interaction to
-- the original.
--
-- ONE WIDGET PER ADDON, deliberately. A data bar widget is one block of text
-- with one OnClick; there is no way for a display to tell which part of a
-- widget's string was clicked, so a single widget listing several addons could
-- only ever open one of them. Separate objects is what makes each one clickable,
-- and it is also what lets the bar's own picker and drag-to-order do the
-- choosing -- there is deliberately no second selection UI here.
--
-- Objects are registered ONCE for every button found and never removed:
-- LibDataBroker has no unregister, and a name can only be claimed once. Which of
-- them you actually display is the bar's business, not this module's.

local AniMods = _G.AniMods
local Broker = AniMods.Broker

local PluginButtons = {
    title = "Plugin Buttons",
    description = "Addon minimap buttons as data bar widgets.",
    dbKey = "pluginButtons",
    category = "At a Click",
    -- No conditions. It needs LibDBIcon, which is what owns addon minimap
    -- buttons -- but that is a fact about whether there is anything to proxy,
    -- not a prerequisite, and the panel says so in a row instead.
}

local OBJECT_PREFIX = "AniModsClick_"

-- name -> { object = ldbObject, source = sourceName }
local proxies = {}
local moduleEnabled = true

local function ModuleDB()
    AniModsDB.pluginButtons = AniModsDB.pluginButtons or {}
    return AniModsDB.pluginButtons
end

local function LDBIcon()
    return _G.LibStub and _G.LibStub("LibDBIcon-1.0", true) or nil
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
local function ForwardClick(sourceName, frame, mouseButton)
    local obj = Source(sourceName)
    if not (obj and type(obj.OnClick) == "function") then return end
    -- xpcall, not a bare call: this runs another addon's handler from inside
    -- the data bar's own click path, and an error escaping would read as the
    -- bar being broken.
    _G.xpcall(obj.OnClick, _G.geterrorhandler(), frame, mouseButton or "LeftButton")
end

-- LibDataBroker has two tooltip conventions and addons use both: OnEnter/OnLeave
-- for an addon that draws its own, OnTooltipShow for one that just fills
-- GameTooltip. Whichever the source has is the one forwarded; a source with
-- neither gets a plain line naming it, so the widget is never silent on hover.
local function ForwardEnter(sourceName, frame)
    local obj = Source(sourceName)
    if obj and type(obj.OnEnter) == "function" then
        _G.xpcall(obj.OnEnter, _G.geterrorhandler(), frame)
        return
    end
    _G.GameTooltip:SetOwner(frame, "ANCHOR_NONE")
    _G.GameTooltip:SetPoint("BOTTOM", frame, "TOP", 0, 6)
    if obj and type(obj.OnTooltipShow) == "function" then
        _G.xpcall(obj.OnTooltipShow, _G.geterrorhandler(), _G.GameTooltip)
    else
        _G.GameTooltip:AddLine(sourceName, 1, 1, 1)
    end
    _G.GameTooltip:Show()
end

local function ForwardLeave(sourceName, frame)
    local obj = Source(sourceName)
    if obj and type(obj.OnLeave) == "function" then
        _G.xpcall(obj.OnLeave, _G.geterrorhandler(), frame)
        return
    end
    _G.GameTooltip:Hide()
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

-- The object name IS the addon's name for almost every plugin ("BigWigs",
-- "Details!"), which is exactly what identifies it. Trailing punctuation goes,
-- because a data bar is a tight row and "Details!" earns nothing over
-- "Details".
local function DefaultLabel(sourceName)
    return (sourceName:gsub("[%p%s]+$", ""))
end

local function Label(sourceName)
    local custom = ModuleDB().labels and ModuleDB().labels[sourceName]
    if type(custom) == "string" and custom ~= "" then return custom end
    return DefaultLabel(sourceName)
end

local function SetLabel(sourceName, text)
    local db = ModuleDB()
    db.labels = db.labels or {}
    if text == nil or text == "" or text == DefaultLabel(sourceName) then
        db.labels[sourceName] = nil
    else
        db.labels[sourceName] = text
    end
end

-- ---------------------------------------------------------------------------
-- Publishing
-- ---------------------------------------------------------------------------

local function RefreshText(sourceName)
    local entry = proxies[OBJECT_PREFIX .. sourceName]
    if not (entry and entry.object) then return end
    -- Blanked rather than unregistered when the module is off. LibDataBroker
    -- objects are permanent, and a bar lays out by measured width -- a widget
    -- measuring zero takes no share, so an empty string is how one disappears.
    Broker.SetText(entry.object, moduleEnabled and Label(sourceName) or "")
end

local function Publish(sourceName)
    local objectName = OBJECT_PREFIX .. sourceName
    if proxies[objectName] then return false end

    local object = Broker.Register(objectName, {
        -- Shown in grey beside the object name in a widget picker, which is
        -- how you find "AniModsClick_BigWigs" by looking for "BigWigs".
        label   = sourceName,
        text    = moduleEnabled and Label(sourceName) or "",
        OnClick = function(frame, mouseButton) ForwardClick(sourceName, frame, mouseButton) end,
        OnEnter = function(frame) ForwardEnter(sourceName, frame) end,
        OnLeave = function(frame) ForwardLeave(sourceName, frame) end,
    })
    if not object then return false end

    proxies[objectName] = { object = object, source = sourceName }
    return true
end

-- Sorted, so what the panel lists is stable between openings: LibDBIcon builds
-- its list by walking a hash, which hands back a different order every call.
local function SourceNames()
    local icons = LDBIcon()
    if not icons then return {} end
    local names = icons:GetButtonList()
    table.sort(names)
    return names
end

local function PublishAll()
    local added = 0
    for _, sourceName in ipairs(SourceNames()) do
        if Publish(sourceName) then added = added + 1 end
    end
    return added
end

local function RefreshAll()
    for _, entry in pairs(proxies) do RefreshText(entry.source) end
end

-- Addons that load late register their button late, and LibDBIcon says so
-- rather than leaving it to be noticed. Registered once; publishing is
-- idempotent, so a duplicate announcement costs nothing.
local callbackOwner = {}

local function EnsureCallback()
    local icons = LDBIcon()
    if not icons or callbackOwner.registered then return end
    if type(icons.RegisterCallback) ~= "function" then return end
    callbackOwner.registered = true
    icons.RegisterCallback(callbackOwner, "LibDBIcon_IconCreated",
        function(_, _, sourceName)
            if sourceName then Publish(sourceName) end
        end)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function PluginButtons:GetInfoRows()
    local rows = {}
    local icons = LDBIcon()

    rows[#rows + 1] = { section = "Widgets" }
    rows[#rows + 1] = {
        label = "LibDBIcon present",
        state = icons and true or false,
        help  = "The library that owns addon minimap buttons. Without it there "
             .. "is nothing to proxy -- not a failure, just an install with no "
             .. "addon buttons on the minimap.",
    }

    local published = 0
    for _ in pairs(proxies) do published = published + 1 end
    rows[#rows + 1] = {
        label = "Published",
        value = tostring(published),
        help  = "One widget per addon button, because a data bar widget has one "
             .. "OnClick and no way to tell which part of its text was clicked "
             .. "-- so a single combined widget could only ever open one addon.",
    }
    rows[#rows + 1] = {
        label = "How to use them",
        value = "Data Bar",
        help  = "These are widgets, not a bar of their own. Add the ones you "
             .. "want in Data Bar's widget picker (or any other LDB display) "
             .. "and drag them into the order you like. Choosing is the bar's "
             .. "job, so there is no second list here to keep in sync.",
    }

    local names = SourceNames()
    if #names > 0 then
        rows[#rows + 1] = { section = "Labels" }
        rows[#rows + 1] = {
            kind = "button", label = "Rename a widget", button = "Rename",
            help = "One name per line, as \"Source = Label\". Leave a source "
                .. "out to keep its default, or set it back to the default to "
                .. "clear it.",
            onClick = function()
                local lines = {}
                for _, sourceName in ipairs(names) do
                    lines[#lines + 1] = sourceName .. " = " .. Label(sourceName)
                end
                AniMods.W.TextBox({
                    title    = "Plugin button labels",
                    action   = "Save",
                    text     = table.concat(lines, "\n"),
                    onAction = function(input)
                        for line in (input or ""):gmatch("[^\n]+") do
                            local source, label = line:match("^%s*(.-)%s*=%s*(.-)%s*$")
                            if source and source ~= "" then SetLabel(source, label) end
                        end
                        RefreshAll()
                        if AniMods.RefreshUI then AniMods.RefreshUI() end
                    end,
                })
            end,
        }
        for _, sourceName in ipairs(names) do
            rows[#rows + 1] = { label = sourceName, value = Label(sourceName) }
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
    -- login. The callback above catches the rest.
    AniMods.W.OnReady(function()
        EnsureCallback()
        PublishAll()
        for _, delay in ipairs({ 2, 5, 10 }) do
            _G.C_Timer.After(delay, PublishAll)
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
