-- General
-- AniMods' own settings, as opposed to any one patch's.
--
-- It is a module like the others so it gets a sidebar row, a tab and the same
-- row descriptors for free -- but it registers with order 0, which sorts it
-- to the top of the list, and it has no Enable() worth switching off: turning
-- the addon's own entry points off is what its settings do.

local General = {
    title = "General",
    description = "Settings for AniMods itself.",
    order = 0,
    -- No master switch. This tab holds the settings that control AniMods
    -- itself, so switching it off would hide the controls for the addon --
    -- including the minimap button and compartment entry that are two of the
    -- three ways back into this panel.
    essential = true,
    -- No dependencies. This listed LibDataBroker, which was simply wrong --
    -- left over from an early plan to build the minimap button on LibDBIcon.
    -- The button is hand-rolled and everything here is plain Blizzard API, so
    -- claiming a requirement would have shown a red badge for a library this
    -- module never touches.
}

local MINIMAP_ICON = "Interface\\AddOns\\AniMods\\Media\\icon.png"

local button          -- the minimap button, once built

local function ModuleDB()
    AniModsDB.general = AniModsDB.general or {}
    local db = AniModsDB.general
    if db.minimap == nil then db.minimap = true end
    if db.minimapAngle == nil then db.minimapAngle = 200 end
    return db
end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------
-- Hand-rolled rather than LibDBIcon. That library does more than this needs
-- (profile handling, a registry of every icon, square-minimap shapes) and
-- AniMods does not bundle it; depending on another addon happening to ship it
-- would make our own button appear or vanish with THEIR install. The whole of
-- what is wanted here is: sit on the minimap ring at a saved angle, drag to
-- move, click to open.

-- Gap between the minimap edge and the button's centre. LibDBIcon's own
-- default, and what makes AniMods' button sit on the same ring as everyone
-- else's.
local EDGE_GAP = 5

-- Which quadrants of a given minimap shape are round. A square minimap needs
-- the button pushed out to the diagonal instead of the circle, or it lands
-- inside the map at the corners. GetMinimapShape is a convention addons that
-- reshape the minimap define; absent, it is round.
local MINIMAP_SHAPES = {
    ROUND = { true, true, true, true },
    SQUARE = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

-- Placement follows LibDBIcon's geometry rather than a fixed radius.
--
-- The first version hard-coded 80px from centre, which is only right for a
-- default-sized minimap: the radius has to come from the minimap's ACTUAL
-- size, and EllesmereUIMinimap (like most minimap addons) resizes it. Width
-- and height are read separately so a non-square minimap still works.
local function PositionButton()
    if not button or not Minimap then return end

    local angle = math.rad(ModuleDB().minimapAngle or 200)
    local x, y = math.cos(angle), math.sin(angle)

    -- Quadrant, in LibDBIcon's numbering: 1 = +x+y, 2 = -x+y, 3 = +x-y, 4 = -x-y.
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end

    local shape = (_G.GetMinimapShape and _G.GetMinimapShape()) or "ROUND"
    local quad = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND

    local w = (Minimap:GetWidth() / 2) + EDGE_GAP
    local h = (Minimap:GetHeight() / 2) + EDGE_GAP

    if quad[q] then
        x, y = x * w, y * h
    else
        -- Square corner: project onto the diagonal, then clamp to the edges.
        local dw = math.sqrt(2 * w * w) - 10
        local dh = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * dw, w))
        y = math.max(-h, math.min(y * dh, h))
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function BuildButton()
    if button then return button end
    if not _G.Minimap then return nil end

    -- Geometry copied from LibDBIcon's retail button, so this sits on the ring
    -- at the same size as every other addon's minimap button rather than at
    -- whatever looked about right. The numbers are not arbitrary: the 50x50
    -- tracking border is drawn anchored TOPLEFT of a 31x31 button, which is
    -- what centres its ring on the button.
    button = CreateFrame("Button", "AniModsMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477) -- UI-Minimap-ZoomButton-Highlight

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture(136467)      -- UI-Minimap-Background
    background:SetPoint("CENTER")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MINIMAP_ICON)
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    -- Round mask, so a square screenshot reads as a minimap button rather
    -- than a sticker stuck on one.
    local mask = button:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

    local ring = button:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(136430)            -- MiniMap-TrackingBorder
    ring:SetSize(50, 50)
    ring:SetPoint("TOPLEFT")

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("AniMods", 1, 0.82, 0)
        GameTooltip:AddLine("Click to open the panel", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag to move around the minimap", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnClick", function()
        if AniMods.ToggleUI then AniMods.ToggleUI() end
    end)

    -- Dragging follows the cursor's angle around the minimap centre rather
    -- than moving the frame freely, so the button cannot be dropped somewhere
    -- off the ring. OnUpdate is set only while a drag is in progress and
    -- cleared on release, so it costs nothing at rest.
    local function DragUpdate()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx, cy = cx / scale, cy / scale
        ModuleDB().minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
        PositionButton()
    end
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", DragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    PositionButton()
    return button
end

local function ApplyMinimap()
    local show = ModuleDB().minimap ~= false
    if not show then
        if button then button:Hide() end
        return
    end
    if BuildButton() then
        PositionButton()
        button:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Accent
