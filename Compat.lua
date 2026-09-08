-- AniMods skin provider.
--
-- Widgets.lua draws every surface through a facade called S. EllesmereUI
-- publishes one (EllesmereUI.RegisterSkin -> EllesmereUIBlizzardSkin's window
-- engine); this file supplies the same shape when EllesmereUI is not there, so
-- AniMods renders on a stock Blizzard UI with no other addon installed.
--
-- ── Why this is not the fallback pattern that was removed ────────────────────
--
-- The old Widgets.lua asked "is EllesmereUI loaded?" at eight separate call
-- sites and had a hand-drawn branch behind each one. Every widget carried two
-- renderings that had to be kept looking alike, and nothing could verify they
-- still did. One of those branches, RegAccent, crashed on login.
--
-- Here there is ONE interface and one implementation chosen once, at load.
-- Widgets.lua contains no provider test at all: it calls S.Panel, and which
-- S answered is not its business. The cost is honest and worth naming -- this
-- file IS a second rendering of the same look -- but it is a single file
-- behind a single boundary, not a branch inside every constructor, and the
-- interface it implements is someone else's published contract rather than
-- one invented here.
--
-- ── What has to be implemented ───────────────────────────────────────────────
--
-- Only the members Widgets.lua actually calls. EllesmereUI's real facade
-- exposes far more (Inset, Tab, ScrollBar, SquareIcon, SortHeaderBar, ...);
-- implementing those unused would be inventing a contract nothing exercises.
-- If Widgets.lua ever reaches for one, it belongs here at the same moment.
--
--   Shell(frame, opts)        Panel(frame, opts)      Button(btn)
--   Checkbox(cb, opts)        Dropdown(dd)            Font(fs, r, g, b)
--   GetAccentColor()          GetPanelColor()         GetFont()
--   GetStyle()                OnLooksChanged(fn)      IsEnabled()
--   apiVersion
--
-- ── The restrip asymmetry ────────────────────────────────────────────────────
--
-- EllesmereUI's Panel/Shell enrol their frame in a registry that periodically
-- alpha-zeroes direct texture regions (see Widgets.lua's header). This
-- provider has no such registry, so the child-frame discipline Widgets.lua
-- follows is unnecessary here -- but it is also harmless, and following it
-- unconditionally is what lets one set of constructors serve both providers.
-- Do not "optimise" it away for this path.

local AniMods = _G.AniMods

local ADDON_LABEL = "AniMods"

-- EllesmereUI's own default green. Used as AniMods' accent when EllesmereUI
-- is not there to supply one, so both providers look like the same addon.
AniMods.ACCENT_DEFAULT = { r = 0.047, g = 0.824, b = 0.616 }

-- True when the accent is EllesmereUI's rather than ours -- read by General to
-- decide whether its Accent color control applies.
function AniMods.AccentIsForeign()
    return (EllesmereUI and EllesmereUI.RegisterSkin) and true or false
end

-- ── Provider selection ──────────────────────────────────────────────────────

-- Calls `fn(S)` once, with whichever facade is available.
--
-- EllesmereUI's dispatch happens at PLAYER_LOGIN after its own boot, and it
-- may never happen at all (the user can switch third-party skinning off for
-- this addon, which is a legitimate choice we honour by simply not being
-- skinned by them). The stock provider therefore waits for PLAYER_LOGIN too,
-- so both paths hand Widgets.lua the facade at the same point in the login
-- sequence and there is only one timing story to reason about.
function AniMods.AcquireSkin(fn)
    if EllesmereUI and EllesmereUI.RegisterSkin then
        EllesmereUI.RegisterSkin(ADDON_LABEL, fn)
        return
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_LOGIN")
        fn(AniMods.BuildStockSkin())
    end)
end

-- ── Stock provider ──────────────────────────────────────────────────────────

-- The palette. Deliberately close to EllesmereUI's own so the two providers
-- produce a recognisably identical panel, but these are OUR numbers now, not
-- a copy that silently rots when EllesmereUI retunes its theme -- this path
-- runs only when EllesmereUI is absent, so there is nothing to stay in sync
-- with.
local PANEL_BG   = { 0.05, 0.07, 0.09, 0.94 }
local INSET_BG   = { 0.02, 0.03, 0.04, 1.00 }
local SHADE_BG   = { 0.00, 0.00, 0.00, 0.25 }
local BUTTON_BG  = { 0.061, 0.095, 0.120, 0.60 }
local BORDER     = { 1, 1, 1, 0.15 }
local CB_BORDER  = { 1, 1, 1, 0.25 }
local SHELL_BG   = { 0.04, 0.05, 0.07, 0.96 }
local TOPBAR_BG  = { 0, 0, 0, 0.5 }
local HOVER      = { 1, 1, 1, 0.10 }
local TOPBAR_H   = 25   -- matches EllesmereUI's shell band, so W.Window's
                        -- TITLE_BAR_H is correct under either provider

