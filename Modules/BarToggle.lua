-- BarToggle
-- A broker widget that shows and hides Action Bar 7 on click.
--
-- Bar 7 is where conditionally-used things live, so the useful operation is
-- "get it out of the way" and "bring it back" without opening any options.
--
-- THE BAR IS MultiBar6, NOT MultiBar7. Blizzard's frame names are offset by
-- one: MultiBar5/6/7 are Action Bars 6/7/8. Both EllesmereUI's bar table
-- (blizzFrame = "MultiBar6" for Bar7) and MouseoverActionSettings' locale
-- (L["MultiBar7"] = "Action Bar 8") say so. Using the obvious name would have
-- silently toggled the wrong bar.
--
-- Three owners, three mechanisms, because whoever manages the bars is the only
-- thing that can move it:
--
--   NDui          C.db.Actionbar.Bar7 plus Actionbar:UpdateVisibility().
--                 Persists -- it is a saved setting.
--   EllesmereUI   EAB._visOverride[key] plus EAB:RefreshRuntimeVisibility().
--                 Runtime only, deliberately: this is the same path EUI's own
--                 "Toggle Action Bar" keybind takes, and it never writes
--                 barVisibility, so a reload restores the saved state.
--   Blizzard      RegisterStateDriver on the frame itself.
--
-- NONE of them work in combat. Changing a secure frame's state-visibility
-- driver is combat-blocked, which EllesmereUI's own toggle documents as its
-- restriction too. That is the game's rule, not a shortcut taken here, and it
-- is worth knowing given what Bar 7 is for.

local AniMods = _G.AniMods
local Broker = AniMods.Broker

local BarToggle = {
    title = "Action Bar 7 Toggle",
    description = "Broker widget that shows and hides Action Bar 7.",
    dbKey = "barToggle",
    -- No conditions: the point is to work under whichever bar addon is present,
    -- including none. The backend is resolved at click time instead.
}

local ldbObject

-- Both EllesmereUI and NDui happen to key this bar as "Bar7".
local BAR_KEY = "Bar7"
local STOCK_FRAME = "MultiBar6"

local function ModuleDB()
    AniModsDB.barToggle = AniModsDB.barToggle or {}
    return AniModsDB.barToggle
end

-- ---------------------------------------------------------------------------
-- Backends
-- ---------------------------------------------------------------------------

local function NDuiParts()
    local nd = _G.NDui
    if type(nd) ~= "table" then return nil end
    local B, C = nd[1], nd[2]
    if type(B) ~= "table" or type(C) ~= "table" then return nil end
    if type(C.db) ~= "table" or type(C.db.Actionbar) ~= "table" then return nil end
    if type(B.GetModule) ~= "function" then return nil end
    local ok, mod = pcall(B.GetModule, B, "Actionbar")
    if not ok or type(mod) ~= "table" or type(mod.UpdateVisibility) ~= "function" then return nil end
    return B, C, mod
end

local function EABInstance()
    local eui = _G.EllesmereUI
    local modNS = eui and eui._ModuleNS and eui._ModuleNS["EllesmereUIActionBars"]
    local eab = modNS and modNS.EAB
    if type(eab) ~= "table" then return nil end
    if type(eab.RefreshRuntimeVisibility) ~= "function" then return nil end
    local bars = eab.db and eab.db.profile and eab.db.profile.bars
    if type(bars) ~= "table" or type(bars[BAR_KEY]) ~= "table" then return nil end
    return eab, bars[BAR_KEY]
end

local BACKENDS = {
    {
        name = "NDui",
        persists = true,
        Available = function() return NDuiParts() ~= nil end,
        IsShown = function()
            local _, C = NDuiParts()
            return C and C.db.Actionbar[BAR_KEY] and true or false
        end,
        Set = function(on)
            local _, C, mod = NDuiParts()
            -- NDuiParts returns all three or nothing, so this cannot split --
            -- but both are named so the checker can see it too.
            if not (C and mod) then return false end
            C.db.Actionbar[BAR_KEY] = on and true or false
            mod:UpdateVisibility()
            return true
        end,
    },
    {
        name = "EllesmereUI",
        persists = false,
        Available = function() return EABInstance() ~= nil end,
        IsShown = function()
            local eab, s = EABInstance()
            if not (eab and s) then return false end
            local effective = (eab._visOverride and eab._visOverride[BAR_KEY])
                or s.barVisibility or "always"
            return effective == "always"
        end,
        Set = function(on)
            local eab, s = EABInstance()
            if not (eab and s) then return false end
            -- EUI's own toggle only participates when the saved mode is a plain
            -- always/never. Overriding a mouseover or conditional bar would
            -- fight the rule the player configured rather than toggle it.
            local saved = s.barVisibility or "always"
            if saved ~= "always" and saved ~= "never" then
                return false, "EllesmereUI has Bar 7 on a conditional visibility "
                           .. "mode, which this cannot override."
            end
            eab._visOverride = eab._visOverride or {}
            eab._visOverride[BAR_KEY] = on and "always" or "never"
            eab:RefreshRuntimeVisibility()
            return true
        end,
    },
    {
        name = "Blizzard",
        persists = false,
        Available = function() return _G[STOCK_FRAME] ~= nil end,
        IsShown = function()
            local f = _G[STOCK_FRAME]
            return f and f:IsShown() and true or false
        end,
        Set = function(on)
            local f = _G[STOCK_FRAME]
            if not f then return false end
            _G.RegisterStateDriver(f, "visibility", on and "show" or "hide")
            return true
        end,
    },
}

