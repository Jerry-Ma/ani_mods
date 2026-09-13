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

-- The accent AniMods draws with -- simply whatever the provider says.
--
-- The provider decides whether an AniMods colour setting applies at all:
-- EllesmereUI's facade answers with the user's EllesmereUI theme and knows
-- nothing about our setting, while the stock provider answers with our
-- setting or our default. So "EllesmereUI wins when present" is enforced by
-- which provider is in play, not by a UI control remembering to defer.
--
-- An earlier version layered the override on top of BOTH providers here. It
-- was added on the theory that EllesmereUI's accent might be too pale to
-- read -- which turned out to be a misdiagnosis of a broken repaint path, so
-- the reason for overriding a working theme went away with it.
function W.Accent()
    local s = Need()
    if not s then
        local d = AniMods.ACCENT_DEFAULT
        return d.r, d.g, d.b
    end
    return s.GetAccentColor()
end

-- The accent as an |cff escape prefix, for text that is part of a larger
-- string and so cannot be coloured by SetTextColor. Read fresh at each call:
-- an inline colour code is baked into the string, so anything using this has
-- to rebuild that string on a theme change rather than being repainted.
function W.AccentHex()
    local r, g, b = W.Accent()
    return ("%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

-- What the "follow the theme" swatch previews: the HOST theme's accent, or
-- nothing to follow when there is no host.
function W.ProviderAccent()
    if AniMods.AccentIsForeign() and EllesmereUI and EllesmereUI.GetAccentColor then
        local ok, r, g, b = pcall(EllesmereUI.GetAccentColor)
        if ok and r then return r, g, b end
    end
    local d = AniMods.ACCENT_DEFAULT
    return d.r, d.g, d.b
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

-- Applies the theme font to an EXISTING FontString.
--
-- Split out of W.Font because the outline flag is the part callers get wrong:
-- S.GetFont() returns path AND the theme's outline flag, and code that reads
-- only the path then passes "" hardcodes no-outline, so that one surface
-- silently ignores an outline-configured theme. SocialStatus' popup did exactly
-- that at four call sites.
--
-- Also what lets a long-lived FontString follow a live theme change: re-call
-- this rather than reaching for SetFont directly.
function W.SetFont(fs, size, flags, alpha)
    local s = Need()
    local path, themeFlag = "Fonts\\FRIZQT__.TTF", ""
    if s then path, themeFlag = s.GetFont() end
    fs:SetFont(path, size or 12, flags or themeFlag or "")
    if alpha then fs:SetTextColor(1, 1, 1, alpha) end
    return fs
end

function W.Font(parent, size, flags, alpha)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    W.SetFont(fs, size, flags, alpha or W.TEXT_A)
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
-- rest of the list is for.
--
-- `prefer` is "texture" or "atlas": candidates of that kind are tried first,
-- then the whole list in its written order. It is a PREFERENCE and never a
-- filter, which is what lets a list that ends in a guaranteed Blizzard atlas
-- still produce an icon when the preferred art is not installed. Ordering, not
-- selecting -- so no caller has to handle "the style you asked for is absent".
--
-- Returns { atlas = ... } or { texture = ... }, or nil if nothing is usable.
function W.ResolveIcon(candidates, prefer)
    local function Usable(candidate)
        if candidate.atlas then
            if W.AtlasExists(candidate.atlas) then return { atlas = candidate.atlas } end
        elseif candidate.texture then
            if (not candidate.addon) or AniMods.IsAddOnLoaded(candidate.addon) then
                return { texture = candidate.texture }
            end
        end
        return nil
    end

    if prefer then
        for _, candidate in ipairs(candidates or {}) do
            if candidate[prefer] then
                local found = Usable(candidate)
                if found then return found end
            end
        end
    end

    for _, candidate in ipairs(candidates or {}) do
        local found = Usable(candidate)
        if found then return found end
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

-- ── Power button ────────────────────────────────────────────────────────────
-- The on/off control for a module, sitting on its sidebar row.
--
-- Same shape and behaviour as EllesmereUI's own module toggles, deliberately:
-- 13px, hard against the row's right edge, white at full strength when on and
-- half-strength when off, and -- the part that is not obvious -- coloured on
-- hover by WHAT THE CLICK WILL DO rather than by the current state. Red while
-- enabled means "this turns it off"; green while disabled means "this turns
-- it on". Copying the convention matters more than agreeing with it: a player
-- who already reads EllesmereUI's sidebar should not have to learn a second
-- meaning for the same glyph.
--
-- The icon is AniMods' own (Media\power.png). EllesmereUI ships one, but
-- referencing it would put the button back on EllesmereUI being installed --
-- and this control has to work on a stock UI like everything else.
local POWER_ICON = "Interface\\AddOns\\AniMods\\Media\\power.png"
local POWER_WILL_ENABLE  = { 0.212, 0.824, 0.325 }
local POWER_WILL_DISABLE = { 0.824, 0.212, 0.212 }

function W.PowerButton(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(13, 13)
    f:RegisterForClicks("AnyUp")

    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture(POWER_ICON)
    tex:SetAlpha(0.75)

    local o = { frame = f, texture = tex, checked = false }

    -- Accent when on, dim white when off.
    --
    -- EllesmereUI uses white-at-full-strength for on, and this deliberately
    -- differs: with a column of rows, "which modules are running" is the
    -- question the list should answer at a glance, and a hue reads faster
    -- than an alpha difference. It also makes this the last control in the
    -- panel that was ignoring the theme.
    --
    -- The hover pair stays red/green, because those mean something else --
    -- what the click will DO, not what the state IS. Worth knowing: if the
    -- accent is itself green, an idle-on button and a hovered-off button sit
    -- in similar hues. They differ in brightness and only one is ever under
    -- the cursor, so it reads, but it is the reason to keep the hover colours
    -- saturated rather than tinting them toward the accent too.
    local function Idle()
        if o.checked then
            local r, g, b = W.Accent()
            tex:SetVertexColor(r, g, b, 1)
        else
            tex:SetVertexColor(1, 1, 1, 0.4)
        end
    end

    -- Repaints on a theme change; the colour depends on the accent AND the
    -- on/off state, so it re-runs its own paint rather than being registered
    -- as a flat recoloured region.
    W.OnLooksChanged(Idle)

    f:SetScript("OnEnter", function(self)
        local c = o.checked and POWER_WILL_DISABLE or POWER_WILL_ENABLE
        tex:SetVertexColor(c[1], c[2], c[3], 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((o.checked and "Disable " or "Enable ") .. (o.label or "module"),
            1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function()
        Idle()
        GameTooltip:Hide()
    end)
    f:SetScript("OnClick", function()
        o.checked = not o.checked
        Idle()
        if o._onClick then o._onClick(o.checked) end
    end)

    function o:SetChecked(v)
        o.checked = v and true or false
        Idle()
    end
    function o:SetLabel(text) o.label = text end
    function o:SetOnClick(fn) o._onClick = fn end

    Idle()
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
        if btn.disabled then
            -- Visible but plainly inert: the choice exists, it just does not
            -- apply here. Hiding it would leave no explanation for why the
            -- panel is the colour it is.
            btn.ring:Hide()
            btn:SetAlpha(0.2)
            return
        end
        btn:SetAlpha(1)
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
    -- `hollow` is a set of keys to draw as rings rather than solid squares;
    -- `disabled` a set to render inert.
    function o:SetList(order, colors, hollow, disabled)
        o.order, o.colors, o.hollow = order or {}, colors or {}, hollow
        o.disabled = disabled

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

                -- Ring form, for a swatch that INHERITS its colour rather than
                -- setting one: it can render identical to a preset -- the host
                -- theme's accent may well be a colour also in the palette --
                -- and two identical squares side by side read as a mistake.
                -- Hollow versus solid says "follows something" and "is this
                -- colour" without needing a label.
                --
                -- Four edge strips, NOT a solid square with a smaller one
                -- painted over the middle. That first attempt drew the centre
                -- in the panel colour at full alpha, but the card it sits on
                -- paints its fill at the theme's panel ALPHA -- so the "hole"
                -- came out darker than its surroundings and read as a black
                -- dot. A hole has to be an absence, not a colour.
                local E = 3
                btn.edges = {}
                for e = 1, 4 do btn.edges[e] = W.Tex(btn, "ARTWORK", 1, 1, 1, 1) end
                btn.edges[1]:SetPoint("TOPLEFT", btn.swatch, "TOPLEFT")
                btn.edges[1]:SetPoint("TOPRIGHT", btn.swatch, "TOPRIGHT")
                btn.edges[1]:SetHeight(E)
                btn.edges[2]:SetPoint("BOTTOMLEFT", btn.swatch, "BOTTOMLEFT")
                btn.edges[2]:SetPoint("BOTTOMRIGHT", btn.swatch, "BOTTOMRIGHT")
                btn.edges[2]:SetHeight(E)
                btn.edges[3]:SetPoint("TOPLEFT", btn.swatch, "TOPLEFT")
                btn.edges[3]:SetPoint("BOTTOMLEFT", btn.swatch, "BOTTOMLEFT")
                btn.edges[3]:SetWidth(E)
                btn.edges[4]:SetPoint("TOPRIGHT", btn.swatch, "TOPRIGHT")
                btn.edges[4]:SetPoint("BOTTOMRIGHT", btn.swatch, "BOTTOMRIGHT")
                btn.edges[4]:SetWidth(E)
                for e = 1, 4 do btn.edges[e]:Hide() end

                -- `swatch` rather than `self`: the enclosing SetList is a
                -- method, so `self` here would shadow its own.
                btn:SetScript("OnEnter", function(swatch) Paint(swatch, o.value == key, true) end)
                btn:SetScript("OnLeave", function(swatch) Paint(swatch, o.value == key, false) end)
                btn:SetScript("OnClick", function(swatch)
                    if swatch.disabled then return end
                    o.value = key
                    Repaint()
                    if o._onChange then o._onChange(key) end
                end)

                o.buttons[key] = btn
            end

            -- Hollow: hide the fill and show the four edges in its place, so
            -- whatever is behind shows through the middle.
            local isRing = o.hollow and o.hollow[key]
            if c then
                btn.swatch:SetColorTexture(c[1], c[2], c[3], 1)
                for e = 1, 4 do btn.edges[e]:SetColorTexture(c[1], c[2], c[3], 1) end
            end
            btn.swatch:SetShown(not isRing)
            for e = 1, 4 do btn.edges[e]:SetShown(isRing and true or false) end

            btn.disabled = (o.disabled and o.disabled[key]) and true or false

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

-- ── Popup placement ─────────────────────────────────────────────────────────
-- Puts `frame` beside `anchor` on whichever side keeps it on screen.
--
-- A data bar can sit anywhere: along the top, along the bottom, or vertically
-- down either edge. A popup that always opens downward is fine for the first
-- and useless for the second, where it would hang off the bottom of the screen
-- (or, with SetClampedToScreen, get shoved back OVER the widget it belongs to,
-- covering the thing the cursor is on).
--
-- Both axes, from the anchor's own position:
--   * widget in the TOP half -> open downward; bottom half -> open upward.
--   * widget in the left third -> align left edges, so it extends RIGHT;
--     right third -> align right edges, so it extends LEFT; middle -> centred.
--
-- Thirds rather than halves horizontally, because the horizontal case is about
-- overflow rather than direction: a widget near the middle has room either way
-- and looks best centred, and only the outer thirds actually need to be pushed
-- inward. Clamping is still on as a backstop for a popup wider than the space
-- its third leaves.
local function AnchorNear(frame, anchor, gap)
    gap = gap or 4
    frame:ClearAllPoints()

    local cx, cy = anchor:GetCenter()
    local sw, sh = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
    if not (cx and cy) or sw == 0 or sh == 0 then
        -- No resolved rect yet (an anchor that has never been laid out): below
        -- is the conventional default and the clamp will rescue it.
        frame:SetPoint("TOP", anchor, "BOTTOM", 0, -gap)
        return
    end

    local openDown = cy >= sh / 2
    local mine  = openDown and "TOP" or "BOTTOM"
    local yours = openDown and "BOTTOM" or "TOP"

    if cx < sw / 3 then
        mine, yours = mine .. "LEFT", yours .. "LEFT"
    elseif cx > sw * 2 / 3 then
        mine, yours = mine .. "RIGHT", yours .. "RIGHT"
    end

    frame:SetPoint(mine, anchor, yours, 0, openDown and -gap or gap)
end

-- ── Tooltip ─────────────────────────────────────────────────────────────────
-- A themed hover popup for broker widgets.
--
-- Why not GameTooltip: it carries Blizzard's own art, so on a stock UI it is the
-- one surface in the addon that does not follow the theme. Under EllesmereUI it
-- happens to look right because EUI reskins the global tooltip -- which is
-- worse, not better, since it means the same code produces a consistent
-- rendering only when a particular other addon is installed.
--
-- **AddLine and AddDoubleLine take GameTooltip's exact signatures**, and that is
-- the point rather than a coincidence: a module writes ONE render function and
-- passes it either this or a real GameTooltip. That matters because the
-- fallback is not optional -- LDB display addons that do not support the
-- `OnEnter(anchor)` contract get `OnTooltipShow(tt)` with their own tooltip, and
-- without a shared signature every broker would need two copies of its tooltip
-- body, which is exactly the kind of divergence that rots.
--
-- Each caller owns an instance. A single shared one would be cheaper and only
-- ever one is on screen, but SocialStatus builds a persistent pool of custom
-- rows on `.inner`, and that cannot share a frame with the line API.
local TT_PAD, TT_LINE_H, TT_COL_GAP = 8, 14, 16

function W.Tooltip()
    local f = W.Panel(UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(200)
    f:SetClampedToScreen(true)
    f:Hide()

    -- Content goes on this child, never on `f`: W.Panel hands the frame to
    -- S.Panel, which enrols it in the restrip registry -- and dividers are
    -- Textures, exactly what the sweep alpha-zeroes (see the file header).
    local inner = CreateFrame("Frame", nil, f)
    inner:SetAllPoints()

    local o = { frame = f, inner = inner, lines = {}, dividers = {} }
    local count, divCount, cursor, widest = 0, 0, 0, 0

    local function EnsureLine(i)
        local line = o.lines[i]
        if line then return line end
        local row = CreateFrame("Frame", nil, inner)
        row:SetHeight(TT_LINE_H)
        local left = W.Font(row, 11, nil, 1)
        left:SetPoint("LEFT")
        left:SetJustifyH("LEFT")
        local right = W.Font(row, 11, nil, 1)
        right:SetPoint("RIGHT")
        right:SetJustifyH("RIGHT")
        line = { frame = row, left = left, right = right }
        o.lines[i] = line
        return line
    end

    local function EnsureDivider(i)
        local d = o.dividers[i]
        if d then return d end
        d = W.Tex(inner, "ARTWORK", 1, 1, 1, 0.12)
        d:SetHeight(1)
        o.dividers[i] = d
        return d
    end

    function o:Clear()
        for i = 1, #o.lines do o.lines[i].frame:Hide() end
        for i = 1, #o.dividers do o.dividers[i]:Hide() end
        count, divCount, cursor, widest = 0, 0, TT_PAD, 0
    end

    -- GameTooltip:AddLine(text, r, g, b) -- the trailing wrap argument is
    -- accepted and ignored, since these popups size to their content.
    function o:AddLine(text, r, g, b)
        count = count + 1
        local line = EnsureLine(count)
        line.left:SetText(text or "")
        line.left:SetTextColor(r or 1, g or 1, b or 1, 1)
        line.right:SetText("")
        line.frame:ClearAllPoints()
        line.frame:SetPoint("TOPLEFT", inner, "TOPLEFT", TT_PAD, -cursor)
        line.frame:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -TT_PAD, -cursor)
        line.frame:Show()
        cursor = cursor + TT_LINE_H
        local w = (line.left:GetStringWidth() or 0)
        if w > widest then widest = w end
    end

    function o:AddDoubleLine(textL, textR, lr, lg, lb, rr, rg, rb)
        count = count + 1
        local line = EnsureLine(count)
        line.left:SetText(textL or "")
        line.left:SetTextColor(lr or 1, lg or 1, lb or 1, 1)
        line.right:SetText(textR or "")
        line.right:SetTextColor(rr or 1, rg or 1, rb or 1, 1)
        line.frame:ClearAllPoints()
        line.frame:SetPoint("TOPLEFT", inner, "TOPLEFT", TT_PAD, -cursor)
        line.frame:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -TT_PAD, -cursor)
        line.frame:Show()
        cursor = cursor + TT_LINE_H
        local w = (line.left:GetStringWidth() or 0) + TT_COL_GAP
                + (line.right:GetStringWidth() or 0)
        if w > widest then widest = w end
    end

    function o:AddDivider()
        divCount = divCount + 1
        cursor = cursor + 3
        local d = EnsureDivider(divCount)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", inner, "TOPLEFT", TT_PAD, -cursor)
        d:SetPoint("TOPRIGHT", inner, "TOPRIGHT", -TT_PAD, -cursor)
        d:Show()
        cursor = cursor + 4
    end

    -- Placed on whichever side of the widget keeps it on screen (see
    -- AnchorNear): a bar along the bottom gets its tooltip above, one along the
    -- top gets it below, and a widget near either side edge has the tooltip
    -- extend inward rather than off the screen.
    --
    -- `point` overrides that entirely, for the one caller that has its own
    -- rule: GroupRoles' docked badge, whose direction is a user setting because
    -- it sits right under EllesmereUI's Raid Tools icon and which way it opens
    -- is a matter of what it would cover.
    function o:Show(anchor, point, relPoint, x, y)
        f:SetSize(widest + TT_PAD * 2, cursor + TT_PAD)
        if point then
            f:ClearAllPoints()
            f:SetPoint(point, anchor, relPoint or "BOTTOM", x or 0, y or 0)
        else
            AnchorNear(f, anchor)
        end
        f:Show()
    end

    function o:Hide() f:Hide() end
    function o:IsShown() return f:IsShown() end

    o:Clear()
    return o
end

-- ── Colour swatch (opens Blizzard's picker) ─────────────────────────────────
-- One clickable square that opens the game's own colour picker, alpha
-- included. Left-click picks, right-click resets.
--
-- Blizzard's picker rather than one of ours, because an RGB+alpha picker is a
-- lot of widget to own and the game ships a perfectly good one that players
-- already know. The call shape is the post-10.2.5 one
-- (SetupColorPickerAndShow, with `opacity` carrying the ALPHA and
-- GetColorAlpha reading it back) -- verified against AceGUI's own colour
-- picker, which keeps both the old and new forms side by side and so shows
-- exactly what changed. No legacy branch here: this addon targets current
-- retail only.
local function OpenColorPicker(r, g, b, a, onChange, onCancel)
    -- Both callbacks push the whole quad. They fire for different reasons --
    -- one for the wheel, one for the opacity slider -- but either way the
    -- current state is all four channels, and reading them together avoids a
    -- handler that knows only three and leaves the fourth stale.
    local function Push()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        onChange(nr, ng, nb, ColorPickerFrame:GetColorAlpha())
    end

    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ColorPickerFrame:SetClampedToScreen(true)
    ColorPickerFrame:SetupColorPickerAndShow({
        r = r, g = g, b = b,
        hasOpacity  = true,
        opacity     = a,
        swatchFunc  = Push,
        opacityFunc = Push,
        cancelFunc  = function() onCancel(r, g, b, a) end,
    })
end

function W.ColorSwatch(parent, size)
    size = size or 18

    local f = CreateFrame("Button", nil, parent)
    f:SetSize(size, size)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Mid-grey backing, so a translucent colour reads AS translucent: alpha
    -- shows up as the colour drifting toward the grey instead of the swatch
    -- quietly going darker with no clue why.
    local back = W.Tex(f, "BACKGROUND", 0.35, 0.35, 0.35, 1)
    back:SetPoint("TOPLEFT", 1, -1)
    back:SetPoint("BOTTOMRIGHT", -1, 1)

    local swatch = W.Tex(f, "ARTWORK", 1, 1, 1, 1)
    swatch:SetPoint("TOPLEFT", 1, -1)
    swatch:SetPoint("BOTTOMRIGHT", -1, 1)

    local edges = {}
    for i = 1, 4 do edges[i] = W.Tex(f, "OVERLAY", 1, 1, 1, 0.25) end
    edges[1]:SetPoint("TOPLEFT");    edges[1]:SetPoint("TOPRIGHT");    edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT");    edges[3]:SetPoint("BOTTOMLEFT");  edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT");   edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)

    local o = { frame = f, r = 1, g = 1, b = 1, a = 1 }

    function o:SetColor(r, g, b, a)
        o.r, o.g, o.b, o.a = r or 1, g or 1, b or 1, a == nil and 1 or a
        swatch:SetColorTexture(o.r, o.g, o.b, o.a)
    end
    function o:SetOnChange(fn) o._onChange = fn end
    function o:SetOnReset(fn) o._onReset = fn end

    f:SetScript("OnEnter", function()
        for i = 1, 4 do edges[i]:SetColorTexture(1, 1, 1, 0.5) end
    end)
    f:SetScript("OnLeave", function()
        for i = 1, 4 do edges[i]:SetColorTexture(1, 1, 1, 0.25) end
    end)
    f:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if o._onReset then o._onReset() end
            return
        end
        OpenColorPicker(o.r, o.g, o.b, o.a,
            function(r, g, b, a)
                o:SetColor(r, g, b, a == nil and o.a or a)
                if o._onChange then o._onChange(o.r, o.g, o.b, o.a) end
            end,
            function(r, g, b, a)
                o:SetColor(r, g, b, a)
                if o._onChange then o._onChange(r, g, b, a) end
            end)
    end)

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

-- ── Check mark ──────────────────────────────────────────────────────────────
-- The box itself, with no label and no hit area: ONE rendering of "this is on"
-- for every place that needs one -- the settings rows and the multi-select
-- menu both build on this rather than each drawing their own.
--
-- Shape is EllesmereUI's, taken from where EUI draws a checkbox from scratch
-- rather than from where it skins one (EllesmereUI_FirstInstall.lua:202-209):
-- a dark box with an accent-coloured square filling the middle half of it. Not
-- a checkmark glyph. S.Checkbox does tint Blizzard's check art in the accent,
-- but that call exists to strip a Blizzard CheckButton -- and the way to get
-- one here was to create Blizzard art purely so the engine could remove it,
-- which also could not be reused inside a menu row.
--
-- Nothing is hardcoded: the box is an S inset panel, so its fill and border
-- come from the theme, and the square is the live accent.
function W.CheckMark(parent, size)
    size = size or 12

    local f = W.Panel(parent, { inset = true })
    f:SetSize(size, size)

    -- The fill goes on a CHILD: `f` went through S.Panel and is therefore in
    -- the restrip registry (see the file header).
    local inner = CreateFrame("Frame", nil, f)
    inner:SetPoint("CENTER")
    inner:SetSize(math.floor(size / 2), math.floor(size / 2))
    inner:Hide()

    local fill = W.Tex(inner, "OVERLAY", W.Accent())
    fill:SetAllPoints()
    W.RegisterAccent(fill, "vertex")

    local o = { frame = f }
    function o:SetChecked(on) inner:SetShown(on and true or false) end
    return o
end

-- ── Checkbox ────────────────────────────────────────────────────────────────
-- W.CheckMark plus a label and a full-row hit area. The label is ours, so it
-- follows our text tokens.

function W.CheckBox(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(20)

    -- 12px box in a 20px row, EllesmereUI's own proportions.
    local box = W.CheckMark(f, 12)
    box.frame:SetPoint("LEFT", f, "LEFT", 6, 0)

    -- Anchored LEFT only, so the FontString sizes to its text. That is what
    -- lets a "?" marker sit immediately after the label instead of at the far
    -- side of the row -- a right anchor would stretch it across the width.
    local label = W.Font(f, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("LEFT", box.frame, "RIGHT", 6, 0)
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

-- The check column, for menus whose items are checkable. The same W.CheckMark
-- the settings rows use -- one rendering of "this is on" across the addon,
-- rather than a menu-only glyph that would drift from it. It carries no hit
-- area of its own: the whole row is the button, so there is one click target,
-- not two that do the same thing.
local function PaintCheck(item, on)
    item._check:SetChecked(on)
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

    local check = W.CheckMark(btn, 12)
    check.frame:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn._check = check

    local fs = W.Font(btn, 12, nil, W.DD_TXT_A)
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

-- Applies one entry to a pooled item. Entries are
--   { key, text, mode = "plain" | "check" | "header", checked, selected, onClick }
-- and every field is re-applied on each open, because items are pooled by
-- position and the item at index 3 is routinely a different thing (and a
-- different MODE) than it was last time the menu opened.
local CHECK_INDENT = 24

local function ApplyMenuEntry(item, entry)
    local mode = entry.mode or "plain"

    item._fs:ClearAllPoints()
    item._fs:SetPoint("LEFT", item, "LEFT", mode == "check" and CHECK_INDENT or 8, 0)
    item._fs:SetPoint("RIGHT", item, "RIGHT", -8, 0)
    item._fs:SetText(entry.text or "")
    item._hl:Hide()
    item._sel:SetShown(mode ~= "header" and entry.selected or false)

    -- The box is present for every checkable item, empty or filled -- it is the
    -- affordance that says the row is a toggle. Absent entirely for the other
    -- two modes, which are not.
    item._check.frame:SetShown(mode == "check")

    if mode == "header" then
        -- A caption, not a choice: mouse off, so it cannot be hovered or
        -- clicked, and tinted like every other section title in the panel.
        local r, g, b = W.Accent()
        item._fs:SetTextColor(r, g, b, 0.9)
        item:EnableMouse(false)
        item:SetScript("OnClick", nil)
        return
    end

    -- Disabled: visible but plainly inert, and NOT hidden. A choice that is
    -- missing leaves no explanation for why it is missing; a greyed one says
    -- "this exists, it just does not apply here" -- the same reasoning the
    -- accent swatches use for a preset the theme has taken over.
    if entry.disabled then
        PaintCheck(item, false)
        item._fs:SetTextColor(1, 1, 1, 0.3)
        item:EnableMouse(false)
        item:SetScript("OnClick", nil)
        return
    end

    item._fs:SetTextColor(1, 1, 1, W.DD_TXT_A)
    item:EnableMouse(true)
    PaintCheck(item, mode == "check" and entry.checked)
    item:SetScript("OnClick", function(self)
        if entry.onClick then entry.onClick(self) end
    end)
end

-- Opens the shared menu under `anchor`, populated from `entries`. Shared by
-- both dropdown flavours: the single-select one closes on a click, the
-- multi-select one does not, and that difference lives entirely in the
-- entries' own onClick handlers rather than in two copies of this.
local function OpenMenuAt(owner, anchor, entries)
    EnsureMenu()
    if menuOwner == owner and menu:IsShown() then
        HideMenu()
        return
    end
    HideMenu()
    menuOwner = owner

    local widest = anchor:GetWidth() or 0
    local count = #entries
    for i, entry in ipairs(entries) do
        local item = EnsureMenuItem(i)
        item:SetPoint("TOPLEFT", menuInner, "TOPLEFT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
        item:SetPoint("TOPRIGHT", menuInner, "TOPRIGHT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
        ApplyMenuEntry(item, entry)
        item:Show()
        local pad = (entry.mode == "check") and (CHECK_INDENT + 16) or 24
        local w = (item._fs:GetStringWidth() or 0) + pad
        if w > widest then widest = w end
    end
    for i = count + 1, #menuItems do menuItems[i]:Hide() end

    menu:SetWidth(widest)
    menu:SetHeight(MENU_PAD * 2 + count * MENU_ITEM_H)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    menuCatcher:Show()
    menu:Show()

    if owner._onOpened then owner._onOpened() end
end

-- ── Click popup ─────────────────────────────────────────────────────────────
-- A menu popped from an arbitrary frame -- a broker widget on a data bar --
-- rather than from a dropdown control.
--
-- This does NOT reuse the dropdown menu above, and the reason is that they are
-- two different controls in EllesmereUI too. Its dropdowns look like ours
-- already (the DD_ITEM_* constants here came from EUI's); its data bar block
-- popups are a separate thing with their own treatment, and that is what this
-- mirrors -- EllesmereUIDataBars_Blocks.lua's BuildPopup:
--
--   * a WHITE title, with the accent reserved for the ACTIVE row. Selection is
--     carried by the accent rather than by a check mark, which is what makes it
--     read as "you are here" rather than "these are ticked" -- the right idiom
--     for a list of mutually exclusive choices.
--   * hover tints the label ACCENT and washes the whole row white at 0.10.
--     Both, not one: the wash shows the hit area, the tint shows the target.
--   * icons cropped 4/64..60/64, the standard trim of Blizzard's baked icon
--     border. Inline |T escapes cannot crop, so spec icons would arrive wearing
--     their border -- which is why entries take an `icon` field rather than a
--     caller-formatted string.
--   * a footer of left/right hint pairs, the same shape EUI's tip footers use.
--
-- Metrics are EUI's: 8px padding, 18px rows, 3px between them, 14px icons.
local POPUP_PAD, POPUP_ROW_H, POPUP_ROW_GAP = 8, 18, 3
local POPUP_FONT, POPUP_ICON = 12, 14
local POPUP_TITLE_H = 18

local clickPopup, clickPopupInner, clickPopupCatcher
local popupRows, popupFooters = {}, {}
local popupTitle
local popupOwner, popupKey

local function HideClickPopup()
    if not clickPopup then return end
    clickPopup:Hide()
    if clickPopupCatcher then clickPopupCatcher:Hide() end
    popupOwner, popupKey = nil, nil
end
W.CloseMenu = HideClickPopup

local function EnsureClickPopup()
    if clickPopup then return end

    clickPopupCatcher = CreateFrame("Button", nil, UIParent)
    clickPopupCatcher:SetAllPoints(UIParent)
    clickPopupCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    clickPopupCatcher:SetFrameLevel(400)
    clickPopupCatcher:RegisterForClicks("AnyUp")

    -- The catcher covers the entire screen, which means it also covers the
    -- widget the popup belongs to -- so while a menu is open, clicking that
    -- widget again lands HERE and the widget's own handler never runs. That is
    -- why right-clicking for the loot menu while the spec menu was open did
    -- nothing but close it: the right-click was eaten, and a second click was
    -- needed to reach the widget at all.
    --
    -- So a click that lands on the owner is forwarded to it, button and all,
    -- and the owner's handler decides. Deliberately WITHOUT hiding first: the
    -- toggle test in W.Menu compares the menu key, so the same button closes
    -- (same key, already shown) while a different button switches (different
    -- key, reopens) -- one click either way.
    clickPopupCatcher:SetScript("OnClick", function(_, button)
        local owner = popupOwner
        if owner and owner:IsMouseOver() then
            local handler = owner:GetScript("OnClick")
            if handler then
                handler(owner, button)
                return
            end
        end
        HideClickPopup()
    end)

    clickPopupCatcher:Hide()

    clickPopup = W.Panel(UIParent)
    clickPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    clickPopup:SetFrameLevel(410)
    clickPopup:SetClampedToScreen(true)
    clickPopup:EnableMouse(true)
    clickPopup:Hide()

    -- Content on a child: `clickPopup` went through S.Panel (see the header).
    clickPopupInner = CreateFrame("Frame", nil, clickPopup)
    clickPopupInner:SetAllPoints()

    popupTitle = W.Font(clickPopupInner, POPUP_FONT, nil, 1)
    popupTitle:SetPoint("TOPLEFT", clickPopupInner, "TOPLEFT", POPUP_PAD, -POPUP_PAD)
end

local function EnsurePopupRow(index)
    local row = popupRows[index]
    if row then return row end

    local btn = CreateFrame("Button", nil, clickPopupInner)
    btn:SetHeight(POPUP_ROW_H)
    btn:RegisterForClicks("AnyUp")

    local hl = W.Tex(btn, "HIGHLIGHT", 1, 1, 1, 0.10)
    hl:SetAllPoints()

    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetSize(POPUP_ICON, POPUP_ICON)
    icon:SetPoint("LEFT")
    -- Trims the border Blizzard bakes into icon art, so a spec icon sits flush
    -- with the label instead of inside a frame of its own.
    icon:SetTexCoord(4 / 64, 60 / 64, 4 / 64, 60 / 64)

    local label = W.Font(btn, POPUP_FONT, nil, 1)

    row = { frame = btn, icon = icon, label = label }
    popupRows[index] = row
    return row
end

local function EnsurePopupFooter(index)
    local foot = popupFooters[index]
    if foot then return foot end
    foot = {
        left  = W.Font(clickPopupInner, POPUP_FONT, nil, 1),
        right = W.Font(clickPopupInner, POPUP_FONT, nil, 1),
    }
    popupFooters[index] = foot
    return foot
end

-- `entries`: { text, icon, active, onClick }
-- `opts`:    { title = "...", footer = { { "Left-click", "Choose spec" }, ... } }
function W.Menu(anchor, entries, opts)
    EnsureClickPopup()
    opts = opts or {}
    entries = entries or {}

    -- Toggle on the same MENU, switch on a different one.
    --
    -- Keyed by anchor plus `opts.key`, not by anchor alone: one widget can own
    -- several menus (SpecSwitch has three -- spec, loadout, loot), and keying
    -- on the widget made them all the same thing, so asking for the loot menu
    -- while the spec menu was open just closed it. Callers that pass no key
    -- get one menu per widget, which is the single-menu case behaving as
    -- before.
    local key = opts.key or true
    if popupOwner == anchor and popupKey == key and clickPopup:IsShown() then
        HideClickPopup()
        return
    end
    popupOwner, popupKey = anchor, key

    local ar, ag, ab = W.Accent()
    local widest, y = 0, POPUP_PAD

    if opts.title and opts.title ~= "" then
        popupTitle:SetText(opts.title)
        popupTitle:Show()
        widest = popupTitle:GetStringWidth() or 0
        y = POPUP_PAD + POPUP_TITLE_H + POPUP_PAD
    else
        popupTitle:Hide()
    end

    for i, entry in ipairs(entries) do
        local row = EnsurePopupRow(i)
        row.frame:ClearAllPoints()
        row.frame:SetPoint("TOPLEFT", clickPopupInner, "TOPLEFT", POPUP_PAD, -y)

        local iconWidth = 0
        row.label:ClearAllPoints()
        if entry.icon then
            row.icon:SetTexture(entry.icon)
            row.icon:Show()
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
            iconWidth = POPUP_ICON + 4
        else
            -- Flush left, not anchored to the hidden icon: its stale rect would
            -- leave a phantom indent.
            row.icon:Hide()
            row.label:SetPoint("LEFT", row.frame, "LEFT", 0, 0)
        end

        row.label:SetText(entry.text or "")
        if entry.active then
            row.label:SetTextColor(ar, ag, ab, 1)
        else
            row.label:SetTextColor(1, 1, 1, 1)
        end

        row.frame:SetScript("OnEnter", function()
            row.label:SetTextColor(W.Accent())
        end)
        row.frame:SetScript("OnLeave", function()
            if entry.active then
                row.label:SetTextColor(W.Accent())
            else
                row.label:SetTextColor(1, 1, 1, 1)
            end
        end)
        row.frame:SetScript("OnClick", function()
            HideClickPopup()
            if entry.onClick then entry.onClick() end
        end)
        row.frame:Show()

        local w = iconWidth + (row.label:GetStringWidth() or 0)
        if w > widest then widest = w end
        y = y + POPUP_ROW_H + POPUP_ROW_GAP
    end
    if #entries > 0 then y = y - POPUP_ROW_GAP end
    for i = #entries + 1, #popupRows do popupRows[i].frame:Hide() end

    local footer = opts.footer or {}
    if #footer > 0 then
        y = y + 8
        for i, pair in ipairs(footer) do
            local foot = EnsurePopupFooter(i)
            foot.left:SetText(pair[1] or "")
            foot.right:SetText(pair[2] or "")
            foot.left:ClearAllPoints()
            foot.left:SetPoint("TOPLEFT", clickPopupInner, "TOPLEFT", POPUP_PAD, -y)
            foot.right:ClearAllPoints()
            foot.right:SetPoint("TOPRIGHT", clickPopupInner, "TOPRIGHT", -POPUP_PAD, -y)
            foot.left:Show()
            foot.right:Show()
            local fw = (foot.left:GetStringWidth() or 0) + 16 + (foot.right:GetStringWidth() or 0)
            if fw > widest then widest = fw end
            y = y + POPUP_FONT + 4
        end
        y = y - 4
    end
    for i = #footer + 1, #popupFooters do
        popupFooters[i].left:Hide()
        popupFooters[i].right:Hide()
    end

    clickPopup:SetSize(widest + POPUP_PAD * 2, y + POPUP_PAD)
    -- Rows span the full inner width, so the hover wash and the hit area cover
    -- the row rather than just its text.
    for i = 1, #entries do popupRows[i].frame:SetWidth(widest) end

    -- Same placement rule as the hover tooltip, so a widget's menu and its
    -- tooltip appear on the same side of it rather than disagreeing. This used
    -- to flip vertically only, which left a menu opened from a widget at the
    -- far right of a bar running off the screen edge.
    AnchorNear(clickPopup, anchor)

    clickPopupCatcher:Show()
    clickPopup:Show()
end

-- The closed-state chrome both dropdown flavours wear: house block, border,
-- left-aligned text and a caret.
local function BuildDropdownFace(parent, width)
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

    local function Hover(on)
        local a = on and W.DD_TXT_HA or W.DD_TXT_A
        text:SetTextColor(1, 1, 1, a)
        caret:SetTextColor(1, 1, 1, a)
    end
    f:SetScript("OnEnter", function() Hover(true) end)
    f:SetScript("OnLeave", function() Hover(false) end)
    Hover(false)

    return f, text
end

function W.Dropdown(parent, width)
    local f, text = BuildDropdownFace(parent, width)

    local o = { frame = f, list = {}, order = {} }

    local function OpenMenu()
        local entries = {}
        for i, key in ipairs(o.order) do
            entries[i] = {
                text = o.list[key] or tostring(key),
                selected = (key == o.value),
                disabled = o.disabled and o.disabled[key] or false,
                onClick = function()
                    o:SetValue(key)
                    HideMenu()
                    if o._onChange then o._onChange(key) end
                end,
            }
        end
        OpenMenuAt(o, f, entries)
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
    -- A set of keys to render inert. Re-pushed on every refresh, since what is
    -- unavailable can change while the panel is open (an addon finishing its
    -- load, say).
    function o:SetDisabled(set) o.disabled = set end
    function o:GetValue() return o.value end
    function o:SetOnChange(fn) o._onChange = fn end
    function o:SetOnOpened(fn) o._onOpened = fn end
    function o:SetOnClosed(fn) o._onClosed = fn end
    function o:IsOpen() return menuOwner == o and menu and menu:IsShown() end

    return o
end

-- ── Multi-select dropdown ───────────────────────────────────────────────────
-- The same face as a dropdown, but every item carries a tick and clicking one
-- toggles it WITHOUT closing the menu -- so picking four widgets is four
-- clicks, not four open/close cycles. EllesmereUI's data bar picks its blocks
-- this way and it is the right shape here for the same reason: the question
-- is "which of these", not "which one".
--
-- It also removes a whole class of layout churn. The list this replaced put
-- one panel row per registered broker, so ticking a box changed the number of
-- rows in the section and forced a rebuild of it -- with the third-party fold
-- expanded that was a dozen rows appearing and disappearing under the cursor.
-- Here the choices live in a popup and the panel's own shape never moves.
--
-- `items` is an ordered array of { key, text, header = true }. Headers are
-- captions, not choices, which is what lets one menu carry "AniMods" and
-- "Other addons" groups without a second control to expand either.
function W.MultiSelect(parent, width)
    local f, text = BuildDropdownFace(parent, width)

    local o = { frame = f, items = {} }

    local function OpenMenu()
        local entries = {}
        for i, item in ipairs(o.items) do
            if item.header then
                entries[i] = { mode = "header", text = item.text }
            else
                local key = item.key
                entries[i] = {
                    mode = "check",
                    text = item.text,
                    checked = o._isChecked and o._isChecked(key) or false,
                    -- Repaints the tick on the clicked item in place. The menu
                    -- stays open, so nothing else re-reads the state -- and a
                    -- full repopulate here would rebuild the very item whose
                    -- OnClick is still running.
                    onClick = function(menuItem)
                        local on = not (o._isChecked and o._isChecked(key))
                        if o._onToggle then o._onToggle(key, on) end
                        PaintCheck(menuItem, on)
                    end,
                }
            end
        end
        OpenMenuAt(o, f, entries)
    end

    f:SetScript("OnClick", OpenMenu)
    f:SetScript("OnHide", function()
        if menuOwner == o then HideMenu() end
    end)

    function o:SetItems(items) o.items = items or {} end
    function o:SetIsChecked(fn) o._isChecked = fn end
    function o:SetOnToggle(fn) o._onToggle = fn end
    function o:SetText(t) text:SetText(t or "") end
    function o:SetOnOpened(fn) o._onOpened = fn end
    function o:SetOnClosed(fn) o._onClosed = fn end
    function o:IsOpen() return menuOwner == o and menu and menu:IsShown() end

    return o
end

-- ── Order strip ─────────────────────────────────────────────────────────────
-- A live preview of the data bar: one cell per widget, in bar order, dragged
-- to reorder.
--
-- Cells are EQUAL WIDTH and fill the strip, because that is exactly what the
-- bar does with them -- so this is a scale model of the result rather than a
-- list that happens to be horizontal. Long names truncate here for the same
-- reason they truncate there.
--
-- Equal width also makes the drag stable. Cells sized to their own text would
-- re-flow on every swap, sliding the neighbours out from under the cursor and
-- triggering the next swap on their own -- a single drag could cascade through
-- the whole strip. Uniform cells never move when their contents change.
--
-- The drag is a SWAP, not a floating ghost: press on a cell, move over another,
-- and the two exchange places. That needs no OnUpdate to follow the cursor --
-- moving over a cell is an OnEnter, which is the event that does the work.
-- Nothing here polls.
local CHIP_H = 20
local CHIP_GAP = 3
local CHIP_MIN_W = 30

function W.OrderStrip(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(CHIP_H)

    local o = { frame = f, chips = {}, order = {}, labels = {}, tips = {} }
    local dragging = nil   -- INDEX being dragged, not a name: cells are pooled
                           -- by position and hold whatever is at that position.

    local empty = W.Font(f, 12, nil, W.TEXT_DIM_A)
    empty:SetPoint("LEFT", f, "LEFT", 4, 0)
    empty:SetText("No widgets on the bar")

    local function Paint(chip)
        if not chip._index then return end
        if dragging == chip._index then
            local r, g, b = W.Accent()
            chip.bg:SetColorTexture(r, g, b, 0.35)
            chip.fs:SetTextColor(1, 1, 1, 1)
        elseif chip:IsMouseOver() then
            chip.bg:SetColorTexture(1, 1, 1, 0.14)
            chip.fs:SetTextColor(1, 1, 1, 1)
        else
            chip.bg:SetColorTexture(1, 1, 1, 0.08)
            chip.fs:SetTextColor(1, 1, 1, W.TEXT_DIM_A)
        end
    end

    local function PaintAll()
        for _, chip in ipairs(o.chips) do
            if chip:IsShown() then Paint(chip) end
        end
    end

    local Layout

    local function Swap(a, b)
        o.order[a], o.order[b] = o.order[b], o.order[a]
        -- The dragged item is now at `b`, so the drag follows it there. Without
        -- this the next OnEnter would compare against a stale index and swap
        -- the wrong pair.
        dragging = b
        Layout()
        -- Applied as it happens rather than on drop, so the real bar reorders
        -- under the cursor. Deliberately does NOT refresh the panel: that would
        -- rebuild this strip mid-drag and the cell holding the drag would go
        -- away before its OnDragStop could fire.
        if o._onReorder then o._onReorder(o.order) end
    end

    local function EnsureChip(index)
        local chip = o.chips[index]
        if chip then return chip end

        chip = CreateFrame("Button", nil, f)
        chip:SetHeight(CHIP_H)
        chip:RegisterForDrag("LeftButton")

        chip.bg = W.Tex(chip, "BACKGROUND", 1, 1, 1, 0.08)
        chip.bg:SetAllPoints()

        chip.fs = W.Font(chip, 11, nil, W.TEXT_DIM_A)
        chip.fs:SetPoint("CENTER")
        chip.fs:SetJustifyH("CENTER")
        chip.fs:SetWordWrap(false)

        chip:SetScript("OnDragStart", function(self)
            dragging = self._index
            PaintAll()
        end)
        chip:SetScript("OnDragStop", function()
            dragging = nil
            PaintAll()
            -- One panel refresh, at the end of the gesture.
            if o._onDrop then o._onDrop(o.order) end
        end)
        chip:SetScript("OnEnter", function(self)
            if dragging then
                if dragging ~= self._index then Swap(dragging, self._index) end
                PaintAll()
                return
            end
            PaintAll()
            -- Only at rest. A tooltip chasing the cursor through a drag would
            -- sit on top of the cells being dropped onto.
            local tip = o.tips[o.order[self._index]]
            if tip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(tip, 1, 1, 1, 1, true)
                GameTooltip:AddLine("Drag to reorder", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end
        end)
        chip:SetScript("OnLeave", function()
            GameTooltip:Hide()
            PaintAll()
        end)

        o.chips[index] = chip
        return chip
    end

    Layout = function()
        local n = #o.order
        empty:SetShown(n == 0)

        local total = f:GetWidth() or 0
        -- Before the panel has resolved a width there is nothing to divide;
        -- RelayoutContent runs again once it has.
        local cellW = (n > 0) and math.max(CHIP_MIN_W, (total - CHIP_GAP * (n - 1)) / n) or 0

        for i = 1, n do
            local chip = EnsureChip(i)
            chip._index = i
            chip.fs:SetText(o.labels[o.order[i]] or o.order[i])
            chip.fs:SetWidth(math.max(cellW - 8, 1))
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", f, "LEFT", (i - 1) * (cellW + CHIP_GAP), 0)
            chip:SetWidth(cellW)
            chip:Show()
            Paint(chip)
        end
        for i = n + 1, #o.chips do
            o.chips[i]:Hide()
            o.chips[i]._index = nil
        end
    end

    -- Ignored while a drag is in flight: the panel refreshing underneath a
    -- gesture would replace the order being edited with the one it was read
    -- from.
    function o:SetList(order, labels, tips)
        if dragging then return end
        o.order, o.labels, o.tips = order or {}, labels or {}, tips or {}
        Layout()
    end
    function o:Relayout() if not dragging then Layout() end end
    function o:SetOnReorder(fn) o._onReorder = fn end
    function o:SetOnDrop(fn) o._onDrop = fn end

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

-- ── Text box ────────────────────────────────────────────────────────────────
-- A window holding one multiline, copy-pasteable field.
--
-- Both directions of an import/export string want the same widget: an export
-- pre-fills it and selects everything so Ctrl+C works without aiming, an import
-- starts empty and hands whatever was pasted to an action button. The only
-- difference is whether `action` is set.
--
-- opts = {
--   title    = window title
--   text     = initial contents
--   action   = label for the action button; omit for a read-only box
--   onAction = function(text) -> ok, message   -- message is shown in the footer
-- }
--
-- Built ONCE and reconfigured per call. It was built fresh every time, which
-- left a new window behind on every click and passed nil where W.Window wanted
-- a global name -- UISpecialFrames holds names, so that indexed _G with nil and
-- threw. One named window fixes all three: no leak, Esc closes it, and the
-- second "Show" reuses the first one's frame.
local textBox

function W.TextBox(opts)
    opts = opts or {}
    local PAD, BTN_H, GAP = 12, 22, 8

    if textBox then
        textBox:Configure(opts)
        return textBox
    end

    local win = W.Window("AniModsTextBox", opts.title or "", opts.width or 620, opts.height or 440)
    local body = win.content

    -- The field surface goes on a child frame. `win` is restrip-registered, so
    -- a texture drawn straight onto it would be alpha-zeroed.
    local box = CreateFrame("Frame", nil, body)
    box:SetPoint("TOPLEFT", PAD, -PAD)
    box:SetPoint("BOTTOMRIGHT", -PAD, PAD + BTN_H + GAP)
    local bg = W.Tex(box, "BACKGROUND", 1, 1, 1, 0.05)
    bg:SetAllPoints()

    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -6, 6)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)
    -- The scroll child has no width of its own; without this the text never
    -- wraps and a 4 KB export string becomes one unreadable line.
    scroll:SetScript("OnSizeChanged", function(_, w) edit:SetWidth(w) end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (edit:GetHeight() or 0) - (self:GetHeight() or 0))
        local target = self:GetVerticalScroll() - delta * 28
        if target < 0 then target = 0 end
        if target > maxScroll then target = maxScroll end
        self:SetVerticalScroll(target)
    end)

    local status = W.Font(body, 11, nil, W.TEXT_DIM_A)
    status:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", PAD, PAD + 4)

    local close = W.Button(body, 90, BTN_H)
    close.frame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -PAD, PAD)
    close:SetText("Close")
    close:SetOnClick(function() win:Hide() end)

    -- Always built, shown only when this call wants one. Creating it on demand
    -- would mean the reused window could never grow an action button it did not
    -- have the first time.
    local act = W.Button(body, 120, BTN_H)
    act.frame:SetPoint("RIGHT", close.frame, "LEFT", -GAP, 0)

    -- Everything that varies between calls lives here, so the window has
    -- exactly one place that knows how to become a different window.
    function win:Configure(o)
        win.titleText:SetText(o.title or "")
        status:SetText("")

        if o.action then
            act:SetText(o.action)
            act:SetOnClick(function()
                if not o.onAction then return end
                local ok, msg = o.onAction(edit:GetText() or "")
                status:SetText(msg or "")
                status:SetTextColor(ok and 0.45 or 1, ok and 0.9 or 0.35, ok and 0.45 or 0.35, 1)
            end)
            act.frame:Show()
        else
            -- Cleared as well as hidden: a stale handler on a hidden button is
            -- the kind of thing that fires again the next time it is shown.
            act:SetOnClick(nil)
            act.frame:Hide()
        end

        edit:SetText(o.text or "")
        win:Show()
        -- Select everything on an export so the user can copy without aiming.
        if o.text and o.text ~= "" then
            edit:SetFocus()
            edit:HighlightText()
        else
            edit:ClearFocus()
        end
    end

    win.edit = edit
    textBox = win
    win:Configure(opts)
    return win
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

    -- DIALOG, and toplevel.
    --
    -- HIGH was the problem: Northern Sky Raid Tools' main window is HIGH too
    -- (its UI/Core.lua), so the two interleaved by frame level -- NSRT's rows
    -- drawing between this window's background and its own cards, which reads
    -- as one window shredded through another rather than as two windows.
    --
    -- DIALOG clears NSRT's main window outright and puts this level with its
    -- sub-panels, where SetToplevel settles it properly: a toplevel frame is
    -- raised to the top of its strata when clicked, so whichever window you are
    -- actually using is the one in front.
    --
    -- Deliberately NOT FULLSCREEN_DIALOG, which is what EllesmereUI's own
    -- options windows use and would have been the obvious suite-matching
    -- choice. That is the strata of THIS addon's dropdown menus, click menus
    -- and popups: raising the window into it would let the window cover its own
    -- open dropdown. Our layering stays strictly ordered instead --
    -- DIALOG window < FULLSCREEN_DIALOG menus < TOOLTIP hover popups -- and no
    -- Raise() within DIALOG can disturb it.
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
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
    -- Exposed so a reusable window can be retitled instead of rebuilt.
    f.titleText = title

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

    -- Esc closes it, matching every other panel in the game. UISpecialFrames
    -- holds GLOBAL NAMES, so this only works for a window that has one --
    -- an anonymous window silently goes without rather than indexing _G with
    -- nil, which is what it used to do.
    if name then
        _G[name] = f
        tinsert(UISpecialFrames, name)
    end

    f.titleBar = titleBar
    return f
end
