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
    description = "A minimal bar for LibDataBroker widgets, for setups with no other data bar. Off by default.",
    dependencies = {
        { text = "None -- displays any LibDataBroker plugin" },
    },
}

local LDB_NAME = "LibDataBroker-1.1"

local BAR_H       = 22
local ITEM_GAP    = 14
local EDGE_PAD    = 10
local FONT_SIZE   = 12

local bar, itemHost
local items = {}          -- objName -> { button, fs, text }
local ldb
local shown = {}          -- objName -> true, the user's chosen widgets
local dirty = false

local function ModuleDB()
    AniModsDB.bar = AniModsDB.bar or {}
    local db = AniModsDB.bar
    if db.widgets == nil then db.widgets = {} end
    if db.enabled == nil then db.enabled = false end
    return db
end

-- Default OFF: a bar that appears uninvited on top of whatever the player
-- already runs is worse than no bar.
local function IsBarEnabled()
    return ModuleDB().enabled == true
end

local function IsWidgetShown(name)
    return ModuleDB().widgets[name] == true
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- LDB's `text` is display-ready and may carry inline escapes (|cff..|r for
-- colour, |A:atlas|a and |T..|t for icons) -- exactly what Broker.BuildText
-- produces. It goes into the FontString verbatim; nothing here parses it.
local function ItemText(obj)
    if not obj then return "" end
    local t = obj.text
    if t and t ~= "" then return t end
    -- Fall back to the object's own label, then its name, so a plugin that
    -- publishes only an icon and a label still occupies a legible slot.
    return obj.label or ""
end

local function EnsureItem(name)
    local it = items[name]
    if it then return it end

    local btn = CreateFrame("Button", nil, itemHost)
    btn:SetHeight(BAR_H)
    btn:RegisterForClicks("AnyUp")

    local fs = AniMods.W.Font(btn, FONT_SIZE, nil, 1)
    fs:SetPoint("LEFT")
    fs:SetJustifyH("LEFT")

    it = { button = btn, fs = fs, text = nil }
    items[name] = it

    -- Forward the standard LDB interaction contract to the plugin. OnEnter is
    -- preferred over OnTooltipShow when a plugin offers both -- the same
    -- precedence EllesmereUIDataBars uses, and what lets SocialStatus draw its
    -- own bordered popup instead of a plain GameTooltip.
    btn:SetScript("OnClick", function(self, button)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if obj and obj.OnClick then obj.OnClick(self, button) end
    end)
    btn:SetScript("OnEnter", function(self)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if not obj then return end
        if obj.OnEnter then
            obj.OnEnter(self)
        elseif obj.OnTooltipShow then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            obj.OnTooltipShow(GameTooltip)
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        local obj = ldb and ldb:GetDataObjectByName(name)
        if obj and obj.OnLeave then
            obj.OnLeave(self)
        else
            GameTooltip:Hide()
        end
    end)

    return it
end

-- Lays the chosen widgets left to right and sizes the bar to fit.
--
-- Only called when the SET of widgets or their WIDTHS change, never on a
-- plain text update that happens to be the same length -- see Refresh below.
local function Relayout()
    if not bar then return end

    local names = {}
    for name in pairs(shown) do names[#names + 1] = name end
    table.sort(names)   -- stable order across sessions; hash order is not

    local x = EDGE_PAD
    for _, name in ipairs(names) do
        local it = items[name]
        if it then
            local w = it.fs:GetStringWidth() or 0
            it.button:SetWidth(math.max(w, 1))
            it.button:ClearAllPoints()
            it.button:SetPoint("LEFT", itemHost, "LEFT", x, 0)
            it.button:Show()
            x = x + w + ITEM_GAP
        end
    end

    for name, it in pairs(items) do
        if not shown[name] then it.button:Hide() end
    end

    bar:SetWidth(math.max(x - ITEM_GAP + EDGE_PAD, 60))
    bar:SetHeight(BAR_H)
end

-- Pulls current text for every shown widget. Dirty-checked per item, and a
-- relayout only when a width actually moved -- the AbstractBar lesson, minus
-- its timer.
local function Refresh()
    dirty = false
    if not (bar and ldb) then return end

    local widthChanged = false
    for name in pairs(shown) do
        local obj = ldb:GetDataObjectByName(name)
        local it = EnsureItem(name)
        local text = ItemText(obj)
        if text ~= it.text then
            it.text = text
            local before = it.fs:GetStringWidth() or 0
            it.fs:SetText(text)
            if (it.fs:GetStringWidth() or 0) ~= before then widthChanged = true end
        end
    end

    if widthChanged then Relayout() end
end

-- Coalesced: a broker that updates several attributes in a row (text, then
-- icon, then value) would otherwise re-measure the whole bar once per
-- assignment. Same one-shot-per-burst helper the modules use.
local QueueRefresh

local function SetWidgetShown(name, on)
    ModuleDB().widgets[name] = on and true or false
    if on then
        shown[name] = true
        EnsureItem(name)
    else
        shown[name] = nil
    end
    Refresh()
    Relayout()
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

local function ApplyVisibility()
    if not IsBarEnabled() then
        if bar then bar:Hide() end
        return
    end
    BuildBar()
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

function Bar:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = { label = "LibDataBroker", value = ldb and "Available" or "Not available" }
    rows[#rows + 1] = {
        label = "Show the bar",
        note  = "off by default -- use a real data bar if you have one",
        get   = IsBarEnabled,
        set   = function(v)
            ModuleDB().enabled = v and true or false
            ApplyVisibility()
        end,
    }

    rows[#rows + 1] = { section = "Widgets" }
    local names = AllBrokerNames()
    if #names == 0 then
        rows[#rows + 1] = { label = "Plugins", value = "None registered" }
    else
        for _, name in ipairs(names) do
            local obj = ldb:GetDataObjectByName(name)
            rows[#rows + 1] = {
                label = (obj and obj.label) or name,
                note  = ((obj and obj.label) and name) or nil,
                get   = function() return IsWidgetShown(name) end,
                set   = function(v) SetWidgetShown(name, v) end,
            }
        end
    end

    return rows
end

function Bar:Enable()
    ldb = _G.LibStub and _G.LibStub:GetLibrary(LDB_NAME, true)
    if not ldb then return end

    QueueRefresh = AniMods.Coalesce(function()
        if dirty then Refresh() end
    end)

    for name, on in pairs(ModuleDB().widgets) do
        if on then shown[name] = true end
    end

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
    ---@diagnostic disable-next-line: param-type-mismatch
    ldb.RegisterCallback(self, "LibDataBroker_AttributeChanged", function(_, name)
        if not shown[name] then return end
        dirty = true
        QueueRefresh()
    end)

    -- A plugin registering after us (a LoadOnDemand addon, or one that waits
    -- for PLAYER_LOGIN as AniMods' own modules do) has to be able to appear.
    ---@diagnostic disable-next-line: param-type-mismatch
    ldb.RegisterCallback(self, "LibDataBroker_DataObjectCreated", function(_, name)
        if not shown[name] then return end
        EnsureItem(name)
        dirty = true
        QueueRefresh()
    end)

    AniMods.W.OnReady(ApplyVisibility)
end

AniMods.RegisterModule("Bar", Bar)
