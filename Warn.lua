-- Warn -- post a line into whatever on-screen warning display you already have.
--
-- NOT A DISPLAY OF OUR OWN. You have already placed, sized and coloured a
-- warning area; a second one from us would be another thing to move and
-- another style to keep in line with the rest. We post into yours, and when
-- there is none we stay quiet -- an unpositioned warning nobody asked for is
-- worse than no warning.
--
-- This started inside Gear Sync and moved here when a second module wanted
-- the same thing. Nothing about the plumbing was ever specific to gear: the
-- part that differs between callers is the sentence and the key it is filed
-- under, and both are arguments.
--
-- ── Why EllesmereUI is not one of these ──────────────────────────────────────
--
-- Its combat alert (EllesmereUIQoL.lua, ShowAlert) is the closest thing it
-- has, and it cannot take a message. The frame is an unnamed local that is
-- never exported, the only exported entry point is _combatAlertPreview(which),
-- and what that draws is AlertText(which) -- the words YOU configured for
-- entering or leaving combat, read from EllesmereUIDB. There is no argument
-- for text.
--
-- Getting a line in would mean overwriting combatAlertEnterText with ours and
-- putting it back afterwards, which corrupts a setting of yours to borrow a
-- frame for 1.85 seconds. Every other EllesmereUI warning -- durability,
-- movement, group death, ready-check mana -- is purpose-built the same way:
-- each formats its own sentence and none takes one.
--
-- So the order is NSRT then BigWigs, and this note is here so the missing
-- first entry reads as a finding rather than an oversight.
--
-- ── The two that do take one ─────────────────────────────────────────────────
--
-- They are different KINDS of channel and are used as each was built:
--
--   NSRT's QoL text display is a list of conditions that are true right now --
--   Gateway Useable, Reset Boss. A line goes up and stays up until the thing
--   stops being true. That is the shape of every warning posted through here,
--   and it is the better of the two for it.
--
--   BigWigs' message area is a stream of things that just happened. Ours is
--   posted once when the condition appears and expires on BigWigs' own
--   schedule, because re-posting a standing fact every few seconds is how a
--   warning becomes noise.

local AniMods = _G.AniMods

local Warn = {}
AniMods.Warn = Warn

local WARN_COLOR = { 1, 0.65, 0.25 }  -- W.BADGE_WARN, the amber the panel uses

-- The icon crop every WoW icon uses -- 4..60 of a 64px canvas trims the border
-- the art is drawn with. NSRT writes its own entries exactly this way.
local function IconEscape(icon, size)
    if not icon then return "" end
    return ("|T%s:%d:%d:0:0:64:64:4:60:4:60|t "):format(icon, size, size)
end

-- Reached by shape rather than by name, the way every other foreign-addon read
-- in AniMods is: the pieces we actually call have to be there, and a partial or
-- renamed install then reads as absent instead of erroring.
local function NSRTDisplay()
    local NSI = _G.NorthernSkyRaidTools
    if type(NSI) ~= "table" or type(NSI.UpdateQoLTextDisplay) ~= "function" then return nil end
    -- Its renderer reads NSRT.QoL.TextDisplay for anchor, font and offsets, so
    -- without that table there is nothing to draw into.
    local db = _G.NSRT
    if type(db) ~= "table" or type(db.QoL) ~= "table" or type(db.QoL.TextDisplay) ~= "table" then
        return nil
    end
    return NSI, db
end

local function BigWigsMessages()
    local bw = _G.BigWigs
    if type(bw) ~= "table" or type(bw.GetPlugin) ~= "function" then return nil end
    -- The silent form: a missing plugin returns nil rather than erroring.
    local ok, plugin = _G.pcall(bw.GetPlugin, bw, "Messages", true)
    if not ok or type(plugin) ~= "table" or type(plugin.SendMessage) ~= "function" then
        return nil
    end
    return plugin
end

