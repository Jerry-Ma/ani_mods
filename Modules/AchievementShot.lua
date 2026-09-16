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
-- Stands down under NDui. This used to argue the opposite -- that the check
-- cost more to explain than the duplicate registration cost to run -- which
-- weighed the wrong thing entirely: the cost is not an event handler, it is that
-- both copies fire and you get TWO screenshots for every achievement, in a
-- folder nothing prunes. A duplicate here is a visible bug, not an overhead.

local AniMods = _G.AniMods

local AchievementShot = {
    title = "Achievement Screenshot",
    description = "Takes a screenshot when you earn an achievement.",
    dbKey = "achievementShot",
    category = "Automation",
    conditions = {
        { text = "NDui not loaded",
          help = "NDui already takes a screenshot when you earn an achievement "
              .. "(Modules/Misc/Misc.lua), and two copies watching the same "
              .. "event means two files for every achievement.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
    },
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

-- A burst of achievements produces ONE screenshot, not one each.
--
-- This is the part of NDui's behaviour that the OnUpdate was quietly providing.
-- Its handler set `delay = 1` on a single shared frame, so a second achievement
-- arriving mid-countdown restarted the clock rather than queuing a second shot.
-- Swapping to one C_Timer.After per event lost that: finishing a quest chain or
-- zoning into a new area can award several at once, and each would have taken
-- its own screenshot of the same screen.
--
-- Restored deliberately rather than accidentally: `fireAt` is pushed forward on
-- every achievement, and the timer re-arms itself for whatever is left instead
-- of firing early.
local pending = false
local fireAt = 0

local function Fire()
    local remaining = fireAt - _G.GetTime()
    if remaining > 0 then
        _G.C_Timer.After(remaining, Fire)
        return
    end
    pending = false
    if not moduleEnabled then return end
    taken = taken + 1
    _G.Screenshot()
    -- The count is the only evidence this module works, and a panel left open
    -- across an achievement showed the figure it had when the tab was built.
    -- Nothing else here changes state, so this is the one place that has to say
    -- so.
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

local function Schedule()
    fireAt = _G.GetTime() + GetDelay()
    if pending then return end
    pending = true
    _G.C_Timer.After(GetDelay(), Fire)
end

-- An OnEvent script is called as (self, event, ...), so ACHIEVEMENT_EARNED's
-- own two payload arguments -- achievementID, then alreadyEarned -- are the
-- THIRD and FOURTH parameters here.
--
-- Getting that wrong is silent and total. An earlier version took three
-- parameters and read achievementID as the already-earned flag; an ID is always
-- a truthy number, so the skip below fired for every achievement and the module
-- never took a single screenshot. Nothing errored, the panel still said
-- "Active", and the only symptom was a count that stayed at zero. The names are
-- spelled out rather than left as `_` for that reason.
local function OnAchievement(_, _, achievementID, alreadyEarnedOnAccount)
    if not moduleEnabled then return end
    if alreadyEarnedOnAccount and ModuleDB().skipAccountEarned ~= false then return end
    Schedule()
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
    rows[#rows + 1] = {
        kind = "button", label = "Test", button = "Take one now",
        help = "Runs the same path an achievement does, delay included, so it "
            .. "proves the whole thing rather than just that Screenshot() "
            .. "exists. The file lands in the Screenshots folder next to your "
            .. "WTF folder, named by date and time; the count above ticks up "
            .. "once the delay elapses.",
        onClick = Schedule,
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