-- First available wins, and the order is deliberate: a bar addon that owns the
-- frames has to be asked, because driving the Blizzard frame underneath it
-- would either be undone or fight whatever it does next.
local function Backend()
    for _, backend in ipairs(BACKENDS) do
        if backend.Available() then return backend end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Toggle
-- ---------------------------------------------------------------------------

local function Toggle()
    local backend = Backend()
    if not backend then
        AniMods.Print("No action bar to toggle: neither NDui, EllesmereUI nor "
            .. STOCK_FRAME .. " is present.")
        return
    end
    if _G.InCombatLockdown() then
        AniMods.Print("Action bars cannot be shown or hidden in combat.")
        return
    end

    local ok, reason = backend.Set(not backend.IsShown())
    if not ok and reason then AniMods.Print(reason) end
    if ldbObject then BarToggle.Update() end
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

-- ---------------------------------------------------------------------------
-- Broker
-- ---------------------------------------------------------------------------

function BarToggle.Update()
    if not ldbObject then return end
    local backend = Backend()
    local shown = backend and backend.IsShown() or false
    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, {
        {
            text  = "Bar 7",
            color = shown and "44ff44" or "888888",
        },
    }))
end

local function ShowTooltip(tt)
    tt:AddLine("Action Bar 7", 1, 0.82, 0)

    local backend = Backend()
    if not backend then
        tt:AddLine("No bar addon or Blizzard bar found.", 1, 0.35, 0.35)
        return
    end

    tt:AddDoubleLine("Currently", backend.IsShown() and "Shown" or "Hidden",
        0.7, 0.7, 0.7, 1, 1, 1)
    tt:AddDoubleLine("Driven by", backend.name, 0.7, 0.7, 0.7, 1, 1, 1)
    tt:AddDoubleLine("Survives a reload", backend.persists and "Yes" or "No",
        0.7, 0.7, 0.7, 0.7, 0.7, 0.7)

    tt:AddLine(" ")
    tt:AddLine("Left-click: toggle", 0.6, 0.6, 0.6)
    if _G.InCombatLockdown() then
        tt:AddLine("Blocked in combat", 1, 0.35, 0.35)
    end
end

local popup

local function ShowPopup(anchor)
    popup = popup or AniMods.W.Tooltip()
    popup:Clear()
    ShowTooltip(popup)
    popup:Show(anchor)
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsBarToggle", {
        label = "AniMods: Action Bar 7",
        OnClick = function(_, button)
            if button == "LeftButton" then
                Toggle()
            elseif AniMods.OpenModuleTab then
                AniMods.OpenModuleTab("BarToggle")
            end
        end,
        OnEnter = ShowPopup,
        OnLeave = function() if popup then popup:Hide() end end,
        OnTooltipShow = ShowTooltip,
    })
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function BarToggle:GetInfoRows()
    local rows = {}
    local backend = Backend()

    rows[#rows + 1] = { section = "Bar 7" }
    rows[#rows + 1] = {
        label = "Backend",
        value = backend and backend.name or "None found",
        help  = "Whichever addon owns the action bars has to be the one asked. "
             .. "Driving Blizzard's frame underneath a bar addon would either be "
             .. "undone or fight whatever it does next.",
    }
    rows[#rows + 1] = {
        label = "Currently shown",
        state = backend and backend.IsShown() or false,
    }
    rows[#rows + 1] = {
        label = "Survives a reload",
        state = backend and backend.persists or false,
        help  = "NDui's toggle is a saved setting. EllesmereUI's is a runtime "
             .. "override by design -- the same one its own Toggle Action Bar "
             .. "keybind uses -- so a reload restores what you configured.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Toggle now", button = "Toggle",
        help = "Action bars cannot be shown or hidden in combat: changing a "
            .. "secure frame's visibility driver is blocked. That is the game's "
            .. "rule, and it applies to every route to this.",
        onClick = Toggle,
    }

    for _, row in ipairs(Broker.SectionRows(ModuleDB, BarToggle.Update, "AniModsBarToggle")) do
        rows[#rows + 1] = row
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function BarToggle:Enable()
    InitLDB()
    -- Deferred: bar addons build their frames during startup, so the backend
    -- cannot be resolved meaningfully before they have.
    AniMods.W.OnReady(BarToggle.Update)
end

function BarToggle:SetEnabled()
    return true
end

AniMods.RegisterModule("BarToggle", BarToggle)
