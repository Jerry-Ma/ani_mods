-- GearSync
-- Equips the equipment set that matches the talent loadout you just applied.
--
-- Both are named by the same convention -- {Prefix}-{Case}{Variant}, the one
-- Talent Loadouts documents and parses -- so "SA-Raid" gear belongs with an
-- "SA-Raid" build, and the pairing needs no table to be maintained. The name IS
-- the mapping.
--
-- The parser is IMPORTED, not copied: AniMods.LoadoutName comes from
-- TalentLoadouts, which owns the convention. Two copies would drift the first
-- time a case token was added, and the symptom would be gear quietly not
-- swapping -- which looks like nothing at all rather than like a bug.
--
-- MATCHING NEVER GUESSES. Exact name first, then a set named for the loadout's
-- base, then -- only if exactly one set shares that base -- that one. Two
-- candidates means doing nothing, because equipping the wrong set costs a
-- conscious regear and a wrong guess here would be silent.
--
-- It acts on loadout CHANGES, not continuously. Equipping something else by
-- hand afterwards is a decision, and a module that undid it every few seconds
-- would be fighting you rather than helping.

local AniMods = _G.AniMods

local GearSync = {
    title = "Gear Sync",
    description = "Equips the gear set matching the talent loadout you apply.",
    dbKey = "gearSync",
    category = "Automation",
    conditions = {
        { text = "TalentLoadoutManager loaded",
          help = "The loadout names this matches against are TLM's. Blizzard's "
              .. "own loadout slots carry a different set of names, so without "
              .. "TLM there is nothing to match.",
          met = function() return AniMods.IsAddOnLoaded("TalentLoadoutManager") end },
    },
}

local moduleEnabled = true
local watcher
local pendingName          -- a loadout applied while we could not act on it
local lastResult = {}      -- what the panel reports about the last attempt

local function ModuleDB()
    AniModsDB.gearSync = AniModsDB.gearSync or {}
    return AniModsDB.gearSync
end

local function Naming()
    return AniMods.LoadoutName
end

-- ---------------------------------------------------------------------------
-- The two sides
-- ---------------------------------------------------------------------------

local function ActiveLoadoutName()
    local api = _G.TalentLoadoutManagerAPI
    local char = api and api.CharacterAPI
    if not (char and type(char.GetActiveLoadoutInfo) == "function") then return nil end
    local ok, info = _G.pcall(char.GetActiveLoadoutInfo, char)
    if not ok or type(info) ~= "table" then return nil end
    return info.name
end

-- name -> setID, plus the ID of whatever is equipped right now.
local function EquipmentSets()
    local byName, equippedID = {}, nil
    local ids = _G.C_EquipmentSet.GetEquipmentSetIDs()
    if type(ids) ~= "table" then return byName, nil end
    for _, id in ipairs(ids) do
        local name, _, _, isEquipped = _G.C_EquipmentSet.GetEquipmentSetInfo(id)
        if name then
            byName[name] = id
            if isEquipped then equippedID = id end
        end
    end
    return byName, equippedID
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

--- @return number|nil setID
--- @return string reason  what was matched, or why nothing was
local function FindSet(loadoutName)
    local naming = Naming()
    if not naming then return nil, "the loadout parser is not available" end

    local byName, _ = EquipmentSets()

    if byName[loadoutName] then
        return byName[loadoutName], "exact name"
    end

    local base = naming.Base(loadoutName)
    if base == naming.UNCATEGORISED then
        return nil, ("%q carries no case token, so it has no base to match on"):format(loadoutName)
    end

    if byName[base] then
        return byName[base], "base name"
    end

    -- Last resort: a set whose own name reduces to the same base. Only when
    -- there is exactly one -- "SA-Raid1" and "SA-Raid-MT" are both plausible
    -- partners for an "SA-Raid" build, and picking between them is a guess.
    local found, count = nil, 0
    for name, id in pairs(byName) do
        if naming.Base(name) == base then
            found, count = id, count + 1
        end
    end
    if count == 1 then return found, "shared base" end
    if count > 1 then
        return nil, ("%d sets share the base %q, so none was picked"):format(count, base)
    end
    return nil, ("no set matches %q or %q"):format(loadoutName, base)
end

-- ---------------------------------------------------------------------------
-- Equipping
-- ---------------------------------------------------------------------------

