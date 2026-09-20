-- GearSync
-- Equips the equipment set that matches the talent loadout you just applied,
-- and puts whether the two agree on a data bar.
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
--
-- ── The widget ───────────────────────────────────────────────────────────────
--
-- That last paragraph is exactly why there is a data bar widget: because the
-- module deliberately stops arguing, the two CAN drift apart, and nothing else
-- would tell you. So the widget shows the set you are wearing, tinted by
-- whether it is the one your loadout names -- amber when it is not, which is
-- the only state worth noticing. Left-click syncs, right-click opens the
-- equipment manager.

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

local Broker = AniMods.Broker

local moduleEnabled = true
local watcher
local pendingSync          -- a sync that combat is holding up
local lastReason           -- what the panel and tooltip report about the last attempt

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
--- `byName` is passed in rather than gathered here: every caller already has
--- the set list, and re-walking C_EquipmentSet to answer one question about it
--- was the module asking the game the same thing three times per refresh.
---
--- @return number|nil setID
--- @return string|nil why  what was matched, for display -- nil when nothing was
local function FindSet(byName, loadoutName)
    local wanted = loadoutName:lower()

    local bestName, bestID
    for name, id in pairs(byName) do
        if name ~= "" and wanted:sub(1, #name) == name:lower() then
            if not bestName or #name > #bestName then
                bestName, bestID = name, id
            end
        end
    end

    if not bestID then return nil, nil end
    if #bestName == #loadoutName then return bestID, "exact name" end
    return bestID, ("prefix %q"):format(bestName)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

-- Everything the module knows, gathered once.
--
-- The bar, the tooltip, the panel and the sync all ask the same four questions
-- -- what loadout, what is worn, what should be, and do those agree -- so they
-- ask them in one place. They used to each gather their own, which is how
-- GetInfoRows came to walk the equipment sets three times to draw four rows,
-- and how "would equip" and "equipped by" could in principle have disagreed.
--
-- Four states, and only ONE of them is a problem:
--
--   synced    -- the set the loadout names is the set you are wearing.
--   drift     -- a set matches and you are wearing something else. The state
--                this widget exists for; it is quiet in every other.
--   unmatched -- a loadout is applied and no set name is a prefix of it. Not a
--                fault: plenty of loadouts are not meant to have gear of their
--                own, and naming one that way is how you say so.
--   noloadout -- nothing applied, so there is nothing to compare against.
local function Status()
    local loadout, source = ActiveLoadoutName()
    local byName, equippedID = EquipmentSets()

    local equippedName, equippedIcon
    if equippedID then
        equippedName, equippedIcon = _G.C_EquipmentSet.GetEquipmentSetInfo(equippedID)
    end

    local targetID, why
    if loadout then targetID, why = FindSet(byName, loadout) end
    local targetName, targetIcon
    if targetID then
        targetName, targetIcon = _G.C_EquipmentSet.GetEquipmentSetInfo(targetID)
    end

    local state
    if not loadout then
        state = "noloadout"
    elseif not targetID then
        state = "unmatched"
    elseif targetID == equippedID then
        state = "synced"
    else
        state = "drift"
    end

    return {
        -- `anySet` is what "is this character using equipment sets at all"
        -- means, and it is a different question from "is one equipped".
        anySet       = next(byName) ~= nil,
        loadout      = loadout,
        source       = source,
        equippedID   = equippedID,
        equippedName = equippedName,
        equippedIcon = equippedIcon,
        targetID     = targetID,
        targetName   = targetName,
        targetIcon   = targetIcon,
        why          = why,
        state        = state,
    }
end

-- ---------------------------------------------------------------------------
-- Equipping
-- ---------------------------------------------------------------------------

--- @param manual boolean|nil  a click asked for this, so say what happened
--- @return boolean equipped   true only when a swap was actually issued
local function Sync(manual)
    local st = Status()

    if st.state == "noloadout" then
        lastReason = "no talent loadout is active"
    elseif st.state == "unmatched" then
        lastReason = ("no set name is a prefix of %q"):format(st.loadout)
    elseif st.state == "synced" then
        lastReason = "already equipped"
    elseif _G.InCombatLockdown() then
        -- Equipment cannot be swapped in combat. Remembered rather than
        -- dropped: applying a loadout mid-fight is exactly when the gear
        -- matters, and the swap should land the moment it is allowed to.
        --
        -- A flag, not the name. The loadout is re-read when combat ends, so
        -- applying a second build before the fight is over syncs to THAT one
        -- rather than to whatever was pending when the first was applied.
        pendingSync = true
        lastReason = "waiting for combat to end"
    else
        _G.C_EquipmentSet.UseEquipmentSet(st.targetID)
        lastReason = ("equipped by %s"):format(st.why)
        if manual or ModuleDB().announce then
            AniMods.Print(("equipped %s for %s."):format(st.targetName or "?", st.loadout))
        end
        return true
    end

    -- A click that changes nothing still has to answer. Only on a manual one:
    -- the automatic path runs on every loadout change, and most of those
    -- legitimately have no gear to swap.
    if manual then AniMods.Print(lastReason .. ".") end
    return false
end

-- ---------------------------------------------------------------------------
-- The widget
-- ---------------------------------------------------------------------------

-- Amber is W.BADGE_WARN's exact hue, so AniMods has one amber rather than each
-- module inventing its own shade of "look at this".
local STATE_COLOR = {
    synced    = "2ecc71",
    drift     = "ffa640",
    unmatched = "999999",
    noloadout = "999999",
}

local ldbObject
local popup

-- The bar says which set you are WEARING, in every state, and the colour says
-- whether that is the right one.
--
-- Showing the target instead while drifting was tried and dropped: it makes one
-- cell answer two different questions depending on which answer it is giving,
-- which is the same mistake Broker.SectionRows' own note describes. The colour
-- already says something is off and the click already fixes it, so the target
-- belongs in the tooltip -- where it is read at the moment you are asking.
--
-- The icon is the SET'S OWN, the one picked in Blizzard's set dialog. That is
-- both more informative than a generic gear glyph and self-maintaining: rename
-- or re-icon a set and the bar follows. It is also why this widget has no "Icon
-- style" row -- neither art family applies, so the control would change nothing.
local function UpdateBroker()
    if not ldbObject then return end

    if not moduleEnabled then
        Broker.SetText(ldbObject, "")
        return
    end

    local st = Status()

    -- Nothing to say on a character with no equipment sets at all. Empty rather
    -- than "none": a zero-width widget takes no share of the bar and simply is
    -- not there, which is the honest rendering of having nothing to report.
    if not st.anySet then
        Broker.SetText(ldbObject, "")
        return
    end

    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, {
        {
            text    = st.equippedName or "No set",
            color   = STATE_COLOR[st.state],
            texture = st.equippedIcon or st.targetIcon,
        },
    }))
