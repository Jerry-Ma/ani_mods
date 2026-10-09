-- CDMSounds
-- Publishes the Cooldown Manager's alert sounds to LibSharedMedia, so every
-- other addon can offer them.
--
-- ── Why this needed a table rather than a lookup ─────────────────────────────
--
-- Blizzard's Cooldown Manager picks its alert sound from Enum.CooldownViewerSound,
-- whose values are plain ordinals. Resolving one takes two steps, and NEITHER is
-- available to an addon at runtime:
--
--   ordinal -> soundKitID   CooldownViewerSoundData, a global in
--                           Blizzard_CooldownViewer. Readable in principle, but
--                           it is loaded only with that addon and is a nested
--                           table keyed by a second enum.
--   soundKitID -> file      SoundKitEntry.db2. There is no Lua call for this at
--                           all; PlaySound takes a kit, PlaySoundFile takes a
--                           file, and nothing converts between them.
--
-- Watching instead of reading does not work either: the settings dropdown does
-- not preview, and a real alert plays entirely in C, so neither PlaySound nor
-- PlaySoundFile ever sees it. Both were measured before this was written.
--
-- So the join is done OFFLINE and the result shipped. See Tools\cdm-sounds.md
-- for the exact provenance and how to regenerate it.
--
-- ── What is shipped is numbers, not audio ────────────────────────────────────
--
-- A FileDataID names a file the GAME already owns. Nothing is extracted, copied
-- or redistributed, and the addon grows by a few kilobytes of integers rather
-- than by ninety-three sound files -- which also means these stay byte-identical
-- to what the Cooldown Manager itself plays, instead of being a stale copy.
--
-- ── The one safety note ──────────────────────────────────────────────────────
--
-- LibSharedMedia validates a sound only when the data is a STRING: it checks the
-- file exists and ends in .ogg or .mp3. A NUMBER goes straight into its table
-- unchecked. So a wrong FileDataID here registers happily and plays silence,
-- with nothing anywhere reporting a problem. That is what the Test button is
-- for, and why the table is generated rather than typed.

local AniMods = _G.AniMods

local CDMSounds = {
    title = "Cooldown Manager Sounds",
    description = "Publishes the Cooldown Manager's alert sounds to LibSharedMedia.",
    dbKey = "cdmSounds",
    category = "Addon Extras",
    conditions = {
        { text = "LibSharedMedia available",
          help = "The whole module is a registration into LibSharedMedia. "
              .. "Without it there is nowhere to publish to.",
          met = function()
              local libStub = _G.LibStub
              return (libStub and libStub:GetLibrary("LibSharedMedia-3.0", true)) and true or false
          end },
        -- Deliberately NOT conditioned on the Cooldown Manager. These are game
        -- files addressed by id; they play whether or not anything uses the
        -- feature they were made for.
    },
}

-- Names are prefixed so ninety-three entries stay together and identifiable in
-- a dropdown shared with every other addon's media.
--
-- The CATEGORY is in the name because two labels repeat across categories --
-- "Stove Pipe" is both a Device and a Short, "Synth High" both an Instrument
-- and a Short -- and LibSharedMedia refuses a name already taken rather than
-- replacing it, so without the category the second of each pair would silently
-- never register.
local PREFIX = "CDM"

local CATEGORY_ORDER = { "Animals", "Devices", "Impacts", "Instruments", "Short", "War2", "War3" }