local DEFAULT_FONT = "Fonts\\FRIZQT__.TTF"

-- Per-object state, external and weak-keyed: never write bookkeeping fields
-- onto a frame, so nothing here can collide with Blizzard's own or another
-- addon's. Also what makes every skinner below idempotent.
local FD = setmetatable({}, { __mode = "k" })
local function D(obj)
    local d = FD[obj]
    if not d then d = {}; FD[obj] = d end
    return d
end

local function Solid(parent, layer, c, sublevel)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

-- A 1px border drawn as four edge textures on a child frame.
--
-- Four textures rather than SetBackdrop: BackdropTemplate's edgeFile scales
-- its edge with UI scale and goes blurry at fractional scales, and it also
-- forces a backdrop object onto the frame that later SetBackdrop calls fight
-- over. Explicit 1px strips are exact and own nothing.
local function AddBorder(frame, c)
    local d = D(frame)
    if d.border then return d.border end

    local host = CreateFrame("Frame", nil, frame)
    host:SetAllPoints()
    host:SetFrameLevel(frame:GetFrameLevel() + 1)
    host:EnableMouse(false)

    local edges = {}
    for i = 1, 4 do
        edges[i] = Solid(host, "OVERLAY", c or BORDER)
    end
    edges[1]:SetPoint("TOPLEFT");     edges[1]:SetPoint("TOPRIGHT");    edges[1]:SetHeight(1)
    edges[2]:SetPoint("BOTTOMLEFT");  edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
    edges[3]:SetPoint("TOPLEFT");     edges[3]:SetPoint("BOTTOMLEFT");  edges[3]:SetWidth(1)
    edges[4]:SetPoint("TOPRIGHT");    edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)

    d.border = { host = host, edges = edges }
    return d.border
end

-- Alpha out every direct texture region. Same visual-only policy as
-- EllesmereUI's engine: never Hide(), never SetParent(), never touch
-- behaviour on a frame we did not create.
local function FadeRegions(frame, keep)
    if not frame.GetRegions then return end
    for i = 1, select("#", frame:GetRegions()) do
        local r = select(i, frame:GetRegions())
        if r and r.IsObjectType and r:IsObjectType("Texture") and not (keep and keep[r]) then
            r:SetAlpha(0)
        end
    end
end

local looksCallbacks = {}

