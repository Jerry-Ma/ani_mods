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
-- Countdown voice
-- ---------------------------------------------------------------------------
-- NSRT counts down in its own bundled voice and offers no way to change it.
-- BigWigs and EXBoss each already have a voice the player has chosen and is
-- used to; this borrows whichever one they point at.
--
-- ── Why the two are read so differently ─────────────────────────────────────
--
-- Both are asked "what should second N sound like", but only one of them
-- answers with a file:
--
--   BigWigs   BigWigsAPI:GetCountdownSound(voiceID, n) -> a sound file path,
--             which we play. The chosen voice is the Countdown plugin's
--             db.profile.voice. Voice packs register 5-10 entries, so a
--             countdown longer than the pack is simply silent past its range,
--             exactly as it would be inside BigWigs.
--   EXBoss    ExBoss.Voice.Countdown:TryPlayDigit(n) -- it PLAYS the digit
--             itself, resolving its own selected pack, that pack's per-digit
--             enable flags and any per-digit LibSharedMedia override on the
--             way. Asking it for a path instead would mean reimplementing all
--             of that and getting it wrong the first time its settings change.
--             Its range is 1-5.
--
-- Take the highest-level call each addon offers, rather than normalising them
-- into a shape of our own: the shape of our own would be a third opinion about
-- how their settings work.
local SOURCE_NSRT, SOURCE_BIGWIGS, SOURCE_EXBOSS = "nsrt", "bigwigs", "exboss"

local SOURCE_LABEL = {
    [SOURCE_NSRT]    = "NSRT (built-in)",
    [SOURCE_BIGWIGS] = "BigWigs",
    [SOURCE_EXBOSS]  = "EXBoss",
}
local SOURCE_ORDER = { SOURCE_NSRT, SOURCE_BIGWIGS, SOURCE_EXBOSS }

local function ModuleDB()
    AniModsDB.nsrtMisc = AniModsDB.nsrtMisc or {}
    return AniModsDB.nsrtMisc
end

-- The BigWigs Countdown plugin's chosen voice id, or nil when BigWigs is not
-- there. Read live rather than cached: it changes in BigWigs' own options, and
-- nothing tells us when.
local function BigWigsVoice()
    local BigWigs = _G.BigWigs
    if not (BigWigs and BigWigs.GetPlugin) then return nil end
    local ok, plugin = pcall(BigWigs.GetPlugin, BigWigs, "Countdown", true)
    if not ok or not plugin then return nil end
    local db = plugin.db and plugin.db.profile
    return db and db.voice or nil
end

local function ExBossCountdown()
    local ExBoss = _G.ExBoss
    local countdown = ExBoss and ExBoss.Voice and ExBoss.Voice.Countdown
    if countdown and type(countdown.TryPlayDigit) == "function" then
        return countdown
    end
    return nil
end

-- Whether a source could actually produce a countdown right now. Drives both
-- the greying-out in the dropdown and the fall back to NSRT's own voice, so a
-- source that disappears mid-session degrades instead of going silent.
local function SourceAvailable(source)
    if source == SOURCE_BIGWIGS then
        local api = _G.BigWigsAPI
        return (api and api.GetCountdownSound and BigWigsVoice()) and true or false
    elseif source == SOURCE_EXBOSS then
        return ExBossCountdown() ~= nil
    end
    return true   -- NSRT's own voice is always available; it ships the files
end

local function CurrentSource()
    local source = ModuleDB().countdownSource
    if source and SOURCE_LABEL[source] then return source end
    return SOURCE_NSRT
end

-- Plays one digit through the chosen source. Returns false when that source
-- has nothing for this number -- a countdown longer than the pack's range --
-- which is silence for that digit, matching what the source itself would do.
local function PlayDigit(source, digit)
    if source == SOURCE_BIGWIGS then
        local api = _G.BigWigsAPI
        local voice = BigWigsVoice()
        if not (voice and api and api.GetCountdownSound) then return false end

        -- COLON, not dot. BigWigsAPI is defined with colon methods
        -- (`function API:GetCountdownSound(id, index)`), so its real first
        -- parameter is self. Calling it with a dot passed the voice id as self
        -- and the digit as `id`, which looked up voices[5] -- a voice named
        -- "5" -- and returned nil every time, so BigWigs was silently never
        -- producing a sound.
        --
        -- Easy to get wrong from BigWigs' own code, which reads
        -- `BigWigsAPI.GetCountdownList()` with a dot in places: that one
        -- ignores self, so both forms work for it and neither form proves
        -- anything about the rest of the table. The colon calls elsewhere
        -- (BigWigsAPI:HasCountdown, BigWigsAPI:GetCountdownList) are the ones
        -- that say what the convention actually is.
        local path = api:GetCountdownSound(voice, digit)
        if not path then return false end
        PlaySoundFile(path, "Master")
        return true
    elseif source == SOURCE_EXBOSS then
        local countdown = ExBossCountdown()
        if not countdown then return false end
        local ok, played = pcall(countdown.TryPlayDigit, countdown, digit)
        return ok and played ~= false
    end
    return false
end

