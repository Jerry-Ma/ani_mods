-- AchievementShot
-- Takes a screenshot when you earn an achievement.
--
-- Ported from NDui (Modules/Misc/Misc.lua, ScreenShotOnEvent / UpdateScreenShot),
-- with two deliberate differences.
--
-- The delay. ACHIEVEMENT_EARNED fires before the toast has animated in, so
-- shooting immediately captures the moment without the thing worth capturing.
-- NDui waits about a second by counting elapsed in an OnUpdate; this uses a
-- one-shot C_Timer.After, which is the same wait without a frame handler
-- running between achievements.
--
-- The account filter. The event's second argument is true when the achievement
-- was already earned elsewhere on the account, which is the case that fires
-- while levelling an alt past things you did years ago. NDui skips those and so
-- does this: a screenshot folder full of re-earned achievements is noise.
--
-- No conditions. NDui has this feature, but NDui also has to be running for its
-- copy to work -- and this costs one event registration, so duplicating it when
-- both are installed is cheaper than the check would be to explain.

local AniMods = _G.AniMods

local AchievementShot = {
    title = "Achievement Screenshot",
    description = "Takes a screenshot when you earn an achievement.",
}

local function ModuleDB()
    AniModsDB.achievementShot = AniModsDB.achievementShot or {}
    return AniModsDB.achievementShot
end

-- Long enough for the toast to finish animating in. NDui uses the same figure.
local SHOT_DELAY = 1

local moduleEnabled = true
local taken = 0

local function GetDelay()
    local v = ModuleDB().delay
    if type(v) == "number" and v > 0 then return v end
    return SHOT_DELAY
end

local function OnAchievement(_, _, alreadyEarnedOnAccount)
    if not moduleEnabled then return end
    if alreadyEarnedOnAccount and ModuleDB().skipAccountEarned ~= false then return end
    _G.C_Timer.After(GetDelay(), function()
        if not moduleEnabled then return end
        taken = taken + 1
        _G.Screenshot()
    end)
end

local frame

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function AchievementShot:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Behaviour" }
    rows[#rows + 1] = {
        label = "Skip already earned on the account",
        get   = function() return ModuleDB().skipAccountEarned ~= false end,
        set   = function(v) ModuleDB().skipAccountEarned = v and true or false end,
        help  = "Levelling an alt re-fires achievements you earned years ago. "
             .. "With this on, only genuinely new ones are captured.",
    }
    rows[#rows + 1] = {
        label   = "Delay",
        min     = 0.2,
        max     = 3,
        step    = 0.1,
        get     = function() return GetDelay() end,
        set     = function(v) ModuleDB().delay = v end,
        help    = "The toast animates in after the event fires, so shooting "
               .. "immediately captures the screen without it.",
    }

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Taken this session",
        value = tostring(taken),
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function AchievementShot:Enable()
    moduleEnabled = true
    if frame then return end
    frame = _G.CreateFrame("Frame")
    frame:RegisterEvent("ACHIEVEMENT_EARNED")
    frame:SetScript("OnEvent", OnAchievement)
end

-- Toggles live. The registration stays put and the flag gates the handler:
-- one event that fires a handful of times a session is not worth the
-- register/unregister dance, and the already-scheduled timer checks the flag
-- again so switching off mid-delay does not fire a stray shot.
function AchievementShot:SetEnabled(on)
    moduleEnabled = on and true or false
    return true
end

AniMods.RegisterModule("AchievementShot", AchievementShot)
