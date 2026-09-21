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
--
-- And because a bar widget only helps if you look at it, the mismatch also goes
-- into whatever on-screen warning display you already have -- NSRT's, or
-- BigWigs' -- and into none of our own when you have neither. See the warning
-- section below, which also records why EllesmereUI cannot be one of those.

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
-- The icon is the SET'S OWN, the one picked in Blizzard's set dialog -- more
-- informative than a generic gear glyph, and self-maintaining: re-icon a set
-- and the bar follows.
--
-- It is published through LibDataBroker's `icon` field rather than packed into
-- the text as an escape sequence, which this widget can do and most of the
-- others cannot: LDB carries one icon per object, and Social Status draws two
-- while Group Roles draws three. See Broker.SetIcon. The payoff is that the
-- data bar draws a real Texture it can size, hover-tint and switch off from its
-- own Show Icon setting, which is where anyone would look for it.
--
-- THE STATE COLOUR RIDES ON THE ICON, not only on the text. EllesmereUIDataBars
-- strips |cff codes out of broker text by default, so a text-only colour would
-- have been invisible until you went and turned that off -- which is no way to
-- carry a warning. The text is tinted too, for bars that keep the codes.
-- Text AND icon, together: an icon left behind after the text was cleared is
-- art sitting on the bar beside nothing.
local function BlankBroker()
    Broker.SetText(ldbObject, "")
    Broker.SetIcon(ldbObject, nil, nil)
end

