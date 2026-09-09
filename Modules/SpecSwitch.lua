-- SpecSwitch
-- Switch talent specialization and loot specialization from a data bar.
--
-- Left-click opens a menu of specs, right-click a menu of loot specs -- the
-- same split EllesmereUIDataBars' spec block uses.
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
    { "Left-click",       "Change spec" },
    { "Ctrl-left-click",  "Change loadout" },
    { "Shift-left-click", "Open talents" },
    { "Right-click",      "Change loot spec" },
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
    AniMods.W.Menu(anchor, entries, {
        title = "Change Spec",
        footer = CLICK_HINTS,
    })
end

-- ---------------------------------------------------------------------------
-- Loadouts
-- ---------------------------------------------------------------------------
-- Talent loadouts for the ACTIVE spec, newest API only.
--
--   C_ClassTalents.GetConfigIDsBySpecID(specID)         -- the saved loadouts
--   C_ClassTalents.GetLastSelectedSavedConfigID(specID) -- which one is applied
--   C_Traits.GetConfigInfo(configID)                    -- its name
--   C_ClassTalents.LoadConfig(configID, true)           -- apply it
--
-- Read live on every open rather than cached, and that is worth stating because
-- it is the whole reason this module does not inherit EllesmereUIDataBars' most
-- delicate piece of machinery. Its block DISPLAYS the loadout name, so it has to
-- know when the name settles -- and Blizzard writes the "last selected" pointer
-- AFTER the talent-commit events fire, so TRAIT_CONFIG_UPDATED reads the old
-- name. EUI solves that by hooking UpdateLastSelectedSavedConfigID itself and
-- listening to four extra events.
--
-- Nothing here displays the name outside a menu or tooltip that is built at the
-- moment it opens, so there is no stale copy to keep fresh: the race has no
-- surface to land on.
local function LoadoutsAvailable()
    return (C_ClassTalents and C_ClassTalents.GetConfigIDsBySpecID
        and C_ClassTalents.GetLastSelectedSavedConfigID
        and C_Traits and C_Traits.GetConfigInfo) and true or false
end

local function GetLoadouts()
    local out = {}
    if not LoadoutsAvailable() then return out end
    local spec = CurrentSpec()
    if not spec then return out end

    local activeID = C_ClassTalents.GetLastSelectedSavedConfigID(spec.id)
    for _, configID in ipairs(C_ClassTalents.GetConfigIDsBySpecID(spec.id) or {}) do
        local info = C_Traits.GetConfigInfo(configID)
        if info and info.name then
            out[#out + 1] = {
                name = info.name,
                configID = configID,
                isActive = (configID == activeID),
            }
        end
    end
    return out
end

local function SwitchLoadout(specID, configID)
    if InCombatLockdown() then
        Warn("can't change loadout in combat")
        return
    end

    -- Blizzard's own sequence, and the branch matters: when the loadout is
    -- already applied talent-wise, LoadConfig reports NoChangesNecessary and
    -- commits nothing -- so the "last selected" pointer has to be moved by hand
    -- or the game keeps thinking the previous loadout is the current one.
    local result = C_ClassTalents.LoadConfig(configID, true)
    if result == Enum.LoadConfigResult.NoChangesNecessary then
        C_ClassTalents.UpdateLastSelectedSavedConfigID(specID, configID)
    end
end

-- PlayerSpellsUtil only. EllesmereUIDataBars keeps the pre-11.0
-- ToggleTalentFrame global as a second branch, which is right for an addon
-- supporting older clients; this one targets current retail, and carrying a
-- branch for a client it never runs on is the kind of debt that never gets
-- removed because nothing ever proves it dead.
local function OpenTalents()
    if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentFrame then
        PlayerSpellsUtil.ToggleClassTalentFrame()
    end
end

local function ShowLoadoutMenu(anchor)
    local spec = CurrentSpec()
    local loadouts = GetLoadouts()
    if not spec or #loadouts == 0 then
        Warn("no saved talent loadouts for this spec")
        return
    end

    -- No icons: loadouts have none, and EUI's own loadout rows sit flush left
    -- for exactly that reason rather than reserving an empty icon column.
    local entries = {}
    for _, loadout in ipairs(loadouts) do
        entries[#entries + 1] = {
            text = loadout.name,
            active = loadout.isActive,
            onClick = function() SwitchLoadout(spec.id, loadout.configID) end,
        }
    end
    AniMods.W.Menu(anchor, entries, { title = "Change Loadout" })
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
    AniMods.W.Menu(anchor, entries, { title = "Change Loot Spec" })
end

-- ---------------------------------------------------------------------------
-- Broker
-- ---------------------------------------------------------------------------

-- The active spec, plus the loot spec only when it differs.
--
-- A second part is added ONLY when the loot spec is pinned to something other
-- than the active spec, because that is the state worth noticing -- it is the
-- one that silently gives you the wrong loot. When loot follows the spec there
-- is nothing to say, and saying it anyway would double the widget's width for
-- no information.
UpdateBroker = function()
    if not ldbObject then return end

    local spec = CurrentSpec()
    if not spec then
        Broker.SetText(ldbObject, "")
        return
    end

    local parts = { { text = spec.name, texture = spec.icon } }
    local loot = SpecByID(LootSpecID())
    if loot and loot.id ~= spec.id then
        parts[#parts + 1] = { text = loot.name, texture = loot.icon, color = "ffd100" }
    end

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

    -- Read at hover, never stored -- see the note on GetLoadouts.
    local activeLoadout
    for _, loadout in ipairs(GetLoadouts()) do
        if loadout.isActive then activeLoadout = loadout.name break end
    end
    if activeLoadout then
        tt:AddDoubleLine("Loadout", activeLoadout, 0.8, 0.8, 0.8, 1, 1, 1)
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
        OnClick = function(frame, button)
            if button == "LeftButton" then
                -- Modifier order matters: Ctrl is checked first because
                -- Ctrl+Shift should reach the loadout menu rather than
                -- whichever branch happened to be tested first.
                if IsControlKeyDown() then
                    ShowLoadoutMenu(frame)
                elseif IsShiftKeyDown() then
                    OpenTalents()
                else
                    ShowSpecMenu(frame)
                end
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

    -- No "specs in the cycle" section: there is no cycle. It existed only to
    -- make cycling tolerable, and the menus made both unnecessary.

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsSpecSwitch")) do
        rows[#rows + 1] = row
    end

    return rows
end

function SpecSwitch:Enable()
    InitLDB()
    UpdateBroker()

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
