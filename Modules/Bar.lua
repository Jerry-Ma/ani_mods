-- Bar
-- A minimal LibDataBroker display bar, so AniMods' broker widgets (and any
-- other addon's) have somewhere to live on a stock Blizzard UI.
--
-- ── Why this exists ──────────────────────────────────────────────────────────
--
-- Every AniMods module that shows live information publishes it as an LDB
-- data object rather than drawing it somewhere: GroupRoles, SocialStatus and
-- SoundSwitch all do. That is the right split -- it means EllesmereUIDataBars,
-- Titan, ChocolateBar, Bazooka or AbstractBar can all display them -- but it
-- leaves a gap: with none of those installed there is nowhere for the data to
-- appear at all. This closes it, without making AniMods depend on any of them.
--
-- Off by default. If a real data bar is installed, that one should be used;
-- this exists for the setup that has none.
--
-- ── Lessons taken from AbstractBar (studied 2026-09-07) ──────────────────────
--
-- AbstractBar is the closest comparable and got the important things right,
-- so they are copied deliberately:
--   * It is a GENERIC LDB display -- DataObjectIterator plus a
--     LibDataBroker_DataObjectCreated subscription -- not a private list of
--     its own brokers. Any plugin registered by anyone shows up. Same here.
--   * Its per-second refresh dirty-checks before touching a FontString, and
--     uses tolerance bands on noisy values so a jittering number does not
--     allocate a new string every tick.
--
-- And one thing deliberately NOT copied: its refresh is an unconditional
-- C_TimerNewTicker(1.0) that runs for the whole session even when the bar is
-- hidden and even when nothing on it needs sampling. That is defensible for
-- its own clock and FPS widgets, which have no events -- but AniMods has no
-- sampled widgets at all. Every broker here pushes: LDB fires
-- LibDataBroker_AttributeChanged_<name> when a plugin assigns .text, and that
-- is the only thing this bar listens to. It does no periodic work whatsoever,
-- which keeps the addon's "nothing polls" property intact (see README).

local Bar = {
    title = "Data Bar",
    description = "A simple bar for LibDataBroker widgets.",
    -- Its "you already have a data bar" requirement is advisory, so the panel
    -- offers a Run anyway switch when that is the only thing holding it back.
    forceable = true,
    conditions = {
        { text = "LibDataBroker available",
          help = "The library data brokers publish through. Shipped by EllesmereUI "
              .. "and most data bars.",
          met = function()
              return (_G.LibStub and _G.LibStub:GetLibrary("LibDataBroker-1.1", true)) and true or false
          end },
        { text = "No other data bar",
          -- Soft: advice, not a prerequisite. Running both is the user's call,
          -- so this one can be overridden with Run anyway.
          soft = true,
          help = "Use your existing bar instead -- it does more. Turn on Run "
              .. "anyway to run both.",
          met = function()
              return not (AniMods.IsAddOnLoaded("EllesmereUIDataBars")
                       or AniMods.IsAddOnLoaded("Titan")
                       or AniMods.IsAddOnLoaded("ChocolateBar")
                       or AniMods.IsAddOnLoaded("Bazooka")
                       or AniMods.IsAddOnLoaded("AbstractBar"))
          end },
    },
}

local LDB_NAME = "LibDataBroker-1.1"

local BAR_H       = 22
local EDGE_PAD    = 6
local SLOT_PAD    = 4    -- breathing room inside a widget's own slot
local FONT_SIZE   = 12
local ICON_SIZE   = 14
local ICON_GAP    = 3    -- between a plugin's icon and its text

-- Attribute keys worth a repaint. LDB fires for EVERY assignment to a data
-- object, and plugins routinely park their own state there, so without this
-- the bar re-measures for keys it never renders.
local WATCHED = {
    text = true, value = true, suffix = true,
    icon = true, iconR = true, iconG = true, iconB = true, iconCoords = true,
}

