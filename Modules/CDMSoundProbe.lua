-- CDMSoundProbe -- THROWAWAY. Delete this file and its .toc line once it has
-- answered its question.
--
-- THE QUESTION. Blizzard's built-in Cooldown Manager can play an alert sound,
-- picked from a categorised list (Animals, Devices, Impacts, Instruments,
-- Warcraft II, Warcraft III, Short, Text to Speech). We want those sounds in
-- LibSharedMedia so other addons can offer them too.
--
-- The obstacle, from the documentation: the picker is Enum.CooldownViewerSound,
-- and its values look like plain ordinals -- 0 for TextToSpeech, then 1..93
-- through the categories. LibSharedMedia stores something PlaySoundFile can
-- take: a path or a FileDataID. An ordinal is neither, and C_CooldownViewer's
-- documented surface has no call that turns one into a playable asset -- the
-- enum goes INTO SetLayoutData and Blizzard's own code plays it.
--
-- So the export is possible if and only if the enum-to-asset mapping exists
-- somewhere Lua can read. That is what this measures, and there are only three
-- answers:
--
--   1. The enum values are not ordinals at all but real soundKitIDs or
--      FileDataIDs -- in which case there is no mapping to find and the export
--      is trivial. Decided by the value range alone.
--   2. They are ordinals AND a Lua table maps them -- the export is possible
--      through that table.
--   3. They are ordinals and nothing in Lua maps them -- the mapping is C-side
--      and the export is impossible. Nothing to build.
--
-- It reads and prints. It registers nothing, hooks nothing and changes no
-- setting, because a probe that alters what it measures is worth nothing.

local AniMods = _G.AniMods

local CDMSoundProbe = {
    title = "CDM Sound Probe",
    description = "Throwaway: can the Cooldown Manager's alert sounds be resolved to playable assets?",
    dbKey = "cdmSoundProbe",
    category = "Addon Extras",
}

local rows = {}      -- what the panel shows
local detail = {}    -- the long dump, printed on demand
local ran = false

