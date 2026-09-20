-- TalentLoadouts -- dump, restore and organise Talent Loadout Manager's builds.
--
-- TLM stores every build individually and has no way to move the whole set to
-- another character: its own import/export is one build at a time. This dumps
-- all of them into a single string, Myslot style, and reads one back.
--
-- Everything goes through TLM's public API (TalentLoadoutManagerAPI), never its
-- saved variables. That matters here: the API is a documented contract with
-- assert-checked arguments, while the saved table is private and reshapes
-- between releases.
--
-- Size note. TLM keeps each build internally as a ~2,000-character
-- `selectedNodes` blob, which would make a whole-collection string useless for
-- copy-paste. GetExportString returns Blizzard's own export code instead --
-- around 120 characters for the same build, already bit-packed and base64'd by
-- the game. That is the difference between a ~95 KB dump and a ~4 KB one, and
-- it is why this module needs no compression library.

local AniMods = _G.AniMods

local W = AniMods.W

-- ---------------------------------------------------------------------------
-- The naming convention
-- ---------------------------------------------------------------------------
-- A loadout name is  {Prefix}-{Case}{Variant}  where
--
--   Prefix   spec + hero talent, e.g. "SA" = Shadow + Archon. Optional: a name
--            may start at the case token (PVP).
--   Case     what the build is for. The token set below.
--   Variant  free text. Anything after the case token, dash or not.
--
-- The BASE is {Prefix}-{Case}; every name sharing a base is a variant of it.
-- That is the whole taxonomy -- which is why "SA-Raid-MT" and "SA-Raid-B1" are
-- siblings under "SA-Raid" rather than one being the other's parent.
--
-- Deliberately NOT derived from TLM's parentMapping. That field records which
-- Blizzard loadout slot a build overwrites when applied, which is a practical
-- slot assignment and not a taxonomy: a collection grown organically has builds
-- parented across cases (a Raid variant sitting in an M+ slot) purely because
-- no slot existed for its own base. The name is the source of truth here, and
-- the dump carries it through unchanged.

-- Matched longest-first so a short token can never shadow a longer one that
-- starts with it. Plain string compares, never patterns -- "M+" contains a
-- magic character and would silently misbehave in a Lua pattern.
local CASE_TOKENS = { "Delve", "Raid", "PVP", "M+" }

local UNCATEGORISED = "Uncategorised"

local DUMP_HEADER = "AniMods-TLM 1"

