-- SpecSwitch
-- Switch talent specialization and loot specialization from a data bar.
--
-- Left-click opens a menu of specs, right-click a menu of loot specs -- the
-- same split EllesmereUIDataBars' spec block uses. Its modifier-clicks (Ctrl
-- for loadouts, Shift for the talent frame) are deliberately not copied: see
-- the loadout section below.
--
-- ── Why this is gated to a stock UI ──────────────────────────────────────────
--
-- Both EllesmereUI and NDui already ship this exact widget --
-- EllesmereUIDataBars' "spec" block and NDui's Modules/Infobar/Spec.lua -- and
-- theirs are better: EUI's offers loadout switching and a talent-frame
-- shortcut from the same button. Running a second one beside either is two
-- widgets doing one job, so this stands down.
--
-- That makes these HARD conditions rather than soft ones. A soft condition is
-- an advisory the user may overrule with "Run anyway", which fits AniMods' own
-- data bar (running two bars is odd but harmless). Here the alternative is not
-- merely redundant, it is strictly worse, so there is nothing to overrule.
--
-- Only Blizzard API is used, so nothing needs to be installed:
--
--   GetNumSpecializations()                  -- spec count
--   GetSpecializationInfo(i)                 -- id, name, _, icon, role
--   GetSpecialization()                      -- active spec INDEX
--   C_SpecializationInfo.SetSpecialization(i)-- change spec (out of combat)
--   GetLootSpecialization()                  -- loot spec ID, 0 = follow spec
--   SetLootSpecialization(id)                -- change loot spec (combat-legal)

local SpecSwitch = {
    title = "Spec Switch",
    description = "Switch your specialization and loot spec.",
    conditions = {
        { text = "EllesmereUI not loaded",
          help = "EllesmereUIDataBars ships a spec block that already does this, "
              .. "with loadout switching too.",
          met = function() return not AniMods.IsAddOnLoaded("EllesmereUI") end },
        { text = "NDui not loaded",
          help = "NDui's infobar ships its own spec and loot-spec switcher.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
    },
}

local Broker = AniMods.Broker

local ldbObject
local popup

local function ModuleDB()
    AniModsDB.specSwitch = AniModsDB.specSwitch or {}
    return AniModsDB.specSwitch
end

-- On by default, but a setting: it is the one part of this widget that makes it
-- wider, and loadout names are user-chosen, so a bar with three widgets and a
-- loadout called "Single Target Cleave Build" has a different opinion about
-- that than one with two and "Raid".
local function ShowLoadout()
    return ModuleDB().showLoadout ~= false
end

-- ---------------------------------------------------------------------------
-- Specs
-- ---------------------------------------------------------------------------

-- Cached, the way EllesmereUIDataBars' own spec block does it (its
-- BuildSpecCache): the list changes only when a character learns a spec, while
-- the things that read it -- the broker text, the tooltip, the cycler -- run on
-- every hover and every click.
--
-- The first version rebuilt it inside each of those, so one broker update walked
-- GetSpecializationInfo three times over to answer a question whose answer had
-- not changed since login. That is the same "compute what the caller actually
-- needs" mistake SocialStatus made with its friend list.
local specCache, specByID = {}, {}

local function BuildSpecCache()
    wipe(specCache)
    wipe(specByID)
    local count = GetNumSpecializations and GetNumSpecializations() or 0
    for i = 1, count do
        local id, name, _, icon = GetSpecializationInfo(i)
        if id and name then
            local spec = { index = i, id = id, name = name, icon = icon }
            specCache[i] = spec
            specByID[id] = spec
        end
    end
end

local function GetSpecs()
    if #specCache == 0 then BuildSpecCache() end
    return specCache
end

-- Indexed straight into the cache rather than searched: GetSpecialization()
-- returns the INDEX, which is exactly the cache's key.
local function CurrentSpec()
    GetSpecs()
    local index = GetSpecialization and GetSpecialization()
    return index and specCache[index] or nil
end

-- 0 means "whatever the active spec is", which is Blizzard's own default and
-- is a real choice rather than an absence -- so it is reported as such.
local function LootSpecID()
    return (GetLootSpecialization and GetLootSpecialization()) or 0
