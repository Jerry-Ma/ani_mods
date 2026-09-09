-- NSRT Misc
-- The bag for small Northern Sky Raid Tools tweaks -- batch edits its own UI
-- can only make one row at a time. One entry so far.
--
-- ── Silencing boss-alert countdowns ──────────────────────────────────────────
--
-- NSRT's encounter alerts each carry a `countdown` field, and the value that
-- matters is what it means when ABSENT (Reminders.lua:112):
--
--     if info.countdown == nil then
--         info.countdown = info.spellID and NSRT.ReminderSettings.SpellCountdown
--                                        or NSRT.ReminderSettings.TextCountdown
--         if info.countdown == 0 then info.countdown = false end
--     end
--
-- nil means INHERIT the global setting. Every built-in boss alert ships without
-- the key, so switching TTS countdowns on for your own note reminders switches
-- them on for all ~200 boss alerts too -- one setting, two populations, which is
-- the thing being separated here.
--
-- ── Why `false` and not `0` ──────────────────────────────────────────────────
--
-- NSRT's own UI writes `false` when you type 0 (its EncounterAlerts.lua:2980,
-- `(v and v > 0) and v or false`), so "countdown for 0 seconds" in that UI IS
-- `countdown = false` in the data. This writes the same value, which is what
-- makes the button equivalent to doing it by hand rather than merely similar.
--
-- A literal 0 would look right and behave differently. 0 is truthy in Lua, so
-- it skips the inherit branch as intended but then survives to
-- Reminders.lua:1293's `if info.countdown then`, which schedules a timer that
-- fires at the end of the alert and calls TTSCountdown(0) -- a no-op loop
-- (`for i = 0, 1, -1`). Harmless, and pointless work per alert per pull.
-- `false` fails `tonumber` at line 119, becomes nil, and no timer is scheduled.

local NSRTMisc = {
    title = "NSRT Misc",
    description = "Batch tweaks for Northern Sky Raid Tools.",
    conditions = {
        { text = "NorthernSkyRaidTools loaded",
          help = "Everything here edits NSRT's own saved settings, so it needs "
              .. "NSRT.",
          met = function() return AniMods.IsAddOnLoaded("NorthernSkyRaidTools") end },
    },
}

-- ---------------------------------------------------------------------------
-- Walking NSRT's alert table
-- ---------------------------------------------------------------------------

-- NSRT.EncounterAlerts[encounterID][difficultyID][alertKey] = alert
--
-- Every level is type-checked. This is another addon's saved variables: it
-- survives its upgrades, its migrations and its profile imports, and a shape we
-- did not expect must make this do nothing rather than error inside a loop
-- halfway through a batch edit.
local function ForEachAlert(fn)
    local root = _G.NSRT and _G.NSRT.EncounterAlerts
    if type(root) ~= "table" then return end

    for _, byDifficulty in pairs(root) do
        if type(byDifficulty) == "table" then
            for _, alerts in pairs(byDifficulty) do
                if type(alerts) == "table" then
                    for _, alert in pairs(alerts) do
                        if type(alert) == "table" then fn(alert) end
                    end
                end
            end
        end
    end
end

-- Total alerts, and how many already have their countdown explicitly off.
local function CountAlerts()
    local total, silenced = 0, 0
    ForEachAlert(function(alert)
        total = total + 1
        if alert.countdown == false then silenced = silenced + 1 end
    end)
    return total, silenced
end

-- `false` on every alert. See the header for why not 0, and why not nil.
local function SilenceAll()
    local changed = 0
    ForEachAlert(function(alert)
        if alert.countdown ~= false then
            alert.countdown = false
            changed = changed + 1
        end
    end)
    return changed
end

-- Back to nil, which is "inherit the global setting" -- the state a freshly
-- shipped alert is in, not "countdown off".
--
-- Worth having rather than leaving the batch one-way: this edits a couple of
-- hundred rows of someone else's saved settings at a click, and the only other
-- way back is NSRT's own per-alert reset, one alert at a time.
local function RestoreAll()
    local changed = 0
    ForEachAlert(function(alert)
        if alert.countdown ~= nil then
            alert.countdown = nil
            changed = changed + 1
        end
    end)
    return changed
end

local function Report(message)
    print("|cff33ccffAniMods|r: " .. message)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function NSRTMisc:GetInfoRows()
    local rows = {}
    local total, silenced = CountAlerts()

    rows[#rows + 1] = { section = "Boss alert countdowns" }

    if total == 0 then
        rows[#rows + 1] = {
            label = "Boss alerts found",
            state = false,
            help  = "NSRT has no encounter alerts loaded yet. They appear once "
                 .. "it has built its alert table for this character.",
        }
        return rows
    end

    rows[#rows + 1] = { label = "Boss alerts", value = tostring(total) }
    rows[#rows + 1] = {
        label = "Countdown silenced",
        value = ("%d of %d"):format(silenced, total),
        help  = "Alerts whose countdown is explicitly off. The rest follow "
             .. "NSRT's global TTS countdown setting, which is the one shared "
             .. "with your own note reminders.",
    }

    rows[#rows + 1] = {
        label  = "Silence every countdown",
        button = "Apply",
        help   = "Sets every boss alert's countdown to 0 -- exactly what typing "
              .. "0 into NSRT's own Countdown box does, for all of them at once. "
              .. "Your note reminders keep the global setting.",
        onClick = function()
            local changed = SilenceAll()
            Report(changed == 0
                and "every boss alert countdown was already off."
                or ("silenced %d boss alert countdown%s."):format(
                    changed, changed == 1 and "" or "s"))
        end,
    }

    rows[#rows + 1] = {
        label  = "Restore to default",
        button = "Restore",
        help   = "Clears the countdown on every boss alert so they follow NSRT's "
              .. "global setting again -- the state they ship in. This undoes "
              .. "Apply above; it does not turn countdowns off.",
        onClick = function()
            local changed = RestoreAll()
            Report(changed == 0
                and "every boss alert countdown was already at its default."
                or ("restored %d boss alert countdown%s to the NSRT default."):format(
                    changed, changed == 1 and "" or "s"))
        end,
    }

    return rows
end

-- No Enable: this module has nothing to start. It owns no frames, hooks
-- nothing, and registers no events -- everything it does happens on a click in
-- its own tab. Core treats a module with no Enable as active rather than
-- failed, which is the correct reading here.

AniMods.RegisterModule("NSRTMisc", NSRTMisc)
