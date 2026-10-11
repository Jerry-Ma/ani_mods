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
    local firstParsed, firstStored
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, #DUMP_HEADER) ~= DUMP_HEADER and line:match("%S") then
            seen = seen + 1
            local sep = line:find("|", 1, true)
            local str = sep and line:sub(1, sep - 1) or nil
            local name = sep and line:sub(sep + 1) or nil
            if str and name and str ~= "" and name ~= "" then
                local ok, result = pcall(api.ImportCustomLoadout, api, str, name)
                if ok and result then
                    added = added + 1
                    -- Both sides of the call for the first one: what we PARSED
                    -- out of the line, and what TLM says it STORED. Kept after
                    -- it caught the stray "|" this module used to restore,
                    -- because the two halves have opposite causes -- a name
                    -- already wrong on the left was mangled in transport, one
                    -- that only differs on the right was changed by TLM -- and
                    -- nothing else distinguishes them from the outside.
                    if not firstParsed then
                        firstParsed = name
                        firstStored = (type(result) == "table") and result.name or nil
                    end
                else
                    failed = failed + 1
                end
            else
                failed = failed + 1
            end
        end
    end

    if seen == 0 then return false, "No loadout lines found." end
    if added == 0 then return false, ("All %d failed to import."):format(failed) end

    -- Silent when the round trip is clean, which is the normal case. It speaks
    -- only when TalentLoadoutManager stored something other than what it was
    -- handed, because that is the one failure the status line below cannot
    -- show: every loadout imports successfully and every name is wrong.
    if firstParsed and firstStored and firstStored ~= firstParsed then
        AniMods.Print(("restore sent the name [%s] and TalentLoadoutManager stored [%s]."):format(
            firstParsed, firstStored))
    end

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
-- Bases -- the Blizzard loadouts that variants hang off
-- ---------------------------------------------------------------------------
--
-- A VIEWER AND AN ACTION LAYER, and nothing else. Everything below runs from a
-- button in this tab: nothing is hooked, scheduled or applied at login, so
-- having this module installed never changes what Blizzard's talent UI or
-- TLM's own panel do while you are using them.
--
-- The shape being managed: a BASE is a Blizzard loadout named exactly
-- {Prefix}-{Case}, and its variants are the TLM custom loadouts whose names
-- share that base. TLM already draws that tree -- it indents a custom loadout
-- under a Blizzard one when the variant's parentMapping points at the base's
-- configID. Aligning that pointer with the name is the whole job.
--
-- The NAME stays the source of truth, as the convention note at the top says.
-- parentMapping is still never read as taxonomy; it is WRITTEN from it. A
-- variant sitting in the wrong slot is something to correct, not a fact to
-- honour.
--
-- ── What is scoped to one spec, and what is not ─────────────────────────────
--
-- THE VIEW IS NOT. TLM's GetAllLoadouts returns Blizzard loadouts as well as
-- custom ones, for every spec it has cached, each carrying its own specID, so
-- every spec can be listed without asking Blizzard anything at all.
--
-- PARENTING IS NOT. TLM:SetParentLoadout writes parentMapping and checks no
-- spec. Its only requirement is that the parent is a Blizzard loadout TLM has
-- seen, because DetectDeletedParents clears a parent it cannot find.
--
-- THE SHARED ACTION BARS FLAG IS BLIZZARD'S, and is the one place a spec may
-- matter: usesSharedActionBars comes from C_Traits.GetConfigInfo and is written
-- through C_ClassTalents.SetUsesSharedActionBars. Whether either answers for a
-- config belonging to a spec you are not currently in cannot be settled from
-- here, so it is DETECTED rather than assumed -- a config whose info does not
-- come back reads as "unknown", never as compliant, and the fix button reports
-- what it could not reach instead of quietly counting it as done.

local function AllLoadouts()
    local api = API()
    if not api then return {} end
    local ok, all = pcall(api.GetAllLoadouts, api)
    if not ok or type(all) ~= "table" then return {} end
    return all
end

local function SpecName(specID)
    local si = _G.C_SpecializationInfo
    if si and si.GetSpecializationInfoByID then
        local ok, _, name = pcall(si.GetSpecializationInfoByID, specID)
        if ok and name and name ~= "" then return name end
    end
    return "Spec " .. tostring(specID)
end

--- The Blizzard loadout TLM currently files a build under, or nil.
--- Index 0 is this character's own entry: the table is keyed per character,
--- because one build can occupy a different slot on each of them.
local function ParentConfigID(info)
    local mapping = info.parentMapping
    return mapping and mapping[0] or nil
end