end

local function SpecByID(id)
    if not id or id == 0 then return nil end
    GetSpecs()
    return specByID[id]
end

-- ---------------------------------------------------------------------------
-- Switching
-- ---------------------------------------------------------------------------

-- Forward-declared, not stubbed: a placeholder body would be assigned and then
-- overwritten before ever running, which is dead code the linter is right to
-- flag. Defined below, with the rest of the broker.
local UpdateBroker

local function Warn(message)
    UIErrorsFrame:AddMessage("AniMods: " .. message, 1, 0.3, 0.3, 1)
end

local function SwitchSpec(spec)
    if not spec then return end
    -- Already there: SetSpecialization on the active spec would start a cast
    -- to arrive where you are.
    local current = CurrentSpec()
    if current and current.id == spec.id then return end

    -- Changing spec is not combat-legal. Checked rather than attempted: the
    -- API failing in lockdown produces nothing visible, so the click would
    -- appear to do nothing at all.
    if InCombatLockdown() then
        Warn("can't change spec in combat")
        return
    end
    -- Both suppressions are for the API metadata, not for a real problem:
    -- neither the LuaLS annotations nor the generated globals list declares
    -- SetSpecialization on C_SpecializationInfo, but it is the current call and
    -- four addons in this folder use it -- EllesmereUIDataBars_Blocks.lua:3700,
    -- EllesmereUIQuickdraw.lua:1792, NDui/Modules/Infobar/Spec.lua:12,
    -- OPie/Meta/SpecSet.lua:21. The bare global SetSpecialization is the
    -- pre-11.0 form and is what the lists still know about.
    --
    -- Suppressed at this exact line in both checkers rather than by adding the
    -- field to the config, which would silence it everywhere.
    -- luacheck: push ignore 143
    ---@diagnostic disable-next-line: undefined-field
    C_SpecializationInfo.SetSpecialization(spec.index)
    -- luacheck: pop
    -- No UpdateBroker() here: the change is asynchronous (it is a cast), and
    -- PLAYER_SPECIALIZATION_CHANGED is what reports it actually happening.
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

-- Left-click picks a spec, right-click picks a loot spec, exactly as
-- EllesmereUIDataBars' own spec block does it (its ToggleSpecPopup /
-- ToggleLootSpecPopup).
--
-- This CYCLED at first, which was wrong. With four specs, reaching a known
-- destination took up to three clicks and three intermediate spec changes --
-- and a spec change is a cast with a global cooldown, so the intermediates are
-- not free the way cycling a sound device is. It also forced a whole settings
-- section into existence ("specs in the cycle") whose only purpose was to make
-- cycling less bad. A menu names the destination and goes there.
--
-- Cycling suits SoundSwitch because switching outputs is instant, reversible,
-- and you are usually alternating between two. None of that holds here.
-- The hint footer, the same four rows EllesmereUIDataBars' spec popup carries.
-- In the popup rather than the hover tooltip, because that is where EUI puts
-- them and matching its feel is the point -- and a footer inside the menu is
-- read at the moment you are choosing, which is when a modifier hint is
-- actually useful.
local CLICK_HINTS = {
    { "Left-click",  "Change spec" },
    { "Right-click", "Change loot spec" },
}

local function ShowSpecMenu(anchor)
    local specs = GetSpecs()
    if #specs == 0 then
        Warn("no specializations available yet")
        return
    end

    local current = CurrentSpec()
    local entries = {}
    for _, spec in ipairs(specs) do
        entries[#entries + 1] = {
            text = spec.name,
            icon = spec.icon,
            active = current and current.id == spec.id or false,
            onClick = function() SwitchSpec(spec) end,
        }
    end
    entries[#entries + 1] = {
        text = "AniMods settings",
        onClick = function()
            if AniMods.OpenModuleTab then AniMods.OpenModuleTab("SpecSwitch") end
        end,
    }
    -- `key` distinguishes this widget's three menus, so right-clicking while
    -- this one is open switches straight to the loot menu instead of just
    -- closing this one.
    AniMods.W.Menu(anchor, entries, {
        key = "spec",
        title = "Change Spec",
        footer = CLICK_HINTS,
    })
end

