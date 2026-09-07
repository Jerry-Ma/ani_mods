-- AniMods widget toolkit -- hand-rolled panel chrome that matches
-- EllesmereUI's look.
--
-- Why hand-rolled rather than a library: every options panel in this
-- install that reads as "modern" is hand-rolled (EllesmereUIOptions,
-- DandersFrames_Options, MidnightRoutine, ClickableRaidBuffs), and the one
-- that reads as dated uses stock Blizzard templates. AceGUI's widgets are
-- Blizzard-template-derived, which is the look being escaped -- no amount
-- of layout tuning fixes that. (ClickableRaidBuffs *ships* AceGUI in its
-- Libs and never references it; an earlier version of this addon cited it
-- as precedent for using AceGUI, which was simply wrong.)
--
-- Two-tier: when EllesmereUI is loaded, its own public primitives do the
-- drawing (MakeBorder for pixel-snapped 1px borders, PanelPP for
-- pixel-perfect sizing, MakeFont for its configured font, RegAccent so this
-- panel recolors live with the user's accent/class color). When it isn't,
-- the fallbacks below draw the same thing with the same literal colors --
-- copied from EllesmereUI.lua's own palette block (lines 72-208) -- so the
-- panel looks the same either way; what's lost without EUI is only pixel
-- snapping and live accent updates.

local AniMods = _G.AniMods

local W = {}
AniMods.W = W

-- ── Palette (EllesmereUI.lua:72-208) ────────────────────────────────────────

W.PANEL_BG  = { 0.05, 0.07, 0.09 }
W.CARD_BG   = { 0.075, 0.09, 0.11 }
W.CB_BOX    = { 0.10, 0.12, 0.16 }   -- checkbox box background
W.DD_BG     = { 0.075, 0.113, 0.141 } -- dropdown background
W.BTN_BG    = { 0.061, 0.095, 0.120 }
W.INPUT_BG  = { 0.02, 0.03, 0.04 }

W.BORDER_A      = 0.15   -- panel chrome border alpha (white)
W.CB_BRD_A      = 0.05   -- checkbox border, unchecked
W.CB_ACT_BRD_A  = 0.15   -- checkbox border, checked (accent-colored)
W.DD_BRD_A      = 0.20
W.DD_BRD_HA     = 0.30
W.DD_TXT_A      = 0.50
W.DD_TXT_HA     = 0.60
W.DD_ITEM_HL_A  = 0.08   -- menu item hover
W.DD_ITEM_SEL_A = 0.04   -- menu item current selection
W.BTN_BRD_A     = 0.30
W.BTN_BRD_HA    = 0.45
W.BTN_TXT_A     = 0.55
W.BTN_TXT_HA    = 0.70
W.SL_TRACK_A    = 0.16
W.SL_FILL_A     = 0.75

W.TEXT_A        = 1.00
W.TEXT_DIM_A    = 0.53
W.TEXT_SECTION_A = 0.41
W.ROW_BG_ODD    = 0.10   -- black overlay alpha
W.ROW_BG_EVEN   = 0.20

-- ── EllesmereUI bridges (all optional) ──────────────────────────────────────

local function EUI()
    return _G.EllesmereUI
end

-- The user's live accent color, or EllesmereUI's own default green.
function W.Accent()
    local eui = EUI()
    if eui and eui.GetAccentColor then
        local ok, r, g, b = pcall(eui.GetAccentColor)
        if ok and r then return r, g, b end
    end
    return 0.05, 0.82, 0.62
end

-- Registers a region for live accent recoloring, so this panel follows a
-- theme change without a reload. `kind` is "vertex" for a Texture or "text"
-- for a FontString.
--
-- EUI's UpdateAccentElements only handles obj-based entries of type solid /
-- gradient / vertex, plus a `callback` type -- there is no font branch, so a
-- FontString has to go through a callback that sets its text color itself.
-- (Registering one as a text/font type instead fails silently: the entry
-- just never matches a branch, and the color quietly stops tracking the
-- theme.)
function W.RegisterAccent(region, kind)
    local eui = EUI()
    if not (eui and eui.RegAccent) then return end

    if kind == "text" then
        pcall(eui.RegAccent, {
            type = "callback",
            fn = function(r, g, b) region:SetTextColor(r, g, b, 1) end,
        })
    else
        pcall(eui.RegAccent, { obj = region, type = "vertex" })
    end
end

-- `addonKey` picks a specific EUI module's configured font (e.g. "minimap"),
-- matching what that part of EUI draws with; omit it for the global one.
function W.FontPath(addonKey)
    local eui = EUI()
    if eui and eui.GetFontPath then
        local ok, path = pcall(eui.GetFontPath, addonKey)
        if ok and path then return path end
    end
    return (eui and eui.EXPRESSWAY) or "Fonts\\FRIZQT__.TTF"
end

function W.Font(parent, size, flags, alpha, addonKey)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(W.FontPath(addonKey), size or 12, flags or "")
    fs:SetTextColor(1, 1, 1, alpha or W.TEXT_A)
    return fs
end

-- ── Icon resolution ─────────────────────────────────────────────────────────
-- Atlas names get renamed and removed between patches, and a missing one
-- draws nothing at all with no error -- which is exactly how the guild icon
-- silently went blank. Anything picking an atlas should check it first
-- rather than trusting a name that merely appears in some list.

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

function W.Tex(parent, layer, r, g, b, a)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetColorTexture(r, g, b, a or 1)
    local eui = EUI()
    if eui and eui.DisablePixelSnap then pcall(eui.DisablePixelSnap, tex) end
    return tex
end

-- 1px border. EUI's MakeBorder is pixel-snapped and rescales with the UI;
-- the fallback is a plain 1px BackdropTemplate edge in the same color.
-- Returns a table with SetColor(self, r, g, b, a) either way.
function W.Border(frame, r, g, b, a)
    local eui = EUI()
    if eui and eui.MakeBorder then
        local ok, border = pcall(eui.MakeBorder, frame, r, g, b, a, eui.PanelPP)
        if ok and border then return border end
    end

    local bf = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    bf:SetAllPoints(frame)
    bf:SetFrameLevel(frame:GetFrameLevel() + 1)
    bf:EnableMouse(false)
    bf:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    bf:SetBackdropBorderColor(r or 1, g or 1, b or 1, a or 1)
    return {
        _frame = bf,
        SetColor = function(_, cr, cg, cb, ca)
            bf:SetBackdropBorderColor(cr, cg, cb, ca or 1)
        end,
    }
end

-- A background+border panel, the base of every surface here.
function W.Panel(parent, bg, borderAlpha)
    local f = CreateFrame("Frame", nil, parent)
    bg = bg or W.PANEL_BG
    f._bg = W.Tex(f, "BACKGROUND", bg[1], bg[2], bg[3], bg[4] or 1)
    f._bg:SetAllPoints()
    f._border = W.Border(f, 1, 1, 1, borderAlpha or W.BORDER_A)
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
    -- Alternating stripe, matching EUI's option rows.
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

-- ── Checkbox ────────────────────────────────────────────────────────────────
-- Same construction as EllesmereUI's (EllesmereUI_Widgets.lua:263-296): a
-- small solid box with a 1px border, filled with the accent color when on,
-- dimmed when idle. No Blizzard template.

function W.CheckBox(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(20)

    local box = CreateFrame("Frame", nil, f)
    box:SetSize(16, 16)
    box:SetPoint("LEFT", f, "LEFT", 8, 0)
    local boxBg = W.Tex(box, "BACKGROUND", W.CB_BOX[1], W.CB_BOX[2], W.CB_BOX[3], 1)
    boxBg:SetAllPoints()
    local boxBorder = W.Border(box, 1, 1, 1, W.CB_BRD_A)

    local fill = W.Tex(box, "ARTWORK", W.Accent())
    fill:SetPoint("TOPLEFT", box, "TOPLEFT", 2, -2)
    fill:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -2, 2)
    fill:Hide()
    W.RegisterAccent(fill, "vertex")

    local label = W.Font(f, 12, nil, W.TEXT_DIM_A)
    label:SetPoint("LEFT", box, "RIGHT", 8, 0)
    label:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    label:SetJustifyH("LEFT")

    local o = { frame = f, checked = false }

    local function ApplyVisual(hovering)
        if o.checked then
            fill:Show()
            fill:SetAlpha(hovering and 1 or 0.85)
            local r, g, b = W.Accent()
            boxBorder:SetColor(r, g, b, W.CB_ACT_BRD_A + 0.25)
        else
            fill:Hide()
            boxBorder:SetColor(1, 1, 1, hovering and (W.CB_BRD_A + 0.15) or W.CB_BRD_A)
        end
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

local menu, menuCatcher
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

local function EnsureMenu()
    if menu then return menu end

    menuCatcher = CreateFrame("Button", nil, UIParent)
    menuCatcher:SetAllPoints(UIParent)
    menuCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
    menuCatcher:SetFrameLevel(500)
    menuCatcher:RegisterForClicks("AnyUp")
    menuCatcher:SetScript("OnClick", HideMenu)
    menuCatcher:Hide()

    menu = W.Panel(UIParent, W.DD_BG, W.DD_BRD_HA)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(510)
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:Hide()

    return menu
end

local MENU_ITEM_H, MENU_PAD = 18, 6

local function EnsureMenuItem(index)
    if menuItems[index] then return menuItems[index] end
    local btn = CreateFrame("Button", nil, menu)
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

    local bg = W.Tex(f, "BACKGROUND", W.DD_BG[1], W.DD_BG[2], W.DD_BG[3], 0.9)
    bg:SetAllPoints()
    local border = W.Border(f, 1, 1, 1, W.DD_BRD_A)

    local text = W.Font(f, 12, nil, W.DD_TXT_A)
    text:SetPoint("LEFT", f, "LEFT", 8, 0)
    text:SetPoint("RIGHT", f, "RIGHT", -22, 0)
    text:SetJustifyH("LEFT")

    -- EUI ships the arrow art; without it a plain caret glyph reads the same.
    local arrow
    local eui = EUI()
    if eui and eui.MakeDropdownArrow then
        local ok, a = pcall(eui.MakeDropdownArrow, f, 6, eui.PanelPP)
        if ok then arrow = a end
    end
    -- `arrow` exists only to answer "did EUI give us one" -- nothing below
    -- needs a handle on either it or the caret, since both are anchored to
    -- `f` and never touched again.
    if not arrow then
        local caret = W.Font(f, 10, nil, W.DD_TXT_A)
        caret:SetPoint("RIGHT", f, "RIGHT", -8, 0)
        caret:SetText("\226\150\188") -- U+25BC
    end

    local o = { frame = f, list = {}, order = {} }

    local function Hover(on)
        bg:SetColorTexture(W.DD_BG[1], W.DD_BG[2], W.DD_BG[3], on and 0.98 or 0.9)
        border:SetColor(1, 1, 1, on and W.DD_BRD_HA or W.DD_BRD_A)
        text:SetTextColor(1, 1, 1, on and W.DD_TXT_HA or W.DD_TXT_A)
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
            item:SetPoint("TOPLEFT", menu, "TOPLEFT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
            item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", 0, -(MENU_PAD + (i - 1) * MENU_ITEM_H))
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
        -- Mirrors AceGUI's Dropdown_OnHide: a menu whose owner just went
        -- away must not be left floating over the screen.
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
-- Track + accent fill + square thumb + numeric readout, matching EUI's
-- (EllesmereUI_Widgets.lua BuildSliderCore) without its editbox/snap extras.

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

    local o = { frame = f, slider = slider }

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

function W.Button(parent, width, height)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(width or 120, height or 22)
    f:RegisterForClicks("AnyUp")

    local bg = W.Tex(f, "BACKGROUND", W.BTN_BG[1], W.BTN_BG[2], W.BTN_BG[3], 0.6)
    bg:SetAllPoints()
    local border = W.Border(f, 1, 1, 1, W.BTN_BRD_A)

    local fs = W.Font(f, 12, nil, W.BTN_TXT_A)
    fs:SetPoint("CENTER")

    local o = { frame = f }
    local function Hover(on)
        bg:SetColorTexture(W.BTN_BG[1], W.BTN_BG[2], W.BTN_BG[3], on and 0.65 or 0.6)
        border:SetColor(1, 1, 1, on and W.BTN_BRD_HA or W.BTN_BRD_A)
        fs:SetTextColor(1, 1, 1, on and W.BTN_TXT_HA or W.BTN_TXT_A)
    end
    f:SetScript("OnEnter", function() Hover(true) end)
    f:SetScript("OnLeave", function() Hover(false) end)
    f:SetScript("OnClick", function() if o._onClick then o._onClick() end end)

    function o:SetText(text) fs:SetText(text or "") end
    function o:SetOnClick(fn) o._onClick = fn end

    Hover(false)
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
-- instead of UIPanelScrollFrameTemplate's chunky stock bar.

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
-- Movable, Esc-closable panel with a title bar and close button.

function W.Window(name, titleText, width, height)
    local f = W.Panel(UIParent, W.PANEL_BG, W.BORDER_A)
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

    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetHeight(30)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")

    local title = W.Font(titleBar, 14, nil, 1)
    title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
    title:SetText(titleText or "")
    local ar, ag, ab = W.Accent()
    title:SetTextColor(ar, ag, ab, 1)
    W.RegisterAccent(title, "text")

    local rule = W.Tex(titleBar, "ARTWORK", 1, 1, 1, W.BORDER_A)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")

    local close = W.Button(titleBar, 22, 20)
    close:SetText("\195\151") -- U+00D7 multiplication sign
    close.frame:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)
    close:SetOnClick(function() f:Hide() end)

    -- Esc closes it, matching every other panel in the game.
    _G[name] = f
    tinsert(UISpecialFrames, name)

    f.titleBar = titleBar
    return f
end