local function Sync(loadoutName, manual)
    lastResult = { loadout = loadoutName }

    if not loadoutName then
        lastResult.reason = "no talent loadout is active"
        return false
    end

    local setID, reason = FindSet(loadoutName)
    lastResult.reason = reason
    if not setID then return false end

    local _, equippedID = EquipmentSets()
    local setName = _G.C_EquipmentSet.GetEquipmentSetInfo(setID)
    lastResult.set = setName

    if equippedID == setID then
        lastResult.reason = "already equipped"
        return true
    end

    -- Equipment cannot be swapped in combat. Remembered rather than dropped:
    -- applying a loadout mid-fight is exactly when the gear matters, and the
    -- swap should land the moment it is allowed to.
    if _G.InCombatLockdown() then
        pendingName = loadoutName
        lastResult.reason = "waiting for combat to end"
        return false
    end

    _G.C_EquipmentSet.UseEquipmentSet(setID)
    lastResult.reason = ("equipped by %s"):format(reason)
    if manual or ModuleDB().announce then
        AniMods.Print(("equipped %s for %s."):format(setName or "?", loadoutName))
    end
    return true
end

local function OnLoadoutApplied()
    if not moduleEnabled then return end
    -- One frame later: TLM fires this as it applies, and the active loadout it
    -- reports is only settled once that has finished.
    _G.C_Timer.After(0, function()
        if moduleEnabled then Sync(ActiveLoadoutName()) end
    end)
end

local callbackOwner = {}
local callbackRegistered = false

local function EnsureCallback()
    if callbackRegistered then return end
    local api = _G.TalentLoadoutManagerAPI
    if not (api and api.Event and type(api.RegisterCallback) == "function") then return end
    callbackRegistered = true
    -- TalentLoadoutManagerAPI implements CallbackRegistryMixin, which its own
    -- header points out is there to be used -- so this is the addon's intended
    -- way in rather than a hook into its internals.
    api:RegisterCallback(api.Event.CustomLoadoutApplied, OnLoadoutApplied, callbackOwner)
end

local function EnsureWatcher()
    if watcher then return end
    watcher = _G.CreateFrame("Frame")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- A spec change swaps the active loadout without applying one, so the
    -- callback above never fires for it.
    watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    watcher:SetScript("OnEvent", function(_, event)
        if not moduleEnabled then return end
        if event == "PLAYER_REGEN_ENABLED" then
            if pendingName then
                local name = pendingName
                pendingName = nil
                Sync(name)
            end
            return
        end
        _G.C_Timer.After(1, function()
            if moduleEnabled then Sync(ActiveLoadoutName()) end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function GearSync:GetInfoRows()
    local rows = {}
    local loadoutName = ActiveLoadoutName()
    local naming = Naming()

    rows[#rows + 1] = { section = "Now" }
    rows[#rows + 1] = {
        label = "Talent loadout",
        value = loadoutName or "none",
        help  = "TLM's active loadout. Blizzard's own slot name is a different "
             .. "thing and is not what this matches on.",
    }
    rows[#rows + 1] = {
        label = "Base",
        value = (loadoutName and naming and naming.Base(loadoutName)) or "-",
        help  = "The {Prefix}-{Case} part of the name, shared by every variant "
             .. "of a build. An equipment set named for the base pairs with all "
             .. "of them.",
    }

    local _, equippedID = EquipmentSets()
    rows[#rows + 1] = {
        label = "Equipped set",
        value = (equippedID and _G.C_EquipmentSet.GetEquipmentSetInfo(equippedID)) or "none",
    }
    rows[#rows + 1] = {
        label = "Last result",
        value = lastResult.reason or "nothing tried yet",
        help  = "Matching is exact name, then a set named for the base, then a "
             .. "set sharing the base -- and only when exactly one does. Two "
             .. "candidates means doing nothing, because equipping the wrong "
             .. "set costs a regear and a wrong guess would be silent.",
    }

    rows[#rows + 1] = { section = "Behaviour" }
    rows[#rows + 1] = {
        label = "Announce swaps",
        get   = function() return ModuleDB().announce and true or false end,
        set   = function(v) ModuleDB().announce = v and true or false end,
        help  = "Prints a line when a set is equipped. Off by default: the gear "
             .. "changing is its own confirmation.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Sync now", button = "Sync",
        help = "Runs the same match the loadout change would, and says what it "
            .. "found either way.",
        onClick = function()
            Sync(ActiveLoadoutName(), true)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function GearSync:Enable()
    moduleEnabled = true
    EnsureWatcher()
    -- Deferred: TLM builds its API during its own load, and the callback cannot
    -- be registered before it exists.
    AniMods.W.OnReady(function()
        EnsureCallback()
        -- Deliberately no sync at login. Logging in is not a decision to change
        -- builds, and equipping over whatever you logged out in would be the
        -- module's first act of the session.
    end)
end

function GearSync:SetEnabled(on)
    moduleEnabled = on and true or false
    if not moduleEnabled then pendingName = nil end
    return true
end

AniMods.RegisterModule("GearSync", GearSync)