-- ---------------------------------------------------------------------------
-- Loadouts
-- ---------------------------------------------------------------------------
-- The applied loadout's NAME, for display. Reading it is all this module does
-- with loadouts.
--
--   C_ClassTalents.GetLastSelectedSavedConfigID(specID) -- which one is applied
--   C_Traits.GetConfigInfo(configID)                    -- its name
--
-- Switching loadouts lived here too, on Ctrl+left-click, mirroring
-- EllesmereUIDataBars' spec block. It went because a modifier-click on a data
-- bar widget is a poor place to put an action: nothing on the bar advertises
-- it, so it is undiscoverable to anyone who has not read the tooltip, and it is
-- reachable by accident by anyone holding Ctrl for another reason. Shift+click
-- for the talent frame went with it, for the same reason and with less excuse
-- -- the talent frame already has a keybind.
--
-- Left and right click, spec and loot spec, is the whole surface now. Both are
-- things this widget exists to show, so clicking the thing you are looking at
-- to change it needs no explanation.
--
-- Reading the name is kept, because that is display rather than action, and it
-- costs one hook rather than a menu (see Enable).
local function LoadoutsAvailable()
    return (C_ClassTalents and C_ClassTalents.GetLastSelectedSavedConfigID
        and C_Traits and C_Traits.GetConfigInfo) and true or false
end

-- Reads the one name directly. It runs on every broker update, so building a
-- list of every saved loadout to take one field off one of them -- which is
-- what the removed menu needed -- would be the shape of waste the performance
-- audit went looking for.
local function ActiveLoadoutName()
    if not LoadoutsAvailable() then return nil end
    local spec = CurrentSpec()
    if not spec then return nil end
    local configID = C_ClassTalents.GetLastSelectedSavedConfigID(spec.id)
    if not configID then return nil end
    local info = C_Traits.GetConfigInfo(configID)
    return info and info.name or nil
end

local function ShowLootMenu(anchor)
    local specs = GetSpecs()
    if #specs == 0 then
        Warn("no specializations available yet")
        return
    end

    local lootID = LootSpecID()
    -- "Follow current spec" leads, as it does in EUI's own loot menu: it is
    -- Blizzard's default and the state people want back after borrowing a loot
    -- spec for one boss.
    local current = CurrentSpec()
    local entries = {
        {
            text = "Follow current spec",
            -- The active spec's own icon, as EUI's loot menu does: the row
            -- means "whatever I am playing", so showing that spec's art says
            -- what it currently resolves to.
            icon = current and current.icon or nil,
            active = (lootID == 0),
            onClick = function() SetLootSpecialization(0) end,
        },
    }
    for _, spec in ipairs(specs) do
        entries[#entries + 1] = {
            text = spec.name,
            icon = spec.icon,
            active = (lootID == spec.id),
            onClick = function() SetLootSpecialization(spec.id) end,
        }
    end
    AniMods.W.Menu(anchor, entries, { key = "loot", title = "Change Loot Spec" })
end

-- ---------------------------------------------------------------------------
-- Broker
-- ---------------------------------------------------------------------------

-- Text is the spec you PLAY; the icon beside it is the spec you LOOT.
--
-- NDui's own spec infobar does exactly this (Modules/Infobar/Spec.lua: the
-- displayed string is the spec name followed by GetLootSpecialization's icon,
-- falling back to the current spec's icon when loot follows it), and it is a
-- better answer than anything with labels in it:
--
--   * The two roles are told apart by MEDIUM -- one is text, one is art -- so
--     no "S:" / "L:" wording is needed in any language.
--   * Width is constant. The loot icon is always present, so the widget does
--     not grow and shove its neighbours along the bar the moment you pin a
--     loot spec, which a second text part would.
--   * The common case reads as decoration and the odd case reads as odd:
--     while loot follows your spec the icon simply matches the name, and the
--     moment it does not you have a visibly different icon sitting next to it.
--     That is the exact state worth noticing -- the one that silently gives you
--     the wrong loot.
--
-- Text Only mode drops the icon and so drops the loot spec entirely. That is
-- the right degradation: it loses information rather than becoming ambiguous,
-- which is what a scheme carrying the distinction in art alone would do if the
-- text were "Frost/Fire". The tooltip states it in full either way.
local classColor