-- ── The override ────────────────────────────────────────────────────────────
--
-- NSAPI.TTSCountdown is REPLACED rather than hooked, and that is the one
-- invasive thing this addon does to another. A hook can only add: hooksecurefunc
-- appends, so NSRT's own voice would still play underneath and the result would
-- be two countdowns at once. The point here is substitution.
--
-- It is contained about it: the original is kept and called for every case the
-- override does not claim -- NSRT selected, the chosen source unavailable, the
-- module switched off. So the replacement is a router, and NSRT's behaviour is
-- the default branch rather than something that had to be reimplemented.
local originalTTSCountdown
local overrideEnabled = true

local function InstallOverride()
    if originalTTSCountdown then return end
    local NSAPI = _G.NSAPI
    if not (NSAPI and type(NSAPI.TTSCountdown) == "function") then return end

    originalTTSCountdown = NSAPI.TTSCountdown

    -- Assigning over a function this file also read. That is the substitution,
    -- not an accident.
    ---@diagnostic disable-next-line: duplicate-set-field
    NSAPI.TTSCountdown = function(apiSelf, num)
        local source = CurrentSource()
        if not overrideEnabled or source == SOURCE_NSRT or not SourceAvailable(source) then
            return originalTTSCountdown(apiSelf, num)
        end

        num = tonumber(num)
        if not num or num < 1 then return end

        -- NSRT gates all of its own audio on this, inside NSAPI:TTS. Reading it
        -- here keeps "TTS off" meaning what it means everywhere else in NSRT,
        -- rather than this override being the one sound that ignores it.
        local settings = _G.NSRT and _G.NSRT.Settings
        if settings and not settings["TTS"] then return end

        -- Same schedule NSRT uses: the first digit now, each later one at
        -- (num - i) seconds. One timer per digit, all one-shot.
        for i = num, 1, -1 do
            local delay = num - i
            if delay == 0 then
                PlayDigit(source, i)
            else
                C_Timer.After(delay, function() PlayDigit(source, i) end)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function NSRTMisc:GetInfoRows()
    local rows = {}
    local total, silenced = CountAlerts()

    -- ── Countdown voice ─────────────────────────────────────────────────────
    --
    -- The unavailable sources are greyed rather than dropped. A missing choice
    -- explains nothing; a greyed one says the option exists and what would make
    -- it usable.
    --
    -- No listener on BigWigs' or EXBoss' settings, deliberately. Both are read
    -- at the moment a digit plays, so re-configuring either is picked up with
    -- no notification, no cached copy to invalidate, and nothing to keep in
    -- step. The dropdown here chooses WHICH addon to ask, never what it says.
    local disabled = {}
    for _, source in ipairs(SOURCE_ORDER) do
        disabled[source] = not SourceAvailable(source)
    end

    rows[#rows + 1] = { section = "Countdown voice" }
    rows[#rows + 1] = {
        label    = "Use voice from",
        options  = SOURCE_LABEL,
        order    = SOURCE_ORDER,
        disabled = disabled,
        help     = "NSRT counts down in its own bundled voice with no way to "
                .. "change it. This borrows whichever voice you have already "
                .. "chosen in BigWigs or EXBoss -- change it there and this "
                .. "follows, with nothing to set up twice.",
        get      = CurrentSource,
        set      = function(v) ModuleDB().countdownSource = v end,
    }

    local source = CurrentSource()
    if source ~= SOURCE_NSRT then
        local ok = SourceAvailable(source)
        rows[#rows + 1] = {
            label = ("%s voice available"):format(SOURCE_LABEL[source]),
            state = ok,
            help  = (not ok) and (source == SOURCE_BIGWIGS
                and "BigWigs is not loaded, or its Countdown plugin has no voice "
                 .. "selected. NSRT's own voice is used until it does."
                or "EXBoss is not loaded, or its countdown voice module has not "
                .. "finished loading. NSRT's own voice is used until it does.")
                or nil,
        }
    end

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
        -- Short enough not to be clamped in the label column; the "?" carries
        -- what it actually does.
        label  = "Silence all",
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
        label  = "Restore defaults",
        button = "Apply",
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

-- Installs the countdown router. The batch buttons need no setup at all --
-- they act on a click -- so this is the module's only startup work.
--
-- Deferred to W.OnReady rather than run at PLAYER_LOGIN: NSAPI is created by
-- NSRT's own boot, and that callback is the first point after it where
-- everything is guaranteed up. Same sequencing the other modules use.
function NSRTMisc:Enable()
    overrideEnabled = true
    AniMods.W.OnReady(InstallOverride)
end

-- Toggles live, because the override is a router: switching the module off
-- makes it take the pass-through branch on the next countdown, which is
-- indistinguishable from never having been installed.
--
-- The replacement itself is NOT uninstalled. Putting the original back is only
-- safe if nothing else replaced NSAPI.TTSCountdown afterwards, and restoring
-- over another addon's function would silently undo its work -- the same reason
-- hooksecurefunc has no inverse. Leaving an inert router in place costs one
-- boolean test per countdown.
function NSRTMisc:SetEnabled(on)
    overrideEnabled = on and true or false
    return true
end

AniMods.RegisterModule("NSRTMisc", NSRTMisc)