local bar, itemHost
local items = {}          -- objName -> { button, fs, icon, text, hasIcon, textW }
local ldb
local enabled = {}        -- objName -> true, a lookup over db.order
local dirty = false

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- ONE ordered list is the whole widget model: membership means the widget is
-- on the bar, and position means where. It replaced a `widgets` map of name ->
-- "left"/"center"/"right", which needed two controls per widget (a switch and
-- an alignment) and still could not express "this one before that one".
local function ModuleDB()
    AniModsDB.bar = AniModsDB.bar or {}
    local db = AniModsDB.bar

    -- Migration off the old per-widget alignment map. Sections are read in
    -- left/centre/right order and each sorted by name, which lands every widget
    -- in the position it was already displayed at -- so an existing bar looks
    -- the same after the upgrade, just reorderable.
    if db.widgets and not db.order then
        local order = {}
        for _, section in ipairs({ "left", "center", "right" }) do
            local group = {}
            for name, value in pairs(db.widgets) do
                -- `true` was the even older boolean form, which meant "on".
                if value == true or value == section then group[#group + 1] = name end
            end
            table.sort(group)
            for _, name in ipairs(group) do order[#order + 1] = name end
        end
        db.order = order
        db.widgets = nil
    end
    db.order = db.order or {}

    -- Unlocked by default: a bar you just switched on has to be positionable
    -- without hunting for the setting that allows it. Lock it once it is
    -- where you want it.
    if db.locked == nil then db.locked = false end
    if db.showIcons == nil then db.showIcons = true end
    if db.width == nil then db.width = 500 end

    -- Dropped settings, cleared rather than left to rot in the saved variables.
    -- `stripColors` discarded the meaning AniMods' own brokers put in their
    -- colours; `maxWidth` capped a widget's width, which equal division now
    -- does by construction -- every widget gets exactly its share and its text
    -- truncates to fit, so there is nothing left for a manual cap to do.
    db.stripColors = nil
    db.maxWidth = nil
    db.showOthers = nil

    return db
end

local function RebuildEnabledLookup()
    wipe(enabled)
    for _, name in ipairs(ModuleDB().order) do enabled[name] = true end
end

local function IsLocked()
    return ModuleDB().locked == true
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- The display string, following LibDataBroker's actual precedence: `text`
-- first, else `value` optionally suffixed by `suffix` -- the pair plugins use
-- when they publish a number and its unit separately.
--
-- NOT `label`. Falling back to the label (as this first did) puts a plugin's
-- full name on the bar forever whenever it has nothing to say -- and worse,
-- it hides the real problem, which was that a plugin publishing only an ICON
-- looked identical to a broken one. Icons are rendered separately below; an
-- empty string here is a legitimate answer, and the icon carries the slot.
-- Each plugin's own colour codes are left exactly as published. There was a
-- "Strip plugin colors" setting; it went because the colours carry meaning
-- rather than decoration -- GroupRoles tints by role, SocialStatus by guild
-- versus friends -- so stripping them silently deleted information from the
-- bar to solve a palette clash that a widget can be switched off to solve.
local function ItemText(obj)
    if not obj then return "" end
    local t = obj.text
    if type(t) == "string" and t ~= "" then return t end

    local v = obj.value
    if v == nil then return "" end
    local str = tostring(v)
    local suffix = obj.suffix
    if type(suffix) == "string" and suffix ~= "" then str = str .. " " .. suffix end
    return str
end

-- Every call into a plugin is isolated. A data object is written by code we
-- do not own, and an error inside our hover or refresh path would otherwise
-- take the whole bar's layout down with it -- the same rule
-- EllesmereUIDataBars states for its own broker block.
local function Safe(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
end

local function EnsureItem(name)
    local it = items[name]
    if it then return it end

    -- The bar must exist first. Creating a button against a nil itemHost
    -- yields an orphan with no parent that can never render, and because it
    -- is cached below, that orphan would be returned forever -- so a widget
    -- toggled on while the bar was hidden stayed invisible even after the bar
    -- was shown, and only a /reload cleared it.
    if not itemHost then return nil end

    local btn = CreateFrame("Button", nil, itemHost)
    btn:SetHeight(BAR_H)
    btn:RegisterForClicks("AnyUp")

    -- Plugins publish `icon` (a texture path or atlas) independently of their
    -- text, and many publish ONLY an icon. Ignoring it, as this first did, is
    -- why several brokers rendered as a blank gap.
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT")
    icon:Hide()

    local fs = AniMods.W.Font(btn, FONT_SIZE, nil, 1)
    fs:SetPoint("LEFT")
    fs:SetJustifyH("LEFT")
    -- Required for the Max Width clamp to ellipsize: with wrapping on, a
    -- clamped FontString grows a second line and overflows the bar's height
    -- instead of being cut.
    fs:SetWordWrap(false)

    it = { button = btn, fs = fs, icon = icon, text = nil, hasIcon = false }
    items[name] = it

    -- Forward the standard LDB interaction contract to the plugin. OnEnter is
    -- preferred over OnTooltipShow when a plugin offers both -- the same
    -- precedence EllesmereUIDataBars uses, and what lets SocialStatus draw its
    -- own bordered popup instead of a plain GameTooltip.
    btn:SetScript("OnClick", function(self, button)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if obj then Safe(obj.OnClick, self, button) end
    end)
    btn:SetScript("OnEnter", function(self)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if not obj then return end
        if obj.OnEnter then
            Safe(obj.OnEnter, self)
        elseif obj.OnTooltipShow then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            Safe(obj.OnTooltipShow, GameTooltip)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if obj and obj.OnLeave then
            Safe(obj.OnLeave, self)
        else
            GameTooltip:Hide()
        end
    end)

    return it
end

-- Natural width of one item's content, and the text width cached alongside it.
-- Measured unconstrained (width 0 = size to content), because a FontString
-- that is still carrying last layout's clamp would otherwise report that clamp
-- back as its own width and the slot would ratchet smaller every pass.
local function MeasureItem(it)
    it.fs:SetWidth(0)
    local textW = it.fs:GetStringWidth() or 0
    it.textW = textW
    if it.hasIcon then
        return ICON_SIZE + (textW > 0 and ICON_GAP or 0) + textW
    end
    return textW
end

-- Places one item in a slot of exactly `slotW`, its content centred.
local function PlaceItem(it, x, slotW)
    local textW = it.textW or 0
    local iconW = it.hasIcon and (ICON_SIZE + (textW > 0 and ICON_GAP or 0)) or 0

    -- Text truncates to whatever the slot leaves it. Word wrap is off (set at
    -- construction), so a constrained FontString ellipsizes rather than growing
    -- a second line and overflowing the bar's height.
    local avail = slotW - SLOT_PAD * 2
    if iconW + textW > avail then
        textW = math.max(avail - iconW, 1)
        it.fs:SetWidth(textW)
    else
        it.fs:SetWidth(0)
    end

    it.button:ClearAllPoints()
    it.button:SetPoint("LEFT", itemHost, "LEFT", x, 0)
    it.button:SetWidth(math.max(slotW, 1))

    local startX = math.max((slotW - (iconW + textW)) / 2, 0)
    if it.hasIcon then
        it.icon:ClearAllPoints()
        it.icon:SetPoint("LEFT", it.button, "LEFT", startX, 0)
        it.fs:ClearAllPoints()
        it.fs:SetPoint("LEFT", it.icon, "RIGHT", textW > 0 and ICON_GAP or 0, 0)
    else
        it.fs:ClearAllPoints()
        it.fs:SetPoint("LEFT", it.button, "LEFT", startX, 0)
    end
    it.button:Show()
end

-- Lays the chosen widgets out in equal shares of the bar.
--
-- This is EllesmereUIDataBars' "even" sizing mode (its SolveLayout, sizingMode
-- == "even"), and copying it settled two things at once. Positions stopped
-- needing a per-widget setting -- with fixed shares, ORDER is the only spatial
-- choice left, which is what made a drag-to-reorder preview possible. And a
-- widget can no longer push its neighbours off the bar, which is what the
-- "Max widget width" cap existed to prevent; each one is bounded by its share.
--
-- Two details taken from EUI's solver rather than reinvented:
--   * Cumulative rounding. Each edge is computed from the START of the bar
--     (k * L / n) instead of adding a rounded width per widget, so the
--     fractional pixels telescope and the last slot lands exactly on the far
--     edge instead of a rounding error short of it.
--   * A widget measuring zero takes no share. A plugin that publishes nothing
--     right now would otherwise hold an empty column of bar open.
--
-- Only called when the SET of widgets or their WIDTHS change, never on a
-- plain text update that happens to be the same length -- see Refresh below.
local function Relayout()
    if not bar then return end

    local db = ModuleDB()
    bar:SetWidth(math.max(db.width or 500, 80))
    bar:SetHeight(BAR_H)

    local live = {}
    for _, name in ipairs(db.order) do
        local it = items[name]
        if it and MeasureItem(it) > 0 then live[#live + 1] = it end
    end

    local L = (bar:GetWidth() or 0) - EDGE_PAD * 2
    local n = #live
    local prevEdge = 0
    for k = 1, n do
        local edge = math.floor(k * L / n + 0.5)
        PlaceItem(live[k], EDGE_PAD + prevEdge, edge - prevEdge)
        prevEdge = edge
    end

    -- Anything not placed is hidden: widgets just switched off, and widgets
    -- that measured zero this pass.
    local placed = {}
    for _, it in ipairs(live) do placed[it] = true end
    for _, it in pairs(items) do
        if not placed[it] then it.button:Hide() end
    end
end

-- Pulls current text for every shown widget. Dirty-checked per item, and a
-- relayout only when a width actually moved -- the AbstractBar lesson, minus
-- its timer.
local function Refresh()
    dirty = false
    if not (bar and ldb) then return end

    local widthChanged = false
    for _, name in ipairs(ModuleDB().order) do
        local obj = ldb:GetDataObjectByName(name)
        local it = EnsureItem(name)
        if it then
            local text = ItemText(obj)
            if text ~= it.text then
                it.text = text
                local before = it.fs:GetStringWidth() or 0
                it.fs:SetText(text)
                if (it.fs:GetStringWidth() or 0) ~= before then widthChanged = true end
            end

            -- `icon` is a texture path or an atlas name; SetTexture rejects an
            -- atlas, so try the atlas form first and fall back. iconCoords and
            -- the iconR/G/B tint are part of the same LDB convention.
            local iconRef = ModuleDB().showIcons and obj and obj.icon or nil
            local had = it.hasIcon
            if iconRef then
                -- Tested with GetAtlasInfo rather than branching on SetAtlas's
                -- return, which is not documented to report failure.
                if AniMods.W.AtlasExists(iconRef) then
                    it.icon:SetAtlas(iconRef)
                else
                    it.icon:SetTexture(iconRef)
                end
                local c = obj.iconCoords
                if c then it.icon:SetTexCoord(c[1], c[2], c[3], c[4]) else it.icon:SetTexCoord(0, 1, 0, 1) end
                it.icon:SetVertexColor(obj.iconR or 1, obj.iconG or 1, obj.iconB or 1)
                it.icon:Show()
                it.hasIcon = true
            else
                it.icon:Hide()
                it.hasIcon = false
            end
            if it.hasIcon ~= had then widthChanged = true end
        end
    end

    if widthChanged then Relayout() end
end

-- Coalesced: a broker that updates several attributes in a row (text, then
-- icon, then value) would otherwise re-measure the whole bar once per
-- assignment. Same one-shot-per-burst helper the modules use.
local QueueRefresh

-- Declared before use: SetWidgetEnabled and SetOrder call it, and it is defined
-- below with the rest of the frame handling. Without this the call would
-- resolve to a global read and silently do nothing.
local ApplyVisibility

-- Applies the lock to the live frame. EnableMouse stays ON either way: the
-- widgets are buttons and must keep taking clicks. Only dragging is withdrawn.
local function ApplyLock()
    if not bar then return end
    local locked = IsLocked()
    bar:SetMovable(not locked)
    if locked then
        bar:RegisterForDrag()
    else
        bar:RegisterForDrag("LeftButton")
    end
end

-- Everything below goes through ApplyVisibility rather than calling
-- Refresh/Relayout directly: the bar may not have been built yet (it is off by
-- default, and widgets can be ticked before it is switched on), and EnsureItem
-- needs its host to exist or it produces an unparented button that is then
-- cached forever.

-- Appends when switched on, so a newly ticked widget lands at the end of the
-- bar where the eye is already looking for it, rather than somewhere in the
-- middle decided by an alphabetical rule.
local function SetWidgetEnabled(name, on)
    local order = ModuleDB().order
    for i, existing in ipairs(order) do
        if existing == name then
            if on then return end
            table.remove(order, i)
            RebuildEnabledLookup()
            ApplyVisibility()
            return
        end
    end
    if not on then return end
    order[#order + 1] = name
    RebuildEnabledLookup()
    ApplyVisibility()
end

-- Takes the order the preview strip arrived at. The strip owns the array while
-- a drag is in flight, so this stores what it hands back rather than trying to
-- reconcile two copies.
local function SetOrder(order)
    local db = ModuleDB()
    db.order = order
    RebuildEnabledLookup()
    ApplyVisibility()
end

-- ---------------------------------------------------------------------------
-- Bar frame
-- ---------------------------------------------------------------------------

local function BuildBar()
    if bar then return bar end

    bar = AniMods.W.Panel(UIParent)
    bar:SetHeight(BAR_H)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local db = ModuleDB()
        local point, _, relPoint, x, y = self:GetPoint()
        db.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    -- Widgets go on a child, never on `bar` itself: W.Panel hands the frame
    -- to S.Panel, and under the EllesmereUI provider that enrols it in a
    -- registry which alpha-zeroes direct texture regions (see Widgets.lua's
    -- header).
    itemHost = CreateFrame("Frame", nil, bar)
    itemHost:SetAllPoints()

    local db = ModuleDB()
    local p = db.pos
    if p then
        bar:SetPoint(p.point or "TOP", UIParent, p.relPoint or "TOP", p.x or 0, p.y or 0)
    else
        bar:SetPoint("TOP", UIParent, "TOP", 0, -4)
    end

    return bar
end

-- The module being active IS the bar being shown -- the tab's own switch owns
-- that decision, so a second "show the bar" setting inside the tab would be a
-- duplicate control for the same state, and the two could disagree.
ApplyVisibility = function()
    BuildBar()
    if not bar then return end
    ApplyLock()
    Refresh()
    Relayout()
    bar:Show()
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

-- Every registered LDB object, sorted. Rebuilt per call rather than cached:
-- plugins register on their own schedule, and this runs only while the
-- settings panel is open.
local function AllBrokerNames()
    local out = {}
    if not ldb then return out end
    for name in ldb:DataObjectIterator() do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- How one broker is named in the picker.
--
-- The registered NAME leads, and a self-declared label rides along in grey
-- ONLY when it differs -- EllesmereUIDataBars' rule (its ns.LDBLabel), and
-- worth copying exactly, because the version here got both halves wrong. It
-- led with the label and put the name beside it as a `note`, which is for a
-- qualifier about the row rather than a second name for the same thing; and it
-- printed both unconditionally, so every plugin whose label matches its name
-- -- BigWigs, Myslot -- rendered its own name twice in a row, once in white
-- and once in accent.
--
-- The name leads because the name is what identifies the object everywhere
-- else: it is the key this bar stores, and the string to look for in any other
-- data bar's widget list.
local function BrokerLabel(name, obj)
    local label = obj and obj.label
    if type(label) == "string" and label ~= "" and label ~= name then
        return name .. "  |cff808080" .. label .. "|r"
    end
    return name
end

-- Short form for the preview strip's cells, which are narrow and already
-- ordered: the friendly label when a plugin offers one, else its name.
local function BrokerShortLabel(name, obj)
    local label = obj and obj.label
    if type(label) == "string" and label ~= "" then return label end
    return name
end

-- Deliberately short. This is a bar for people who do not have a data bar, so
-- its settings are the ones without which it cannot be used at all: where it
-- sits, how wide it is, and what is on it. Everything else was removed rather
-- than kept "in case" -- a lightweight bar with a heavyweight options tab is
-- not lightweight.
--
-- What went, and why none of it is missed:
--   * Per-widget position. Equal division decides placement, so only ORDER is
--     left to choose, and the preview strip below is where that is done.
--   * Max widget width. Each widget is bounded by its share already.
--   * Strip plugin colors. It deleted meaning to solve a palette clash.
--   * Per-widget settings behind a gear. There is nothing left to put in one:
--     a widget is either on the bar or it is not.
function Bar:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Bar" }
    rows[#rows + 1] = {
        label = "Lock position",
        help  = "Stops the bar being dragged.",
        get   = IsLocked,
        set   = function(v)
            ModuleDB().locked = v and true or false
            ApplyLock()
        end,
    }
    rows[#rows + 1] = {
        label = "Bar width",
        min   = 200, max = 1400, step = 10,
        get   = function() return ModuleDB().width or 500 end,
        set   = function(v)
            ModuleDB().width = v
            Relayout()
        end,
    }
    rows[#rows + 1] = {
        label = "Show plugin icons",
        get   = function() return ModuleDB().showIcons ~= false end,
        set   = function(v)
            ModuleDB().showIcons = v and true or false
            dirty = true
            Refresh()
            Relayout()
        end,
    }

    -- Widgets: the preview first, the picker under it.
    --
    -- That order matches EllesmereUIDataBars' own config, and it is the right
    -- way round -- the strip is the thing being edited, and the picker is how
    -- rows get into it. It also puts the answer to "what is on my bar" at the
    -- top rather than at the end of a list of everything installed.
    local db = ModuleDB()
    local names = AllBrokerNames()

    local mine, others = {}, {}
    for _, name in ipairs(names) do
        local list = name:match("^AniMods") and mine or others
        list[#list + 1] = name
    end

    rows[#rows + 1] = { section = "Widgets" }

    if #names == 0 then
        rows[#rows + 1] = { label = "Plugins", value = "None registered" }
        return rows
    end

    local labels = {}
    for _, name in ipairs(db.order) do
        labels[name] = BrokerShortLabel(name, ldb and ldb:GetDataObjectByName(name))
    end

    rows[#rows + 1] = {
        strip  = db.order,
        labels = labels,
        -- Applied live, so the bar itself reorders under the cursor.
        onReorder = SetOrder,
        onDrop    = SetOrder,
    }

    -- One menu, two groups: AniMods' own widgets first because they are what
    -- this bar is for, then everyone else's under a caption. Grouping inside
    -- the menu is what removed the need for a separate expander -- the long
    -- list is already behind one click, and the panel's own height no longer
    -- depends on how many brokers happen to be installed.
    local picker = {}
    local function AddGroup(header, list)
        if #list == 0 then return end
        picker[#picker + 1] = { header = true, text = header }
        for _, name in ipairs(list) do
            picker[#picker + 1] = {
                key = name,
                text = BrokerLabel(name, ldb and ldb:GetDataObjectByName(name)),
            }
        end
    end
    AddGroup("AniMods", mine)
    AddGroup(("Other addons (%d)"):format(#others), others)

    local function Summary()
        return ("%d of %d"):format(#ModuleDB().order, #names)
    end

    rows[#rows + 1] = {
        label     = "Show widgets",
        help      = "Pick which data broker widgets appear on the bar. Drag the "
                 .. "preview above to reorder them.",
        picker    = picker,
        summary   = Summary(),
        summarize = Summary,
        isChecked = function(name) return enabled[name] == true end,
        onToggle  = SetWidgetEnabled,
    }

    return rows
end

function Bar:Enable()
    ldb = _G.LibStub and _G.LibStub:GetLibrary(LDB_NAME, true)
    if not ldb then return end

    QueueRefresh = AniMods.Coalesce(function()
        if dirty then Refresh() end
    end)

    -- ModuleDB() performs the alignment-map -> ordered-list migration on first
    -- touch, so this also settles what a pre-upgrade bar shows.
    RebuildEnabledLookup()

    -- The two disables below are for the WoW API annotations, not for a real
    -- problem: they declare RegisterCallback's third argument as a method-NAME
    -- string, but CallbackHandler-1.0 accepts a function just as happily --
    -- `if type(method) ~= "string" and type(method) ~= "function" then
    -- error(...)`. Suppressed at the two exact lines rather than by turning
    -- param-type-mismatch off, which would hide real argument errors
    -- everywhere else.

    -- The only thing this bar listens to. LDB fires one callback per changed
    -- attribute per object; the handler just marks dirty and lets the
    -- coalescer answer the whole burst on the next frame.
    -- Args are (eventName, sourceName, key, value, dataobj) -- CallbackHandler
    -- passes the event name first (Dispatch(handlers, eventname, ...)), which
    -- is why the first parameter is discarded.
    ---@diagnostic disable-next-line: param-type-mismatch
    ldb.RegisterCallback(self, "LibDataBroker_AttributeChanged", function(_, name, key)
        if not enabled[name] then return end
        if key and not WATCHED[key] then return end
        dirty = true
        QueueRefresh()
    end)

    -- A plugin registering after us (a LoadOnDemand addon, or one that waits
    -- for PLAYER_LOGIN as AniMods' own modules do) has to be able to appear.
    ---@diagnostic disable-next-line: param-type-mismatch
    ldb.RegisterCallback(self, "LibDataBroker_DataObjectCreated", function(_, name)
        if not enabled[name] then return end
        EnsureItem(name)
        dirty = true
        QueueRefresh()
    end)

    AniMods.W.OnReady(ApplyVisibility)
end

-- Toggles cleanly, so the panel applies the switch without offering a reload.
--
-- This module can, where most cannot, because everything it owns is its own:
-- one frame it created, and LDB callbacks that are cheap no-ops while the bar
-- is hidden (the handler returns immediately for any broker not in `enabled`).
-- It installs no hooks on anyone else's frames and registers no data
-- object of its own -- the two things that cannot be undone.
function Bar:SetEnabled(on)
    if on then
        ApplyVisibility()
    elseif bar then
        bar:Hide()
    end
end

AniMods.RegisterModule("Bar", Bar)
