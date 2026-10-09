-- SharedSounds
-- Publishes EllesmereUI's bundled alert sounds to LibSharedMedia, so every
-- other addon can offer them too.
--
-- ── Where the sounds actually come from ──────────────────────────────────────
--
-- This started as "export the Cooldown Manager's sounds", and the Cooldown
-- Manager has none. Blizzard's built-in one is C_CooldownViewer plus four
-- frames (EssentialCooldownViewer, UtilityCooldownViewer, BuffIconCooldownViewer,
-- BuffBarCooldownViewer) and a settings panel; there is no sound API, no sound
-- setting and no bundled audio anywhere in it. EllesmereUICooldownManager hooks
-- that surface about as deeply as anything could and never touches a sound of
-- Blizzard's either.
--
-- The sound dropdown you see in a cooldown manager's options belongs to
-- EllesmereUI, not to the Cooldown Manager. EUI keeps ONE alert-sound catalogue
-- (EllesmereUI.ALERT_SOUND_FILES, sixteen files under its media\sounds\) and
-- every EUI feature that can make a noise offers the same list -- CDM's Focus
-- Kick alert is simply one of the places it surfaces. So that catalogue is what
-- gets exported, and exporting it covers the sounds the question was about.
--
-- ── Why it needs doing at all ────────────────────────────────────────────────
--
-- EllesmereUI is a LibSharedMedia CONSUMER and not a provider. It appends
-- SharedMedia sounds into its own dropdowns (its AppendSharedMediaSounds), and
-- it registers its FONTS and one statusbar texture -- but not one sound. So the
-- traffic is entirely one-way: EUI can play WeakAuras' sounds, and WeakAuras,
-- BigWigs, NSRT and Details cannot play EUI's. This opens the other direction.
--
-- ── Why it is a module rather than an EllesmereUI Misc entry ─────────────────
--
-- It would pass that bag's first test -- it is meaningless without EllesmereUI
-- -- and fails its second outright: LibSharedMedia has no unregister. A name,
-- once registered, is registered for the session. That makes this the one thing
-- an entry may not be, irreversible, and one of those in the bag would quietly
-- take the live-toggle property away from every other entry in it.
--
-- The same fact is why there is no SetEnabled below. Its absence is what makes
-- the panel offer a reload on the switch instead of claiming a live toggle, so
-- the honest behaviour falls out of the framework rather than being described
-- in a help string next to a switch that lies.

local AniMods = _G.AniMods

local SharedSounds = {
    title = "Shared Sounds",
    description = "Publishes EllesmereUI's alert sounds to LibSharedMedia.",
    dbKey = "sharedSounds",
    category = "Addon Extras",
    conditions = {
        { text = "LibSharedMedia available",
          help = "The whole module is a registration into LibSharedMedia. "
              .. "Without it there is nowhere to publish to -- which is a "
              .. "theoretical case here, since EllesmereUI ships the library "
              .. "itself under its Libs folder.",
          met = function()
              local libStub = _G.LibStub
              return (libStub and libStub:GetLibrary("LibSharedMedia-3.0", true)) and true or false
          end },
        { text = "EllesmereUI loaded",
          help = "The sounds are EllesmereUI's own files. Without it there is "
              .. "nothing to publish.",
          met = function() return AniMods.IsAddOnLoaded("EllesmereUI") end },
    },
}

-- Registered names are prefixed so they sort together and are identifiable
-- among the few hundred entries a media-heavy install accumulates -- and so
-- that "Glass" does not look like it might be somebody else's Glass.
--
-- It also decides a collision in the right direction. LSM's Register refuses a
-- key that is already taken rather than overwriting it, so an unprefixed
-- "Glass" would simply lose to whoever registered first, silently and
-- differently depending on addon load order.
local PREFIX = "EUI: "

-- What happened to each sound, in catalogue order, for the panel to report.
-- Rebuilt on the one run; never read before it.
local results = {}
local registeredCount = 0
local publishRan = false

-- No ModuleDB(). There is nothing to configure: what gets published is
-- EllesmereUI's catalogue in full, and the one choice that could be a setting
-- -- the prefix -- cannot change after the fact, since the old names would
-- stay registered under the old prefix until a reload. `dbKey` is still
-- declared above so General's Saved settings cleanup knows the key is ours
-- rather than an orphan, should this module ever grow one.

