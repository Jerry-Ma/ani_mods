-- GearSync
-- Equips the equipment set that matches the talent loadout you just applied.
--
-- Both are named by the same convention -- {Prefix}-{Case}{Variant}, the one
-- Talent Loadouts documents and parses -- so "SA-Raid" gear belongs with an
-- "SA-Raid" build, and the pairing needs no table to be maintained. The name IS
-- the mapping.
--
-- MATCHING IS BY LONGEST PREFIX. A set named "HO" serves every HO-* loadout; a
-- set named "H" serves every Holy one. So one set can cover a whole spec, a
-- finer one can cover a hero talent, and a specific one can cover a single
-- build -- and the most specific name that fits always wins, because a longer
-- prefix is a more deliberate choice.
--
-- That also removes the need to refuse. An earlier version matched exact name,
-- then base, then any set sharing the base -- and did nothing when two shared
-- one, since picking between "SA-Raid1" and "SA-Raid-MT" was a guess. Longest
-- prefix has no such case: set names are unique, so the longest one that fits
-- is unique too.
--
-- NO ADDON IS REQUIRED. TalentLoadoutManager's names are read when it is there,
-- and Blizzard's own saved loadouts when it is not -- the convention lives in
-- the names, not in whoever stores them.
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
    -- No conditions. It reads whichever loadout source is present, and an
    -- install with neither simply has no name to match on -- which the panel
    -- says in a row rather than as a red badge.
}

local moduleEnabled = true
local watcher
local pendingName          -- a loadout applied while we could not act on it
local lastResult = {}      -- what the panel reports about the last attempt

local function ModuleDB()
    AniModsDB.gearSync = AniModsDB.gearSync or {}
    return AniModsDB.gearSync
end

-- ---------------------------------------------------------------------------
-- The two sides
-- ---------------------------------------------------------------------------

-- TalentLoadoutManager first when it is there, Blizzard's own saved loadout
-- otherwise. TLM's list is a superset -- its loadouts are the ones a TLM user
-- actually names and applies -- but nothing here needs it, because the
-- convention lives in the NAME rather than in whoever stores it.
local function ActiveLoadoutName()
    local api = _G.TalentLoadoutManagerAPI
    local char = api and api.CharacterAPI
    if char and type(char.GetActiveLoadoutInfo) == "function" then
        local ok, info = _G.pcall(char.GetActiveLoadoutInfo, char)
        if ok and type(info) == "table" and info.name then return info.name, "TLM" end
    end

    -- Blizzard's, by the route SpecSwitch documents: the last-selected saved
    -- config for this spec, then that config's name.
    local talents, traits = _G.C_ClassTalents, _G.C_Traits
    if not (talents and talents.GetLastSelectedSavedConfigID and traits and traits.GetConfigInfo) then
        return nil, nil
    end
    local specIndex = _G.C_SpecializationInfo.GetSpecialization()
    local specID = specIndex and _G.C_SpecializationInfo.GetSpecializationInfo(specIndex)
    if not specID then return nil, nil end
    local configID = talents.GetLastSelectedSavedConfigID(specID)
    if not configID then return nil, nil end
    local info = traits.GetConfigInfo(configID)
    if type(info) ~= "table" or not info.name then return nil, nil end
    return info.name, "Blizzard"
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

