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
    dependencies = {
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
local ITEM_GAP    = 14
local EDGE_PAD    = 10
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

-- Alignment sections, laid out independently: left anchors from the bar's
-- left edge, right from its right, centre is centred on the whole bar. This
-- is why the bar has an explicit width rather than hugging its content --
-- "right-aligned" is meaningless on a frame that shrinks to fit.
-- No "hidden" entry: whether a widget is on the bar is the checkbox's job
-- now, so this dropdown only answers where.
local SECTION_LABEL = { left = "Left", center = "Center", right = "Right" }
local SECTION_ORDER = { "left", "center", "right" }

local bar, itemHost
local items = {}          -- objName -> { button, fs, icon, text, hasIcon }
local ldb
local shown = {}          -- objName -> "left" | "center" | "right"
local dirty = false

local function ModuleDB()
    AniModsDB.bar = AniModsDB.bar or {}
    local db = AniModsDB.bar
    if db.widgets == nil then db.widgets = {} end
    -- Unlocked by default: a bar you just switched on has to be positionable
    -- without hunting for the setting that allows it. Lock it once it is
    -- where you want it.
    if db.locked == nil then db.locked = false end
    if db.showIcons == nil then db.showIcons = true end
    -- Off by default: AniMods' own brokers colour their text deliberately
    -- (role counts, guild vs friends), and stripping would throw that away.
    -- It exists for third-party plugins whose palette clashes with the bar.
    if db.stripColors == nil then db.stripColors = false end
    if db.maxWidth == nil then db.maxWidth = 0 end   -- 0 = unclamped
    if db.width == nil then db.width = 500 end
    return db
end

-- Widget placement. Stored per broker name as a section string; `false` or
-- absent means hidden.
--
-- Migration: this setting used to be a boolean. `true` becomes "left", which
-- reproduces the previous single-row layout exactly.
local function WidgetSection(name)
    local v = ModuleDB().widgets[name]
    if v == true then return "left" end
    if type(v) == "string" and SECTION_LABEL[v] and v ~= "hidden" then return v end
    return nil
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
-- Broker text arrives carrying the plugin's own colour codes, which override
-- anything the bar would apply. Stripping hands the colour back to the bar;
-- leaving them keeps the plugin's palette. Both escape forms are handled --
-- the literal |cAARRGGBB and the named |cnCOLOR_NAME: variant.
local function StripColors(str)
    if not str then return str end
    str = str:gsub("|c%x%x%x%x%x%x%x%x", "")
    str = str:gsub("|cn[%a%d_]+:", "")
    str = str:gsub("|r", "")
    return str
end

local function ItemText(obj)
    if not obj then return "" end
    local str
    local t = obj.text
    if type(t) == "string" and t ~= "" then
        str = t
    else
        local v = obj.value
        if v == nil then return "" end
        str = tostring(v)
        local suffix = obj.suffix
        if type(suffix) == "string" and suffix ~= "" then str = str .. " " .. suffix end
    end
    if ModuleDB().stripColors then str = StripColors(str) end
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

-- Measures one item and positions its icon/text within its own button.
-- Returns the width the slot occupies.
local function SizeItem(it)
    local textW = it.fs:GetStringWidth() or 0

    it.fs:ClearAllPoints()
    if it.hasIcon then
        it.fs:SetPoint("LEFT", it.icon, "RIGHT", textW > 0 and ICON_GAP or 0, 0)
    else
        it.fs:SetPoint("LEFT")
    end

    local w = textW
    if it.hasIcon then
        w = ICON_SIZE + (textW > 0 and ICON_GAP or 0) + textW
    end

    -- Max Width clamp. Broker text has no shape we can predict -- a plugin can
    -- decide to publish a whole sentence -- so this stops one widget pushing
    -- every other off the bar. The FontString is given the remaining width and
    -- has word wrap off, so it ellipsizes rather than wrapping into the row
    -- below.
    local maxW = ModuleDB().maxWidth or 0
    if maxW > 0 and w > maxW then
        w = maxW
        local avail = maxW - (it.hasIcon and (ICON_SIZE + ICON_GAP) or 0)
        it.fs:SetWidth(math.max(avail, 1))
    else
        it.fs:SetWidth(0)   -- 0 = size to content
    end

    it.button:SetWidth(math.max(w, 1))
    return w
end

-- Lays the chosen widgets into their three alignment sections.
--
-- Only called when the SET of widgets or their WIDTHS change, never on a
-- plain text update that happens to be the same length -- see Refresh below.
local function Relayout()
    if not bar then return end

    local db = ModuleDB()
    bar:SetWidth(math.max(db.width or 500, 80))
    bar:SetHeight(BAR_H)

    -- Bucket by section, each bucket sorted so order is stable across
    -- sessions -- pairs() order is not.
    local buckets = { left = {}, center = {}, right = {} }
    for name, section in pairs(shown) do
        local b = buckets[section]
        if b and items[name] then b[#b + 1] = name end
    end
    for _, b in pairs(buckets) do table.sort(b) end

    -- Total width of a bucket, including the gaps between its members.
    local function Measure(b)
        local total = 0
        for i, name in ipairs(b) do
            total = total + SizeItem(items[name])
            if i > 1 then total = total + ITEM_GAP end
        end
        return total
    end

    -- Every bucket must be measured, because Measure is also what sizes each
    -- button. The left section's own total is not needed for placement -- it
    -- starts at a fixed inset -- so it is not bound.
    Measure(buckets.left)
    local centerW = Measure(buckets.center)
    local rightW = Measure(buckets.right)

    local function Place(b, startX)
        local x = startX
        for _, name in ipairs(b) do
            local it = items[name]
            it.button:ClearAllPoints()
            it.button:SetPoint("LEFT", itemHost, "LEFT", x, 0)
            it.button:Show()
            x = x + (it.button:GetWidth() or 0) + ITEM_GAP
        end
    end

    local barW = bar:GetWidth() or 0
    Place(buckets.left, EDGE_PAD)
    Place(buckets.center, (barW - centerW) / 2)
    Place(buckets.right, barW - EDGE_PAD - rightW)

    -- Anything not currently placed is hidden, including items whose section
    -- was just cleared.
    for name, it in pairs(items) do
        if not shown[name] then it.button:Hide() end
    end
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

-- Declared before use: SetWidgetShown calls it, and it is defined below with
-- the rest of the frame handling. Without this the call would resolve to a
-- global read and silently do nothing.
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

local function SetWidgetSection(name, section)
    ModuleDB().widgets[name] = section or false
    shown[name] = section
    -- Goes through ApplyVisibility rather than calling Refresh/Relayout
    -- directly: the bar may not have been built yet (it is off by default, and
    -- widgets can be ticked before it is switched on), and EnsureItem needs
    -- its host to exist or it produces an unparented button that is then
    -- cached forever.
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

function Bar:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Appearance" }
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
    rows[#rows + 1] = {
        label = "Strip plugin colors",
        help  = "Ignore each plugin's own text color. AniMods' widgets use color "
             .. "to carry meaning, so this discards that too.",
        get   = function() return ModuleDB().stripColors == true end,
        set   = function(v)
            ModuleDB().stripColors = v and true or false
            -- Text is cached per item for the dirty check, so it has to be
            -- invalidated or the re-render is a no-op.
            for _, it in pairs(items) do it.text = nil end
            dirty = true
            Refresh()
            Relayout()
        end,
    }
    rows[#rows + 1] = {
        label = "Max widget width",
        note  = "0 = unlimited",
        help  = "Caps a single widget's width. Longer text is truncated.",
        min   = 0, max = 400, step = 10,
        get   = function() return ModuleDB().maxWidth or 0 end,
        set   = function(v)
            ModuleDB().maxWidth = v
            Relayout()
        end,
    }

    -- Widgets: AniMods' own first, then everyone else's behind a fold.
    --
    -- Ours are the ones you came here to arrange, and on a busy install they
    -- were buried alphabetically among a dozen third-party brokers. Splitting
    -- them also lets the long list start collapsed, which is what keeps this
    -- tab a readable length.
    local function WidgetRows(name, obj)
        local out = {}
        -- On/off is a checkbox rather than a four-way section dropdown: the
        -- question "is this on the bar" is a different one from "where", and
        -- answering both through one control meant Hidden was a position.
        out[#out + 1] = {
            label = (obj and obj.label) or name,
            note  = ((obj and obj.label) and name) or nil,
            get   = function() return WidgetSection(name) ~= nil end,
            set   = function(v) SetWidgetSection(name, v and "left" or nil) end,
        }
        -- Position follows the switch, and only while it is on -- an alignment
        -- for something not on the bar is noise.
        if WidgetSection(name) then
            out[#out + 1] = {
                label   = "Position",
                options = SECTION_LABEL,
                order   = SECTION_ORDER,
                get     = function() return WidgetSection(name) or "left" end,
                set     = function(v) SetWidgetSection(name, v) end,
            }
        end
        return out
    end

    local mine, others = {}, {}
    for _, name in ipairs(AllBrokerNames()) do
        local list = name:match("^AniMods") and mine or others
        list[#list + 1] = name
    end

    rows[#rows + 1] = { section = "Widgets" }
    if #mine == 0 and #others == 0 then
        rows[#rows + 1] = { label = "Plugins", value = "None registered" }
    end
    for _, name in ipairs(mine) do
        for _, r in ipairs(WidgetRows(name, ldb:GetDataObjectByName(name))) do
            rows[#rows + 1] = r
        end
    end

    if #others > 0 then
        rows[#rows + 1] = { section = ("Other addons (%d)"):format(#others) }
        rows[#rows + 1] = {
            label = "Show these widgets",
            get   = function() return ModuleDB().showOthers == true end,
            set   = function(v)
                ModuleDB().showOthers = v and true or false
                if AniMods.RefreshUI then AniMods.RefreshUI() end
            end,
        }
        if ModuleDB().showOthers then
            for _, name in ipairs(others) do
                for _, r in ipairs(WidgetRows(name, ldb:GetDataObjectByName(name))) do
                    rows[#rows + 1] = r
                end
            end
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

    -- WidgetSection also performs the boolean -> section migration, so a
    -- saved `true` from before alignment sections existed comes back as
    -- "left" and the bar looks exactly as it did.
    for name in pairs(ModuleDB().widgets) do
        shown[name] = WidgetSection(name)
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
    -- Args are (eventName, sourceName, key, value, dataobj) -- CallbackHandler
    -- passes the event name first (Dispatch(handlers, eventname, ...)), which
    -- is why the first parameter is discarded.
    ---@diagnostic disable-next-line: param-type-mismatch
    ldb.RegisterCallback(self, "LibDataBroker_AttributeChanged", function(_, name, key)
        if not shown[name] then return end
        if key and not WATCHED[key] then return end
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

-- Toggles cleanly, so the panel applies the switch without offering a reload.
--
-- This module can, where most cannot, because everything it owns is its own:
-- one frame it created, and LDB callbacks that are cheap no-ops while the bar
-- is hidden (the handler returns immediately once `shown` is empty of visible
-- work). It installs no hooks on anyone else's frames and registers no data
-- object of its own -- the two things that cannot be undone.
function Bar:SetEnabled(on)
    if on then
        ApplyVisibility()
    elseif bar then
        bar:Hide()
    end
end

AniMods.RegisterModule("Bar", Bar)
