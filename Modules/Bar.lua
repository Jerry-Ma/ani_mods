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
    dbKey = "bar",
    category = "At a Glance",
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
local GRIP_W      = 12   -- the unlocked-only drag handle, outside the left edge
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
local barFill, barEdges   -- the bar's own configurable background and border
local barGrip             -- drag handle, visible only while unlocked
local barOverlay          -- unlocked-state wash over the bar's whole extent
local overlayWash, overlayEdges
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
--
-- The list is a SET as well as a sequence -- a widget appears at most once --
-- and that is enforced here rather than trusted, because the migration that
-- built the first one got it wrong (see below) and there is now saved data in
-- the wild carrying duplicates.
-- In place, and returning the SAME table. Both matter.
--
-- Returning a fresh table (the first version) meant `db.order` was replaced on
-- every read, which quietly broke the preview strip: it holds a reference to
-- the live order array and mutates it as you drag, so a replacement mid-gesture
-- left it editing a table nobody read any more. It self-healed on the next drop
-- only because SetOrder assigns the strip's copy back.
local function DedupeOrderInPlace(order)
    local seen, write = {}, 0
    for read = 1, #order do
        local name = order[read]
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            write = write + 1
            order[write] = name
        end
    end
    for i = #order, write + 1, -1 do order[i] = nil end
    return order
end

-- Normalisation runs ONCE, not on every accessor call.
--
-- It used to run on each one -- and ModuleDB() is called from Relayout, from
-- Refresh's per-widget loop, from BarColor, ApplyAppearance, IsLocked and the
-- settings rows -- so a single bar repaint allocated a dozen throwaway tables
-- deduplicating a list that had not changed since the last time it was
-- deduplicated. Migration and defaults are one-time work; only the guard was
-- missing.
local prepared = false