--- true, false, or nil meaning Blizzard did not answer for this config.
--- The three are kept apart on purpose -- see the scope note above.
local function UsesSharedBars(configID)
    local traits = _G.C_Traits
    if not (traits and traits.GetConfigInfo) then return nil end
    local ok, cfg = pcall(traits.GetConfigInfo, configID)
    if not ok or type(cfg) ~= "table" or cfg.usesSharedActionBars == nil then return nil end
    return cfg.usesSharedActionBars and true or false
end

--- Everything the view and both buttons need, gathered in one pass.
--- @return table specs  specID -> { bases = name -> entry, baseOrder, orphans }
--- @return table order  specIDs, sorted
local function Survey()
    local all = AllLoadouts()
    local specs, order = {}, {}

    local function Spec(specID)
        local s = specs[specID]
        if not s then
            s = { bases = {}, baseOrder = {}, orphans = {} }
            specs[specID] = s
            order[#order + 1] = specID
        end
        return s
    end

    -- Blizzard loadouts first. A variant can only be adopted by a base that
    -- already exists, so the bases have to be known before the walk that files
    -- variants under them.
    for _, info in ipairs(all) do
        if info.isBlizzardLoadout and info.name and info.specID then
            local s = Spec(info.specID)
            if not s.bases[info.name] then
                s.bases[info.name] = { name = info.name, configID = info.id, variants = {} }
                s.baseOrder[#s.baseOrder + 1] = info.name
            end
        end
    end

    for _, info in ipairs(all) do
        if not info.isBlizzardLoadout and info.name and info.specID then
            local s = Spec(info.specID)
            local base = BaseOf(info.name)
            local entry = s.bases[base]
            if entry then
                entry.variants[#entry.variants + 1] = info
            else
                -- No Blizzard loadout of that name: nothing to hang it off.
                -- Reported rather than guessed at -- creating the base is a
                -- decision with a loadout slot attached, so it stays yours.
                s.orphans[#s.orphans + 1] = { info = info, base = base }
            end
        end
    end

    table.sort(order)
    for _, specID in ipairs(order) do table.sort(specs[specID].baseOrder) end
    return specs, order
end

--- Point every variant at the Blizzard loadout its NAME says it belongs to.
local function AdoptAll()
    local tlm = _G.TalentLoadoutManagerAPI
    local charAPI = tlm and tlm.CharacterAPI
    if not (charAPI and charAPI.SetParentLoadout) then
        return false, "TalentLoadoutManager has no SetParentLoadout."
    end

    local specs, order = Survey()
    local moved, already, failed = 0, 0, 0
    for _, specID in ipairs(order) do
        for _, baseName in ipairs(specs[specID].baseOrder) do
            local base = specs[specID].bases[baseName]
            for _, variant in ipairs(base.variants) do
                if ParentConfigID(variant) == base.configID then
                    already = already + 1
                elseif pcall(charAPI.SetParentLoadout, charAPI, variant.id, base.configID) then
                    moved = moved + 1
                else
                    failed = failed + 1
                end
            end
        end
    end

    if moved == 0 and failed == 0 then
        return true, ("All %d already filed correctly."):format(already)
    end
    return true, ("Re-filed %d, %d already correct%s."):format(
        moved, already, failed > 0 and (", " .. failed .. " failed") or "")
end

--- Put every Blizzard loadout on shared action bars.
local function ShareAll()
    local talents = _G.C_ClassTalents
    if not (talents and talents.SetUsesSharedActionBars) then
        return false, "This client has no SetUsesSharedActionBars."
    end

    local specs, order = Survey()
    local fixed, already, unknown, failed = 0, 0, 0, 0
    for _, specID in ipairs(order) do
        for _, baseName in ipairs(specs[specID].baseOrder) do
            local configID = specs[specID].bases[baseName].configID
            local state = UsesSharedBars(configID)
            if state == true then
                already = already + 1
            elseif state == nil then
                -- Blizzard would not say. Counted apart rather than attempted
                -- blind: a write we cannot verify is not a fix.
                unknown = unknown + 1
            elseif pcall(talents.SetUsesSharedActionBars, configID, true) then
                fixed = fixed + 1
            else
                failed = failed + 1
            end
        end
    end

    local parts = { ("%d set"):format(fixed), ("%d already shared"):format(already) }
    if unknown > 0 then parts[#parts + 1] = ("%d unreadable"):format(unknown) end
    if failed > 0 then parts[#parts + 1] = ("%d failed"):format(failed) end
    return true, table.concat(parts, ", ") .. "."
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

    -- The convention first, before any count that assumes it. It is the same
    -- one Gear Sync matches equipment sets against, and stating it in both
    -- places is deliberate: it is one rule, and a reader who meets it in only
    -- one module would think it belonged to that module.
    rows[#rows + 1] = { section = "Convention" }
    rows[#rows + 1] = {
        label = "Name",
        value = "{Prefix}-{Case}{Variant}",
        help  = "Prefix is spec plus hero talent (\"SA\" = Shadow Archon) and "
             .. "may be left off. Case is one of " .. table.concat(CASE_TOKENS, ", ")
             .. ". Variant is anything after it.\n\nThe BASE is "
             .. "{Prefix}-{Case}: every name sharing one is a variant of it, so "
             .. "\"SA-Raid-MT\" and \"SA-Raid-B1\" are siblings under "
             .. "\"SA-Raid\" rather than one being the other's parent.\n\n"
             .. "Gear Sync reads the same convention to pick an equipment set, "
             .. "matching the longest set name that is a prefix of the loadout "
             .. "name. One rule, two modules.",
    }

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

    -- ── Bases, every spec ───────────────────────────────────────────────────
    --
    -- All specs, not just the one you are in: these come from TLM's cache,
    -- which carries a specID per loadout, so nothing here has to ask Blizzard
    -- which spec is active.
    local specs, specOrder = Survey()
    local notShared, unreadable, unparented, orphanCount = 0, 0, 0, 0

    for _, specID in ipairs(specOrder) do
        local spec = specs[specID]
        rows[#rows + 1] = { section = SpecName(specID) }

        for _, baseName in ipairs(spec.baseOrder) do
            local base = spec.bases[baseName]
            local shared = UsesSharedBars(base.configID)
            if shared == false then notShared = notShared + 1
            elseif shared == nil then unreadable = unreadable + 1 end

            local filed = 0
            for _, variant in ipairs(base.variants) do
                if ParentConfigID(variant) == base.configID then
                    filed = filed + 1
                else
                    unparented = unparented + 1
                end
            end

            -- One row per base: how many variants it holds, how many are
            -- actually filed under it, and whether it is on shared bars. The
            -- three facts that decide whether either button has work to do.
            local state = (shared == true and "shared")
                or (shared == false and "|cffff8800not shared|r")
                or "|cff999999bars unknown|r"
            rows[#rows + 1] = {
                label = base.name,
                value = ("%d/%d filed, %s"):format(filed, #base.variants, state),
                help  = (shared == nil)
                    and "Blizzard did not report this loadout's action bar "
                     .. "setting, which usually means it belongs to a spec you "
                     .. "are not in. It is left alone rather than assumed to be "
                     .. "correct."
                    or nil,
            }
        end

        for _, orphan in ipairs(spec.orphans) do
            orphanCount = orphanCount + 1
            rows[#rows + 1] = {
                label = "   " .. orphan.info.name,
                value = ("no \"%s\" loadout"):format(orphan.base),
                help  = "There is no Blizzard loadout named \"" .. orphan.base
                     .. "\" on this spec, so nothing can hold this one. Make "
                     .. "one in Blizzard's talent UI and press File, or leave "
                     .. "it loose -- creating a loadout spends a slot, so that "
                     .. "stays your call rather than a button here.",
            }
        end
    end

    rows[#rows + 1] = { section = "Housekeeping" }
    rows[#rows + 1] = {
        label = "Variants filed under the wrong base",
        value = tostring(unparented),
        help  = "A variant is filed correctly when TLM points it at the "
             .. "Blizzard loadout its NAME says it belongs to. The name is the "
             .. "source of truth; this reads the pointer and reports the "
             .. "difference.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "File variants under their base", button = "File",
        help = "Points every variant at the Blizzard loadout matching its base "
            .. "name, across all specs. Safe to press twice -- one already in "
            .. "the right place is left alone.",
        onClick = function()
            local ok, msg = AdoptAll()
            AniMods.Print(msg or (ok and "done." or "nothing to do."))
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
    }
    rows[#rows + 1] = {
        label = "Loadouts not on shared action bars",
        value = unreadable > 0
            and ("%d (%d unreadable)"):format(notShared, unreadable)
            or tostring(notShared),
        help  = "With shared action bars off, a loadout carries its own bar "
             .. "layout and keybindings and swapping builds rearranges them. "
             .. "Unreadable ones belong to specs you are not in; they are "
             .. "counted apart rather than assumed correct.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Put all on shared action bars", button = "Share",
        help = "Sets the shared flag on every Blizzard loadout this can read, "
            .. "and says how many it could not.",
        onClick = function()
            local ok, msg = ShareAll()
            AniMods.Print(msg or (ok and "done." or "nothing to do."))
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
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