end

local function ShowTooltip(tt)
    local st = Status()

    tt:AddLine("Gear Sync", 1, 0.82, 0)

    if not st.anySet then
        tt:AddLine("No equipment sets saved.", 0.6, 0.6, 0.6)
        return
    end

    tt:AddDoubleLine("Loadout", st.loadout or "none", 0.8, 0.8, 0.8, 1, 1, 1)
    tt:AddDoubleLine("Equipped", st.equippedName or "none", 0.8, 0.8, 0.8, 1, 1, 1)

    if st.state == "drift" then
        -- The one line the amber on the bar is pointing at.
        tt:AddDoubleLine("Should be", st.targetName, 0.8, 0.8, 0.8, 1, 0.65, 0.25)
        tt:AddLine("Matched by " .. st.why .. ".", 0.6, 0.6, 0.6)
    elseif st.state == "synced" then
        tt:AddLine("Matches your loadout.", 0.35, 1, 0.35)
    elseif st.state == "unmatched" then
        tt:AddLine("No set name is a prefix of this loadout.", 0.6, 0.6, 0.6)
    else
        tt:AddLine("No talent loadout is applied.", 0.6, 0.6, 0.6)
    end

    if lastReason then
        tt:AddDoubleLine("Last result", lastReason, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
    end

    -- Hints live here rather than in a menu footer, the way SpecSwitch's do,
    -- because this widget has no menu -- both clicks act immediately, and the
    -- tooltip is the only place that can say so before one is spent.
    tt:AddLine(" ")
    tt:AddDoubleLine("Left-click", "Sync now", 0.6, 0.6, 0.6, 1, 1, 1)
    tt:AddDoubleLine("Right-click", "Equipment manager", 0.6, 0.6, 0.6, 1, 1, 1)
end

local function ShowPopup(anchor)
    popup = popup or AniMods.W.Tooltip()
    popup:Clear()
    ShowTooltip(popup)
    popup:Show(anchor)
end

-- Right-click goes to the list this widget is about.
--
-- ToggleCharacter TOGGLES, so calling it on an already-open character sheet
-- would shut it -- the opposite of "show me my sets". Opened only when it is
-- closed; the equipment view is then selected either way, so a second
-- right-click on a sheet already open on another tab still lands somewhere.
--
-- EllesmereUIBlizzardSkin overlays Blizzard's EquipmentManagerPane with its own
-- gear-sets panel and adds a button to the sheet for it
-- (EllesmereUIBlizzardSkin_CharacterSheet.lua, EUI_CharSheet_Equipment).
-- Clicking that button is what switches ITS view, and it clicks
-- PaperDollSidebarTab3 itself on the way. So its button is used when the skin
-- built one and Blizzard's tab when it did not: two different character sheets,
-- not a fallback.
local function OpenEquipmentManager()
    if not _G.CharacterFrame:IsShown() then
        _G.ToggleCharacter("PaperDollFrame")
    end
    -- Next frame. The skin's button is only shown once the sheet is, and
    -- Blizzard re-runs PaperDollFrame_UpdateSidebarTabs on show -- which is
    -- what decides whether tab 3 is enabled.
    _G.C_Timer.After(0, function()
        local euiButton = _G.EUI_CharSheet_Equipment
        if euiButton and euiButton:IsShown() then
            euiButton:Click()
            return
        end
        local tab = _G.PaperDollSidebarTab3
        if tab and tab:IsShown() and tab:IsEnabled() then tab:Click() end
    end)
end

-- Forward-declared, not stubbed: a placeholder body would be assigned and then
-- overwritten before ever running, which is dead code the linter is right to
-- flag. Defined with the event plumbing below.
local Refresh

local function InitLDB()
    -- NOTE: this name is an ID, not a label -- data bars store it verbatim in
    -- their own saved variables as the block's source. Renaming it orphans any
    -- block already pointing at the old name.
    ldbObject = Broker.Register("AniModsGearSync", {
        label = "AniMods: Gear Sync",
        -- Both clicks act, neither opens a menu. There is exactly one thing to
        -- do about drift and exactly one place to go to look at the sets, so a
        -- menu would be a list of one option and a title.
        OnClick = function(_, button)
            if button == "LeftButton" then
                Sync(true)
                Refresh()
            else
                OpenEquipmentManager()
            end
        end,
        -- Themed popup where the display supports it, plain GameTooltip where
        -- it does not; one render function serves both (see W.Tooltip).
        OnEnter = ShowPopup,
        OnLeave = function() if popup then popup:Hide() end end,
        OnTooltipShow = ShowTooltip,
    })
end

-- ---------------------------------------------------------------------------
-- Watching
-- ---------------------------------------------------------------------------

Refresh = function()
    UpdateBroker()
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

local function OnLoadoutApplied()
    -- One frame later: TLM fires this as it applies, and the active loadout it
    -- reports is only settled once that has finished.
    _G.C_Timer.After(0, function()
        if moduleEnabled then Sync() end
        Refresh()
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
    -- Which sets exist and which is worn are half of what the widget and the
    -- panel display, so both have to be heard. Neither triggers a sync: saving
    -- a set or changing clothes is your doing, and re-equipping over it would
    -- be the module arguing.
    watcher:RegisterEvent("EQUIPMENT_SETS_CHANGED")
    watcher:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
    -- Display only. Logging in is not a decision to change builds, but the sets
    -- are not readable until the world is, so this is when the widget can first
    -- say anything at all.
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function(_, event)
        -- Every one of these changes what is displayed, whether or not it
        -- changes what is worn -- so the redraw is unconditional and what
        -- follows is only about acting.
        Refresh()

        if not moduleEnabled then return end

        if event == "PLAYER_REGEN_ENABLED" then
            if pendingSync then
                pendingSync = false
                Sync()
            end
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            _G.C_Timer.After(1, function()
                if moduleEnabled then Sync() end
                Refresh()
            end)
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function GearSync:GetInfoRows()
    local rows = {}
    local st = Status()

    rows[#rows + 1] = { section = "Now" }
    rows[#rows + 1] = {
        label = "Talent loadout",
        value = st.loadout or "none",
        help  = st.source
            and ("Read from " .. st.source .. ". TalentLoadoutManager is used when "
                .. "it is installed, Blizzard's own saved loadouts otherwise -- "
                .. "the convention lives in the name, not in whoever stores it.")
            or  "No saved loadout is selected, so there is no name to match on.",
    }
    rows[#rows + 1] = { label = "Equipped set", value = st.equippedName or "none" }
    rows[#rows + 1] = {
        label = "Would equip",
        value = st.targetName or "nothing",
        help  = "The set whose name is the longest prefix of the loadout name. "
             .. "\"HO\" serves every HO-* loadout and \"H\" every Holy one, so "
             .. "one set can cover a spec and a more specific name always wins. "
             .. "Matched ignoring case."
             .. (st.why and ("\n\nRight now: matched by " .. st.why .. ".") or ""),
    }
    rows[#rows + 1] = {
        label = "In sync",
        state = st.state == "synced",
        help  = st.state == "drift"
            and "You are wearing a different set from the one this loadout names. "
             .. "The data bar widget goes amber while that is true."
            or nil,
    }
    rows[#rows + 1] = {
        label = "Last result",
        value = lastReason or "nothing tried yet",
    }

    rows[#rows + 1] = { section = "Behaviour" }
    rows[#rows + 1] = {
        label = "Announce swaps",
        get   = function() return ModuleDB().announce and true or false end,
        set   = function(v) ModuleDB().announce = v and true or false end,
        help  = "Prints a line when a set is equipped. Off by default: the gear "
             .. "changing is its own confirmation. A swap you asked for by "
             .. "clicking always says what it did.",
    }
    rows[#rows + 1] = {
        kind = "button", label = "Sync now", button = "Sync",
        help = "Runs the same match the loadout change would, and says what it "
            .. "found either way.",
        onClick = function()
            Sync(true)
            Refresh()
        end,
    }

    -- No "Icon style" row: the widget draws the equipment set's own icon, so
    -- neither art family is involved and the control would change nothing.
    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsGearSync",
        { noIconStyle = true })) do
        rows[#rows + 1] = row
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function GearSync:Enable()
    moduleEnabled = true
    InitLDB()
    EnsureWatcher()
    UpdateBroker()
    -- Deferred: TLM builds its API during its own load, and the callback cannot
    -- be registered before it exists.
    AniMods.W.OnReady(function()
        EnsureCallback()
        -- Deliberately no sync at login. Logging in is not a decision to change
        -- builds, and equipping over whatever you logged out in would be the
        -- module's first act of the session. The widget still shows whether the
        -- two agree, which is the part worth knowing at login.
        UpdateBroker()
    end)
end

function GearSync:SetEnabled(on)
    moduleEnabled = on and true or false
    if not moduleEnabled then pendingSync = nil end
    -- LibDataBroker has no unregister, so switching off means blanking the
    -- text; a zero-width widget takes no share of the bar.
    UpdateBroker()
    return true
end

AniMods.RegisterModule("GearSync", GearSync)