-- `key` is the caller's, and is what keeps two modules' warnings apart: it is
-- written into another addon's saved variables, so it says whose it is on
-- sight and one module clearing its line cannot take down another's.
local BACKENDS = {
    {
        title  = "Northern Sky Raid Tools",
        detail = "Its QoL text display -- the one that says Gateway Useable or "
              .. "Reset Boss. The line stays up while the thing is true.",
        Available = function() return NSRTDisplay() ~= nil end,
        Show = function(key, text, icon)
            local NSI, db = NSRTDisplay()
            if not (NSI and db) then return false end
            -- Its renderer draws an entry only while NSRT.QoL[SettingsName] is
            -- truthy -- that is how its own displays are switched on and off in
            -- its options. Ours has no row there, so we set the flag ourselves.
            -- One boolean under a name that says who put it there; with AniMods
            -- gone it is read by nothing, since the entry it gated is gone too.
            db.QoL[key] = true
            NSI.QoLTextDisplays = NSI.QoLTextDisplays or {}
            NSI.QoLTextDisplays[key] = {
                SettingsName = key,
                text = IconEscape(icon, 12) .. text,
            }
            NSI:UpdateQoLTextDisplay()
            return true
        end,
        Clear = function(key)
            local NSI = NSRTDisplay()
            if not NSI or type(NSI.QoLTextDisplays) ~= "table" then return end
            if NSI.QoLTextDisplays[key] == nil then return end
            NSI.QoLTextDisplays[key] = nil
            NSI:UpdateQoLTextDisplay()
        end,
    },
    {
        title  = "BigWigs",
        detail = "Its message area, where boss warnings appear. Posted once "
              .. "when the thing becomes true rather than held there.",
        Available = function() return BigWigsMessages() ~= nil end,
        Show = function(_, text, icon)
            local plugin = BigWigsMessages()
            if not plugin then return false end
            -- BigWigs' own idiom, the one its Victory and Wipe plugins use.
            -- The colour is passed as a TABLE rather than a name, which is what
            -- makes the module and key arguments irrelevant: with a table it
            -- never consults the Colors plugin, so there is no boss module to
            -- pretend to be. Not emphasized -- that is the huge centre-screen
            -- treatment, and these are housekeeping notes, not mechanics.
            plugin:SendMessage("BigWigs_Message", plugin, nil, text, WARN_COLOR, icon, false)
            return true
        end,
        -- No Clear. A BigWigs message is something that already happened and
        -- fades on its own; there is nothing standing there to take away.
    },
}

--- The display a warning would go to right now, or nil when there is none.
--- Exported because the panel names it, and a module should not have to keep
--- its own copy of the order to say which one won.
function Warn.Pick()
    for _, backend in ipairs(BACKENDS) do
        if backend.Available() then return backend end
    end
    return nil
end

--- One module's line. Holding the backend and the text it last posted is what
--- makes Show idempotent, which both kinds of channel need for opposite
--- reasons: a held display should be left alone while nothing changes, and a
--- stream should get one message rather than one per refresh.
function Warn.New(key)
    local channel = { key = key }

    function channel:Clear()
        if not self.backend then return end
        if self.backend.Clear then self.backend.Clear(self.key) end
        self.backend, self.text = nil, nil
    end

    --- Posts `text`, or clears if there is nothing to say. Returns the backend
    --- that took it, so a caller can report where it went.
    function channel:Show(text, icon)
        if not text then
            self:Clear()
            return nil
        end

        local backend = Warn.Pick()
        if not backend then
            self:Clear()
            return nil
        end

        -- Post only when the line we would put up differs from the one already
        -- up, and take the old one down first if the display itself changed --
        -- otherwise a line is left standing in a display nobody is reading.
        if backend == self.backend and text == self.text then return backend end
        if self.backend and self.backend ~= backend then self:Clear() end

        if backend.Show(self.key, text, icon) then
            self.backend, self.text = backend, text
        end
        return self.backend
    end

    return channel
end

--- The panel rows every module with a warning shows: the switch, and which
--- display it would go to. Kept here so two modules cannot drift into
--- describing the same channel two different ways.
---
--- `getDB` is the module's own settings accessor, so the switch lives in that
--- module's saved variables rather than in a shared one.
function Warn.SectionRows(getDB, onChange, help)
    local backend = Warn.Pick()
    return {
        { section = "On-screen warning" },
        {
            label = "Warn on screen",
            get   = function() return getDB().warn ~= false end,
            set   = function(v)
                getDB().warn = v and true or false
                if onChange then onChange() end
            end,
            help  = help,
        },
        {
            label = "Channel",
            value = backend and backend.title or "none detected",
            help  = (backend and (backend.detail .. "\n\n") or "")
                 .. "Northern Sky Raid Tools first, then BigWigs -- whichever is "
                 .. "there. Nothing is drawn when neither is: you have already "
                 .. "placed and styled a warning area, and a second one from us "
                 .. "would be another thing to position.\n\n"
                 .. "EllesmereUI is deliberately not in that list. Its combat alert "
                 .. "is the nearest thing it has and it takes no message -- it "
                 .. "draws the words you configured for entering and leaving "
                 .. "combat, and every other EllesmereUI warning writes its own "
                 .. "sentence the same way.",
        },
    }
end
