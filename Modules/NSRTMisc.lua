-- NSRT Misc
-- The bag for small Northern Sky Raid Tools tweaks -- batch edits its own UI
-- can only make one row at a time. One entry so far, plus the button that
-- undoes it.
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
--
-- ── The countdown voice, and its one hard rule ───────────────────────────────
--
-- The other entry plays NSRT's countdown in BigWigs' or EXBoss' voice, by
-- replacing NSAPI.TTSCountdown.
--
-- NOTHING IS REPLACED UNTIL A NON-NSRT SOURCE IS CHOSEN. On the default setting
-- this module does not touch NSAPI at all -- it reads no field and assigns
-- none. That is not politeness, it is the property that makes the feature
-- diagnosable: setting the source back to NSRT returns AniMods to having zero
-- footprint on NSRT, so "is this addon involved" is answerable by one dropdown
-- change instead of by disabling things and reloading.
--
-- It matters because NSAPI.TTSCountdown has other claimants.
-- NSRT_Countdown_Companion replaces the same function when it is enabled, and a
-- function has room for exactly one owner: whoever installs second wraps the
-- first, and which that is depends on load order. Installing lazily means we
-- are not in that contest unless the player has actually asked us to be.

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
--
-- Nothing calls this at login. The batch is a one-shot that NSRT then persists,
-- so it runs on a button click and nowhere else; the only other reader is the
-- count below, which fills in a row while this tab is open.
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
-- Each addon is asked at its highest level rather than normalised into a shape
-- of ours, because a shape of ours would be a third opinion about how their
-- settings work:
--
--   BigWigs   BigWigsAPI:GetCountdownSound(voiceID, n) -> a sound file path,
--             which we play. The chosen voice is the Countdown plugin's
--             db.profile.voice. Packs carry 5-10 entries, so a longer countdown
--             is simply silent past the pack's range, as it is inside BigWigs.
--             COLON, not dot: the API is colon-defined, so a dot call passes
--             the voice id as self and the digit as `id`, looks up a voice
--             NAMED "5", and returns nil every time -- silence, no error.
--   EXBoss    ExBoss.Voice.Countdown:TryPlayDigit(n) -- it PLAYS the digit
--             itself, resolving its selected pack, that pack's per-digit
--             switches and any per-digit LibSharedMedia override on the way.
--             Range 1-5.
--
-- Neither is cached, so neither needs a listener: re-configuring BigWigs or
-- EXBoss is picked up by the very next countdown. The dropdown chooses WHICH
-- addon to ask, never what it says.
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

local function CurrentSource()
    local source = ModuleDB().countdownSource
    if source and SOURCE_LABEL[source] then return source end
    return SOURCE_NSRT
end

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

local function SourceAvailable(source)
    if source == SOURCE_BIGWIGS then
        local api = _G.BigWigsAPI
        return (api and api.GetCountdownSound and BigWigsVoice()) and true or false
    elseif source == SOURCE_EXBOSS then
        return ExBossCountdown() ~= nil
    end
    return true
end

-- Returns false when the source has nothing for this number -- a countdown
-- past the pack's range -- which is silence for that digit, matching what the
-- source itself would do.
local function PlayDigit(source, digit)
    if source == SOURCE_BIGWIGS then
        local api = _G.BigWigsAPI
        local voice = BigWigsVoice()
        if not (voice and api and api.GetCountdownSound) then return false end
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
-- Replaced rather than hooked, because a hook can only ADD: hooksecurefunc
-- appends, so NSRT's own voice would still play underneath and you would hear
-- two countdowns.
--
-- Contained by being a ROUTER. The original is kept and called for every case
-- the override does not claim, so NSRT's behaviour is the default branch rather
-- than something reimplemented -- and by the time this is installed at all, the
-- player has chosen a source, so the claimed case is the one they asked for.
local originalTTSCountdown

-- Switched off by the module's own power button. Checked inside the router
-- rather than used to uninstall anything: putting the original function back is
-- only safe if nothing else has replaced it since, and restoring over another
-- addon's replacement would silently undo its work -- the same reason
-- hooksecurefunc has no inverse.
--
-- So "off" means the router hands every countdown straight through, which is
-- indistinguishable from never having been installed, at the cost of one
-- boolean test per countdown.
local moduleEnabled = true

