-- ExtraButtonClicks
-- Stops the zone/extra ability artwork from eating clicks.
--
-- The zone/extra ability button draws a decorative surround much larger than
-- the button itself, and that surround takes the mouse. Clicks landing on the
-- art near the button hit nothing, and anything underneath it -- an action bar,
-- a unit frame -- is unreachable while the button is up.
--
-- Ported from EUI_Kogotool (Core/Gameplay/BlizzUIEnhance.lua), which switches
-- the mouse off on the bar frame, the container, and the zone ability's Style.
-- The BUTTON itself is untouched and stays clickable -- only the decoration
-- stops intercepting.
--
-- Three things NOT copied from the source. Its apply function ignores its own
-- setting, so switching the option off still disabled the mouse; here Revert
-- actually puts it back. It guards combat on one of the three frames only,
-- while all of them are protected -- EnableMouse on a protected frame in combat
-- is blocked, so every one is guarded and the work is deferred.
--
-- And the source's list is incomplete: it silences ZoneAbilityFrame.Style but
-- not ZoneAbilityFrame, which is mouse-enabled in its own right and sits ABOVE
-- Style in the stack. /framestack over the surround reports ZoneAbilityFrame as
-- the frame taking the click, so silencing only its child changes nothing
-- there. Disabling the parent does not reach the spell button: EnableMouse is
-- per frame, and the button is a child of ZoneAbilityFrame.SpellButtonContainer
-- with its own mouse still on. Edit Mode keeps working too -- dragging that
-- system is done through ExtraAbilityContainer.Selection, an overlay with its
-- own mouse, not through ZoneAbilityFrame's.
--
-- No conditions. This was born in the EllesmereUI Misc bag, which gated it on
-- EllesmereUI being loaded -- wrong on its own terms: the frames are
-- Blizzard's, the problem is Blizzard's, and a stock UI has it just as much.

local AniMods = _G.AniMods

local ExtraButtonClicks = {
    title = "Extra Button Click-Through",
    description = "Stops the zone/extra ability artwork from eating clicks.",
}

local EXTRA_FRAMES = {
    { name = "ExtraActionBarFrame" },
    { name = "ExtraAbilityContainer" },
    { name = "ZoneAbilityFrame" },
    -- Still needed alongside the parent: EnableMouse is per frame, so silencing
    -- ZoneAbilityFrame leaves this child taking clicks on its own.
    { name = "ZoneAbilityFrame", child = "Style" },
}

local moduleEnabled = true
local watcher

local function ForEachExtraFrame(fn)
    for _, spec in ipairs(EXTRA_FRAMES) do
        local frame = _G[spec.name]
        if spec.child then frame = frame and frame[spec.child] end
        if frame and frame.EnableMouse then fn(frame) end
    end
end

local Apply

-- The events below say "something changed", not "the frame exists now" -- the
-- zone ability is built the first time the game has one to show, which can land
-- after all of them. Blizzard re-shows and rebuilds it through these two, so
-- hooking them is what actually keeps the setting asserted; EllesmereUI's own
-- skin hooks the same pair for the same reason. Installed once each, the first
-- time the frame is there to hook.
local hooked = {}

local function HookFrames()
    local zone = _G.ZoneAbilityFrame
    if zone and not hooked.zone then
        hooked.zone = true
        zone:HookScript("OnShow", function() Apply() end)
        if zone.UpdateDisplayedZoneAbilities then
            hooksecurefunc(zone, "UpdateDisplayedZoneAbilities", function() Apply() end)
        end
    end
    local extra = _G.ExtraActionBarFrame
    if extra and not hooked.extra then
        hooked.extra = true
        extra:HookScript("OnShow", function() Apply() end)
    end
end

-- The frames are created on demand and Blizzard re-shows them per zone or
-- encounter, so this has to re-assert rather than run once at login.
local function EnsureWatcher()
    if watcher then return end
    watcher = _G.CreateFrame("Frame")
    watcher:RegisterEvent("UPDATE_EXTRA_ACTIONBAR")
    watcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    watcher:SetScript("OnEvent", function() Apply() end)
end

Apply = function()
    HookFrames()
    -- Deferred rather than skipped: PLAYER_REGEN_ENABLED is in the watcher's
    -- event list, so leaving combat runs this again.
    if _G.InCombatLockdown() then return end
    ForEachExtraFrame(function(frame) frame:EnableMouse(not moduleEnabled) end)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function ExtraButtonClicks:GetInfoRows()
    local found, silenced = 0, 0
    ForEachExtraFrame(function(frame)
        found = found + 1
        if not frame:IsMouseEnabled() then silenced = silenced + 1 end
    end)
    return {
        {
            label = "Decoration frames present",
            value = tostring(found),
            help  = "The surround is built on demand, so this reads zero until "
                 .. "the game gives you a zone or extra ability.",
        },
        {
            label = "Click-through now",
            value = ("%d of %d"):format(silenced, found),
            help  = "The button itself is never touched -- only the art around "
                 .. "it stops taking the mouse.",
        },
    }
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ExtraButtonClicks:Enable()
    moduleEnabled = true
    EnsureWatcher()
    AniMods.W.OnReady(Apply)
end

-- Toggles live: Apply reads the flag and hands the mouse back when it is off,
-- so switching this off restores Blizzard's behaviour without a reload.
function ExtraButtonClicks:SetEnabled(on)
    moduleEnabled = on and true or false
    Apply()
    return true
end

AniMods.RegisterModule("ExtraButtonClicks", ExtraButtonClicks)
