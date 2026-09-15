-- NSRT Misc
-- The bag for small Northern Sky Raid Tools tweaks -- things its own UI cannot
-- do, either because they are batch edits it only offers one row at a time, or
-- because it offers no setting at all. Three so far: silencing boss-alert
-- countdowns (plus the button that undoes it), borrowing another addon's
-- countdown voice, and boxing the live line in the reminder note.
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
    dbKey = "nsrtMisc",
    category = "Addon Extras",
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
-- Current-line box
-- ---------------------------------------------------------------------------
-- MRT boxes the reminder line that is about to fire. NSRT draws its note as one
-- FontString and boxes nothing, so the line you need is the one you have to
-- find by reading -- which is the wrong job to give someone mid-pull.
--
-- NSRT's own countdown pass is what makes this cheap. NSI:CountdownNoteFrame
-- rebuilds the displayed text every tick during an encounter: it drops lines
-- whose timer has reached zero and rewrites the remaining times. So the first
-- line still on screen that carries a countdown IS the next thing that happens,
-- and there is nothing to track -- reading the text NSRT just drew answers it.
--
-- Hooked rather than reimplemented, and hooked on the function that does the
-- drawing, so the box cannot disagree with the text it is behind.
-- NorthernSkyRaidTools_UI hooks NSI methods the same way, so this is the
-- addon's own idiom rather than a liberty taken with it.

local NOTE_FRAMES = { "ReminderFrame", "PersonalReminderFrame", "ExtraReminderFrame" }
local BOX_ALPHA = 0.22
local BOX_PAD = 2

local lineBoxHooked = false
local scratchText

local function NS()
    local ns = _G.NorthernSkyRaidTools
    return type(ns) == "table" and ns or nil
end

local function LineBoxOn()
    local v = ModuleDB().lineBox
    if v == nil then return true end
    return v and true or false
end

-- Shown and transparent rather than hidden: a FontString on a hidden frame is
-- not guaranteed to have been laid out, and an unlaid-out string measures zero.
-- Parked far off-screen so being shown costs nothing visible.
local function Scratch()
    if not scratchText then
        local holder = _G.CreateFrame("Frame", nil, _G.UIParent)
        holder:SetSize(1, 1)
        holder:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", -5000, 5000)
        holder:SetAlpha(0)
        scratchText = holder:CreateFontString(nil, "ARTWORK")
        scratchText:SetJustifyH("LEFT")
        scratchText:SetJustifyV("TOP")
    end
    return scratchText
end

-- Measured against a copy of the note's own font and width, never computed from
-- the font size and a line count. The note wraps -- NSRT builds it with
-- SetWordWrap(true) and a fixed width -- so a long assignment is two rows tall,
-- and arithmetic would put the box in the wrong place for exactly the lines
-- long enough to be worth boxing.
local function MeasuredHeight(noteText, text)
    if not text or text == "" then return 0 end
    local file, size, flags = noteText:GetFont()
    if not file then return 0 end
    local fs = Scratch()
    fs:SetFont(file, size, flags)
    fs:SetSpacing(noteText:GetSpacing() or 0)
    fs:SetWidth(noteText:GetWidth())
    fs:SetWordWrap(true)
    fs:SetNonSpaceWrap(true)
    fs:SetText(text)
    return fs:GetStringHeight() or 0
end