-- category, label, FileDataID. Generated; see the header.
local SOUNDS = {
    -- Animals
    { "Animals", "Cat", 7466002 },
    { "Animals", "Chicken", 7466004 },
    { "Animals", "Cow", 7466006 },
    { "Animals", "Gnoll", 7466010 },
    { "Animals", "Goat", 7466951 },
    { "Animals", "Lion", 7466012 },
    { "Animals", "Panther", 7466014 },
    { "Animals", "Rattlesnake", 7466016 },
    { "Animals", "Sheep", 7466018 },
    { "Animals", "Wolf", 7466020 },
    -- Devices
    { "Devices", "Boat Horn", 7466062 },
    { "Devices", "Air Horn", 7466054 },
    { "Devices", "Bike Horn", 7466947 },
    { "Devices", "Cash Register", 7466070 },
    { "Devices", "Jackpot Bell", 7466955 },
    { "Devices", "Jackpot Coins", 7466957 },
    { "Devices", "Jackpot Fail", 7466959 },
    { "Devices", "Rotary Phone Dial", 7466048 },
    { "Devices", "Rotary Phone Ring", 7466124 },
    { "Devices", "Stove Pipe", 7466036 },
    { "Devices", "Trashcan Lid", 7466046 },
    -- Impacts
    { "Impacts", "Anvil Strike", 7466899 },
    { "Impacts", "Bubble Smash", 7466026 },
    { "Impacts", "Low Thud", 7466901 },
    { "Impacts", "Metal Clanks", 7466903 },
    { "Impacts", "Metal Rattle", 7466116 },
    { "Impacts", "Metal Scrape", 7466112 },
    { "Impacts", "Metal Warble", 7466913 },
    { "Impacts", "Pop Click", 7466050 },
    { "Impacts", "Strange Clang", 7466082 },
    { "Impacts", "Sword Scrape", 7466911 },
    -- Instruments
    { "Instruments", "Bell Ring", 7466126 },
    { "Instruments", "Bell Trill", 7466945 },
    { "Instruments", "Brass", 7466965 },
    { "Instruments", "Chime Ascending", 7466072 },
    { "Instruments", "Guitar Chug", 7466098 },
    { "Instruments", "Guitar Pinch", 7466108 },
    { "Instruments", "Pitch Pipe Distressed", 7466148 },
    { "Instruments", "Pitch Pipe Note", 7466138 },
    { "Instruments", "Synth Big", 7466915 },
    { "Instruments", "Synth Buzz", 7466096 },
    { "Instruments", "Synth High", 7466092 },
    { "Instruments", "Warhorn", 7466967 },
    -- Short
    { "Short", "Bell Strike", 7962218 },
    { "Short", "Bell Tree", 7962208 },
    { "Short", "Big Pot", 7962210 },
    { "Short", "Blades", 7962212 },
    { "Short", "Coffee Mug", 7962220 },
    { "Short", "Cow Bell", 7962222 },
    { "Short", "Finger Snap", 7962224 },
    -- "Guiter" is Blizzard's spelling, kept so the name matches what the
    -- Cooldown Manager's own list says rather than quietly disagreeing with it.
    { "Short", "Guiter", 7962236 },
    { "Short", "Kalimba", 7962238 },
    { "Short", "Metal Blade Drop", 7962240 },
    { "Short", "Metal Blade On Rod", 7962242 },
    { "Short", "Metal Impact", 7962244 },
    { "Short", "Mini Wood Xylophone", 7962246 },
    { "Short", "Paper Cup", 7962248 },
    { "Short", "Sheet Metal", 7962256 },
    { "Short", "Stove Pipe", 7962258 },
    { "Short", "Stove Pipe Blade", 7962260 },
    { "Short", "Sword Shing", 7962262 },
    { "Short", "Synth Bleep", 7962234 },
    { "Short", "Synth Blurp", 7962232 },
    { "Short", "Synth Error", 7962228 },
    { "Short", "Synth High", 7962230 },
    { "Short", "Triangle", 7962266 },
    { "Short", "Water Drop", 7962268 },
    { "Short", "Wine Bottle", 7962270 },
    { "Short", "Wood Xylophone", 7962272 },
    -- War2
    { "War2", "Abstract Whoosh", 7467017 },
    { "War2", "Choir", 7467021 },
    { "War2", "Construction", 7467023 },
    { "War2", "Magic Chimes", 7467025 },
    { "War2", "Pig Squeal", 7464792 },
    { "War2", "Saws", 7467029 },
    { "War2", "Seal", 7464794 },
    { "War2", "Slow", 7464798 },
    { "War2", "Smith", 7464800 },
    { "War2", "Synth Stinger", 7467031 },
    { "War2", "Trumpet Rally", 7467033 },
    { "War2", "Zippy Magic", 7467027 },
    -- War3
    { "War3", "Bell", 7467088 },
    { "War3", "Crunchy Bell", 7467090 },
    { "War3", "Drum Splash", 7467080 },
    { "War3", "Error", 7467092 },
    { "War3", "Fanfare", 7467082 },
    { "War3", "Gate Open", 7467094 },
    { "War3", "Gold", 7467072 },
    { "War3", "Magic Shimmer", 7467098 },
    { "War3", "Ringout", 7467084 },
    { "War3", "Rooster", 7467074 },
    { "War3", "Shimmer Bell", 7467100 },
    { "War3", "Wolf Howl", 7467076 },
}

