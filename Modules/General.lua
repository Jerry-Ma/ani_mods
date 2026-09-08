-- General
-- AniMods' own settings, as opposed to any one patch's.
--
-- It is a module like the others so it gets a sidebar row, a tab and the same
-- row descriptors for free -- but it registers with order 0, which sorts it
-- to the top of the list, and it has no Enable() worth switching off: turning
-- the addon's own entry points off is what its settings do.

local General = {
    title = "General",
    description = "AniMods' own settings: how you reach the panel.",
    order = 0,
    dependencies = {
        { text = "LibDataBroker", help = "Used to publish AniMods' own minimap "
            .. "button. Shipped by EllesmereUI and most data-bar addons.",
          met = function()
              return (_G.LibStub and _G.LibStub:GetLibrary("LibDataBroker-1.1", true)) and true or false
          end },
    },
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

local RADIUS = 80   -- distance from the minimap centre to the ring

local function PositionButton()
    if not button then return end
    local angle = math.rad(ModuleDB().minimapAngle or 200)
    button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

local function BuildButton()
    if button then return button end
    if not _G.Minimap then return nil end

    button = CreateFrame("Button", "AniModsMinimapButton", Minimap)
    button:SetSize(24, 24)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("AnyUp")
    button:RegisterForDrag("LeftButton")

    local ring = button:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(50, 50)
    ring:SetPoint("TOPLEFT")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(MINIMAP_ICON)
    icon:SetSize(16, 16)
    icon:SetPoint("CENTER", button, "CENTER", -1, 1)
    -- Round mask so a square screenshot reads as a minimap button rather than
    -- a sticker on top of one.
    local mask = button:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
        "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)

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
-- Status panel
-- ---------------------------------------------------------------------------

function General:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Access" }
    rows[#rows + 1] = {
        label = "Minimap button",
        help  = "A round AniMods button on the minimap ring. Drag it around the "
             .. "ring to reposition; the angle is saved.",
        get   = function() return ModuleDB().minimap ~= false end,
        set   = function(v)
            ModuleDB().minimap = v and true or false
            ApplyMinimap()
        end,
    }
    rows[#rows + 1] = {
        label = "Addon compartment entry",
        reload = true,
        help  = "The entry in Blizzard's addon-compartment dropdown, next to the "
             .. "minimap. Blizzard reads this from the .toc once at startup, so "
             .. "removing it needs a reload -- AniMods writes the preference now "
             .. "and honours it on the next login.",
        get   = function() return ModuleDB().compartment ~= false end,
        set   = function(v) ModuleDB().compartment = v and true or false end,
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