local function InstallOverride()
    if originalTTSCountdown then return true end
    local NSAPI = _G.NSAPI
    if not (NSAPI and type(NSAPI.TTSCountdown) == "function") then return false end

    originalTTSCountdown = NSAPI.TTSCountdown

    -- Assigning over a function this file also read. That is the substitution,
    -- not an accident.
    ---@diagnostic disable-next-line: duplicate-set-field
    NSAPI.TTSCountdown = function(apiSelf, num)
        local source = CurrentSource()
        if not moduleEnabled or source == SOURCE_NSRT or not SourceAvailable(source) then
            return originalTTSCountdown(apiSelf, num)
        end

        num = tonumber(num)
        if not num or num < 1 then return end

        -- NSRT gates all of its own audio on this, inside NSAPI:TTS. Reading it
        -- here keeps "TTS off" meaning what it means everywhere else in NSRT.
        local settings = _G.NSRT and _G.NSRT.Settings
        if settings and not settings["TTS"] then return end

        for i = num, 1, -1 do
            local delay = num - i
            if delay == 0 then
                PlayDigit(source, i)
            else
                C_Timer.After(delay, function() PlayDigit(source, i) end)
            end
        end
    end
    return true
end

-- Installed on demand, never at load. See the header: on the default setting
-- this module leaves NSAPI untouched, which is what makes "is AniMods involved"
-- answerable by changing one dropdown.
local function ApplySource(source)
    ModuleDB().countdownSource = source
    if source ~= SOURCE_NSRT then InstallOverride() end
end

local function OverrideInstalled()
    return originalTTSCountdown ~= nil
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function NSRTMisc:GetInfoRows()
    local rows = {}
    local total, silenced = CountAlerts()

    -- Unavailable sources are greyed rather than dropped: a missing choice
    -- explains nothing, a greyed one says what would make it usable.
    local disabled = {}
    for _, src in ipairs(SOURCE_ORDER) do
        disabled[src] = not SourceAvailable(src)
    end

    rows[#rows + 1] = { section = "Countdown voice" }
    rows[#rows + 1] = {
        label    = "Use voice from",
        options  = SOURCE_LABEL,
        order    = SOURCE_ORDER,
        disabled = disabled,
        help     = "NSRT counts down in its own bundled voice with no way to "
                .. "change it. This borrows the voice you already chose in "
                .. "BigWigs or EXBoss -- change it there and this follows.",
        get      = CurrentSource,
        set      = ApplySource,
    }

    -- Reported because it is the one thing about this module worth being able
    -- to check: whether AniMods has replaced anything inside NSRT. On the
    -- default source it never does, and this says so.
    rows[#rows + 1] = {
        label = "NSRT countdown replaced",
        state = OverrideInstalled(),
        help  = OverrideInstalled()
            and "AniMods owns NSRT's countdown until you reload. Setting the "
             .. "source back to NSRT -- or switching this module off -- makes it "
             .. "hand every countdown straight back, but the replacement itself "
             .. "stays until the next reload."
            or  "AniMods has not touched NSRT. Nothing is installed until a "
             .. "non-NSRT voice is chosen. If a voice IS chosen and this still "
             .. "says No, NSRT had not loaded in time -- toggle the module off "
             .. "and on to retry.",
    }

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
              .. "Silence all above; it does not turn countdowns off.",
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

-- The only startup work is re-installing the override for a source chosen in a
-- previous session -- and only then. It owns no frames, registers no events,
-- and on the default source does nothing at all.
--
-- Deferred to W.OnReady rather than PLAYER_LOGIN because NSAPI is created by
-- NSRT's own boot; that callback is the first point after it where everything
-- is guaranteed up. Same sequencing the other modules use.
function NSRTMisc:Enable()
    moduleEnabled = true
    if CurrentSource() == SOURCE_NSRT then return end
    AniMods.W.OnReady(InstallOverride)
end

-- Toggles live, so the sidebar power button means something here rather than
-- asking for a reload.
--
-- Switching ON retries the install when a source is already selected. Not for
-- the "off at login" case -- Core only calls this for a module whose Enable
-- actually ran -- but for the one where the install FAILED: if NSRT had not
-- created NSAPI yet when Enable fired, InstallOverride returned false and
-- nothing ever retried it. Toggling the module is then the only way back, and
-- the status row is what shows it is needed.
function NSRTMisc:SetEnabled(on)
    moduleEnabled = on and true or false
    if moduleEnabled and CurrentSource() ~= SOURCE_NSRT then
        InstallOverride()
    end
    return true
end

AniMods.RegisterModule("NSRTMisc", NSRTMisc)