local function SharedMedia()
    local libStub = _G.LibStub
    return libStub and libStub:GetLibrary("LibSharedMedia-3.0", true) or nil
end

-- Why a Register came back false.
--
-- The library answers with a bare boolean, so this re-derives the reason from
-- its own rules (LibSharedMedia-3.0.lua's Register) -- and only ever runs on a
-- failure, so the common path pays nothing for it.
local function RefusalReason(lsm, label, path)
    local lower = path:lower()
    if not (lower:find(".ogg", 1, true) or lower:find(".mp3", 1, true)) then
        return "LibSharedMedia accepts only .ogg and .mp3"
    end
    local existing = lsm.HashTable and lsm:HashTable(lsm.MediaType.SOUND)
    if existing and existing[label] then
        return "another addon already registered that name"
    end
    -- The remaining rules are "the file is not on disk" and "the path is not
    -- under Interface", neither of which can be told apart from here.
    return "LibSharedMedia refused the file"
end

-- Runs ONCE. Not an optimisation: a second pass would re-register names that
-- are already taken -- by us -- and report every one of them as a collision.
local function Publish()
    if publishRan then return end

    local lsm = SharedMedia()
    local eui = _G.EllesmereUI
    if not (lsm and eui and type(eui.BuildAlertSoundTables) == "function") then return end

    publishRan = true
    wipe(results)
    registeredCount = 0

    -- EllesmereUI's own builder rather than its raw tables. It returns fresh
    -- paths/names/order with the media directory already joined on, and its own
    -- comment says it is meant for exactly this kind of caller ("Safe for the
    -- SM appenders") -- so the one thing we must not get wrong, the file path,
    -- is not assembled here.
    local paths, names, order = eui.BuildAlertSoundTables()
    if type(order) ~= "table" then return end

    for _, key in ipairs(order) do
        local path = paths[key]
        -- "none" is in the catalogue as a name with no file: it is how EUI's
        -- own dropdowns offer "play nothing", and it is not a sound.
        if path then
            local label = PREFIX .. (names[key] or key)
            local ok = lsm:Register(lsm.MediaType.SOUND, label, path) and true or false
            if ok then registeredCount = registeredCount + 1 end
            results[#results + 1] = {
                label = label,
                ok    = ok,
                why   = (not ok) and RefusalReason(lsm, label, path) or nil,
            }
        end
    end
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function SharedSounds:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Published",
        state = publishRan and registeredCount > 0,
        help  = publishRan
            and "Registration happens once, at login. LibSharedMedia has no "
             .. "unregister, so a name stays for the session."
            or  "Nothing has been published yet this session.",
    }
    rows[#rows + 1] = {
        label = "Sounds registered",
        value = ("%d of %d"):format(registeredCount, #results),
        help  = "Pick them in any addon's sound dropdown -- WeakAuras, BigWigs, "
             .. "Northern Sky, Details -- under names beginning \"" .. PREFIX .. "\".",
    }

    -- Only the failures are listed. A list of sixteen rows saying "yes" is not
    -- a report, and the count above already says how many there were.
    local failed = false
    for _, entry in ipairs(results) do
        if not entry.ok then
            if not failed then
                failed = true
                rows[#rows + 1] = { section = "Not registered" }
            end
            rows[#rows + 1] = { label = entry.label, value = entry.why or "refused" }
        end
    end

    rows[#rows + 1] = { section = "Naming" }
    rows[#rows + 1] = {
        label = "Prefix",
        value = PREFIX,
        help  = "Keeps these together in a dropdown and tells a collision which "
             .. "way to fall: LibSharedMedia refuses a name that is already "
             .. "taken rather than replacing it, so an unprefixed \"Glass\" "
             .. "would lose to whoever registered first, differently depending "
             .. "on addon load order.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function SharedSounds:Enable()
    -- Deferred like every other module's setup, though this one could run at
    -- file load: EllesmereUI builds its catalogue as its own file loads, so the
    -- tables are there long before this. Deferred anyway, so that "when do
    -- modules start" has one answer rather than one per module.
    AniMods.W.OnReady(Publish)
end

-- Deliberately no SetEnabled. See the header: LibSharedMedia has no
-- unregister, so switching this off cannot take effect until a reload, and
-- omitting SetEnabled is what makes the panel say so.

AniMods.RegisterModule("SharedSounds", SharedSounds)
