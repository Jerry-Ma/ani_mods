-- AniMods widget toolkit, drawn through the skin facade S.
--
-- ── One interface, one code path ─────────────────────────────────────────────
--
-- This file used to hand-draw everything and reach into EllesmereUI internals
-- (MakeBorder, PanelPP, RegAccent, DisablePixelSnap, MakeDropdownArrow,
-- GetFontPath, EXPRESSWAY) with a literal-colour fallback branch behind each
-- one -- eight undocumented couplings and two renderings per widget to keep
-- looking alike. One of them, RegAccent, crashed on login because its shape
-- was guessed wrong.
--
-- All of that is replaced by ONE contract. S is the facade EllesmereUI
-- publishes to third-party addons over its window-skin engine: the public
-- surface (never raw WSkin), late-bound pass-throughs so engine internals
-- stay free to change, additive-only signatures versioned by S.apiVersion,
-- and pcall isolation at the boundary in both directions.
--
-- NOTHING BELOW ASKS WHICH PROVIDER ANSWERED. Compat.lua picks one at load --
-- EllesmereUI's when it is there, an AniMods-owned implementation of the same
-- interface when it is not -- and every constructor here simply calls S.
-- There is no `if EllesmereUI then` in this file, which is the difference
-- that matters: the second rendering exists (it has to, for a stock Blizzard
-- UI) but it lives behind a single boundary in one file rather than as a
-- branch inside every widget.
--
-- Consequence worth stating: AniMods has NO hard dependency on EllesmereUI.
-- The panel, the brokers and the modules all work on a stock UI.
--
-- ── The one rule that is not obvious ─────────────────────────────────────────
--
-- S.Panel and S.Shell enrol their frame in the engine's RESTRIP REGISTRY.
-- WSkin.Restrip() is a global sweep -- called from ~20 places whenever a
-- Blizzard window repaints (Collections, Spellbook, Guild, Calendar, Loot,
-- Item Upgrade, ...) -- and it alpha-zeroes every direct texture region on
-- every registered frame except the engine's own protected keys.
--
-- So: NEVER add our own texture directly to a frame passed to S.Panel or
-- S.Shell. It will silently vanish the first time the player opens their
-- collections. Put our art on a CHILD frame instead. Every constructor below
-- follows that rule, and it is why W.Window hands back `content` rather than
-- letting callers draw on the window itself.

local AniMods = _G.AniMods

local W = {}
AniMods.W = W

-- ── Design tokens ───────────────────────────────────────────────────────────
-- Alphas and metrics only. Every COLOR now comes from the theme via S, so a
-- palette copied out of EllesmereUI's source no longer exists here to drift
-- out of date. These are AniMods' own proportions, not EllesmereUI's values.

W.TEXT_A         = 1.00
W.TEXT_DIM_A     = 0.53
W.TEXT_SECTION_A = 0.41
W.ROW_BG_ODD     = 0.10   -- black overlay alpha, odd rows
W.ROW_BG_EVEN    = 0.20

W.DD_TXT_A       = 0.50
W.DD_TXT_HA      = 0.60
W.DD_ITEM_HL_A   = 0.08   -- menu item hover
W.DD_ITEM_SEL_A  = 0.04   -- menu item current selection
W.BTN_TXT_A      = 0.55
W.BTN_TXT_HA     = 0.70
W.SL_TRACK_A     = 0.16
W.SL_FILL_A      = 0.75

-- ── The facade ──────────────────────────────────────────────────────────────

local S                 -- set once, when EllesmereUI dispatches at PLAYER_LOGIN
local readyQueue = {}   -- fns waiting on that dispatch
local warned = false