-- ---------------------------------------------------------------------------
-- A short preset list rather than a colour picker. Blizzard's ColorPickerFrame
-- would give arbitrary colours but arrives wearing Blizzard's own art, which
-- would make it the one part of this panel that ignores the theme -- and its
-- API has moved twice in recent expansions. Presets need no new widget kind
-- and cover what an accent is for.
--
-- Only reachable when EllesmereUI is absent; with it loaded, its accent wins.
-- Hues only, no names. Naming them was the previous version's mistake: it
-- called 0.047/0.824/0.616 "Green" when it is a mint, and carried a separate
-- "Teal" that was nearly the same colour. A swatch shows what it is.
--
-- "auto" is first and is the default -- it means follow the host theme, and
-- its swatch renders in whatever that currently resolves to, so the choice
-- previews itself. Selecting it clears the override rather than storing a
-- copy, so it keeps tracking a theme that later changes.
local ACCENTS = {
    { key = "auto" },                                  -- follows the provider
    { key = "mint",    rgb = { 0.047, 0.824, 0.616 } },
    { key = "green",   rgb = { 0.298, 0.780, 0.353 } },
    { key = "cyan",    rgb = { 0.204, 0.741, 0.890 } },
    { key = "blue",    rgb = { 0.204, 0.541, 0.890 } },
    { key = "purple",  rgb = { 0.608, 0.400, 0.859 } },
    { key = "magenta", rgb = { 0.890, 0.353, 0.639 } },
    { key = "red",     rgb = { 0.906, 0.298, 0.235 } },
    { key = "orange",  rgb = { 0.949, 0.573, 0.204 } },
    { key = "gold",    rgb = { 0.937, 0.788, 0.271 } },
    { key = "class" },                                 -- resolved live
}

local ACCENT_ORDER = {}
for i, def in ipairs(ACCENTS) do ACCENT_ORDER[i] = def.key end

local function ClassColor()
    local _, class = UnitClass("player")
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return { c.r, c.g, c.b } end
    local d = AniMods.ACCENT_DEFAULT
    return { d.r, d.g, d.b }
end

-- Swatch colours, rebuilt per call so "auto" and "class" show what they
-- currently resolve to rather than a value captured at load.
local function AccentSwatchColors()
    local out = {}
    for _, def in ipairs(ACCENTS) do
        if def.key == "auto" then
            local r, g, b = AniMods.W.ProviderAccent()
            out.auto = { r, g, b }
        elseif def.key == "class" then
            out.class = ClassColor()
        else
            out[def.key] = def.rgb
        end
    end
    return out
end

local function CurrentAccentKey()
    return ModuleDB().accentKey or "auto"
end

local function SetAccent(key)
    local db = ModuleDB()
    db.accentKey = key

    if key == "auto" then
        db.accent = nil
    elseif key == "class" then
        local c = ClassColor()
        db.accent = { r = c[1], g = c[2], b = c[3] }
    else
        for _, def in ipairs(ACCENTS) do
            if def.key == key and def.rgb then
                db.accent = { r = def.rgb[1], g = def.rgb[2], b = def.rgb[3] }
                break
            end
        end
    end

    -- W.RefreshLooks, not AniMods.RefreshStockLooks: the latter walks the
    -- STOCK provider's callback list, which is empty whenever EllesmereUI is
    -- the provider -- so under EllesmereUI this saved the colour and repainted
    -- nothing. W owns the registry the widgets actually register with, and it
    -- is the same one under either provider.
    AniMods.W.RefreshLooks()
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function General:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Access" }
    rows[#rows + 1] = {
        label = "Minimap button",
        help  = "Drag it around the ring to move it.",
        get   = function() return ModuleDB().minimap ~= false end,
        set   = function(v)
            ModuleDB().minimap = v and true or false
            ApplyMinimap()
        end,
    }
    rows[#rows + 1] = {
        label = "Addon compartment entry",
        reload = true,
        help  = "AniMods' entry in Blizzard's addon dropdown by the minimap.",
        get   = function() return ModuleDB().compartment ~= false end,
        set   = function(v) ModuleDB().compartment = v and true or false end,
    }

    rows[#rows + 1] = { section = "Appearance" }
    rows[#rows + 1] = {
        label    = "Accent color",
        help     = AniMods.AccentIsForeign()
            and "Headings, highlights and switches. The first swatch follows EllesmereUI."
            or  "Headings, highlights and switches. The first swatch is the default.",
        swatches = AccentSwatchColors(),
        order    = ACCENT_ORDER,
        get      = CurrentAccentKey,
        set      = SetAccent,
    }

    rows[#rows + 1] = { section = "Modules" }
    local active, total = 0, 0
    for _, entry in pairs(AniMods.status) do
        total = total + 1
        if entry.active then active = active + 1 end
    end
    rows[#rows + 1] = { label = "Active", value = ("%d of %d"):format(active, total) }
    rows[#rows + 1] = { label = "Version", value = AniMods.GetAddOnVersion("AniMods") or "?" }

    return rows
end

function General:Enable()
    -- Deferred to the skin provider, which lands after EllesmereUI's own boot:
    -- building on the minimap earlier can land under whatever a minimap addon
    -- rearranges at login.
    AniMods.W.OnReady(ApplyMinimap)
end

-- Toggles cleanly: the only thing it owns is a minimap button of its own
-- making, which hides on demand. Nothing hooked, nothing registered.
function General:SetEnabled(on)
    if on then
        ApplyMinimap()
    elseif button then
        button:Hide()
    end
end

AniMods.RegisterModule("General", General)