UpdateBroker = function()
    if not ldbObject then return end

    local spec = CurrentSpec()
    if not spec then
        Broker.SetText(ldbObject, "")
        return
    end

    -- Loot spec, or the active spec when loot follows it -- so there is always
    -- exactly one icon.
    local loot = SpecByID(LootSpecID()) or spec

    local parts = {}

    -- Loadout first, because it is the narrower thing: "Raid" qualifies
    -- "Frost", not the other way round, and reading left to right it goes from
    -- the specific setup to the spec it belongs to. Optional, and absent
    -- entirely when this character has saved none.
    if ShowLoadout() then
        local loadout = ActiveLoadoutName()
        if loadout then
            parts[#parts + 1] = { text = loadout }
        end
    end

    parts[#parts + 1] = {
        text = spec.name,
        texture = loot.icon,
        iconAfter = true,
        color = classColor,
    }

    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, parts))
end

local function ShowTooltip(tt)
    local specs = GetSpecs()
    local current = CurrentSpec()
    local lootID = LootSpecID()

    tt:AddLine("Specialization", 1, 0.82, 0)

    if #specs == 0 then
        tt:AddLine("No specializations available yet", 0.6, 0.6, 0.6)
        return
    end

    for _, spec in ipairs(specs) do
        local isCurrent = current and spec.id == current.id
        local r, g, b = 1, 1, 1
        if isCurrent then r, g, b = 0.35, 1, 0.35 end
        tt:AddLine((isCurrent and "> " or "   ") .. spec.name, r, g, b)
    end

    tt:AddLine(" ")
    local loot = SpecByID(lootID)
    tt:AddDoubleLine("Loot spec", loot and loot.name or "Follows current spec",
        0.8, 0.8, 0.8, 1, 0.82, 0)

    -- Read at hover, never stored -- see the note on ActiveLoadoutName. Shown
    -- here regardless of the bar setting: hiding it on the bar is about width,
    -- and the tooltip has none of that pressure.
    local loadout = ActiveLoadoutName()
    if loadout then
        tt:AddDoubleLine("Loadout", loadout, 0.8, 0.8, 0.8, 1, 1, 1)
    end

    -- No click hints here: they live in the spec popup's footer, where EUI puts
    -- them. Carrying them in both would be two renderings of one fact, and the
    -- footer is the one read at the moment you are choosing.
end

local function ShowPopup(anchor)
    popup = popup or AniMods.W.Tooltip()
    popup:Clear()
    ShowTooltip(popup)
    popup:Show(anchor)
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsSpecSwitch", {
        label = "AniMods: Spec Switch",
        -- EllesmereUIDataBars' own split: left for spec, right for loot spec.
        -- Settings move into the spec menu rather than claiming right-click, so
        -- the two menus keep the layout anyone who has used EUI's block already
        -- knows.
        --
        -- `frame` is the button the data bar drew for this widget, and it is
        -- what the menu anchors to.
        -- Left for spec, right for loot spec, and nothing else. No modifier
        -- variants: on a data bar widget nothing advertises them, so they are
        -- undiscoverable to anyone who has not read the tooltip and reachable
        -- by accident by anyone holding a modifier for another reason.
        OnClick = function(frame, button)
            if button == "LeftButton" then
                ShowSpecMenu(frame)
            else
                ShowLootMenu(frame)
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
-- Status panel
-- ---------------------------------------------------------------------------

local LOOT_FOLLOW = "follow"