-- Anything needing S must go through here. It runs `fn` immediately when the
-- facade has already arrived, and otherwise queues it -- which is also the
-- fix for a load-order problem this addon used to paper over with retry
-- timers: EllesmereUI fires the callback after its own boot, so "the skin
-- engine is ready" and "EllesmereUI's frames exist" are the same moment.
function W.OnReady(fn)
    if S then return fn(S) end
    readyQueue[#readyQueue + 1] = fn
end

function W.IsReady()
    return S ~= nil
end

-- Live-recolor registry for accent-colored things WE drew. EllesmereUI's own
-- primitives track the accent themselves; anything we colour by hand has to
-- be re-applied, which is what S.OnLooksChanged is for. Weak keys so a
-- released widget does not pin its frame.
local accentTex = setmetatable({}, { __mode = "k" })   -- texture    -> alpha
local accentText = setmetatable({}, { __mode = "k" })  -- fontstring -> alpha
local looksFns = {}

-- For widgets whose repaint is not a flat recolour of one region -- the
-- toggle's track depends on the accent AND its on/off state, so it has to
-- re-run its own paint function rather than be assigned a colour.
function W.OnLooksChanged(fn)
    if type(fn) == "function" then looksFns[#looksFns + 1] = fn end
end

-- Repaints everything registered for accent changes.
--
-- Public, because two different things have to be able to trigger it and only
-- one of them is the provider: the host theme changing (EllesmereUI calls
-- this through S.OnLooksChanged) and AniMods' own accent setting changing.
-- The second used to call AniMods.RefreshStockLooks, which walks the STOCK
-- provider's callback list -- empty whenever EllesmereUI is the provider, so
-- picking a swatch saved the colour and repainted nothing.
--
-- Reads W.Accent, not S.GetAccentColor. The provider's accent is only the
-- default; using it here would have repainted in the host's colour and
-- discarded the user's choice even once the repaint did fire.
function W.RefreshLooks()
    if not S then return end
    local r, g, b = W.Accent()
    for tex, a in pairs(accentTex) do tex:SetColorTexture(r, g, b, a) end
    for fs, a in pairs(accentText) do fs:SetTextColor(r, g, b, a) end
    for i = 1, #looksFns do
        local ok, err = pcall(looksFns[i])
        if not ok then geterrorhandler()(err) end
    end
end

-- Which facade answered is not this file's business: Compat.lua picks the
-- provider once, at load, and nothing below ever asks whether EllesmereUI is
-- present. That absence of a provider test is the whole point -- it is what
-- keeps one rendering path instead of two.
AniMods.AcquireSkin(function(facade)
    S = facade
    W.S = facade
    S.OnLooksChanged(W.RefreshLooks)
    for i = 1, #readyQueue do
        -- Isolated per entry: one module's bad layout must not stop the
        -- rest of the addon from coming up.
        local ok, err = pcall(readyQueue[i])
        if not ok then geterrorhandler()(err) end
    end
    readyQueue = {}
end)

-- Every constructor asserts through this. Reaching it means a widget was
-- built before PLAYER_LOGIN, which is a sequencing bug in the caller -- it
-- should have gone through W.OnReady -- so the message says that rather than
-- blaming the environment.
local function Need()
    if S then return S end
    if not warned then
        warned = true
        print("|cffff4444AniMods:|r a widget was built before the skin provider "
            .. "was ready. Wrap the construction in |cffffd700AniMods.W.OnReady|r.")
    end
    return nil
end

-- ── Theme reads ─────────────────────────────────────────────────────────────

-- The accent AniMods draws with.
--
-- An explicit AniMods setting wins; otherwise the provider's answer, which is
-- EllesmereUI's live theme accent when EllesmereUI is there.
--
-- The override exists because "follow the host" is the right DEFAULT but the
-- wrong rule: EllesmereUI's accent can be pale, and a pale accent leaves this
-- panel's title, headings and switches near-white. Following the theme by
-- default and allowing a local override costs one saved colour and removes
-- the whole class of "AniMods is unreadable in my theme".
function W.Accent()
    local g = AniModsDB and AniModsDB.general
    local a = g and g.accent
    if a and a.r then return a.r, a.g, a.b end

    local s = Need()
    if not s then
        local d = AniMods.ACCENT_DEFAULT
        return d.r, d.g, d.b
    end
    return s.GetAccentColor()
end

-- The house panel fill, for the rare element that has to blend into a card
-- rather than sit on it.
function W.PanelColor()
    local s = S
    if not s then return 0.05, 0.07, 0.09 end
    return s.GetPanelColor()
end

-- The provider's own accent, ignoring any AniMods override -- what the
-- "follow the theme" swatch shows, so that choice previews itself.
function W.ProviderAccent()
    local s = S
    if not s then
        local d = AniMods.ACCENT_DEFAULT
        return d.r, d.g, d.b
    end
    return s.GetAccentColor()
end

-- Registers a region for live accent recolouring, so the panel follows a
-- theme change without a reload. `kind` is "vertex" for a Texture, "text" for
-- a FontString.
function W.RegisterAccent(region, kind, alpha)
    if kind == "text" then
        accentText[region] = alpha or 1
    else
        accentTex[region] = alpha or 1
    end
end

-- The user's configured UI font. Returns path only; W.Font applies the flag.
function W.FontPath()
    local s = Need()
    if not s then return "Fonts\\FRIZQT__.TTF" end
    local path = s.GetFont()
    return path
end

function W.Font(parent, size, flags, alpha)
    local s = Need()
    local fs = parent:CreateFontString(nil, "OVERLAY")
    local path, themeFlag = "Fonts\\FRIZQT__.TTF", ""
    if s then path, themeFlag = s.GetFont() end
    fs:SetFont(path, size or 12, flags or themeFlag or "")
    fs:SetTextColor(1, 1, 1, alpha or W.TEXT_A)
    return fs
end

-- ── Icon resolution ─────────────────────────────────────────────────────────
-- Independent of the skin API: pure client queries, usable before S arrives.
-- Atlas names get renamed and removed between patches, and a missing one
-- draws nothing at all with no error -- which is exactly how the guild icon
-- silently went blank. Anything picking an atlas checks it first rather than
-- trusting a name that merely appears in some list.

function W.AtlasExists(atlas)
    if not atlas then return false end
    if not (C_Texture and C_Texture.GetAtlasInfo) then return false end
    return C_Texture.GetAtlasInfo(atlas) and true or false
end

-- Picks the first usable icon from an ordered candidate list. Candidates are
--   { atlas = "some-atlas" }                        -- used if it exists here
--   { texture = "Interface\\...", addon = "Name" }  -- used if that addon is loaded
-- The addon-scoped texture form REFERENCES a file already on disk rather
-- than bundling a copy, so it carries no redistribution question -- it just
-- has to degrade gracefully when that addon isn't there, which is what the
-- rest of the list is for. Returns { atlas = ... } or { texture = ... }, or
-- nil if nothing is usable.
function W.ResolveIcon(candidates)
    for _, candidate in ipairs(candidates or {}) do
        if candidate.atlas then
            if W.AtlasExists(candidate.atlas) then return { atlas = candidate.atlas } end
        elseif candidate.texture then
            if (not candidate.addon) or AniMods.IsAddOnLoaded(candidate.addon) then
                return { texture = candidate.texture }
            end
        end
    end
    return nil
end

-- ── Surfaces ────────────────────────────────────────────────────────────────

-- A plain solid texture. Only ever used on frames we did NOT hand to S (see
-- the restrip rule at the top of this file).
function W.Tex(parent, layer, r, g, b, a)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetColorTexture(r, g, b, a or 1)
    return tex
end

-- A themed panel: house fill plus the house 1px border, painted by the
-- engine. `opts` is passed through to S.Panel -- {inset = true} for the
-- darker nested fill, {shade = true} for a translucent black wash,
-- {noBorder = true} to skip the border.
--
-- The returned frame is in the restrip registry, so callers must not draw
-- textures on it directly; add child frames instead.
function W.Panel(parent, opts)
    local s = Need()
    local f = CreateFrame("Frame", nil, parent)
    if s then s.Panel(f, opts) end
    return f
end

-- ── Vertical stacking ───────────────────────────────────────────────────────
-- Deliberately not a layout engine: every container here stacks its children
-- top-to-bottom in add order, which is all this panel needs. A running
-- cursor beats a generic solver for something inspectable without a client
-- to test against.

function W.ResetStack(container, topPad)
    container._cursor = topPad or 0
end

-- Places `child` full-width at the current cursor and advances it. `indent`
-- insets BOTH edges, so a stacked block sits symmetrically inside its
-- container. Returns the child so callers can chain.
function W.Stack(container, child, height, gap, indent)
    indent = indent or 0
    child:ClearAllPoints()
    child:SetPoint("TOPLEFT", container, "TOPLEFT", indent, -(container._cursor or 0))
    child:SetPoint("TOPRIGHT", container, "TOPRIGHT", -indent, -(container._cursor or 0))
    if height then child:SetHeight(height) end
    container._cursor = (container._cursor or 0) + (height or child:GetHeight() or 0) + (gap or 0)
    container:SetHeight(container._cursor)
    return child
end

-- ── Text rows ───────────────────────────────────────────────────────────────

-- A wrapped paragraph. The FontString is anchored TOPLEFT only and given an
-- explicit width, because GetStringHeight() is only meaningful once the
-- string knows the width it has to wrap within -- anchoring it left AND
-- right instead would leave the height measured against an unresolved width
-- (zero, on a panel that hasn't been shown yet), collapsing every paragraph
-- to one line. Callers set the width via Resize() at layout time.
function W.Text(parent, size, alpha)
    local f = CreateFrame("Frame", nil, parent)
    local fs = W.Font(f, size or 12, nil, alpha or W.TEXT_DIM_A)
    fs:SetPoint("TOPLEFT")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")

    local o = { frame = f, fs = fs, _width = 0 }

    local function Measure()
        f:SetHeight(math.max(fs:GetStringHeight() or 14, 14))
    end

    function o:SetText(text)
        fs:SetText(text or "")
        Measure()
    end
    function o:Resize(width)
        if not width or width <= 0 or width == o._width then return end
        o._width = width
        fs:SetWidth(width)
        Measure()
    end

    return o
end

-- Label on the left, value right-aligned -- the two-column readout used for
-- every live status row. Reads far cleaner than "Label: value" run together.
function W.ValueRow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(18)

    local label = W.Font(f, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("LEFT", f, "LEFT", 8, 0)
    label:SetJustifyH("LEFT")

    local value = W.Font(f, 12, nil, W.TEXT_A)
    value:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    value:SetJustifyH("RIGHT")

    local o = { frame = f, labelFS = label, valueFS = value }
    function o:Set(labelText, valueText)
        label:SetText(labelText or "")
        value:SetText(valueText or "")
    end
    -- Alternating stripe, matching EllesmereUI's option rows. Safe as a
    -- direct texture: this frame is ours and never went through S.
    function o:Stripe(index)
        if not f._stripe then
            f._stripe = W.Tex(f, "BACKGROUND", 0, 0, 0, 0)
            f._stripe:SetAllPoints()
        end
        f._stripe:SetColorTexture(0, 0, 0, (index % 2 == 0) and W.ROW_BG_EVEN or W.ROW_BG_ODD)
    end
    return o
end

-- Section divider: accent-tinted caption with a hairline rule beside it.
function W.Heading(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(22)

    local fs = W.Font(f, 12, nil, 1)
    fs:SetPoint("LEFT", f, "LEFT", 8, 0)
    local r, g, b = W.Accent()
    fs:SetTextColor(r, g, b, 1)
    W.RegisterAccent(fs, "text")

    local rule = W.Tex(f, "ARTWORK", 1, 1, 1, W.TEXT_SECTION_A * 0.4)
    rule:SetHeight(1)
    rule:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    rule:SetPoint("RIGHT", f, "RIGHT", -8, 0)

    local o = { frame = f, fs = fs }
    function o:SetText(text) fs:SetText(text or "") end
    return o
end

-- ── Help marker ─────────────────────────────────────────────────────────────
-- A small accent "?" that reveals the long explanation on hover.
--
-- The point is what it takes OFF the panel. Every setting worth explaining
-- used to carry its reasoning inline, which turned each tab into a wall of
-- muted paragraphs that nobody reads twice and that buries the controls. A
-- short label plus a "?" keeps the panel scannable and still leaves the
-- detail one hover away -- the pattern PIHelper's options use throughout.
--
-- Corollary for callers: the label must stand alone. "Coalesce events" with
-- the reasoning behind it in the tooltip is right; "Coalesce" with the whole
-- explanation hidden is not.
function W.Help(parent, text)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(14, 14)

    local mark = W.Font(f, 11, nil, 1)
    mark:SetPoint("CENTER")
    mark:SetText("?")
    local ar, ag, ab = W.Accent()
    mark:SetTextColor(ar, ag, ab, 0.75)
    W.RegisterAccent(mark, "text", 0.75)

    local o = { frame = f, fs = mark, text = text }

    f:SetScript("OnEnter", function(self)
        if not o.text or o.text == "" then return end
        mark:SetTextColor(1, 1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        -- The trailing `true` is wrapText; without it a long explanation
        -- renders as one unreadable line running off the screen.
        GameTooltip:SetText(o.text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        GameTooltip:Hide()
        local r, g, b = W.Accent()
        mark:SetTextColor(r, g, b, 0.75)
    end)

    function o:SetText(t) o.text = t end
    function o:SetShown(v) f:SetShown(v and o.text ~= nil and o.text ~= "") end

    o:SetShown(true)
    return o
end

-- ── Confirm popup ───────────────────────────────────────────────────────────
-- A small two-button dialog, built once and reused.
--
-- EllesmereUI has its own (EllesmereUI:ShowConfirmPopup) and it would have
-- been one call, but reaching for it would put back exactly the coupling
-- Compat.lua removed: it is not part of the skinning facade, so the dialog
-- would exist with EllesmereUI loaded and be missing without it. Ours is
-- built from the same primitives as everything else and works either way.
--
-- Not a Blizzard StaticPopup for the same reason plus one more: those carry
-- Blizzard's own art and would be the one part of this panel that does not
-- follow the user's theme.

local confirmPopup

function W.Confirm(spec)
    spec = spec or {}

    if not confirmPopup then
        local f = W.Window("AniModsConfirmPopup", "AniMods", 380, 150)
        f:SetFrameStrata("FULLSCREEN_DIALOG")

        local host = f.content
        local msg = W.Text(host, 12, 0.85)
        msg.frame:SetPoint("TOPLEFT", host, "TOPLEFT", 14, -10)
        msg.frame:SetPoint("TOPRIGHT", host, "TOPRIGHT", -14, -10)
        msg:Resize(352)

        local confirm = W.Button(host, 120, 22)
        confirm.frame:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -14, 14)

        local cancel = W.Button(host, 100, 22)
        cancel.frame:SetPoint("BOTTOMRIGHT", confirm.frame, "BOTTOMLEFT", -8, 0)

        confirmPopup = { frame = f, msg = msg, confirm = confirm, cancel = cancel }
    end

    local p = confirmPopup
    p.msg:SetText(spec.message or "")
    p.msg:Resize(352)
    p.confirm:SetText(spec.confirmText or "OK")
    p.cancel:SetText(spec.cancelText or "Cancel")

    p.confirm:SetOnClick(function()
        p.frame:Hide()
        if spec.onConfirm then spec.onConfirm() end
    end)
    p.cancel:SetOnClick(function()
        p.frame:Hide()
        if spec.onCancel then spec.onCancel() end
    end)

    p.frame:Show()
    p.frame:Raise()
    return p
end

-- ── Toggle switch ───────────────────────────────────────────────────────────
-- A sliding switch, for the one control per tab that turns the whole module
-- on or off.
--
-- Deliberately not a checkbox. A checkbox is one of many equal settings; this
-- is the master control that decides whether any of the others matter, and it
-- should not look like its own contents. Same reason it lives in the tab
-- header rather than in a card with everything else.
--
-- All textures sit directly on `f`, which is ours and never passed to S, so
-- the restrip rule does not apply.
-- Colours are EllesmereUI's own toggle recipe (EllesmereUI.lua:102-108), which
-- is worth copying exactly because it solves the problem the first attempt
-- had. That version used a near-invisible white track with a separate accent
-- layer over it, so a light accent left a white knob on a white track with no
-- readable on-state.
--
-- EUI instead uses ONE track that changes colour: a solid dark grey when off,
-- the accent when on. Contrast then comes from grey-versus-accent rather than
-- from the accent alone, so it reads at any accent -- including a pale one.
local TG_OFF   = { 0.267, 0.267, 0.267, 0.65 }  -- #444, track when off
local TG_ON_A  = 0.75                           -- track alpha when on (colour = accent)
local TG_KNOB_OFF_A = 0.5
local TG_KNOB_ON_A  = 1

function W.Toggle(parent)
    -- EUI's proportions too: 40x20 with a 2px knob pad.
    local TRACK_W, TRACK_H, KNOB_PAD = 40, 20, 2
    local KNOB = TRACK_H - KNOB_PAD * 2

    local f = CreateFrame("Button", nil, parent)
    f:SetSize(TRACK_W, TRACK_H)
    f:RegisterForClicks("AnyUp")

    local track = W.Tex(f, "BACKGROUND", TG_OFF[1], TG_OFF[2], TG_OFF[3], TG_OFF[4])
    track:SetAllPoints()

    local knob = W.Tex(f, "ARTWORK", 1, 1, 1, TG_KNOB_OFF_A)
    knob:SetSize(KNOB, KNOB)

    local o = { frame = f, checked = false }

    -- Re-reads the accent on every call rather than capturing it once, so a
    -- theme change repaints correctly (see the OnLooksChanged registration
    -- below, which is what delivers that change).
    local function Apply(hovering)
        knob:ClearAllPoints()
        if o.checked then
            local r, g, b = W.Accent()
            knob:SetPoint("RIGHT", f, "RIGHT", -KNOB_PAD, 0)
            track:SetColorTexture(r, g, b, hovering and 0.9 or TG_ON_A)
            knob:SetColorTexture(1, 1, 1, TG_KNOB_ON_A)
        else
            knob:SetPoint("LEFT", f, "LEFT", KNOB_PAD, 0)
            track:SetColorTexture(TG_OFF[1], TG_OFF[2], TG_OFF[3],
                hovering and (TG_OFF[4] + 0.15) or TG_OFF[4])
            knob:SetColorTexture(1, 1, 1, hovering and 0.75 or TG_KNOB_OFF_A)
        end
    end

    -- The track's colour depends on BOTH the accent and the on/off state, so
    -- it cannot just be registered as a vertex-recoloured region -- repainting
    -- it means re-running Apply.
    W.OnLooksChanged(function() Apply(false) end)

    f:SetScript("OnEnter", function() Apply(true) end)
    f:SetScript("OnLeave", function() Apply(false) end)
    f:SetScript("OnClick", function()
        o.checked = not o.checked
        Apply(f:IsMouseOver())
        if o._onClick then o._onClick(o.checked) end
    end)

    function o:SetChecked(v)
        o.checked = v and true or false
        Apply(false)
    end
    function o:SetOnClick(fn) o._onClick = fn end

    -- Greyed and unclickable, for a switch that exists but cannot be used --
    -- forcing a module past a HARD requirement, which would not help. Shown
    -- rather than hidden so the option is discoverable once it does apply.
    function o:SetEnabled(on)
        o.disabled = not on
        f:EnableMouse(on and true or false)
        f:SetAlpha(on and 1 or 0.35)
    end

    Apply(false)
    return o
end

-- ── Status badge ────────────────────────────────────────────────────────────
-- Right-aligned pill carrying a state word, tinted by that state.
--
-- The colour is the point: a column of these answers "what is wrong here" at a
-- glance, without reading any of them. Text stays a plain word ("Loaded",
-- "Not loaded") rather than a sentence -- the reasoning belongs in the row's
-- "?" marker.
W.BADGE_OK   = { 0.35, 1.00, 0.35 }
W.BADGE_BAD  = { 1.00, 0.42, 0.42 }
W.BADGE_IDLE = { 0.60, 0.60, 0.60 }
W.BADGE_WARN = { 1.00, 0.65, 0.25 }

function W.Badge(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(16)

    local bg = W.Tex(f, "BACKGROUND", 1, 1, 1, 0.06)
    bg:SetAllPoints()

    local fs = W.Font(f, 11, nil, 1)
    fs:SetPoint("CENTER")

    local o = { frame = f, fs = fs }

    function o:Set(text, color)
        text = text or ""
        fs:SetText(text)
        local c = color or W.BADGE_IDLE
        fs:SetTextColor(c[1], c[2], c[3], 1)
        bg:SetColorTexture(c[1], c[2], c[3], 0.10)
        -- Sized to its word, so badges stay pills rather than a fixed block
        -- with ragged text inside.
        f:SetWidth((fs:GetStringWidth() or 30) + 14)
    end

    o:Set("")
    return o
end

-- ── Colour swatches ─────────────────────────────────────────────────────────
-- A row of clickable colour squares, the current one ringed.
--
-- Not a dropdown. A dropdown names colours, and names are the problem: the
-- list this replaced called 0.047/0.824/0.616 "Green" when it is a mint, and
-- carried a separate "Teal" that was nearly the same colour. Showing the
-- colours removes both the naming and the question of whether the name is
-- accurate -- you pick what you can see.
function W.Swatches(parent, size)
    size = size or 16
    local GAP, RING = 6, 2

    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(size + RING * 2)

    local o = { frame = f, buttons = {}, order = {}, colors = {} }

    local function Paint(btn, selected, hovering)
        btn.ring:SetShown(selected)
        btn.swatch:SetAlpha((selected or hovering) and 1 or 0.75)
    end

    local function Repaint()
        for key, btn in pairs(o.buttons) do
            Paint(btn, key == o.value, btn:IsMouseOver())
        end
    end

    -- `colors` maps key -> {r, g, b}. Rebuilt rather than pooled: the palette
    -- is fixed and set once.
    -- `hollow` is a set of keys to draw as rings rather than solid squares.
    function o:SetList(order, colors, hollow)
        o.order, o.colors, o.hollow = order or {}, colors or {}, hollow

        local x = 0
        for _, key in ipairs(o.order) do
            local c = o.colors[key]
            local btn = o.buttons[key]
            if not btn then
                btn = CreateFrame("Button", nil, f)
                btn:SetSize(size + RING * 2, size + RING * 2)
                btn:RegisterForClicks("AnyUp")

                -- The ring is a plain backing square a little larger than the
                -- swatch, so the selected colour reads as framed without
                -- needing a border texture.
                btn.ring = W.Tex(btn, "BACKGROUND", 1, 1, 1, 0.85)
                btn.ring:SetAllPoints()
                btn.ring:Hide()

                btn.swatch = W.Tex(btn, "ARTWORK", 1, 1, 1, 1)
                btn.swatch:SetPoint("TOPLEFT", RING, -RING)
                btn.swatch:SetPoint("BOTTOMRIGHT", -RING, RING)

                -- Punches the centre out, turning the square into a ring.
                -- Used for a swatch that INHERITS its colour rather than
                -- setting one: it can render identical to a preset -- the
                -- host theme's accent may well be a colour also in the
                -- palette -- and two identical squares side by side read as a
                -- mistake. Hollow versus solid says "follows something" and
                -- "is this colour" without needing a label.
                btn.hole = W.Tex(btn, "OVERLAY", 0, 0, 0, 0)
                btn.hole:SetPoint("TOPLEFT", btn.swatch, "TOPLEFT", 3, -3)
                btn.hole:SetPoint("BOTTOMRIGHT", btn.swatch, "BOTTOMRIGHT", -3, 3)
                btn.hole:Hide()

                -- `swatch` rather than `self`: the enclosing SetList is a
                -- method, so `self` here would shadow its own.
                btn:SetScript("OnEnter", function(swatch) Paint(swatch, o.value == key, true) end)
                btn:SetScript("OnLeave", function(swatch) Paint(swatch, o.value == key, false) end)
                btn:SetScript("OnClick", function()
                    o.value = key
                    Repaint()
                    if o._onChange then o._onChange(key) end
                end)

                o.buttons[key] = btn
            end

            if c then btn.swatch:SetColorTexture(c[1], c[2], c[3], 1) end

            if o.hollow and o.hollow[key] then
                -- The hole is painted in the panel fill so it reads as a hole
                -- rather than a black dot, whatever the card sits on.
                local pr, pg, pb = W.PanelColor()
                btn.hole:SetColorTexture(pr, pg, pb, 1)
                btn.hole:Show()
            else
                btn.hole:Hide()
            end

            btn:ClearAllPoints()
            btn:SetPoint("LEFT", f, "LEFT", x, 0)
            btn:Show()
            x = x + size + RING * 2 + GAP
        end

        f:SetWidth(math.max(x - GAP, 1))
        Repaint()
    end

    function o:SetValue(key) o.value = key; Repaint() end
    function o:GetValue() return o.value end
    function o:SetOnChange(fn) o._onChange = fn end
    -- Re-reads a colour that resolves live (the class swatch), so it stays
    -- right if it is rebuilt after the player's class is known.
    function o:SetColor(key, c)
        local btn = o.buttons[key]
        if btn and c then btn.swatch:SetColorTexture(c[1], c[2], c[3], 1) end
    end

    return o
end

-- ── Card ────────────────────────────────────────────────────────────────────
-- A titled panel that groups related rows.
--
-- Replaces a bare accent caption with a hairline rule. A rule separates but
-- does not enclose: with several sections stacked, everything read as one
-- undifferentiated column and the eye had nothing to group on. A filled,
-- bordered card makes each group a visible object, which is what
-- EllesmereUI's options and PIHelper's both do.
--
-- Callers stack into `.body` and call `:Finish()` once, which sizes the card
-- around whatever the body ended up being. `.body` is a child, per the
-- restrip rule at the top of this file.
local CARD_PAD = 10
local CARD_HEADER_H = 17

function W.Card(parent, titleText)
    local f = W.Panel(parent)

    local inner = CreateFrame("Frame", nil, f)
    inner:SetPoint("TOPLEFT", CARD_PAD, -CARD_PAD)
    inner:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD)
    inner:SetHeight(1)

    -- Uppercase and small: a section title should register as a label, not
    -- compete with the content under it.
    local header = W.Font(inner, 11, nil, 1)
    header:SetPoint("TOPLEFT")
    header:SetText(string.upper(titleText or ""))
    local ar, ag, ab = W.Accent()
    header:SetTextColor(ar, ag, ab, 1)
    W.RegisterAccent(header, "text")

    local body = CreateFrame("Frame", nil, inner)
    body:SetPoint("TOPLEFT", inner, "TOPLEFT", 0, -CARD_HEADER_H)
    body:SetPoint("TOPRIGHT", inner, "TOPRIGHT", 0, -CARD_HEADER_H)
    body:SetHeight(1)

    local o = { frame = f, body = body, header = header }

    function o:SetTitle(t) header:SetText(string.upper(t or "")) end
    function o:Finish()
        f:SetHeight((body:GetHeight() or 0) + CARD_HEADER_H + CARD_PAD * 2)
    end

    return o
end

-- ── Checkbox ────────────────────────────────────────────────────────────────
-- A real CheckButton skinned by the engine: S.Checkbox strips the Blizzard
-- art, lays the house dark box with a 1px border, and tints the check itself
-- in the accent colour -- tracking theme changes on its own, with no
-- registration from us. The label is ours, so it follows our text tokens.

function W.CheckBox(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(20)

    -- 20, not 24: S.Checkbox insets its box 4px inside the frame, so a 24px
    -- CheckButton draws a 16px box that crowded the 20px row. At 20 the box
    -- is 12px and the row breathes.
    local box = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    box:SetSize(20, 20)
    box:SetPoint("LEFT", f, "LEFT", 4, 0)
    box:EnableMouse(false)   -- the whole row is the hit area, not just the box
    W.OnReady(function(s) s.Checkbox(box) end)

    -- Anchored LEFT only, so the FontString sizes to its text. That is what
    -- lets a "?" marker sit immediately after the label instead of at the far
    -- side of the row -- a right anchor would stretch it across the width.
    local label = W.Font(f, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("LEFT", box, "RIGHT", 4, 0)
    label:SetJustifyH("LEFT")

    local o = { frame = f, checked = false, labelFS = label }

    local function ApplyVisual(hovering)
        box:SetChecked(o.checked)
        label:SetTextColor(1, 1, 1, hovering and W.TEXT_A or W.TEXT_DIM_A)
    end

    f:SetScript("OnEnter", function() ApplyVisual(true) end)
    f:SetScript("OnLeave", function() ApplyVisual(false) end)
    f:SetScript("OnClick", function()
        o.checked = not o.checked
        ApplyVisual(f:IsMouseOver())
        if o._onClick then o._onClick(o.checked) end
    end)

    function o:SetLabel(text) label:SetText(text or "") end
    function o:SetChecked(v)
        o.checked = v and true or false
        ApplyVisual(false)
    end
    function o:SetOnClick(fn) o._onClick = fn end

    ApplyVisual(false)
    return o
end

-- ── Dropdown ────────────────────────────────────────────────────────────────
-- One shared popup menu, reused by whichever dropdown opened it (the same
-- thing EllesmereUI does). Closing is driven by an invisible full-screen
-- click-catcher behind the menu, which is what makes "click anywhere else
-- to dismiss" work without polling for mouse position.

local menu, menuCatcher, menuInner
local menuItems = {}
local menuOwner

local function HideMenu()
    if not menu then return end
    menu:Hide()
    if menuCatcher then menuCatcher:Hide() end
    local owner = menuOwner
    menuOwner = nil
    if owner and owner._onClosed then owner._onClosed() end
end
W.CloseDropdownMenu = HideMenu

local MENU_ITEM_H, MENU_PAD = 18, 6

local function EnsureMenu()
    if menu then return menu end

    menuCatcher = CreateFrame("Button", nil, UIParent)
    menuCatcher:SetAllPoints(UIParent)
    menuCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    menuCatcher:SetFrameLevel(500)
    menuCatcher:RegisterForClicks("AnyUp")
    menuCatcher:SetScript("OnClick", HideMenu)
    menuCatcher:Hide()

    menu = W.Panel(UIParent, { inset = true })
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(510)
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:Hide()

    -- Items live on a child, not on `menu` itself: `menu` went through
    -- S.Panel and is therefore in the restrip registry (see the file header).
    menuInner = CreateFrame("Frame", nil, menu)
    menuInner:SetAllPoints()

    return menu
end

local function EnsureMenuItem(index)
    if menuItems[index] then return menuItems[index] end
    local btn = CreateFrame("Button", nil, menuInner)
    btn:SetHeight(MENU_ITEM_H)
    btn:RegisterForClicks("AnyUp")

    local hl = W.Tex(btn, "BACKGROUND", 1, 1, 1, W.DD_ITEM_HL_A)
    hl:SetAllPoints()
    hl:Hide()
    btn._hl = hl

    local sel = W.Tex(btn, "BACKGROUND", 1, 1, 1, W.DD_ITEM_SEL_A)
    sel:SetAllPoints()
    sel:Hide()
    btn._sel = sel

    local fs = W.Font(btn, 12, nil, W.DD_TXT_A)
    fs:SetPoint("LEFT", btn, "LEFT", 8, 0)
    fs:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    fs:SetJustifyH("LEFT")
    btn._fs = fs

    btn:SetScript("OnEnter", function(self)
        self._hl:Show()
        self._fs:SetTextColor(1, 1, 1, 1)
    end)
    btn:SetScript("OnLeave", function(self)
        self._hl:Hide()
        self._fs:SetTextColor(1, 1, 1, W.DD_TXT_A)
    end)

    menuItems[index] = btn
    return btn
end

function W.Dropdown(parent, width)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(22)
    f:SetWidth(width or 200)
    f:RegisterForClicks("AnyUp")
    -- S.Dropdown gives the flat house block and border. It is idempotent and
    -- nil-guarded per template, so a bare Button is a valid target.
    W.OnReady(function(s) s.Dropdown(f) end)

    -- Content on a child: `f` is a restrip-registered frame.
    local inner = CreateFrame("Frame", nil, f)
    inner:SetAllPoints()

    local text = W.Font(inner, 12, nil, W.DD_TXT_A)
    text:SetPoint("LEFT", inner, "LEFT", 8, 0)
    text:SetPoint("RIGHT", inner, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")

    local caret = W.Font(inner, 10, nil, W.DD_TXT_A)
    caret:SetPoint("RIGHT", inner, "RIGHT", -8, 0)
    caret:SetText("\226\150\188") -- U+25BC

    local o = { frame = f, list = {}, order = {} }

    local function Hover(on)
        local a = on and W.DD_TXT_HA or W.DD_TXT_A
        text:SetTextColor(1, 1, 1, a)
        caret:SetTextColor(1, 1, 1, a)
    end
    f:SetScript("OnEnter", function() Hover(true) end)
    f:SetScript("OnLeave", function() Hover(false) end)

    local function OpenMenu()
        EnsureMenu()
        if menuOwner == o and menu:IsShown() then
            HideMenu()
            return
        end
        HideMenu()
        menuOwner = o

        local widest = f:GetWidth()
        local count = 0
        for i, key in ipairs(o.order) do
            count = i
            local item = EnsureMenuItem(i)
            item:SetPoint("TOPLEFT", menuInner, "TOPLEFT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
            item:SetPoint("TOPRIGHT", menuInner, "TOPRIGHT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
            item._fs:SetText(o.list[key] or tostring(key))
            item._sel:SetShown(key == o.value)
            item._hl:Hide()
            item._fs:SetTextColor(1, 1, 1, W.DD_TXT_A)
            item:SetScript("OnClick", function()
                o:SetValue(key)
                HideMenu()
                if o._onChange then o._onChange(key) end
            end)
            item:Show()
            local w = (item._fs:GetStringWidth() or 0) + 24
            if w > widest then widest = w end
        end
        for i = count + 1, #menuItems do menuItems[i]:Hide() end

        menu:SetWidth(widest)
        menu:SetHeight(MENU_PAD * 2 + count * MENU_ITEM_H)
        menu:ClearAllPoints()
        menu:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -2)
        menuCatcher:Show()
        menu:Show()

        if o._onOpened then o._onOpened() end
    end

    f:SetScript("OnClick", OpenMenu)
    f:SetScript("OnHide", function()
        -- A menu whose owner just went away must not be left floating over
        -- the screen.
        if menuOwner == o then HideMenu() end
    end)

    function o:SetList(list, order)
        o.list = list or {}
        o.order = order or {}
        if not order then
            local keys = {}
            for k in pairs(o.list) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            o.order = keys
        end
    end
    function o:SetValue(key)
        o.value = key
        text:SetText(o.list[key] or "")
    end
    function o:GetValue() return o.value end
    function o:SetOnChange(fn) o._onChange = fn end
    function o:SetOnOpened(fn) o._onOpened = fn end
    function o:SetOnClosed(fn) o._onClosed = fn end
    function o:IsOpen() return menuOwner == o and menu and menu:IsShown() end

    Hover(false)
    return o
end

-- ── Slider ──────────────────────────────────────────────────────────────────
-- Track + accent fill + square thumb + numeric readout. Drawn by us (the
-- engine has no slider primitive), so the fill registers for accent updates.

function W.Slider(parent, width)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(26)
    f:SetWidth(width or 200)

    local label = W.Font(f, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("TOPLEFT", f, "TOPLEFT", 8, 0)
    label:SetJustifyH("LEFT")

    local valueFS = W.Font(f, 12, nil, W.TEXT_A)
    valueFS:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, 0)
    valueFS:SetJustifyH("RIGHT")

    local slider = CreateFrame("Slider", nil, f)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(6)
    slider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 8, 2)
    slider:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 2)

    local track = W.Tex(slider, "BACKGROUND", 1, 1, 1, W.SL_TRACK_A)
    track:SetAllPoints()

    local fill = W.Tex(slider, "ARTWORK", W.Accent())
    fill:SetAlpha(W.SL_FILL_A)
    fill:SetPoint("TOPLEFT", slider, "TOPLEFT", 0, 0)
    fill:SetPoint("BOTTOMLEFT", slider, "BOTTOMLEFT", 0, 0)
    fill:SetWidth(1)
    W.RegisterAccent(fill, "vertex")

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.9)
    thumb:SetSize(6, 14)
    slider:SetThumbTexture(thumb)

    local o = { frame = f, slider = slider, labelFS = label }

    local function Redraw()
        local minV, maxV = slider:GetMinMaxValues()
        local v = slider:GetValue() or minV
        local pct = (maxV > minV) and ((v - minV) / (maxV - minV)) or 0
        local w = slider:GetWidth() or 0
        fill:SetWidth(math.max(1, w * pct))
        valueFS:SetText(tostring(math.floor(v + 0.5)))
    end

    slider:SetScript("OnValueChanged", function(_, value)
        Redraw()
        if o._live then o._live(value) end
    end)
    slider:SetScript("OnMouseUp", function()
        if o._onChange then o._onChange(slider:GetValue()) end
    end)
    slider:SetScript("OnSizeChanged", Redraw)

    function o:SetLabel(text) label:SetText(text or "") end
    function o:SetRange(minV, maxV, step)
        slider:SetMinMaxValues(minV, maxV)
        slider:SetValueStep(step or 1)
        slider:SetObeyStepOnDrag(true)
        Redraw()
    end
    function o:SetValue(v) slider:SetValue(v); Redraw() end
    function o:SetOnChange(fn) o._onChange = fn end

    return o
end

-- ── Button ──────────────────────────────────────────────────────────────────
-- S.Button paints the flat dark block, the house border and a subtle white
-- hover overlay, so all that is left here is the label and the click.

function W.Button(parent, width, height)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(width or 120, height or 22)
    f:RegisterForClicks("AnyUp")
    W.OnReady(function(s) s.Button(f) end)

    -- Label on a child: `f` is restrip-registered.
    local inner = CreateFrame("Frame", nil, f)
    inner:SetAllPoints()
    local fs = W.Font(inner, 12, nil, W.BTN_TXT_A)
    fs:SetPoint("CENTER")

    local o = { frame = f }
    f:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1, W.BTN_TXT_HA) end)
    f:SetScript("OnLeave", function() fs:SetTextColor(1, 1, 1, W.BTN_TXT_A) end)
    f:SetScript("OnClick", function() if o._onClick then o._onClick() end end)

    function o:SetText(text) fs:SetText(text or "") end
    function o:SetOnClick(fn) o._onClick = fn end

    return o
end

-- ── Icon ────────────────────────────────────────────────────────────────────
-- Accepts either a Blizzard atlas name or a plain texture path, so style
-- previews can show either without the caller resolving anything.

function W.Icon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size or 20, size or 20)
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()

    local o = { frame = f, texture = tex }
    function o:SetAtlas(atlas)
        if atlas then tex:SetAtlas(atlas) end
    end
    function o:SetTexture(path)
        if path then tex:SetTexture(path); tex:SetTexCoord(0, 1, 0, 1) end
    end
    return o
end

-- ── Scroll area ─────────────────────────────────────────────────────────────
-- Blizzard ScrollFrame for the clipping/scrolling, but a thin custom thumb
-- instead of the chunky stock bar. `outer` never goes through S, so its
-- textures are safe to place directly.

function W.ScrollArea(parent)
    local outer = CreateFrame("Frame", nil, parent)

    local scroll = CreateFrame("ScrollFrame", nil, outer)
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -8, 0)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    local barBg = W.Tex(outer, "BACKGROUND", 1, 1, 1, 0.06)
    barBg:SetWidth(3)
    barBg:SetPoint("TOPRIGHT", outer, "TOPRIGHT", -2, 0)
    barBg:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -2, 0)

    local thumb = W.Tex(outer, "ARTWORK", 1, 1, 1, 0.25)
    thumb:SetWidth(3)
    thumb:SetPoint("TOPRIGHT", outer, "TOPRIGHT", -2, 0)
    thumb:SetHeight(20)

    local o = { frame = outer, scroll = scroll, content = content }

    local function Range()
        local viewH = scroll:GetHeight() or 1
        local contentH = content:GetHeight() or 1
        return math.max(0, contentH - viewH), viewH, contentH
    end

    local function UpdateThumb()
        local maxScroll, viewH, contentH = Range()
        if maxScroll <= 0 then
            barBg:Hide(); thumb:Hide()
            return
        end
        barBg:Show(); thumb:Show()
        local frac = math.min(1, viewH / contentH)
        local h = math.max(20, viewH * frac)
        thumb:SetHeight(h)
        local pct = scroll:GetVerticalScroll() / maxScroll
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", outer, "TOPRIGHT", -2, -((viewH - h) * pct))
    end

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(_, delta)
        local maxScroll = Range()
        local target = scroll:GetVerticalScroll() - delta * 28
        if target < 0 then target = 0 end
        if target > maxScroll then target = maxScroll end
        scroll:SetVerticalScroll(target)
        UpdateThumb()
    end)
    scroll:SetScript("OnVerticalScroll", function() UpdateThumb() end)
    scroll:SetScript("OnSizeChanged", function() UpdateThumb() end)

    -- Called after the caller has laid out and sized `content`.
    function o:Update()
        content:SetWidth(scroll:GetWidth() or 1)
        local maxScroll = Range()
        if scroll:GetVerticalScroll() > maxScroll then
            scroll:SetVerticalScroll(maxScroll)
        end
        UpdateThumb()
    end
    function o:GetScroll() return scroll:GetVerticalScroll() end
    function o:SetScroll(v)
        local maxScroll = Range()
        scroll:SetVerticalScroll(math.min(math.max(0, v or 0), maxScroll))
        UpdateThumb()
    end

    return o
end

-- ── Window ──────────────────────────────────────────────────────────────────
-- Movable, Esc-closable window wearing EllesmereUI's own window dress:
-- S.Shell lays the atlas backdrop, the black title band and the frame border,
-- and registers the window so it LIVE-FOLLOWS the user's window style -- the
-- "eui" atlas look and the flat "modern" colour swap without a reload, and
-- Modern colour edits apply immediately. That is the whole point of going
-- through the skin API rather than painting a panel ourselves.
--
-- Returns the frame with `.content` -- a child covering everything below the
-- title band. Callers must build into `.content`, never onto the window
-- itself, because the window is restrip-registered (see the file header).

local TITLE_BAR_H = 25   -- S.Shell's own top band height
local FOOTER_H = 22

function W.Window(name, titleText, width, height, opts)
    local s = Need()

    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(width or 700, height or 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    if s then s.Shell(f) end

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(TITLE_BAR_H)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")

    -- Addon icon, left of the name. `opts.icon` is a texture path.
    local titleX = 12
    if opts and opts.icon then
        local ico = titleBar:CreateTexture(nil, "ARTWORK")
        ico:SetSize(16, 16)
        ico:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
        ico:SetTexture(opts.icon)
        titleX = 32
        f.titleIcon = ico
    end

    local title = W.Font(titleBar, 14, nil, 1)
    title:SetPoint("LEFT", titleBar, "LEFT", titleX, 0)
    title:SetText(titleText or "")
    local ar, ag, ab = W.Accent()
    title:SetTextColor(ar, ag, ab, 1)
    W.RegisterAccent(title, "text")

    local close = W.Button(titleBar, 22, 20)
    close:SetText("\195\151") -- U+00D7 multiplication sign
    close.frame:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    close:SetOnClick(function() f:Hide() end)

    -- Footer strip, for the things that belong to the window rather than to
    -- any one tab: slash commands, version. Keeping them here means no tab has
    -- to spend rows explaining how to reach the panel it is already in.
    local footer, footerLeft, footerRight
    if opts and opts.footer then
        footer = CreateFrame("Frame", nil, f)
        footer:SetHeight(FOOTER_H)
        footer:SetPoint("BOTTOMLEFT")
        footer:SetPoint("BOTTOMRIGHT")

        local rule = W.Tex(footer, "ARTWORK", 1, 1, 1, 0.10)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT")
        rule:SetPoint("TOPRIGHT")

        footerLeft = W.Font(footer, 11, nil, 0.45)
        footerLeft:SetPoint("LEFT", footer, "LEFT", 12, 0)
        footerLeft:SetJustifyH("LEFT")

        footerRight = W.Font(footer, 11, nil, 0.35)
        footerRight:SetPoint("RIGHT", footer, "RIGHT", -12, 0)
        footerRight:SetJustifyH("RIGHT")

        f.footerLeft, f.footerRight = footerLeft, footerRight
    end

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -TITLE_BAR_H)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, footer and FOOTER_H or 0)
    f.content = content

    -- Esc closes it, matching every other panel in the game.
    _G[name] = f
    tinsert(UISpecialFrames, name)

    f.titleBar = titleBar
    return f
end