function AniMods.BuildStockSkin()
    local S = {}

    S.apiVersion = 1

    -- Always true: this provider only exists when it is the one in use.
    function S.IsEnabled() return true end

    -- EllesmereUI answers "eui" or "modern"; neither is meaningful here, and
    -- Widgets.lua does not branch on it. Reported honestly rather than
    -- claiming one of theirs.
    function S.GetStyle() return "stock" end

    -- The accent, from AniMods' own setting (General -> Accent color).
    --
    -- EllesmereUI's provider answers this from the user's EUI theme, so when
    -- EUI is loaded that is what the panel follows and this setting does not
    -- apply -- General says so rather than offering a control that would be
    -- silently overridden.
    --
    -- Default is EllesmereUI's green, so the two providers look like the same
    -- addon out of the box.
    function S.GetAccentColor()
        local g = AniModsDB and AniModsDB.general
        local a = g and g.accent
        if a and a.r then return a.r, a.g, a.b end
        return AniMods.ACCENT_DEFAULT.r, AniMods.ACCENT_DEFAULT.g, AniMods.ACCENT_DEFAULT.b
    end

    function S.GetPanelColor()
        return PANEL_BG[1], PANEL_BG[2], PANEL_BG[3], PANEL_BG[4]
    end

    -- Path plus outline flag, matching EllesmereUI's GetFont contract.
    function S.GetFont()
        return DEFAULT_FONT, ""
    end

    -- Registered and kept, but nothing fires it: this provider's theme is
    -- static (class colour cannot change mid-session). Honouring the contract
    -- costs nothing and means Widgets.lua needs no special case; if AniMods
    -- ever grows its own accent setting, AniMods.RefreshStockLooks() below is
    -- the hook to call.
    function S.OnLooksChanged(fn)
        if type(fn) == "function" then looksCallbacks[#looksCallbacks + 1] = fn end
    end

    -- Flat solid panel with the house border. opts.inset = darker nested
    -- fill, opts.shade = translucent wash, opts.noBorder = skip the border.
    function S.Panel(frame, opts)
        opts = opts or {}
        local d = D(frame)
        if d.panel then return end
        d.panel = true

        FadeRegions(frame)
        if not opts.noBg then
            local c = PANEL_BG
            if opts.inset then c = INSET_BG elseif opts.shade then c = SHADE_BG end
            local bg = Solid(frame, "BACKGROUND", c, -6)
            bg:SetAllPoints()
            d.bg = bg
        end
        if not opts.noBorder then AddBorder(frame) end
    end

    -- Window dress. EllesmereUI's Shell lays an atlas backdrop, a black title
    -- band and an atlas frame border; this is the same three elements in flat
    -- colour. opts.noTopBar skips the band for popups with no title row.
    function S.Shell(frame, opts)
        opts = opts or {}
        local d = D(frame)
        if d.shell then return end
        d.shell = true

        FadeRegions(frame)
        local bg = Solid(frame, "BACKGROUND", SHELL_BG, -8)
        bg:SetAllPoints()
        d.bg = bg

        if not opts.noTopBar then
            local top = Solid(frame, "BACKGROUND", TOPBAR_BG, -5)
            top:SetPoint("TOPLEFT")
            top:SetPoint("TOPRIGHT")
            top:SetHeight(TOPBAR_H)
            d.topBar = top
        end

        if not opts.noBorder then AddBorder(frame) end
    end

    -- Generic action button -> flat block, border, subtle white hover.
    -- The label is left alone (colour-only text policy), matching
    -- EllesmereUI's engine, so callers own their own FontString.
    function S.Button(btn)
        local d = D(btn)
        if d.button then return end
        d.button = true

        FadeRegions(btn)
        for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture",
                                  "GetDisabledTexture", "GetHighlightTexture" }) do
            local fn = btn[getter]
            local t = fn and fn(btn)
            if t then t:SetAlpha(0) end
        end

        local fill = Solid(btn, "BACKGROUND", BUTTON_BG)
        fill:SetAllPoints()
        d.bg = fill
        AddBorder(btn)

        local hover = Solid(btn, "HIGHLIGHT", HOVER)
        hover:SetAllPoints()
        d.hover = hover
    end

    -- Checkbox -> dark box, border, accent tick. Mirrors the engine's
    -- handling of Blizzard's template: clear the state textures, fade
    -- everything except the check itself, then lay our own box inside the
    -- 4px inset the template leaves.
    function S.Checkbox(cb, opts)
        local d = D(cb)
        if d.checkbox then return end
        d.checkbox = true

        if cb.SetNormalTexture then cb:SetNormalTexture("") end
        if cb.SetPushedTexture then cb:SetPushedTexture("") end
        if cb.SetHighlightTexture then cb:SetHighlightTexture("") end

        local checked = cb.GetCheckedTexture and cb:GetCheckedTexture()
        local dchecked = cb.GetDisabledCheckedTexture and cb:GetDisabledCheckedTexture()
        FadeRegions(cb, { [checked or false] = true, [dchecked or false] = true })

        local fill = Solid(cb, "BACKGROUND", INSET_BG)
        fill:SetPoint("TOPLEFT", 4, -4)
        fill:SetPoint("BOTTOMRIGHT", -4, 4)
        d.bg = fill
        AddBorder(cb, CB_BORDER)

        if checked and not (opts and opts.stockCheck) then
            local r, g, b = S.GetAccentColor()
            checked:SetVertexColor(r, g, b, 1)
        end
    end

    -- Dropdown -> flat block plus border. Nil-guarded per template the same
    -- way the engine is, so a bare Button is a valid target.
    function S.Dropdown(dd)
        local d = D(dd)
        if d.dropdown then return end
        d.dropdown = true

        FadeRegions(dd)
        local name = dd.GetName and dd:GetName()
        if name then
            for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
                local r = _G[name .. suffix]
                if r and r.SetAlpha then r:SetAlpha(0) end
            end
        end
        if dd.Background then dd.Background:SetAlpha(0) end
        if dd.Texture then dd.Texture:SetAlpha(0) end

        local fill = Solid(dd, "BACKGROUND", PANEL_BG)
        fill:SetAllPoints()
        d.bg = fill
        AddBorder(dd)
    end

    -- Re-face a FontString at its existing size.
    --
    -- Two rules taken from EllesmereUI's engine and from MeetingStoneEllesmereUI,
    -- both learned the hard way there:
    --   * re-face at the CURRENT size, never a size of our own, so callers
    --     keep control of scale;
    --   * a secret size (12.x secret-values) must be rejected before it is
    --     compared or passed on.
    -- Widget LABELS are not re-faced anywhere in AniMods: buttons and edit
    -- boxes re-apply their font OBJECT on every state change, so the first
    -- mouseover would throw the face away and the re-measure can clip text.
    function S.Font(fs, r, g, b)
        if not (fs and fs.GetFont) then return end
        local _, size = fs:GetFont()
        if issecretvalue and issecretvalue(size) then return end
        fs:SetFont(DEFAULT_FONT, size or 12, "")
        if r then fs:SetTextColor(r, g, b or r) end
    end

    return S
end

-- Fires every OnLooksChanged callback. Nothing calls this yet -- see the note
-- on S.OnLooksChanged -- but it is what an AniMods-owned accent setting would
-- call, and having it here keeps that a one-line change rather than a
-- redesign.
function AniMods.RefreshStockLooks()
    for i = 1, #looksCallbacks do
        local ok, err = pcall(looksCallbacks[i])
        if not ok then geterrorhandler()(err) end
    end
end
