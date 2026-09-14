-- ShiftFocus
-- Modifier + click on anything under the cursor sets it as your focus.
--
-- Ported from the same idea in NDui_Plus (Modules/Combat/FocusMarker.lua) and
-- EllesmereUI_WindTools (Modules/UnitFrames/QuickFocus.lua). Both come down to
-- one secure button carrying a macro, bound over the mouse:
--
--   button:SetAttribute("type*", "macro")
--   button:SetAttribute("macrotext", "/focus mouseover")
--   SetOverrideBindingClick(button, true, "SHIFT-BUTTON1", buttonName)
--
-- It works on ANYTHING the game gives a mouseover unit for -- unit frames,
-- nameplates, the 3D world -- because /focus mouseover asks the game rather
-- than any particular frame. That is why it needs no per-frame hooks.
--
-- Three details are load-bearing, and each is a bug if missed:
--
--   * The button must be SHOWN. A hidden frame never processes a binding
--     click, so the override silently does nothing. WindTools has a comment
--     saying this cost it an off/on toggle to notice.
--   * RegisterForClicks has to match the ActionButtonUseKeyDown CVar, or the
--     binding fires on the opposite edge from every other click in the game.
--   * SetOverrideBindingClick is protected. Rebinding during combat is
--     blocked, so a settings change mid-fight is deferred to the end of it.

local AniMods = _G.AniMods

local ShiftFocus = {
    title = "Shift Focus",
    description = "Modifier-click anything to set it as your focus.",
    conditions = {
        { text = "NDui not loaded",
          help = "NDui ships its own focus button (NDui_Plus extends it as "
              .. "FocusMarker), so this would be a second binding competing "
              .. "for the same click.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
    },
}

local BUTTON_NAME = "AniModsShiftFocusButton"

local MODIFIER_LABEL = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt" }
local MODIFIER_ORDER = { "SHIFT", "CTRL", "ALT" }

local MOUSE_LABEL = {
    BUTTON1 = "Left", BUTTON2 = "Right", BUTTON3 = "Middle",
    BUTTON4 = "Button 4", BUTTON5 = "Button 5",
}
local MOUSE_ORDER = { "BUTTON1", "BUTTON2", "BUTTON3", "BUTTON4", "BUTTON5" }

local button
local moduleEnabled = true
local deferred = false
local combatWatcher

local function ModuleDB()
    AniModsDB.shiftFocus = AniModsDB.shiftFocus or {}
    return AniModsDB.shiftFocus
end

local function GetModifier()
    local v = ModuleDB().modifier
    return MODIFIER_LABEL[v] and v or "SHIFT"
end

local function GetMouseButton()
    local v = ModuleDB().button
    return MOUSE_LABEL[v] and v or "BUTTON1"
end

local function GetMark()
    local v = ModuleDB().markNumber
    if type(v) == "number" and v >= 1 and v <= 8 then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- The macro
-- ---------------------------------------------------------------------------

-- Optionally marks the new focus, the way both source implementations do. The
-- 0 first is not redundant: re-marking a unit that already carries the icon
-- would otherwise toggle it off, so clearing and setting makes the result the
-- same whatever it started as.
local function MacroText()
    local lines = { "/focus mouseover" }
    local mark = GetMark()
    if mark then
        lines[#lines + 1] = "/tm [@focus,exists] 0"
        lines[#lines + 1] = "/tm [@focus,exists] " .. mark
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Binding
-- ---------------------------------------------------------------------------

local Apply

-- Registered once, only while something is waiting. Re-registering an event
-- with a second handler is how one of these quietly replaces the other.
local function DeferToCombatEnd()
    if deferred then return end
    deferred = true
    combatWatcher = combatWatcher or _G.CreateFrame("Frame")
    combatWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    combatWatcher:SetScript("OnEvent", function(self)
        self:UnregisterAllEvents()
        deferred = false
        Apply()
    end)
end

Apply = function()
    if not button then return end
    if _G.InCombatLockdown() then
        DeferToCombatEnd()
        return
    end

    _G.ClearOverrideBindings(button)
    if not moduleEnabled then return end

    button:SetAttribute("macrotext", MacroText())
    -- Matching the CVar matters: with ActionButtonUseKeyDown on, every other
    -- click in the game acts on press, and a binding that acts on release
    -- feels broken rather than different.
    local useKeyDown = _G.C_CVar and _G.C_CVar.GetCVarBool
        and _G.C_CVar.GetCVarBool("ActionButtonUseKeyDown")
    button:RegisterForClicks(useKeyDown and "AnyDown" or "AnyUp")
    _G.SetOverrideBindingClick(button, true,
        GetModifier() .. "-" .. GetMouseButton(), BUTTON_NAME)
end

local function Build()
    if button then return end
    button = _G.CreateFrame("Button", BUTTON_NAME, _G.UIParent, "SecureActionButtonTemplate")
    -- Shown, and deliberately so: a hidden frame never processes a binding
    -- click. Sized to nothing and anchored off-screen instead of hidden, so it
    -- takes no space and intercepts no real clicks.
    button:SetSize(1, 1)
    button:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", -100, -100)
    button:Show()
    button:SetAttribute("type*", "macro")
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function ShiftFocus:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Binding" }
    rows[#rows + 1] = {
        label   = "Modifier",
        options = MODIFIER_LABEL,
        order   = MODIFIER_ORDER,
        get     = function() return GetModifier() end,
        set     = function(v) ModuleDB().modifier = v; Apply() end,
    }
    rows[#rows + 1] = {
        label   = "Mouse button",
        options = MOUSE_LABEL,
        order   = MOUSE_ORDER,
        get     = function() return GetMouseButton() end,
        set     = function(v) ModuleDB().button = v; Apply() end,
        help    = "The override only takes this click while the modifier is "
               .. "held, so the button keeps its normal job otherwise.",
    }
    rows[#rows + 1] = {
        label = "Currently bound",
        value = GetModifier() .. "-" .. GetMouseButton(),
    }

    rows[#rows + 1] = { section = "Raid marker" }
    rows[#rows + 1] = {
        label = "Mark the focus",
        get   = function() return GetMark() ~= nil end,
        set   = function(v)
            ModuleDB().markNumber = v and (ModuleDB().markNumber or 8) or nil
            Apply()
        end,
        help  = "Puts a raid target icon on whatever you just focused. Both "
             .. "NDui_Plus and WindTools do this; it needs assist or lead in a "
             .. "group, and does nothing without.",
    }
    if GetMark() then
        rows[#rows + 1] = {
            label = "Marker",
            min   = 1,
            max   = 8,
            step  = 1,
            get   = function() return GetMark() or 8 end,
            set   = function(v) ModuleDB().markNumber = v; Apply() end,
        }
    end

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Waiting for combat to end",
        state = deferred,
        help  = "Changing an override binding is blocked in combat, so a change "
             .. "made mid-fight is applied when it ends.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ShiftFocus:Enable()
    moduleEnabled = true
    Build()
    AniMods.W.OnReady(Apply)
end

-- Toggles live: the binding is cleared outright rather than left pointing at a
-- button that would do nothing, so the click goes back to whatever it does
-- normally the moment this is switched off.
function ShiftFocus:SetEnabled(on)
    moduleEnabled = on and true or false
    Apply()
    return true
end

AniMods.RegisterModule("ShiftFocus", ShiftFocus)