local function ModuleDB()
    AniModsDB.bar = AniModsDB.bar or {}
    local db = AniModsDB.bar
    if prepared then return db end
    prepared = true

    -- Migration off the old per-widget alignment map. Sections are read in
    -- left/centre/right order and each sorted by name, which lands every widget
    -- in the position it was already displayed at -- so an existing bar looks
    -- the same after the upgrade, just reorderable.
    if db.widgets and not db.order then
        local order = {}
        for _, section in ipairs({ "left", "center", "right" }) do
            local group = {}
            for name, value in pairs(db.widgets) do
                -- The boolean `true` is the oldest form, from before alignment
                -- sections existed, and it means "on the bar" -- it is not a
                -- section. Matching it in every pass, as the first version of
                -- this did, appended such a widget three times, which is where
                -- the duplicated rows came from.
                local inSection = (value == section)
                    or (value == true and section == "left")
                if inSection then group[#group + 1] = name end
            end
            table.sort(group)
            for _, name in ipairs(group) do order[#order + 1] = name end
        end
        db.order = order
        db.widgets = nil
    end

    -- Unconditional, not just after the migration: it also repairs a list
    -- already saved with duplicates in it. Once is enough -- nothing after this
    -- point can introduce one (SetWidgetEnabled checks for the name first).
    db.order = db.order or {}
    DedupeOrderInPlace(db.order)

    -- Unlocked by default: a bar you just switched on has to be positionable
    -- without hunting for the setting that allows it. Lock it once it is
    -- where you want it.
    if db.locked == nil then db.locked = false end
    if db.width == nil then db.width = 500 end
    if db.border == nil then db.border = true end

    -- Dropped settings, cleared rather than left to rot in the saved variables.
    -- `stripColors` discarded the meaning AniMods' own brokers put in their
    -- colours; `maxWidth` capped a widget's width, which equal division now
    -- does by construction; `showIcons` hid art the plugin chose to publish,
    -- for no gain -- an icon is the most compact thing on the bar and several
    -- brokers publish nothing else.
    db.stripColors = nil
    db.maxWidth = nil
    db.showOthers = nil
    db.showIcons = nil

    return db
end

-- ---------------------------------------------------------------------------
-- Appearance
-- ---------------------------------------------------------------------------

-- The bar's fill colour: the user's choice, else the theme's panel colour.
--
-- `nil` means "follow the theme" rather than being resolved to a concrete
-- colour at first run, so a bar left alone keeps tracking the theme instead of
-- freezing whatever it happened to be the first time it was drawn. Right-click
-- on the swatch returns to it.
local function BarColor()
    local c = ModuleDB().color
    if c then return c.r, c.g, c.b, c.a end
    local S = AniMods.W.S
    if S then return S.GetPanelColor() end
    return 0.05, 0.07, 0.09, 0.94
end

-- Bar textures come from LibSharedMedia when some addon has registered it.
-- Not a dependency and not shipped: LSM is a registry, so this offers whatever
-- the user's other addons have already contributed and simply has nothing to
-- offer when nothing has. "None" is always present and is a flat fill.
local function SharedMedia()
    return _G.LibStub and _G.LibStub:GetLibrary("LibSharedMedia-3.0", true)
end

local function TexturePath(key)
    if not key or key == "none" then return nil end
    local lsm = SharedMedia()
    if not lsm then return nil end
    -- noDefault: a key that is no longer registered (its addon was removed)
    -- must come back nil so the bar falls to a flat fill, rather than silently
    -- becoming LibSharedMedia's default texture.
    --
    -- The disable is for the WoW API annotations, not a real problem: they
    -- declare Fetch with two parameters, but the library's own source is
    -- `function lib:Fetch(mediatype, key, noDefault)` -- verified in
    -- LibSharedMedia-3.0.lua:250. Suppressed at this exact line rather than by
    -- turning the check off.
    ---@diagnostic disable-next-line: redundant-parameter
    return lsm:Fetch("statusbar", key, true)
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
            local iconRef = obj and obj.icon or nil
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

-- Paints the bar's background and border from the current settings.
--
-- ONE texture carries both the flat colour and the picked texture, tinted by
-- that same colour -- EllesmereUIDataBars' own arrangement (its
-- ApplyThemeToHost, where a barTexture is drawn with SetVertexColor from the
-- style's colour), and the reason the colour keeps working when a texture is
-- chosen instead of being replaced by it.
--
-- The vertex colour has to be reset before SetColorTexture: it is a multiplier
-- that survives the texture being swapped, so a flat fill picked after a
-- texture would otherwise come out multiplied by the old tint.
local function ApplyAppearance()
    if not (bar and barFill) then return end
    local db = ModuleDB()
    local r, g, b, a = BarColor()

    local path = TexturePath(db.texture)
    if path then
        barFill:SetTexture(path)
        barFill:SetVertexColor(r, g, b, a)
    else
        barFill:SetVertexColor(1, 1, 1, 1)
        barFill:SetColorTexture(r, g, b, a)
    end

    -- Black at 0.8, matching EllesmereUIDataBars' own bar border, so a bar
    -- sitting next to one of theirs does not read as a different kind of
    -- object.
    for _, edge in ipairs(barEdges) do
        edge:SetColorTexture(0, 0, 0, 0.8)
        edge:SetShown(db.border ~= false)
    end

    -- The unlocked overlay is accent-coloured, and painted here rather than
    -- registered for accent updates: this function is already the module's
    -- OnLooksChanged handler, so it follows a theme change for free.
    --
    -- The wash is deliberately faint. It has to read as "this region is in
    -- play" without competing with the widget text it sits over, so the OUTLINE
    -- does the work of showing the bounds and the wash only tints them.
    if overlayWash then
        local ar, ag, ab = AniMods.W.Accent()
        overlayWash:SetColorTexture(ar, ag, ab, 0.10)
        for _, edge in ipairs(overlayEdges) do
            edge:SetColorTexture(ar, ag, ab, 0.85)
        end
    end
end

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
    -- The handle and the overlay are the "unlocked" indicator between them:
    -- their presence is what tells you the bar can be moved, so there is no
    -- separate state to display. Shown and hidden together, always.
    if barGrip then barGrip:SetShown(not locked) end
    if barOverlay then barOverlay:SetShown(not locked) end
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

    -- A plain frame, NOT W.Panel.
    --
    -- The house panel paints its own fill and border and owns both, which is
    -- right for the settings window and wrong here: this bar's background is a
    -- setting. Skipping S.Panel also keeps the frame out of the restrip
    -- registry, so its textures can live directly on it -- the one place in
    -- this addon where that is true, and why it is worth saying out loud.
    bar = CreateFrame("Frame", nil, UIParent)
    bar:SetHeight(BAR_H)

    barFill = bar:CreateTexture(nil, "BACKGROUND")
    barFill:SetAllPoints()

    -- 1px border, drawn as four strips for the same reason Compat.lua does:
    -- a backdrop's edgeFile blurs at fractional UI scales.
    barEdges = {}
    for i = 1, 4 do barEdges[i] = bar:CreateTexture(nil, "OVERLAY") end
    barEdges[1]:SetPoint("TOPLEFT");    barEdges[1]:SetPoint("TOPRIGHT");    barEdges[1]:SetHeight(1)
    barEdges[2]:SetPoint("BOTTOMLEFT"); barEdges[2]:SetPoint("BOTTOMRIGHT"); barEdges[2]:SetHeight(1)
    barEdges[3]:SetPoint("TOPLEFT");    barEdges[3]:SetPoint("BOTTOMLEFT");  barEdges[3]:SetWidth(1)
    barEdges[4]:SetPoint("TOPRIGHT");   barEdges[4]:SetPoint("BOTTOMRIGHT"); barEdges[4]:SetWidth(1)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:EnableMouse(true)
    bar:SetMovable(true)
    bar:RegisterForDrag("LeftButton")
    local function StopAndSave()
        bar:StopMovingOrSizing()
        local db = ModuleDB()
        local point, _, relPoint, x, y = bar:GetPoint()
        db.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end

    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", StopAndSave)

    -- Unlocked-state overlay: an accent wash and outline over the bar's whole
    -- extent, paired with the handle below.
    --
    -- The handle says WHERE TO GRAB; this says WHAT MOVES. That second question
    -- is a real one here and not padding, because the bar has a fixed width and
    -- does not hug its contents -- with three widgets on a 500px bar, most of
    -- what you are about to drag is empty and invisible, so the handle alone
    -- gives no sense of the thing's actual bounds. Blizzard's Edit Mode makes
    -- the same pairing for the same reason.
    --
    -- A frame ABOVE itemHost rather than textures on the bar: child frames draw
    -- over their parent's regions whatever the draw layer, so an outline on
    -- `bar` would sit under the widgets and its edges would be clipped by them.
    -- EnableMouse(false) so it is purely visual -- the widgets underneath keep
    -- taking their clicks, and the bar keeps taking the drag.
    barOverlay = CreateFrame("Frame", nil, bar)
    barOverlay:SetAllPoints()
    barOverlay:SetFrameLevel(bar:GetFrameLevel() + 10)
    barOverlay:EnableMouse(false)
    barOverlay:Hide()

    overlayWash = barOverlay:CreateTexture(nil, "BACKGROUND")
    overlayWash:SetAllPoints()

    overlayEdges = {}
    for i = 1, 4 do overlayEdges[i] = barOverlay:CreateTexture(nil, "OVERLAY") end
    overlayEdges[1]:SetPoint("TOPLEFT");    overlayEdges[1]:SetPoint("TOPRIGHT");    overlayEdges[1]:SetHeight(1)
    overlayEdges[2]:SetPoint("BOTTOMLEFT"); overlayEdges[2]:SetPoint("BOTTOMRIGHT"); overlayEdges[2]:SetHeight(1)
    overlayEdges[3]:SetPoint("TOPLEFT");    overlayEdges[3]:SetPoint("BOTTOMLEFT");  overlayEdges[3]:SetWidth(1)
    overlayEdges[4]:SetPoint("TOPRIGHT");   overlayEdges[4]:SetPoint("BOTTOMRIGHT"); overlayEdges[4]:SetWidth(1)

    -- Drag handle, shown only while the bar is unlocked.
    --
    -- Two problems, one control. An unlocked bar looked exactly like a locked
    -- one, so there was nothing to say it could be moved; and the widgets on it
    -- are buttons that swallow the press, so on a full bar there was often
    -- nowhere left to grab.
    --
    -- OUTSIDE the left edge, not inset into the bar. The widgets divide the
    -- bar's whole width between them, so anything placed inside would either
    -- overlap a widget or have to be subtracted from the layout -- which would
    -- make the bar's contents shift every time it was locked or unlocked.
    barGrip = CreateFrame("Frame", nil, bar)
    barGrip:SetSize(GRIP_W, BAR_H)
    barGrip:SetPoint("RIGHT", bar, "LEFT", -2, 0)
    barGrip:EnableMouse(true)
    barGrip:RegisterForDrag("LeftButton")
    barGrip:SetScript("OnDragStart", function() bar:StartMoving() end)
    barGrip:SetScript("OnDragStop", StopAndSave)

    -- The handle carries its OWN dark plate rather than floating loose.
    --
    -- The first version was three 1px accent rules on a transparent frame, and
    -- it was nearly invisible: it sits outside the bar, so its backdrop is
    -- whatever the game world happens to be behind it -- grass, snow, a fire --
    -- and thin lines have nothing to hold contrast against. A dark plate gives
    -- the marks a constant background, which is the same reason the bar itself
    -- has a fill instead of drawing its text straight onto the world.
    local gripBg = barGrip:CreateTexture(nil, "BACKGROUND")
    gripBg:SetAllPoints()
    gripBg:SetColorTexture(0, 0, 0, 0.75)

    local gripEdges = {}
    for i = 1, 4 do gripEdges[i] = barGrip:CreateTexture(nil, "BORDER") end
    gripEdges[1]:SetPoint("TOPLEFT");    gripEdges[1]:SetPoint("TOPRIGHT");    gripEdges[1]:SetHeight(1)
    gripEdges[2]:SetPoint("BOTTOMLEFT"); gripEdges[2]:SetPoint("BOTTOMRIGHT"); gripEdges[2]:SetHeight(1)
    gripEdges[3]:SetPoint("TOPLEFT");    gripEdges[3]:SetPoint("BOTTOMLEFT");  gripEdges[3]:SetWidth(1)
    gripEdges[4]:SetPoint("TOPRIGHT");   gripEdges[4]:SetPoint("BOTTOMRIGHT"); gripEdges[4]:SetWidth(1)
    for i = 1, 4 do gripEdges[i]:SetColorTexture(1, 1, 1, 0.18) end

    -- Three short rules, accent-coloured: the conventional "grab here" mark.
    -- 2px tall and full strength now -- at 1px and 0.8 alpha they read as
    -- artefacts rather than as a control.
    --
    -- Painted here AND registered: RegisterAccent only repaints on a theme
    -- change, so a texture never given a colour of its own starts out invisible
    -- and stays that way until the user happens to retheme.
    local gr, gg, gb = AniMods.W.Accent()
    for i = 1, 3 do
        local line = barGrip:CreateTexture(nil, "OVERLAY")
        line:SetSize(GRIP_W - 4, 2)
        line:SetPoint("CENTER", barGrip, "CENTER", 0, (2 - i) * 5)
        line:SetColorTexture(gr, gg, gb, 1)
        AniMods.W.RegisterAccent(line, "vertex", 1)
    end

    barGrip:SetScript("OnEnter", function(self)
        gripBg:SetColorTexture(0, 0, 0, 0.9)
        for i = 1, 4 do gripEdges[i]:SetColorTexture(1, 1, 1, 0.35) end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Drag to move the bar", 1, 1, 1, 1, true)
        GameTooltip:AddLine("Lock it in the AniMods panel to hide this handle",
            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    barGrip:SetScript("OnLeave", function()
        gripBg:SetColorTexture(0, 0, 0, 0.75)
        for i = 1, 4 do gripEdges[i]:SetColorTexture(1, 1, 1, 0.18) end
        GameTooltip:Hide()
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
    ApplyAppearance()
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

-- What a preview cell shows: the widget's CURRENT OUTPUT -- the same string the
-- bar itself renders.
--
-- The cells used to carry the broker's name, which was wrong twice over. The
-- names are long and the cells are narrow (they are equal shares of a strip),
-- so most of them truncated to nothing useful; and a preview that shows
-- something other than what the thing previews is not one. Live text also
-- makes the cell width honest -- it is what that widget will actually occupy.
--
-- A broker publishing only an icon, or nothing yet, has no text to show, so
-- the cell falls back to naming it. Otherwise the cell would be blank and the
-- widget would look broken rather than quiet.
local function BrokerPreviewText(name, obj)
    local text = ItemText(obj)
    if text ~= "" then return text end
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
-- The texture list, rebuilt at each panel refresh rather than cached: an addon
-- registering with LibSharedMedia later in the session should simply appear.
local function TextureChoices()
    local labels, order = { none = "None" }, { "none" }
    local lsm = SharedMedia()
    if not lsm then return labels, order end
    for _, key in ipairs(lsm:List("statusbar") or {}) do
        labels[key] = key
        order[#order + 1] = key
    end
    return labels, order
end

function Bar:GetInfoRows()
    local rows = {}
    local textureLabels, textureOrder = TextureChoices()

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
        label = "Bar color",
        color = true,
        help  = "The bar's fill, transparency included. Right-click the swatch "
             .. "to go back to following your UI theme.",
        get   = BarColor,
        set   = function(r, g, b, a)
            ModuleDB().color = { r = r, g = g, b = b, a = a }
            ApplyAppearance()
        end,
        reset = function()
            ModuleDB().color = nil
            ApplyAppearance()
        end,
    }
    rows[#rows + 1] = {
        label   = "Bar texture",
        help    = "Textures come from LibSharedMedia, so this lists whatever "
               .. "your other addons have registered.",
        options = textureLabels,
        order   = textureOrder,
        get     = function() return ModuleDB().texture or "none" end,
        set     = function(v)
            ModuleDB().texture = (v ~= "none") and v or nil
            ApplyAppearance()
        end,
    }
    rows[#rows + 1] = {
        label = "Show border",
        get   = function() return ModuleDB().border ~= false end,
        set   = function(v)
            ModuleDB().border = v and true or false
            ApplyAppearance()
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
        rows[#rows + 1] = {
            label = "Widgets available",
            state = false,
            help  = "Nothing has registered a LibDataBroker widget yet. AniMods' "
                 .. "own appear once their modules are active.",
        }
        return rows
    end

    -- Cells show live output; the tooltip carries the identity, which is what
    -- the cell no longer has room for.
    local labels, tips = {}, {}
    for _, name in ipairs(db.order) do
        local obj = ldb and ldb:GetDataObjectByName(name)
        labels[name] = BrokerPreviewText(name, obj)
        tips[name] = BrokerLabel(name, obj)
    end

    rows[#rows + 1] = {
        strip  = db.order,
        labels = labels,
        tips   = tips,
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

    -- "Follow the theme" has to keep following. With no colour of its own the
    -- bar paints from S.GetPanelColor(), which changes when the user retunes
    -- their theme -- without this it would only track it across a reload,
    -- which is not what following means. Cheap and correct when a colour IS
    -- set, too: ApplyAppearance simply repaints the same colour.
    AniMods.W.OnLooksChanged(ApplyAppearance)

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