function SpecSwitch:GetInfoRows()
    local rows = {}
    local specs = GetSpecs()
    local current = CurrentSpec()

    rows[#rows + 1] = { section = "Status" }
    if #specs == 0 then
        rows[#rows + 1] = {
            label = "Specializations available",
            state = false,
            help  = "This character has no specializations yet.",
        }
        return rows
    end

    rows[#rows + 1] = { label = "Current spec", value = current and current.name or "None" }

    local loot = SpecByID(LootSpecID())
    rows[#rows + 1] = {
        label = "Loot spec follows current",
        state = (loot == nil),
        help  = loot and ("Loot is set to " .. loot.name .. " regardless of the "
             .. "spec you are playing.") or nil,
    }

    -- The loot spec as a real control, not just a readout: it is the half of
    -- this module that cannot be cycled safely by muscle memory alone.
    local lootLabels, lootOrder = { [LOOT_FOLLOW] = "Follow current spec" }, { LOOT_FOLLOW }
    for _, spec in ipairs(specs) do
        lootLabels[spec.id] = spec.name
        lootOrder[#lootOrder + 1] = spec.id
    end
    rows[#rows + 1] = {
        label   = "Loot spec",
        options = lootLabels,
        order   = lootOrder,
        get     = function()
            local id = LootSpecID()
            return (id == 0) and LOOT_FOLLOW or id
        end,
        set     = function(v)
            SetLootSpecialization(v == LOOT_FOLLOW and 0 or v)
        end,
    }

    rows[#rows + 1] = { section = "Display" }
    rows[#rows + 1] = {
        label = "Show talent loadout",
        help  = "Puts the applied loadout's name before the spec on the bar. "
             .. "The tooltip shows it either way.",
        get   = ShowLoadout,
        set   = function(v)
            ModuleDB().showLoadout = v and true or false
            UpdateBroker()
        end,
    }

    -- No "specs in the cycle" section: there is no cycle. It existed only to
    -- make cycling tolerable, and the menus made both unnecessary.

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsSpecSwitch")) do
        rows[#rows + 1] = row
    end

    return rows
end

function SpecSwitch:Enable()
    -- Resolved once: a character's class cannot change, and this is only read
    -- when the Colored text setting is on. NDui tints the spec name the class
    -- colour and it is the obvious colour for the name of a spec.
    local _, classToken = UnitClass("player")
    local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c then
        classColor = ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
    end

    InitLDB()
    UpdateBroker()

    -- Loadout-name freshness, and the reason this module previously refused to
    -- display the name at all.
    --
    -- Blizzard writes the "last selected loadout" pointer AFTER the
    -- talent-commit events fire, so TRAIT_CONFIG_UPDATED and SPELLS_CHANGED
    -- both race it and read the name that was current a moment ago. Listening
    -- to them would produce a display that is reliably one swap behind.
    --
    -- So hook the WRITE instead: every path that changes which loadout is
    -- current -- Blizzard's talent UI and any loadout addon -- funnels through
    -- UpdateLastSelectedSavedConfigID. EllesmereUIDataBars reaches the same
    -- conclusion for the same display (its HookLoadoutPointer).
    --
    -- This module no longer changes loadouts itself, which makes the hook the
    -- ONLY way it learns of a swap: there is no local action to update from.
    --
    -- Unlike EUI's, this handler needs no combat guard and no
    -- PLAYER_REGEN_ENABLED catch-up: theirs re-measures and re-anchors frames,
    -- which is protected, while all this does is assign a string to an LDB
    -- object and repaint a panel that is ours.
    if C_ClassTalents and C_ClassTalents.UpdateLastSelectedSavedConfigID then
        hooksecurefunc(C_ClassTalents, "UpdateLastSelectedSavedConfigID", function()
            UpdateBroker()
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)
    end

    -- Single notifications rather than per-item bursts, so there is nothing to
    -- coalesce; and none fires while nothing is happening, so there is nothing
    -- periodic here either.
    --
    -- The same three EllesmereUIDataBars' spec block listens to, minus the ones
    -- that exist for its loadout NAME (TRAIT_CONFIG_UPDATED, SPELLS_CHANGED,
    -- CONFIG_COMMIT_FAILED) -- that display races Blizzard's last-selected
    -- pointer, and this shows no loadout, so it inherits neither the problem nor
    -- the events.
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("PLAYER_LOOT_SPEC_UPDATED")
    eventFrame:SetScript("OnEvent", function(_, event)
        -- The spec LIST changes when a character learns one, which arrives as a
        -- specialization change. Rebuilt rather than merely re-read, or a
        -- newly learned spec would stay missing from the cycle until reload.
        if event ~= "PLAYER_LOOT_SPEC_UPDATED" then BuildSpecCache() end
        UpdateBroker()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)
end

AniMods.RegisterModule("SpecSwitch", SpecSwitch)