-- The one from the Cooldown Manager's own screenshot, used by the Test button.
local TEST_FILE = 7466126  -- Instruments / Bell Ring

local registered, refused = 0, 0
local publishRan = false

local function ModuleDB()
    AniModsDB.cdmSounds = AniModsDB.cdmSounds or {}
    return AniModsDB.cdmSounds
end

-- Per category, default on. Ninety-three entries in every sound dropdown in the
-- game is a lot to impose on someone who wanted three, which is the lesson
-- PluginButtons already learned about publishing everything it could find. On
-- by default rather than off, because unlike minimap buttons these were asked
-- for by name -- but trimmable, and the trim lands on the next reload for the
-- same reason the module's own switch does.
local function CategoryEnabled(category)
    local db = ModuleDB()
    return not (db.categories and db.categories[category] == false)
end

local function SetCategory(category, on)
    local db = ModuleDB()
    db.categories = db.categories or {}
    db.categories[category] = on and true or false
end

local function CountIn(category)
    local n = 0
    for _, entry in ipairs(SOUNDS) do
        if entry[1] == category then n = n + 1 end
    end
    return n
end

local function SharedMedia()
    local libStub = _G.LibStub
    return libStub and libStub:GetLibrary("LibSharedMedia-3.0", true) or nil
end

local function Publish()
    if publishRan then return end
    local lsm = SharedMedia()
    if not lsm then return end

    publishRan = true
    registered, refused = 0, 0

    for _, entry in ipairs(SOUNDS) do
        local category, label, fileID = entry[1], entry[2], entry[3]
        if CategoryEnabled(category) then
            local key = ("%s %s: %s"):format(PREFIX, category, label)
            if lsm:Register(lsm.MediaType.SOUND, key, fileID) then
                registered = registered + 1
            else
                -- Only two things can cause this, since a number skips every
                -- file check: the name is already taken, or we registered it
                -- ourselves a moment ago.
                refused = refused + 1
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function CDMSounds:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Published",
        state = publishRan and registered > 0,
        help  = "Registration happens once, at login. LibSharedMedia has no "
             .. "unregister, so a name stays for the session.",
    }
    rows[#rows + 1] = {
        label = "Registered",
        value = ("%d of %d"):format(registered, #SOUNDS),
        help  = "Pick them in any addon's sound dropdown -- WeakAuras, BigWigs, "
             .. "Northern Sky, Details -- under names beginning \"" .. PREFIX .. "\".",
    }
    if refused > 0 then
        rows[#rows + 1] = {
            label = "Refused",
            value = tostring(refused),
            help  = "LibSharedMedia would not take the name, which for a "
                 .. "numeric file id can only mean another addon claimed it "
                 .. "first.",
        }
    end
    rows[#rows + 1] = {
        kind = "button", label = "Test", button = "Play",
        help = "Plays CDM Instruments: Bell Ring straight from its file id. "
            .. "Worth doing once: a wrong id registers happily and plays "
            .. "silence, because LibSharedMedia only validates strings.",
        onClick = function()
            if not _G.PlaySoundFile(TEST_FILE, "Master") then
                AniMods.Print("the test sound did not play -- the file id is wrong.")
            end
        end,
    }

    rows[#rows + 1] = { section = "Categories" }
    for _, category in ipairs(CATEGORY_ORDER) do
        rows[#rows + 1] = {
            label = ("%s (%d)"):format(category, CountIn(category)),
            get   = function() return CategoryEnabled(category) end,
            set   = function(v) SetCategory(category, v) end,
        }
    end
    rows[#rows + 1] = {
        label = "Changes apply on reload",
        state = false,
        help  = "LibSharedMedia has no unregister, so a category switched off "
             .. "keeps its names until the client reloads. Switching one ON "
             .. "waits for the same reload.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function CDMSounds:Enable()
    AniMods.W.OnReady(Publish)
end

-- Deliberately no SetEnabled: LibSharedMedia has no unregister, so switching
-- this off cannot take effect until a reload, and omitting SetEnabled is what
-- makes the panel say so instead of claiming a live toggle.

AniMods.RegisterModule("CDMSounds", CDMSounds)