--- Splits a loadout name into prefix, case and variant.
--- Returns nothing at all when the name carries no recognised case token.
--- @return string|nil prefix
--- @return string|nil case
--- @return string|nil variant
local function ParseName(name)
    if type(name) ~= "string" or name == "" then return nil end

    -- With a prefix: everything before the first dash, but only if what follows
    -- actually begins with a known case token. "SA-H6" fails here and stays
    -- uncategorised rather than inventing "H6" as a case.
    local dash = name:find("-", 1, true)
    if dash then
        local head, tail = name:sub(1, dash - 1), name:sub(dash + 1)
        for _, case in ipairs(CASE_TOKENS) do
            if tail:sub(1, #case) == case then
                return head, case, tail:sub(#case + 1)
            end
        end
    end

    -- Without a prefix: the name starts at the case token, e.g. "PVP-1".
    for _, case in ipairs(CASE_TOKENS) do
        if name:sub(1, #case) == case then
            return nil, case, name:sub(#case + 1)
        end
    end

    return nil
end

local function BaseName(prefix, case)
    return prefix and (prefix .. "-" .. case) or case
end

-- There is deliberately no canonical spelling to rewrite names into.
--
-- The dump used to insert a dash between base and variant, turning "SA-M+1"
-- into "SA-M+-1". That was wrong: the separator belongs to the VARIANT, which
-- is free text, so both "HA-Raid1" and "PVP-1" are correct as written and
-- "HA-Raid1" is the better-looking of the two. Normalising imposed a spelling
-- the convention never asked for and made the shorter form unreachable.
--
-- Names are therefore dumped exactly as TLM holds them. The parse still runs,
-- but only to find the base a name groups under -- reading, not rewriting.

--- The base a name groups under. Names with no recognised case token land in
--- the bag; nothing is ever renamed.
local function BaseOf(name)
    local prefix, case = ParseName(name)
    if not case then return UNCATEGORISED end
    return BaseName(prefix, case)
end

-- Published so the convention has ONE definition. Gear Sync matches equipment
-- set names against loadout names, which only works while both are read by the
-- same parser -- a second copy of CASE_TOKENS would drift the first time a case
-- was added, and the symptom would be gear quietly not swapping rather than
-- anything that looks like a bug.
AniMods.LoadoutName = {
    Parse        = ParseName,
    Base         = BaseOf,
    CASE_TOKENS  = CASE_TOKENS,
    UNCATEGORISED = UNCATEGORISED,
}

-- ---------------------------------------------------------------------------
-- Talking to TLM
-- ---------------------------------------------------------------------------

local function API()
    return _G.TalentLoadoutManagerAPI and _G.TalentLoadoutManagerAPI.GlobalAPI
end

--- Every custom loadout TLM knows about, across all classes and specs.
--- Blizzard loadouts are skipped: they already live in the game, and importing
--- them elsewhere would duplicate builds the target character already has.
local function CustomLoadouts()
    local api = API()
    if not api then return {} end

    local ok, all = pcall(api.GetAllLoadouts, api)
    if not ok or type(all) ~= "table" then return {} end

    local out = {}
    for _, info in ipairs(all) do
        if type(info) == "table" and not info.isBlizzardLoadout and info.name then
            out[#out + 1] = info
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Dump / restore
-- ---------------------------------------------------------------------------

--- One loadout per line: export string, then the name exactly as TLM holds it.
---
--- The export string comes first on purpose. Blizzard's codes are base64 and
--- never contain "|", while names freely can, so splitting on the FIRST "|"
--- is unambiguous no matter what the name holds.
local function BuildDump()
    local api = API()
    if not api then return nil, "Talent Loadout Manager is not loaded." end

    local loadouts = CustomLoadouts()
    local lines, skipped = {}, 0

    for _, info in ipairs(loadouts) do
        local ok, str = pcall(api.GetExportString, api, info.id)
        if ok and type(str) == "string" and str ~= "" then
            lines[#lines + 1] = str .. "|" .. info.name
        else
            skipped = skipped + 1
        end
    end

    if #lines == 0 then return nil, "No custom loadouts to dump." end

    table.sort(lines)
    table.insert(lines, 1, DUMP_HEADER .. " " .. #lines)
    return table.concat(lines, "\n"), skipped
end

--- Recreates every loadout in a dump. Class and spec are carried inside each
--- export string, so a mixed-class dump files itself correctly on any
--- character -- nothing here needs to know who is logged in.
local function ApplyDump(text)
    local api = API()
    if not api then return false, "Talent Loadout Manager is not loaded." end
    if type(text) ~= "string" or text == "" then return false, "Nothing pasted." end

    local added, failed, seen = 0, 0, 0
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, #DUMP_HEADER) ~= DUMP_HEADER and line:match("%S") then
            seen = seen + 1
            local sep = line:find("|", 1, true)
            local str = sep and line:sub(1, sep - 1) or nil
            local name = sep and line:sub(sep + 1) or nil
            if str and name and str ~= "" and name ~= "" then
                local ok, result = pcall(api.ImportCustomLoadout, api, str, name)
                if ok and result then added = added + 1 else failed = failed + 1 end
            else
                failed = failed + 1
            end
        end
    end

    if seen == 0 then return false, "No loadout lines found." end
    if added == 0 then return false, ("All %d failed to import."):format(failed) end
    return true, ("Imported %d loadout%s%s."):format(
        added, added == 1 and "" or "s",
        failed > 0 and (", " .. failed .. " failed") or "")
end

--- The collection as the convention sees it: base, then its variants.
local function BuildGroupReport()
    local groups, order = {}, {}
    for _, info in ipairs(CustomLoadouts()) do
        local base = BaseOf(info.name)
        if not groups[base] then
            groups[base] = {}
            order[#order + 1] = base
        end
        table.insert(groups[base], info.name)
    end

    if #order == 0 then return "No custom loadouts found." end

    -- The bag sorts last however it is spelled: it is a leftover, not a group.
    table.sort(order, function(a, b)
        if (a == UNCATEGORISED) ~= (b == UNCATEGORISED) then return b == UNCATEGORISED end
        return a < b
    end)

    local out = {}
    for _, base in ipairs(order) do
        out[#out + 1] = base
        table.sort(groups[base])
        for _, entry in ipairs(groups[base]) do
            out[#out + 1] = "    " .. entry
        end
        out[#out + 1] = ""
    end
    return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Module
-- ---------------------------------------------------------------------------

local TalentLoadouts = {
    title = "Talent Loadouts",
    description = "Dump, restore and organise Talent Loadout Manager's builds.",
    category = "Addon Extras",
    conditions = {
        { text = "TalentLoadoutManager loaded",
          help = "Everything here reads and writes TLM's loadouts through its "
              .. "public API, so it needs TLM.",
          met = function() return AniMods.IsAddOnLoaded("TalentLoadoutManager") end },
    },
}

function TalentLoadouts:GetInfoRows()
    local rows = {}

    local loadouts = CustomLoadouts()
    local bases, baseCount, bagged = {}, 0, 0
    for _, info in ipairs(loadouts) do
        local base = BaseOf(info.name)
        if not bases[base] then bases[base] = true; baseCount = baseCount + 1 end
        if base == UNCATEGORISED then bagged = bagged + 1 end
    end

    rows[#rows + 1] = { section = "Collection" }
    rows[#rows + 1] = { label = "Custom loadouts", value = tostring(#loadouts) }
    rows[#rows + 1] = {
        label = "Groups",
        value = tostring(baseCount),
        help  = "Distinct {Prefix}-{Case} bases. Every name sharing a base is a "
             .. "variant of it.",
    }
    rows[#rows + 1] = {
        label = UNCATEGORISED,
        value = tostring(bagged),
        help  = "Names with no recognised case token. They keep their spelling "
             .. "and are dumped as-is.",
    }

    rows[#rows + 1] = { section = "Transfer" }
    rows[#rows + 1] = {
        kind = "button", label = "Show groups", button = "Show",
        help = "What the convention makes of the current collection, before "
            .. "anything is written anywhere.",
        onClick = function()
            W.TextBox({ title = "Talent loadout groups", text = BuildGroupReport() })
        end,
    }
    rows[#rows + 1] = {
        kind = "button", label = "Dump all loadouts", button = "Dump",
        help = "Every custom loadout as one string. Copy it, then paste it into "
            .. "Restore on another character.",
        onClick = function()
            local dump, err = BuildDump()
            -- An empty collection is a normal answer, not an error state: say so
            -- in the same window the dump would have appeared in.
            W.TextBox({
                title = "Talent loadout dump",
                text  = dump or tostring(err),
            })
        end,
    }
    rows[#rows + 1] = {
        kind = "button", label = "Restore from a dump", button = "Restore",
        help = "Recreates every loadout in a pasted dump. Existing loadouts are "
            .. "left alone, so re-importing makes duplicates rather than "
            .. "overwriting.",
        onClick = function()
            W.TextBox({
                title    = "Restore talent loadouts",
                action   = "Restore",
                onAction = ApplyDump,
            })
        end,
    }

    return rows
end

-- Nothing is installed, hooked or scheduled: every action runs from a button.
function TalentLoadouts:Enable() end

function TalentLoadouts:SetEnabled()
    return true
end

AniMods.RegisterModule("TalentLoadouts", TalentLoadouts)