local function SplitLines(text)
    local out = {}
    -- CountdownNoteFrame always appends a trailing newline; stripping it here
    -- keeps that from counting as an empty row at the bottom.
    for line in (text:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

-- Same pattern NSRT parses its own note with, so a line this boxes is a line
-- NSRT considers timed.
local function CurrentLineIndex(lines)
    for i = 1, #lines do
        if lines[i]:match("%d+:%d%d") then return i end
    end
    return nil
end

local function HideBox(frame)
    if frame and frame.AniModsLineBox then frame.AniModsLineBox:Hide() end
end

-- ── Keeping the line that just fired ────────────────────────────────────────
--
-- NSRT removes a line the instant its countdown reaches zero, which is the
-- moment you are most likely to look at it -- the thing that just happened
-- disappears as it happens, and the box lands hard against the top edge with no
-- context above it. One line of history fixes both.
--
-- Which line that is comes from WATCHING rather than from re-deriving NSRT's
-- visibility rule. Duplicating that rule would mean two copies drifting apart
-- on NSRT's next release; instead each pass remembers what NSRT drew, and the
-- line that vanishes off the top between one pass and the next is by definition
-- the one that just fired.
--
-- The comparison has to ignore the time, because NSRT rewrites every countdown
-- on every tick -- so the text of a line changes constantly while the line
-- itself has not moved. Stripping the times leaves an identity that only
-- changes when the line really does.
local function LineIdentity(line)
    return (line:gsub("%d+:%d%d", ""))
end

local function KeepPrevOn()
    local v = ModuleDB().keepPrevLine
    if v == nil then return true end
    return v and true or false
end

-- NSRT's own text, not ours. Reading frame.Text back would feed our prepended
-- line into the next comparison and keep it forever.
local function TrackExpiredLine(frame)
    local current = frame.CountdownDisplayedText
    if not current then return end
    local previous = frame.AniModsPrevNSRT
    if current == previous then return end

    if previous then
        local prevFirst = SplitLines(previous)[1]
        local curFirst = SplitLines(current)[1]
        if prevFirst and curFirst and LineIdentity(prevFirst) ~= LineIdentity(curFirst) then
            -- Shown at 0:00 rather than frozen at whatever it last rendered.
            -- The last value drawn was always above zero -- a line is dropped
            -- only once its time has passed -- so leaving it would show a
            -- countdown still running for something already done.
            frame.AniModsKeptLine = (prevFirst:gsub("%d+:%d%d", "0:00"))
        end
    end
    frame.AniModsPrevNSRT = current
end

local function ClearKeptLine(frame)
    if not frame then return end
    frame.AniModsKeptLine = nil
    frame.AniModsPrevNSRT = nil
end

local function UpdateBox(frame)
    if not (frame and frame.Text) then return end
    if not (LineBoxOn() and moduleEnabled and frame:IsShown()) then
        HideBox(frame)
        return
    end

    local nsrtText = frame.CountdownDisplayedText
    if not nsrtText or nsrtText == "" then HideBox(frame) return end

    -- Index is taken on NSRT's text and shifted, not searched for in the final
    -- string: the kept line still carries a time, so a search would find IT and
    -- box the thing that is already over.
    local index = CurrentLineIndex(SplitLines(nsrtText))
    if not index then HideBox(frame) return end

    local text = nsrtText
    if KeepPrevOn() then
        TrackExpiredLine(frame)
        local kept = frame.AniModsKeptLine
        if kept then
            text = kept .. "\n" .. nsrtText
            index = index + 1
        end
    end

    -- NSRT only calls SetText when ITS text changes, so once ours is in place it
    -- stays until NSRT genuinely redraws. Guarded anyway: SetText every tick on
    -- an unchanged string is layout work for nothing.
    if frame.Text:GetText() ~= text then frame.Text:SetText(text) end

    local lines = SplitLines(text)
    if not lines[index] then HideBox(frame) return end

    local spacing = frame.Text:GetSpacing() or 0
    local top = 0
    if index > 1 then
        -- The gap BELOW the preceding block is part of the offset: a string of
        -- n lines measures n rows plus n-1 gaps, and the next row starts one
        -- more gap down.
        top = MeasuredHeight(frame.Text, table.concat(lines, "\n", 1, index - 1)) + spacing
    end
    local height = MeasuredHeight(frame.Text, lines[index])
    if height <= 0 then HideBox(frame) return end

    local box = frame.AniModsLineBox
    if not box then
        -- ARTWORK, while NSRT draws the note on OVERLAY sublevel 7 -- so the
        -- box is behind its own text without touching NSRT's draw order.
        -- Parented to the note frame, which sets SetClipsChildren(true), so a
        -- box near the bottom edge is clipped with the text rather than
        -- hanging out of the panel.
        box = frame:CreateTexture(nil, "ARTWORK")
        frame.AniModsLineBox = box
    end

    local r, g, b = AniMods.W.Accent()
    box:SetColorTexture(r, g, b, BOX_ALPHA)
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", frame.Text, "TOPLEFT", -BOX_PAD, -top + BOX_PAD)
    box:SetPoint("TOPRIGHT", frame.Text, "TOPRIGHT", BOX_PAD, -top + BOX_PAD)
    box:SetHeight(height + BOX_PAD * 2)
    box:Show()
end

local function HideAllBoxes()
    local ns = NS()
    if not ns then return end
    for _, name in ipairs(NOTE_FRAMES) do
        HideBox(ns[name])
        ClearKeptLine(ns[name])
    end
end

-- Installed lazily and once, for the same reason the countdown override is:
-- hooksecurefunc cannot be undone, so it is only taken out when the setting
-- actually asks for it. After that the flag inside UpdateBox does the work.
local function InstallLineBox()
    if lineBoxHooked then return true end
    local ns = NS()
    if not ns or type(ns.CountdownNoteFrame) ~= "function" then return false end
    if type(ns.UpdateNoteFrame) ~= "function" then return false end

    lineBoxHooked = true
    _G.hooksecurefunc(ns, "CountdownNoteFrame", function(_, frame) UpdateBox(frame) end)
    -- The note text is also replaced wholesale outside the countdown path (a
    -- new note arrives, a setting changes, an encounter ends). Where the box
    -- goes is the countdown's answer, so there is nothing valid to draw until it
    -- next runs -- and the remembered line belongs to the note that just went
    -- away, so it goes with it. Without this, the first countdown of the next
    -- pull would open with a line left over from the last one.
    _G.hooksecurefunc(ns, "UpdateNoteFrame", function(_, name)
        local frame = name and ns[name]
        HideBox(frame)
        ClearKeptLine(frame)
    end)
    return true
end

local function ApplyLineBox()
    if moduleEnabled and LineBoxOn() then
        InstallLineBox()
    else
        HideAllBoxes()
    end
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
             .. "non-NSRT voice is chosen.",
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

    rows[#rows + 1] = { section = "Reminder note" }
    rows[#rows + 1] = {
        label = "Box the current line",
        get   = LineBoxOn,
        set   = function(v) ModuleDB().lineBox = v and true or false; ApplyLineBox() end,
        help  = "Draws a box behind the note line that is about to fire, the "
             .. "way MRT does. NSRT draws its note as one block and boxes "
             .. "nothing, so mid-pull the line you need is the one you have to "
             .. "find by reading.",
    }
    if LineBoxOn() then
        rows[#rows + 1] = {
            label = "Keep the line that just fired",
            get   = KeepPrevOn,
            set   = function(v)
                ModuleDB().keepPrevLine = v and true or false
                HideAllBoxes()
            end,
            help  = "NSRT removes a line the instant its countdown reaches "
                 .. "zero -- the thing that just happened disappears as it "
                 .. "happens, and the box sits against the top edge with no "
                 .. "context above it. This holds that one line, shown at "
                 .. "0:00, until the next one fires.",
        }
        local boxed, ns = nil, NS()
        if ns then
            for _, name in ipairs(NOTE_FRAMES) do
                local f = ns[name]
                if f and f.AniModsLineBox and f.AniModsLineBox:IsShown() then
                    boxed = name
                    break
                end
            end
        end
        rows[#rows + 1] = {
            label = "Hooked into NSRT",
            state = lineBoxHooked,
            help  = "The box is positioned from the text NSRT has just drawn, "
                 .. "by hooking the function that draws it -- so it cannot "
                 .. "disagree with the line it sits behind. Installed the first "
                 .. "time this is switched on, and never uninstalled: "
                 .. "hooksecurefunc cannot be undone, so the setting gates the "
                 .. "work rather than the hook.",
        }
        rows[#rows + 1] = {
            label = "Boxing now",
            value = boxed or "nothing",
            help  = "A line only carries a box while its countdown is running, "
                 .. "so \"nothing\" outside an encounter is the right answer.",
        }
    end

    return rows
end

-- The only startup work is re-installing the override for a source chosen in a
-- previous session -- and only then. It owns no frames, registers no events,
-- and on the default source does nothing at all.
--
-- Deferred to W.OnReady rather than PLAYER_LOGIN because NSAPI is created by
-- NSRT's own boot; that callback is the first point after it where everything
-- is guaranteed up. Same sequencing the other modules use.
-- No retry ladder here, unlike GroupRoles and EllesmereUI Misc.
--
-- Those wait on EllesmereUI FRAMES, which it builds on its own schedule long
-- after login. This waits on a FUNCTION, and NSRT defines NSAPI.TTSCountdown
-- while its files load -- so it is already there by PLAYER_LOGIN, which is when
-- Enable runs. There is no window left to retry into, and a ladder guarding a
-- case that cannot happen is the kind of code nothing ever proves dead.
--
-- The current-line box is the one thing here that DOES wait on frames: NSRT
-- builds its note frames lazily, in UpdateReminderFrame, which can be long
-- after login. It needs no ladder either though -- the hook goes on the NSI
-- method, which exists from the moment NSRT's files load, and the frames are
-- only ever touched from inside that hook, by which time they exist.
function NSRTMisc:Enable()
    moduleEnabled = true
    AniMods.W.OnReady(ApplyLineBox)
    if CurrentSource() == SOURCE_NSRT then return end
    AniMods.W.OnReady(InstallOverride)
end

-- Toggles live, so the sidebar power button means something here rather than
-- asking for a reload.
--
-- Just the flag. Switching on does not need to install anything: every path
-- that selects a non-NSRT source installs at the moment it is selected
-- (ApplySource) or at the next login (Enable), so by the time this runs the
-- override is either already in place or not wanted.
function NSRTMisc:SetEnabled(on)
    moduleEnabled = on and true or false
    -- The box is the exception: it draws something, so switching off has to
    -- take it off the screen rather than wait for a tick that is not coming
    -- outside an encounter.
    ApplyLineBox()
    return true
end

AniMods.RegisterModule("NSRTMisc", NSRTMisc)