local function Row(label, value, help)
    rows[#rows + 1] = { label = label, value = value, help = help }
end

local function State(label, state, help)
    rows[#rows + 1] = { label = label, state = state, help = help }
end

local function Line(text)
    detail[#detail + 1] = text
end

-- ---------------------------------------------------------------------------
-- 1. The enum, and the question its value range settles
-- ---------------------------------------------------------------------------

local function ProbeEnum()
    rows[#rows + 1] = { section = "Enum.CooldownViewerSound" }

    local enum = _G.Enum and _G.Enum.CooldownViewerSound
    if type(enum) ~= "table" then
        State("Present", false, "Without the enum there is nothing to resolve.")
        return nil
    end

    local names, count, lowest, highest = {}, 0, nil, nil
    for key, value in pairs(enum) do
        count = count + 1
        if type(value) == "number" then
            if not lowest or value < lowest then lowest = value end
            if not highest or value > highest then highest = value end
            names[#names + 1] = ("%s = %d"):format(tostring(key), value)
        else
            names[#names + 1] = ("%s = %s (%s)"):format(tostring(key), tostring(value), type(value))
        end
    end
    table.sort(names)

    State("Present", true)
    Row("Entries", tostring(count))
    Row("Value range", ("%s..%s"):format(tostring(lowest), tostring(highest)),
        "THE DECIDING NUMBER. A range starting at 0 and ending near the entry "
     .. "count means these are ordinals -- an index into a mapping Blizzard "
     .. "owns, useless to LibSharedMedia on its own. Values in the thousands "
     .. "would mean they are already soundKitIDs or FileDataIDs, and the whole "
     .. "export becomes a loop.")

    Line("Enum.CooldownViewerSound -- " .. count .. " entries, range "
        .. tostring(lowest) .. ".." .. tostring(highest))
    for _, line in ipairs(names) do Line("  " .. line) end

    return highest
end

-- ---------------------------------------------------------------------------
-- 2. The namespace, read rather than trusted
-- ---------------------------------------------------------------------------

-- The documentation lists seven functions and none about sound. Iterated here
-- anyway: the wiki describes some build, and this client is the one that
-- matters -- an undocumented member would be the shortest path there is.
local function ProbeNamespace()
    rows[#rows + 1] = { section = "C_CooldownViewer" }

    local ns = _G.C_CooldownViewer
    if type(ns) ~= "table" then
        State("Present", false)
        return
    end

    local names = {}
    for key in pairs(ns) do names[#names + 1] = tostring(key) end
    table.sort(names)

    local soundish = {}
    for _, name in ipairs(names) do
        if name:lower():find("sound", 1, true) or name:lower():find("alert", 1, true) then
            soundish[#soundish + 1] = name
        end
    end

    State("Present", true)
    Row("Members", tostring(#names), table.concat(names, "\n"))
    Row("Sound or alert members", #soundish > 0 and table.concat(soundish, ", ") or "none",
        "Anything here that returns a path or a file ID would end the question "
     .. "on its own.")

    Line("")
    Line("C_CooldownViewer members:")
    for _, name in ipairs(names) do Line("  " .. name) end
end

-- ---------------------------------------------------------------------------
-- 3. Anything in Lua that could BE the mapping
-- ---------------------------------------------------------------------------

-- What a mapping would look like: roughly as many entries as the enum has, and
-- values that are either numbers too large to be ordinals (a soundKitID or
-- FileDataID) or strings that read like a sound path.
local function Shape(t)
    local count, big, pathish = 0, 0, 0
    for _, v in pairs(t) do
        count = count + 1
        if type(v) == "number" then
            if v > 1000 then big = big + 1 end
        elseif type(v) == "string" then
            local lower = v:lower()
            if lower:find("sound", 1, true) or lower:find(".ogg", 1, true)
                or lower:find(".mp3", 1, true) then
                pathish = pathish + 1
            end
        end
        if count > 2000 then break end
    end
    return count, big, pathish
end

-- Blizzard's Cooldown Manager is a load-on-demand addon, and its settings UI
-- may be another. A table that only exists once the panel has been opened is
-- still a table we can read -- so the candidates are loaded first, rather than
-- the probe reporting "absent" about something merely not loaded yet.
local LOD_CANDIDATES = {
    "Blizzard_CooldownViewer",
    "Blizzard_CooldownViewerSettings",
    "Blizzard_CooldownManager",
}

local function LoadBlizzardUI()
    rows[#rows + 1] = { section = "Blizzard addons" }
    local addons = _G.C_AddOns
    if not addons then
        State("C_AddOns available", false)
        return
    end
    for _, name in ipairs(LOD_CANDIDATES) do
        local loaded = addons.IsAddOnLoaded and addons.IsAddOnLoaded(name)
        if not loaded and addons.LoadAddOn then
            -- pcall: asking for an addon this client does not ship is an error,
            -- and "not shipped" is a result rather than a failure.
            _G.pcall(addons.LoadAddOn, name)
            loaded = addons.IsAddOnLoaded and addons.IsAddOnLoaded(name)
        end
        State(name, loaded and true or false)
        Line("addon " .. name .. ": " .. (loaded and "loaded" or "absent"))
    end
end

local function ProbeGlobals(enumMax)
    rows[#rows + 1] = { section = "Globals" }

    local hits, candidates = {}, {}
    for key, value in pairs(_G) do
        if type(key) == "string" and key:find("CooldownViewer", 1, true) then
            hits[#hits + 1] = { name = key, kind = type(value), value = value }
        end
    end
    table.sort(hits, function(a, b) return a.name < b.name end)

    Line("")
    Line("Globals matching CooldownViewer: " .. #hits)

    for _, hit in ipairs(hits) do
        Line("  " .. hit.name .. "  (" .. hit.kind .. ")")
        if hit.kind == "table" then
            local ok, count, big, pathish = _G.pcall(Shape, hit.value)
            if ok then
                Line(("      %d entries, %d numbers over 1000, %d sound-like strings")
                    :format(count, big, pathish))
                -- A plausible mapping: enough entries to cover the enum, and
                -- values that are not themselves ordinals.
                if count >= (enumMax or 0) and (big > 0 or pathish > 0) then
                    candidates[#candidates + 1] = hit.name
                end
            end
        end
    end

    Row("Matching globals", tostring(#hits),
        "Everything in the global namespace whose name mentions CooldownViewer. "
     .. "Use the dump button for the list and the shape of each table.")
    Row("Mapping candidates", #candidates > 0 and table.concat(candidates, ", ") or "none",
        "A table with at least as many entries as the enum has, holding numbers "
     .. "too large to be ordinals or strings that read like sound paths. None "
     .. "means the mapping is not in the Lua global namespace -- which, with "
     .. "ordinal enum values, is the answer that closes the question.")

    return #candidates
end

-- ---------------------------------------------------------------------------
-- 4. The wider route: Blizzard's sounds generally, not just this picker's
-- ---------------------------------------------------------------------------
--
-- The actual goal is "use the game's own sounds in other addons", and the
-- Cooldown Manager's list is one curated slice of that. So this measures the
-- general route as well, because the two can fail independently.
--
-- What LibSharedMedia can carry is the crux. Its Register validates only when
-- the data is a STRING -- a number goes straight into the table untouched. So
-- a FileDataID registers and plays, because PlaySoundFile takes one. A
-- soundKitID is a different number space entirely: handed to PlaySoundFile it
-- is read as a file id, and you get the wrong sound or silence. Any route that
-- ends in soundKitIDs needs a soundKit-to-file step, and whether one exists in
-- Lua is exactly what this section asks.
local function ProbeSoundCatalogue()
    rows[#rows + 1] = { section = "Blizzard sounds generally" }

    local kit = _G.SOUNDKIT
    if type(kit) == "table" then
        local n = 0
        for _ in pairs(kit) do n = n + 1 end
        Row("SOUNDKIT entries", tostring(n),
            "Blizzard's named sounds. These are soundKitIDs -- PlaySound takes "
         .. "them, PlaySoundFile does not, so they cannot go into "
         .. "LibSharedMedia as they are.")
        Line("")
        Line("SOUNDKIT: " .. n .. " entries")
    else
        State("SOUNDKIT present", false)
    end

    local sound = _G.C_Sound
    if type(sound) == "table" then
        local names = {}
        for key in pairs(sound) do names[#names + 1] = tostring(key) end
        table.sort(names)
        Row("C_Sound members", #names > 0 and table.concat(names, ", ") or "none",
            "Looking for anything that turns a soundKitID into a file id or a "
         .. "path. That single call would open the whole catalogue.")
        Line("C_Sound: " .. table.concat(names, ", "))
    else
        State("C_Sound present", false)
    end

    -- What LibSharedMedia already holds, as a baseline: if something has
    -- already published Blizzard's sounds, there is nothing left to write.
    local libStub = _G.LibStub
    local lsm = libStub and libStub:GetLibrary("LibSharedMedia-3.0", true)
    if lsm then
        local list = lsm:List("sound")
        Row("Sounds already in LibSharedMedia", tostring(list and #list or 0),
            "The baseline. Use the dump button for the names -- if Blizzard's "
         .. "own are in there already, somebody has solved this.")
        Line("")
        Line("LibSharedMedia sounds: " .. tostring(list and #list or 0))
        for _, name in ipairs(list or {}) do Line("  " .. tostring(name)) end
    else
        State("LibSharedMedia present", false)
    end
end

-- ---------------------------------------------------------------------------
-- The run
-- ---------------------------------------------------------------------------

local function Run()
    wipe(rows)
    wipe(detail)
    ran = true

    LoadBlizzardUI()
    local enumMax = ProbeEnum()
    ProbeNamespace()
    local candidates = ProbeGlobals(enumMax)
    ProbeSoundCatalogue()

    -- The verdict, stated rather than left to be inferred from the rows above.
    rows[#rows + 1] = { section = "Verdict" }
    local verdict, why
    if not enumMax then
        verdict = "no enum"
        why = "Enum.CooldownViewerSound is not present on this client."
    elseif enumMax > 1000 then
        verdict = "exportable"
        why = "The enum values are too large to be ordinals, so they are "
           .. "already soundKitIDs or FileDataIDs. Registering them into "
           .. "LibSharedMedia is a loop over the enum."
    elseif candidates > 0 then
        verdict = "exportable through a table"
        why = "The values are ordinals, but a global table of the right shape "
           .. "exists. Read it, resolve each enum value, register the result."
    else
        verdict = "not exportable"
        why = "The values are ordinals and nothing in the Lua global namespace "
           .. "maps them to an asset. The mapping is C-side, and there is "
           .. "nothing for an addon to read."
    end
    Row("Result", verdict, why)

    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

function CDMSoundProbe:GetInfoRows()
    local out = {}

    out[#out + 1] = { section = "Probe" }
    out[#out + 1] = {
        kind = "button", label = "Run probe", button = "Run",
        help = "Reads the enum, the C_CooldownViewer namespace and every "
            .. "global whose name mentions CooldownViewer. Changes nothing.",
        onClick = Run,
    }
    if ran then
        out[#out + 1] = {
            kind = "button", label = "Print full dump", button = "Print",
            help = "Writes everything found to chat -- the whole enum, every "
                .. "namespace member, and the shape of each matching global.",
            onClick = function()
                for _, line in ipairs(detail) do AniMods.Print(line) end
                AniMods.Print(("dump complete, %d lines."):format(#detail))
            end,
        }
    end

    for _, row in ipairs(rows) do out[#out + 1] = row end

    if not ran then
        out[#out + 1] = {
            label = "Status",
            value = "not run yet",
        }
    end

    return out
end

-- No Enable. It owns no frames, hooks nothing and registers no events:
-- everything it does happens on a click in its own tab.

AniMods.RegisterModule("CDMSoundProbe", CDMSoundProbe)
