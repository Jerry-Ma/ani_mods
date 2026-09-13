-- DamageMeter
-- Turns on the game's own combat record when nothing else is providing one.
--
-- Retail ships a built-in damage meter: the C_DamageMeter API with a Blizzard
-- LOD addon, Blizzard_DamageMeter, drawing its UI. It is off by default because
-- most people run a meter addon, and every meter addon switches it off to avoid
-- two windows showing the same numbers -- EllesmereUIDamageMeters does
-- SetCVarSafe("damageMeterEnabled", 0), and Details does the same through its
-- own slash handling.
--
-- Which leaves the gap this fills: a setup with NO meter addon gets no meter at
-- all, even though the game has one sitting there switched off.
--
-- The conditions are the three things that would otherwise own the window. They
-- are FORBIDS rather than requires: this module exists only when the field is
-- empty.

local AniMods = _G.AniMods

local DamageMeter = {
    title = "Blizzard Damage Meter",
    description = "Switches on the game's built-in combat record when no meter addon is present.",
    conditions = {
        { text = "EllesmereUI not loaded",
          help = "EllesmereUIDamageMeters draws its own window from the same "
              .. "C_DamageMeter data and switches the built-in off, so turning "
              .. "it back on would show the same numbers twice.",
          met = function() return not AniMods.IsAddOnLoaded("EllesmereUI") end },
        { text = "NDui not loaded",
          help = "NDui docks a meter into its own layout and manages the "
              .. "built-in alongside it.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
        { text = "Details not loaded",
          help = "Details is a meter in its own right and switches the "
              .. "built-in off when it takes over.",
          met = function() return not AniMods.IsAddOnLoaded("Details") end },
    },
}

-- The CVar the whole module is about, named once.
local CVAR = "damageMeterEnabled"

local function GetCVarBool(name)
    return _G.C_CVar and _G.C_CVar.GetCVarBool and _G.C_CVar.GetCVarBool(name) or false
end

-- Only ever called out of combat: Enable runs at login through W.OnReady, and
-- the toggle is a click in a panel that hides itself when combat starts.
local function SetMeterEnabled(on)
    if not (_G.C_CVar and _G.C_CVar.SetCVar) then return false end
    if _G.InCombatLockdown() then return false end
    _G.C_CVar.SetCVar(CVAR, on and "1" or "0")
    return true
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function DamageMeter:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Built-in meter" }
    rows[#rows + 1] = {
        label = "Currently on",
        state = GetCVarBool(CVAR),
        help  = "The " .. CVAR .. " console variable. This module sets it at "
             .. "login and when toggled; Blizzard's own interface options set "
             .. "the same thing.",
    }
    rows[#rows + 1] = {
        label = "Blizzard_DamageMeter loaded",
        state = AniMods.IsAddOnLoaded("Blizzard_DamageMeter"),
        help  = "The game loads its meter addon on demand once the setting is "
             .. "on, so this can read false until then.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Deferred to OnReady rather than run at PLAYER_LOGIN directly: a meter addon
-- that switches the CVar off does so during its own startup, and asserting this
-- first would simply be overwritten.
function DamageMeter:Enable()
    AniMods.W.OnReady(function() SetMeterEnabled(true) end)
end

-- Symmetric on purpose. This module's whole job is deciding whether the
-- built-in meter runs, so switching the module off switches the meter off --
-- anything else would leave a toggle that does nothing visible.
function DamageMeter:SetEnabled(on)
    SetMeterEnabled(on and true or false)
    return true
end

AniMods.RegisterModule("DamageMeter", DamageMeter)
