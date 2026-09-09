-- SpecSwitch
-- Switch talent specialization and loot specialization from a data bar.
--
-- Left-click cycles to the next spec, Shift+left-click cycles the loot spec,
-- right-click opens this module's tab to choose which specs are in the cycle.
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
        { text = "EllesmereUI not installed",
          help = "EllesmereUIDataBars ships a spec block that already does this, "
              .. "with loadout switching too.",
          met = function() return not AniMods.IsAddOnLoaded("EllesmereUI") end },
        { text = "NDui not installed",
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

-- Keyed by spec ID, not index: indices are positional and would silently
-- re-point at a different spec if Blizzard ever reordered them, while the ID
-- is the same number the loot-spec API speaks in.
local function CycleDB()
    local db = ModuleDB()
    db.specs = db.specs or {}
    return db.specs
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

-- Absent means in the cycle: a newly learned spec should participate without
-- having to be found in the options first. Same default as SoundSwitch's
-- devices, and for the same reason.
local function IsInCycle(id)
    local v = CycleDB()[id]
    if v == nil then return true end
    return v
end

local function SetInCycle(id, enabled)
    CycleDB()[id] = enabled and true or false
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

-- Returns the next in-cycle spec after the current one, wrapping; or nil plus
-- a reason.
local function NextSpec()
    local cycle = {}
    for _, spec in ipairs(GetSpecs()) do
        if IsInCycle(spec.id) then cycle[#cycle + 1] = spec end
    end
    if #cycle == 0 then
        return nil, "every spec is excluded from the cycle"
    end
    if #cycle == 1 then
        return nil, "only one spec is in the cycle"
    end

    local current = CurrentSpec()
    local at = 0
    for i, spec in ipairs(cycle) do
        if current and spec.id == current.id then at = i break end
    end
    return cycle[(at % #cycle) + 1]
end

local function Warn(message)
    UIErrorsFrame:AddMessage("AniMods: " .. message, 1, 0.3, 0.3, 1)
end

local function SwitchSpec()
    -- Changing spec is not combat-legal. Checked rather than attempted: the
    -- API failing in lockdown produces nothing visible, so the click would
    -- appear to do nothing at all.
    if InCombatLockdown() then
        Warn("can't change spec in combat")
        return
    end
    local spec, reason = NextSpec()
    if not spec then
        Warn(reason or "no spec to switch to")
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

-- Cycles: follow-current -> each spec in turn -> back to follow-current.
--
-- "Follow current spec" is part of the cycle rather than a separate control,
-- because it is the state most people want back after borrowing a loot spec
-- for one boss, and it would otherwise be reachable only from the panel.
local function SwitchLootSpec()
    local specs = GetSpecs()
    if #specs == 0 then
        Warn("no specializations available yet")
        return
    end

    local currentID = LootSpecID()
    if currentID == 0 then
        SetLootSpecialization(specs[1].id)
        return
    end
    for i, spec in ipairs(specs) do
        if spec.id == currentID then
            local nextSpec = specs[i + 1]
            SetLootSpecialization(nextSpec and nextSpec.id or 0)
            return
        end
    end
    -- Current loot spec is not one of this character's specs (it can be left
    -- over from a spec change): reset to following the active spec.
    SetLootSpecialization(0)
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
        local inCycle = IsInCycle(spec.id)
        local r, g, b
        if isCurrent then
            r, g, b = 0.35, 1, 0.35
        elseif inCycle then
            r, g, b = 1, 1, 1
        else
            r, g, b = 0.5, 0.5, 0.5
        end
        tt:AddDoubleLine((isCurrent and "> " or "   ") .. spec.name,
            inCycle and "" or "skipped", r, g, b, 0.5, 0.5, 0.5)
    end

    tt:AddLine(" ")
    local loot = SpecByID(lootID)
    tt:AddDoubleLine("Loot spec", loot and loot.name or "Follows current spec",
        0.8, 0.8, 0.8, 1, 0.82, 0)

    tt:AddLine(" ")
    tt:AddLine("Left-click: next spec", 0.6, 0.6, 0.6)
    tt:AddLine("Shift-click: next loot spec", 0.6, 0.6, 0.6)
    tt:AddLine("Right-click: settings", 0.6, 0.6, 0.6)
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
        OnClick = function(_, button)
            if button == "LeftButton" then
                if IsShiftKeyDown() then SwitchLootSpec() else SwitchSpec() end
            elseif AniMods.OpenModuleTab then
                AniMods.OpenModuleTab("SpecSwitch")
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

    rows[#rows + 1] = { section = "Specs in the cycle" }
    for _, spec in ipairs(specs) do
        local id = spec.id
        rows[#rows + 1] = {
            label = spec.name,
            get   = function() return IsInCycle(id) end,
            set   = function(v) SetInCycle(id, v) end,
            note  = (current and current.id == id) and "Current" or nil,
        }
    end

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