--- The set whose name is the LONGEST prefix of the loadout name.
---
--- "HO" serves every HO-* loadout and "H" every Holy one, so one set can cover
--- a spec, a finer one a hero talent, and a specific one a single build. The
--- longest match wins because a longer name is a more deliberate choice -- an
--- exact match is simply the longest possible prefix, needing no special case.
---
--- Compared case-insensitively. The convention's letters carry meaning but
--- their capitalisation does not, and a set named "ha-raid" failing to match
--- "HA-Raid1" would be a silent nothing rather than a visible mistake.
---
--- @return number|nil setID
--- @return string reason  what was matched, or why nothing was
local function FindSet(loadoutName)
    local byName = EquipmentSets()
    local wanted = loadoutName:lower()

    local bestName, bestID
    for name, id in pairs(byName) do
        if name ~= "" and wanted:sub(1, #name) == name:lower() then
            if not bestName or #name > #bestName then
                bestName, bestID = name, id
            end
        end
    end

    if not bestID then
        return nil, ("no set name is a prefix of %q"):format(loadoutName)
    end
    if #bestName == #loadoutName then
        return bestID, "exact name"
    end
    return bestID, ("prefix %q"):format(bestName)
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
    callbackRegistered = true

    local api = _G.TalentLoadoutManagerAPI
    if api and api.Event and type(api.RegisterCallback) == "function" then
        -- TalentLoadoutManagerAPI implements CallbackRegistryMixin, which its
        -- own header points out is there to be used -- so this is the addon's
        -- intended way in rather than a hook into its internals.
        api:RegisterCallback(api.Event.CustomLoadoutApplied, OnLoadoutApplied, callbackOwner)
    end

    -- Blizzard's side, for an install with no TalentLoadoutManager and for the
    -- loadouts TLM does not own. This is the same pointer SpecSwitch watches:
    -- there is no event for "a saved loadout was selected", only the call that
    -- records which one.
    local talents = _G.C_ClassTalents
    if talents and talents.UpdateLastSelectedSavedConfigID then
        _G.hooksecurefunc(talents, "UpdateLastSelectedSavedConfigID", OnLoadoutApplied)
    end
end

local function EnsureWatcher()
    if watcher then return end
    watcher = _G.CreateFrame("Frame")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- A spec change swaps the active loadout without applying one, so the
    -- callback above never fires for it.
    watcher:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    -- The panel's "Now" section reports live state -- which sets exist and
    -- which is worn -- so it has to hear about both. Neither triggers a sync:
    -- saving a set or changing clothes is your doing, and re-equipping over it
    -- would be the module arguing.
    watcher:RegisterEvent("EQUIPMENT_SETS_CHANGED")
    watcher:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
    watcher:SetScript("OnEvent", function(_, event)
        if event == "EQUIPMENT_SETS_CHANGED" or event == "EQUIPMENT_SWAP_FINISHED" then
            if AniMods.RefreshUI then AniMods.RefreshUI() end
            return
        end
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
    local loadoutName, source = ActiveLoadoutName()

    rows[#rows + 1] = { section = "Now" }
    rows[#rows + 1] = {
        label = "Talent loadout",
        value = loadoutName or "none",
        help  = source
            and ("Read from " .. source .. ". TalentLoadoutManager is used when "
                .. "it is installed, Blizzard's own saved loadouts otherwise -- "
                .. "the convention lives in the name, not in whoever stores it.")
            or  "No saved loadout is selected, so there is no name to match on.",
    }

    local _, equippedID = EquipmentSets()
    rows[#rows + 1] = {
        label = "Equipped set",
        value = (equippedID and _G.C_EquipmentSet.GetEquipmentSetInfo(equippedID)) or "none",
    }

    local matchID, matchWhy = nil, nil
    if loadoutName then matchID, matchWhy = FindSet(loadoutName) end
    rows[#rows + 1] = {
        label = "Would equip",
        value = (matchID and _G.C_EquipmentSet.GetEquipmentSetInfo(matchID)) or "nothing",
        help  = "The set whose name is the longest prefix of the loadout name. "
             .. "\"HO\" serves every HO-* loadout and \"H\" every Holy one, so "
             .. "one set can cover a spec and a more specific name always wins. "
             .. "Matched ignoring case."
             .. (matchWhy and ("\n\nRight now: " .. matchWhy .. ".") or ""),
    }
    rows[#rows + 1] = {
        label = "Last result",
        value = lastResult.reason or "nothing tried yet",
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