-- `st` is passed in by Redraw, which needs the same answer for the warning;
-- omitted by the panel's own change handlers, which have no reason to have one.
local function UpdateBroker(st)
    if not ldbObject then return end

    if not moduleEnabled then
        BlankBroker()
        return
    end

    st = st or Status()

    -- Nothing to say on a character with no equipment sets at all. Empty rather
    -- than "none": a zero-width widget takes no share of the bar and simply is
    -- not there, which is the honest rendering of having nothing to report.
    -- The icon goes with it, or the bar would draw art beside no text.
    if not st.anySet then
        BlankBroker()
        return
    end

    local color = Broker.IsColored(ModuleDB) and STATE_COLOR[st.state] or nil
    Broker.SetIcon(ldbObject, st.equippedIcon or st.targetIcon, color)
    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, {
        { text = st.equippedName or "No set", color = STATE_COLOR[st.state] },
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
-- On-screen warning
-- ---------------------------------------------------------------------------
-- The widget is a glance. It only helps if you happen to look at the bar, and
-- the moment gear matters most is the moment you are looking anywhere else. So
-- the mismatch also goes somewhere you cannot miss.
--
-- NOT INTO A DISPLAY OF OUR OWN. You have already placed, sized and coloured a
-- warning area; a second one from us would be another thing to move and another
-- style to keep in line with the rest. We post into yours, and when there is
-- none we stay quiet -- an unpositioned warning nobody asked for is worse than
-- no warning.
--
-- ── Why EllesmereUI is not one of these ──────────────────────────────────────
--
-- Its combat alert (EllesmereUIQoL.lua, ShowAlert) is the closest thing it has,
-- and it cannot take a message. The frame is an unnamed local that is never
-- exported, the only exported entry point is _combatAlertPreview(which), and
-- what that draws is AlertText(which) -- the words YOU configured for entering
-- or leaving combat, read from EllesmereUIDB. There is no argument for text.
--
-- Getting a line in would mean overwriting combatAlertEnterText with ours and
-- putting it back afterwards, which corrupts a setting of yours to borrow a
-- frame for 1.85 seconds. Every other EllesmereUI warning -- durability,
-- movement, group death, ready-check mana -- is purpose-built the same way:
-- each formats its own sentence and none takes one.
--
-- So the order is NSRT then BigWigs, and this note is here so the missing first
-- entry reads as a finding rather than an oversight.
--
-- ── The two that do take one ─────────────────────────────────────────────────
--
-- They are different KINDS of channel and are used as each was built:
--
--   NSRT's QoL text display is a list of conditions that are true right now --
--   Gateway Useable, Reset Boss. A line goes up and stays up until the thing
--   stops being true. That is exactly the shape of a gear mismatch, and it is
--   the better of the two for it.
--
--   BigWigs' message area is a stream of things that just happened. Ours is
--   posted once when the mismatch appears and expires on BigWigs' own
--   schedule, because re-posting a standing fact every few seconds is how a
--   warning becomes noise.

local WARN_COLOR = { 1, 0.65, 0.25 }  -- W.BADGE_WARN, the widget's amber

-- Our key in NSRT's display. Named after us on purpose: it is written into
-- another addon's saved variables and should say whose it is on sight.
local NSRT_KEY = "AniModsGearSync"

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

local BACKENDS = {
    {
        title  = "Northern Sky Raid Tools",
        detail = "Its QoL text display -- the one that says Gateway Useable or "
              .. "Reset Boss. The line stays up while the gear is wrong.",
        Available = function() return NSRTDisplay() ~= nil end,
        Show = function(text, icon)
            local NSI, db = NSRTDisplay()
            if not (NSI and db) then return false end
            -- Its renderer draws an entry only while NSRT.QoL[SettingsName] is
            -- truthy -- that is how its own displays are switched on and off in
            -- its options. Ours has no row there, so we set the flag ourselves.
            -- One boolean under a name that says who put it there; with AniMods
            -- gone it is read by nothing, since the entry it gated is gone too.
            db.QoL[NSRT_KEY] = true
            NSI.QoLTextDisplays = NSI.QoLTextDisplays or {}
            NSI.QoLTextDisplays[NSRT_KEY] = {
                SettingsName = NSRT_KEY,
                text = IconEscape(icon, 12) .. text,
            }
            NSI:UpdateQoLTextDisplay()
            return true
        end,
        Clear = function()
            local NSI = NSRTDisplay()
            if not NSI or type(NSI.QoLTextDisplays) ~= "table" then return end
            if NSI.QoLTextDisplays[NSRT_KEY] == nil then return end
            NSI.QoLTextDisplays[NSRT_KEY] = nil
            NSI:UpdateQoLTextDisplay()
        end,
    },
    {
        title  = "BigWigs",
        detail = "Its message area, where boss warnings appear. Posted once "
              .. "when the mismatch appears rather than held there.",
        Available = function() return BigWigsMessages() ~= nil end,
        Show = function(text, icon)
            local plugin = BigWigsMessages()
            if not plugin then return false end
            -- BigWigs' own idiom, the one its Victory and Wipe plugins use.
            -- The colour is passed as a TABLE rather than a name, which is what
            -- makes the module and key arguments irrelevant: with a table it
            -- never consults the Colors plugin, so there is no boss module to
            -- pretend to be. Not emphasized -- that is the huge centre-screen
            -- treatment, and this is a housekeeping note, not a mechanic.
            plugin:SendMessage("BigWigs_Message", plugin, nil, text, WARN_COLOR, icon, false)
            return true
        end,
        -- No Clear. A BigWigs message is something that already happened and
        -- fades on its own; there is nothing standing there to take away.
    },
}

local warnBackend, warnText

local function ClearWarning()
    if not warnBackend then return end
    if warnBackend.Clear then warnBackend.Clear() end
    warnBackend, warnText = nil, nil
end

local function PickBackend()
    for _, backend in ipairs(BACKENDS) do
        if backend.Available() then return backend end
    end
    return nil
end

local function WarnEnabled()
    return ModuleDB().warn ~= false
end

local function UpdateWarning(st)
    if not (moduleEnabled and WarnEnabled() and st.state == "drift") then
        ClearWarning()
        return
    end

    local backend = PickBackend()
    if not backend then
        ClearWarning()
        return
    end

    local text = ("Gear mismatch: %s, loadout wants %s"):format(
        st.equippedName or "no set", st.targetName)

    -- One rule serves both kinds of channel: post only when the line we would
    -- put up differs from the one already up. A held display is left alone
    -- while nothing changes, and a stream gets exactly one message when the
    -- mismatch appears -- and another only if you drift into a DIFFERENT wrong
    -- set, which is genuinely new information.
    if backend == warnBackend and text == warnText then return end
    if warnBackend and warnBackend ~= backend then ClearWarning() end

    if backend.Show(text, st.targetIcon) then
        warnBackend, warnText = backend, text
    end
end

-- ---------------------------------------------------------------------------
-- Watching
-- ---------------------------------------------------------------------------

-- Status once, for both displays. They are two renderings of one answer, and
-- computing it twice is how they would come to disagree.
local function Redraw()
    local st = Status()
    UpdateBroker(st)
    UpdateWarning(st)
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

-- Next frame. For everything whose answer is readable the moment its event
-- fires: a loadout was applied, a spec changed, a click was made.
Refresh = AniMods.Coalesce(Redraw)

-- And the same redraw a third of a second later, for the events that mean YOUR
-- GEAR CHANGED. Two reasons, and the second is a bug this fixes.
--
-- The first is volume: PLAYER_EQUIPMENT_CHANGED fires once per SLOT, so a set
-- swap arrives as a dozen-odd events and each would re-walk the sets to reach
-- the answer the last one produces anyway.
--
-- The second is that the answer is not there yet. C_EquipmentSet's isEquipped
-- is derived from what you are wearing, so mid-swap it still names the set you
-- are leaving -- EllesmereUIBlizzardSkin waits exactly this long before reading
-- it, saying so in its QueueColorRefresh: Blizzard's numLost/isEquipped
-- metadata needs all slots to settle first.
--
-- That is what made a manual set switch leave the widget on its old colour. The
-- redraw ran inside EQUIPMENT_SWAP_FINISHED, read the set being left as still
-- equipped, concluded everything agreed -- and nothing fired afterwards to say
-- otherwise, because EQUIPMENT_SETS_CHANGED is structural (add, rename, delete)
-- and not "a different set is on now". The tooltip looked right throughout
-- because it recomputes at hover, long after the dust has settled, which is
-- exactly the shape of a staleness bug: the cached view is wrong and the
-- computed-on-demand one is not.
local RefreshSettled = AniMods.Coalesce(Redraw, 0.3)

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
    -- The three that mean your gear or your sets moved. All display, none a
    -- sync: saving a set or changing clothes is your doing, and re-equipping
    -- over it would be the module arguing. All settled rather than immediate,
    -- for the reason RefreshSettled gives at length.
    --
    -- All THREE, because no one of them covers the others. EQUIPMENT_SETS_CHANGED
    -- is structural -- a set added, renamed or deleted -- and stays silent when
    -- you merely put a different one on. EQUIPMENT_SWAP_FINISHED covers that,
    -- and only that. And PLAYER_EQUIPMENT_CHANGED is the one for swapping an
    -- ITEM by hand, which can take you out of a set without any set ever having
    -- been applied.
    watcher:RegisterEvent("EQUIPMENT_SETS_CHANGED")
    watcher:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
    watcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    -- Display only. Logging in is not a decision to change builds, but the sets
    -- are not readable until the world is, so this is when the widget can first
    -- say anything at all.
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function(_, event)
        if event == "EQUIPMENT_SETS_CHANGED"
            or event == "EQUIPMENT_SWAP_FINISHED"
            or event == "PLAYER_EQUIPMENT_CHANGED" then
            RefreshSettled()
            return
        end

        -- The rest are readable at once, and some of them are also a reason to
        -- act, which is what follows.
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
             .. "The data bar widget goes amber while that is true, and the "
             .. "on-screen warning below says so where you will see it."
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

    rows[#rows + 1] = { section = "On-screen warning" }
    local backend = PickBackend()
    rows[#rows + 1] = {
        label = "Warn on screen",
        get   = WarnEnabled,
        set   = function(v)
            ModuleDB().warn = v and true or false
            Refresh()
        end,
        help  = "Says so in your existing warning display when the set you are "
             .. "wearing is not the one your loadout names. The data bar widget "
             .. "only helps if you happen to look at it, and gear matters most "
             .. "when you are looking somewhere else.",
    }
    rows[#rows + 1] = {
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
    }

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsGearSync", {
        -- The icon is the equipment set's own and is published through LDB's
        -- own field, so both icon controls belong to the data bar.
        nativeIcon = true,
        colorHelp  = "The colour is the whole warning: amber means the set you "
                  .. "are wearing is not the one your loadout names. It is put "
                  .. "on the icon as well as the text, because data bars "
                  .. "commonly strip colour codes out of broker text -- "
                  .. "EllesmereUIDataBars does by default. Turning this off "
                  .. "leaves the widget readable and silent.",
    })) do
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
    -- text; a zero-width widget takes no share of the bar. The warning is
    -- taken down the same way -- a line left standing in someone else's
    -- display after the module that put it there is off would be ours to
    -- explain and nobody's to remove.
    UpdateBroker()
    UpdateWarning(Status())
    return true
end

AniMods.RegisterModule("GearSync", GearSync)
