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

-- The same four cases in reading order, for the grid's columns. A separate
-- list because the order above exists to make the parse unambiguous and this
-- one exists to be looked at; tying them together would mean one of the two
-- jobs losing.
local CASE_COLUMNS = { "M+", "Raid", "Delve", "PVP" }

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

--- Every custom loadout TLM knows about, for every spec it has cached.
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

-- Forward-declared, defined with the Bases section further down. Restore files
-- each loadout as it arrives and needs the lookup here, but the lookup belongs
-- with the rest of the base handling rather than being hoisted or duplicated.
-- Declared rather than left to resolve later: a local defined below this point
-- reads as a nil GLOBAL from inside these functions, and says nothing about it
-- until the line runs.
local BlizzardBases, FileVariant

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
    -- Filed as they arrive, rather than left for a second pass. The import
    -- already hands back each loadout's id and specID, so the base lookup is
    -- free at that moment -- and a restore that leaves everything loose until
    -- you remember to press File is a restore that half worked.
    local bases, filed, loose = BlizzardBases(), 0, 0
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
                    -- Filed now, while the loadout's id and spec are in hand.
                    -- A base that does not exist yet is not a failure: the
                    -- expectation is recorded either way, so the Bases view
                    -- can list it as missing on a character that has never
                    -- had one.
                    if FileVariant(result, bases) then
                        filed = filed + 1
                    else
                        loose = loose + 1
                    end
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

    return true, ("Imported %d loadout%s, %d filed%s%s."):format(
        added, added == 1 and "" or "s", filed,
        loose > 0 and (", " .. loose .. " with no base yet") or "",
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
-- every spec can be drawn without asking Blizzard anything at all. Which specs
-- to draw does come from Blizzard, because the answer is "the ones this
-- character has" and neither the cache nor the account-wide plan knows that.
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

-- ── The plan: which bases the collection EXPECTS to exist ───────────────────
--
-- TLM's GetAllLoadouts is a CACHE of what it has seen. That is the right
-- answer to "what exists" and the wrong one to "what should exist": on a fresh
-- character it is empty, so a view built only on it has nothing to say at
-- exactly the moment you most want a checklist.
--
-- So the expected set is ours, and TLM is matched against it rather than
-- consulted for it. It is DERIVED, never curated: every custom loadout name
-- implies its base, so the plan is a fact about the collection rather than a
-- second list to keep in step with it. Curating one by hand would just add
-- something that can disagree with the names.
--
-- Persisted because derivation needs the collection present, and the fresh
-- character has the opposite problem. Restoring a dump records the plan as it
-- goes, so the checklist survives into a session where TLM knows nothing yet.
local function PlanDB()
    AniModsDB.talentLoadouts = AniModsDB.talentLoadouts or {}
    local db = AniModsDB.talentLoadouts
    db.plan = db.plan or {}
    return db.plan
end

--- Records that `specID` is expected to carry a Blizzard loadout called `base`.
local function RememberBase(specID, base)
    if not specID or not base or base == UNCATEGORISED then return end
    local plan = PlanDB()
    plan[specID] = plan[specID] or {}
    plan[specID][base] = true
end

--- specID -> baseName -> configID, for the Blizzard loadouts TLM can see.
BlizzardBases = function()
    local bases = {}
    for _, info in ipairs(AllLoadouts()) do
        if info.isBlizzardLoadout and info.name and info.specID then
            bases[info.specID] = bases[info.specID] or {}
            bases[info.specID][info.name] = info.id
        end
    end
    return bases
end

--- Files one variant under the base its name asks for, if that base exists.
--- Returns true when the pointer ends up right, false when there is no base.
--- Records the expectation either way -- a base that does not exist yet is
--- exactly what the plan is for.
FileVariant = function(info, bases)
    if not (info and info.name and info.specID) then return false end
    local base = BaseOf(info.name)
    if base == UNCATEGORISED then return false end
    RememberBase(info.specID, base)

    local configID = bases[info.specID] and bases[info.specID][base]
    if not configID then return false end
    -- Read inline rather than through the helper below it: a local declared
    -- further down this file would resolve to a nil global from here, which
    -- Lua reports as nothing at all until the line actually runs.
    local mapping = info.parentMapping
    if mapping and mapping[0] == configID then return true end

    local tlm = _G.TalentLoadoutManagerAPI
    local charAPI = tlm and tlm.CharacterAPI
    if not (charAPI and charAPI.SetParentLoadout) then return false end
    return pcall(charAPI.SetParentLoadout, charAPI, info.id, configID) and true or false
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
--- @return table specs  specID -> { bases = name -> entry, baseOrder, waiting }
--- @return table order  specIDs, sorted
local function Survey()
    local all = AllLoadouts()
    local specs, order = {}, {}

    local function Spec(specID)
        local s = specs[specID]
        if not s then
            s = { bases = {}, baseOrder = {}, waiting = {} }
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
            -- Every walk refreshes the plan, so simply opening this tab on a
            -- populated character records what that collection expects -- and
            -- the fresh character it is later restored onto starts with the
            -- checklist already written.
            RememberBase(info.specID, base)
            local entry = s.bases[base]
            if entry then
                entry.variants[#entry.variants + 1] = info
            else
                -- No Blizzard loadout of that name: nothing to hang it off.
                -- Counted per base rather than listed, because the base is
                -- what the view draws and what creating one would fix.
                s.waiting[base] = (s.waiting[base] or 0) + 1
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

-- ── Acting on one cell ──────────────────────────────────────────────────────
--
-- BLIZZARD'S OWN CONFIRMATION, not a copy of it. Their edit dialog registers
-- StaticPopupDialogs["LOADOUT_CONFIRM_SHARED_ACTION_BARS"], whose OnAccept
-- calls ClassTalentLoadoutEditDialog:OnSharedActionBarsConfirmed(), which in
-- turn does SetUsesSharedActionBars(self.configID, true). Both the popup and
-- the dialog are globals, so pointing the dialog at a configID and showing the
-- popup runs their exact path: their wording, their alert styling, their call.
--
-- Worth knowing why a confirmation exists at all, from the same file: turning
-- sharing ON is the only direction they guard. Turning it off calls the API
-- straight. So the thing being confirmed is the loss of that loadout's own bar
-- layout, which is exactly what a yellow cell is asking you to agree to.
--
-- The dialog lives in Blizzard_PlayerSpells, which is load-on-demand, so it is
-- loaded first. And it is skipped entirely while their edit dialog is open:
-- configID is a field on a shared object, and overwriting it mid-edit would
-- retarget a dialog the player is already using.
local function ConfirmShareOne(configID, name)
    local addons = _G.C_AddOns
    if addons and addons.LoadAddOn and not addons.IsAddOnLoaded("Blizzard_PlayerSpells") then
        pcall(addons.LoadAddOn, "Blizzard_PlayerSpells")
    end

    local dialog = _G.ClassTalentLoadoutEditDialog
    if not (dialog and _G.StaticPopup_Show and _G.StaticPopupDialogs
        and _G.StaticPopupDialogs["LOADOUT_CONFIRM_SHARED_ACTION_BARS"]) then
        -- Their path is not there. Ours is not a substitute for a confirmation
        -- the player expects to look a particular way, so this says so rather
        -- than quietly applying the change behind a different dialog.
        AniMods.Print("Blizzard's shared action bars dialog is not available; "
            .. "use the cog in the talent loadout list for " .. tostring(name) .. ".")
        return
    end
    if dialog:IsShown() then
        AniMods.Print("close Blizzard's loadout edit dialog first.")
        return
    end

    dialog.configID = configID
    _G.StaticPopup_Show("LOADOUT_CONFIRM_SHARED_ACTION_BARS")
end

--- Create the Blizzard loadout a red cell stands for.
---
--- CURRENT SPEC ONLY, and that is Blizzard's constraint rather than a choice:
--- a new loadout is a snapshot of the talents you have on right now, so there
--- is no way to make one for a spec you are not in. Cells for other specs are
--- drawn as missing but are not clickable, which is the honest rendering --
--- the alternative is a button that fails for a reason the player cannot see.
local function CreateBase(name)
    local talents = _G.C_ClassTalents
    if not (talents and talents.RequestNewConfig) then
        return AniMods.Print("this client cannot create loadouts from an addon.")
    end
    if talents.CanCreateNewConfig and not talents.CanCreateNewConfig() then
        return AniMods.Print("no loadout slots left, or talents cannot change here.")
    end

    AniMods.W.Confirm({
        message = ("Create a Blizzard loadout called \"%s\" from the talents "
              .. "you have on right now?\n\nThat is the only thing a new "
              .. "loadout can be made from -- set your talents first if these "
              .. "are not the ones you want saved under that name."):format(name),
        confirmText = "Create",
        onConfirm = function()
            local ok = pcall(talents.RequestNewConfig, name)
            AniMods.Print(ok and ("asked for \"" .. name .. "\".")
                or "the game refused the new loadout.")
            -- Creation is a server round trip, so the grid cannot be correct
            -- immediately. Refreshed a moment later rather than guessed at.
            _G.C_Timer.After(1, function()
                if AniMods.RefreshUI then AniMods.RefreshUI() end
            end)
        end,
    })
end

--- Put every Blizzard loadout on shared action bars.
--- ONE CONFIRMATION FOR THE WHOLE SET, not Blizzard's per-loadout dialog shown
--- N times. A chain of identical popups is not consent, it is something to
--- click through; a single prompt that NAMES what it is about to change is.
---
--- Blizzard's own warning string is reused, so the sentence about what sharing
--- costs is the one already seen in the talent UI rather than a paraphrase.
local function ShareAll()
    local talents = _G.C_ClassTalents
    if not (talents and talents.SetUsesSharedActionBars) then
        AniMods.Print("this client has no SetUsesSharedActionBars.")
        return
    end

    local specs, order = Survey()
    local targets, unknown = {}, 0
    for _, specID in ipairs(order) do
        for _, baseName in ipairs(specs[specID].baseOrder) do
            local configID = specs[specID].bases[baseName].configID
            local state = UsesSharedBars(configID)
            if state == false then
                targets[#targets + 1] = { configID = configID, name = baseName }
            elseif state == nil then
                -- Blizzard would not say. Left alone rather than written
                -- blind: this change destroys a bar layout when it lands, and
                -- one that cannot be verified is not a fix.
                unknown = unknown + 1
            end
        end
    end

    if #targets == 0 then
        AniMods.Print(unknown > 0
            and ("nothing to change, %d could not be read."):format(unknown)
            or "every loadout is already on shared action bars.")
        return
    end

    local names = {}
    for i, t in ipairs(targets) do names[i] = t.name end

    AniMods.W.Confirm({
        message = ("Put these %d loadouts on shared action bars?\n\n%s\n\n%s")
            :format(#targets, table.concat(names, ", "),
                -- Blizzard's own sentence about what sharing costs, so the
                -- warning here is the one already seen in the talent UI.
                -- Indexed by name because the capital L is their typo, and
                -- spelling it as a field just looks like ours.
                _G["HUD_ClASS_TALENTS_EDIT_LOADOUT_CONFIRM_SHARED_ACTION_BARS"]),
        confirmText = "Share all",
        onConfirm = function()
            local done, failed = 0, 0
            for _, t in ipairs(targets) do
                if pcall(talents.SetUsesSharedActionBars, t.configID, true) then
                    done = done + 1
                else
                    failed = failed + 1
                end
            end
            AniMods.Print(("%d set%s%s."):format(done,
                failed > 0 and (", " .. failed .. " failed") or "",
                unknown > 0 and (", " .. unknown .. " unreadable") or ""))
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
    })
end

-- ── The grid ────────────────────────────────────────────────────────────────
--
-- Rows are prefixes -- spec plus hero talent -- and columns are the four
-- cases, so a cell is one base: exactly the thing the convention names. The
-- grid is drawn per spec, every spec, because the plan spans all of them; only
-- the spec you are in gets clickable cells, since both actions behind them
-- (create a loadout, change its action bar setting) are things Blizzard only
-- allows against the active spec.

--- This character's specIDs, in the game's own order, plus the active one.
---
--- The view is driven from this rather than from what the plan or TLM's cache
--- happen to hold. Both are account-wide: the plan is saved per account on
--- purpose, so restoring a dump onto a fresh character of the same class
--- arrives with its checklist already written -- which also means it carries
--- entries for every other character's specs. Those belong to those
--- characters; drawing a Warlock grid on a Priest would be reading the saved
--- table as if it were about whoever is logged in.
local function PlayerSpecs()
    local si = _G.C_SpecializationInfo
    if not (si and si.GetNumSpecializations) then return {}, nil end

    local order, activeIndex = {}, si.GetSpecialization and si.GetSpecialization()
    local active
    for i = 1, si.GetNumSpecializations() do
        local specID = si.GetSpecializationInfo(i)
        if specID then
            order[#order + 1] = specID
            if i == activeIndex then active = specID end
        end
    end
    return order, active
end

--- A cell's tooltip: what it is, and what a click does or why it cannot.
local function CellTip(cell, editable)
    if cell.state == "missing" then
        return ("No Blizzard loadout called \"%s\".\n\n%s\n\n%s"):format(
            cell.name,
            (cell.waiting > 0)
                and ("%d variant%s named for it, with nothing to be filed "
                  .. "under."):format(cell.waiting,
                        cell.waiting == 1 and " is" or "s are")
                or "The collection expects it, because a loadout name "
                .. "somewhere says so.",
            editable
                and "Click to create one from the talents you have on right now."
                or "Creatable only while you are in this spec: a new loadout is "
                .. "a snapshot of your current talents, so there is no way to "
                .. "make one for a spec you are not in.")
    end

    local head = ("\"%s\" -- %d of %d variants filed under it."):format(
        cell.name, cell.filed, cell.total)
    if cell.shared == true then
        return head .. "\n\nOn shared action bars, which is what the collection "
            .. "expects: swapping builds leaves your bars and keybindings alone."
    elseif cell.shared == false then
        return head .. "\n\nKeeps an action bar layout of its own, so applying "
            .. "it rearranges your bars.\n\n" .. (editable
                and "Click to put it on shared bars, through Blizzard's own "
                .. "confirmation dialog."
                or "Changeable only while you are in this spec.")
    end
    return head .. "\n\nBlizzard did not report its action bar setting; it only "
        .. "answers for the spec you are in."
end

--- What a click on this cell does, or nil when there is nothing to do.
local function CellClick(cell)
    if cell.state == "missing" then
        return function() CreateBase(cell.name) end
    elseif cell.shared == false then
        return function() ConfirmShareOne(cell.configID, cell.name) end
    end
    return nil
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
    -- The legend lives here rather than above each grid: it is one explanation
    -- of one colour scheme, and repeating it per spec would be noise in the
    -- place the grids are meant to be read at a glance.
    rows[#rows + 1] = {
        label = "Grid",
        value = "|cff2ec759shared|r / |cffffa640own bars|r / |cffd94040missing|r",
        help  = "A grid per spec below, one cell per {Prefix}-{Case} base: rows "
             .. "are prefixes, columns are cases.\n\nGreen means the Blizzard "
             .. "loadout exists and is on shared action bars, which is what "
             .. "the collection expects. Amber means it exists but keeps bars "
             .. "of its own; clicking it offers Blizzard's own confirmation to "
             .. "share them. Red means the collection expects it and this "
             .. "character has no such loadout; clicking it creates one from "
             .. "your current talents. Empty means no loadout name ever "
             .. "implied that combination.\n\nOnly the spec you are in has "
             .. "clickable cells -- the bordered rows -- because both actions "
             .. "need the spec active. Every other spec is still shown.",
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
    local specs = Survey()
    local notShared, unreadable, unparented, offPlan = 0, 0, 0, 0

    local plan = PlanDB()

    -- One grid per spec this character has, in the game's order -- not one per
    -- spec TLM has cached. A spec with nothing cached still gets its grid, red
    -- cells and all, because a fresh character is the one time a checklist is
    -- worth having and the only time the cache is empty.
    local specOrder, currentSpecID = PlayerSpecs()

    for _, specID in ipairs(specOrder) do
        local spec = specs[specID] or { bases = {}, baseOrder = {}, waiting = {} }
        -- Whether this spec's cells do anything. Not a permission we grant:
        -- both actions a cell offers only work against the spec you are in.
        local editable = (specID == currentSpecID)

        -- prefix -> case -> cell. A base is a {Prefix}-{Case} pair, which is
        -- the row and column of exactly one cell, so the grid is the
        -- convention drawn out rather than a layout chosen for it.
        local cellOf, prefixOrder = {}, {}
        --- Puts `cell` where `base` names, making the row if it is not there
        --- yet. A name the convention cannot parse has neither a row nor a
        --- column and so nowhere to go: that returns false, and the caller
        --- counts it rather than losing it silently.
        local function Place(base, cell)
            local prefix, case = ParseName(base)
            if not case then return false end
            local key = prefix or ""
            local cells = cellOf[key]
            if not cells then
                cells = {}
                cellOf[key] = cells
                prefixOrder[#prefixOrder + 1] = key
            end
            cells[case] = cell
            return true
        end

        -- Planned first, so what exists overwrites it: the plan says which
        -- cells should be there at all, and on a fresh character it is the
        -- only thing with anything to say.
        for base in pairs(plan[specID] or {}) do
            Place(base, {
                state = "missing", text = "missing", name = base,
                waiting = spec.waiting[base] or 0,
            })
        end

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

            local placed = Place(baseName, {
                -- Three visible states from a tri-state: shared is green, not
                -- shared is amber and clickable, and unreadable gets its own
                -- mark rather than being guessed into one of the other two.
                -- Unreadable only happens off-spec, where nothing is
                -- clickable anyway.
                state = (shared == true) and "ok" or "warn",
                text  = (shared == true and "shared")
                    or (shared == false and "own bars")
                    or "?",
                name = baseName, configID = base.configID,
                shared = shared, filed = filed, total = #base.variants,
            })
            -- A Blizzard loadout whose name the convention cannot parse.
            -- Counted, because the Share button still acts on it, but it has
            -- no cell to live in.
            if not placed then offPlan = offPlan + 1 end
        end

        table.sort(prefixOrder)

        local gridRows = {}
        for _, key in ipairs(prefixOrder) do
            local cells = {}
            for c, case in ipairs(CASE_COLUMNS) do
                local cell = cellOf[key][case]
                -- Absent on purpose: a case this prefix never had is left nil
                -- and drawn as a faint well. The gaps are the information --
                -- "no Delve build for this hero talent" is a thing a list of
                -- what exists cannot say.
                if cell then
                    cells[c] = {
                        state   = cell.state,
                        text    = cell.text,
                        tip     = CellTip(cell, editable),
                        onClick = editable and CellClick(cell) or nil,
                    }
                end
            end
            gridRows[#gridRows + 1] = {
                label  = (key ~= "" and key or "--"),
                active = editable,
                cells  = cells,
            }
        end

        rows[#rows + 1] = {
            section = SpecName(specID)
                .. (editable and "  (current)" or ""),
        }
        rows[#rows + 1] = { grid = { cols = CASE_COLUMNS, rows = gridRows } }
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
        help = "Every amber cell at once, behind one confirmation that names "
            .. "them, rather than Blizzard's per-loadout dialog shown over and "
            .. "over. Ones Blizzard would not report are left alone.",
        onClick = ShareAll,
    }
    rows[#rows + 1] = {
        label = "Bases outside the convention",
        value = tostring(offPlan),
        help  = "Blizzard loadouts whose names carry no case token, so the grid "
             .. "has no cell to draw them in. They are left exactly as they "
             .. "are, except that Share counts them in -- a loadout is a "
             .. "loadout whether or not it is named like one.",
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
