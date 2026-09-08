-- AniMods
-- Personal grab-bag of small UI patches / QoL tweaks, cherry-picked from other
-- addons or written from scratch. Each patch lives in its own file under
-- Modules\ and registers itself with AniMods.RegisterModule(name, module).
--
-- A module is a table:
--   {
--     title       = "Display Name",              -- optional, defaults to name
--     description = "What this patch does.",      -- optional, shown in the UI
--     condition   = { requires = {...}, forbids = {...}, check = function() end },
--     Enable      = function(self) ... end,        -- called once if condition + user enabled
--   }
--
-- `condition` decides whether the patch is even applicable right now (e.g. "only
-- when NDui is NOT loaded" for a feature NDui already provides itself). It is
-- evaluated at PLAYER_LOGIN, once every addon that is going to load this session
-- has loaded, so IsAddOnLoaded() checks on other addons are reliable regardless
-- of load order.
--
--   requires = { "AddOnA", { name = "AddOnB", minVersion = "1.2.0" } }
--   forbids  = { "AddOnC" }
--   check    = function() return true end  -- arbitrary extra predicate, ANDed in
--
-- Most WoW UI hooks (hooksecurefunc, etc.) can't be cleanly undone at runtime, so
-- there is no Disable() contract — toggling a module off in the UI just skips its
-- Enable() next login/reload.

local ADDON_NAME = "AniMods"

AniMods = AniMods or {}
local AniMods = AniMods

local modules = {}   -- name -> module table, as registered
local status  = {}   -- name -> { title, description, conditionMet, conditionReason, userEnabled, active }
AniMods.status = status

local db

function AniMods.RegisterModule(name, module)
    modules[name] = module
end

-- WoW's addon sandbox does not expose the `debug` table at all (confirmed:
-- indexing it is a nil-value error here), only specific whitelisted globals
-- like debugstack(). This combines the original error message with the call
-- stack from where it was thrown -- debugstack() only sees the stack, not the
-- message, so xpcall's message handler has to glue both together itself.
local function ErrorHandler(err)
    return tostring(err) .. "\n" .. (debugstack(2) or "")
end

-- ── AddOn / version helpers ───────────────────────────────────────────────────

local function IsAddOnLoaded(name)
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
        return _G.C_AddOns.IsAddOnLoaded(name) and true or false
    end
    return _G.IsAddOnLoaded(name) and true or false
end
AniMods.IsAddOnLoaded = IsAddOnLoaded

local function GetAddOnVersion(name)
    local getMeta = (_G.C_AddOns and _G.C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    return getMeta and getMeta(name, "Version") or nil
end
AniMods.GetAddOnVersion = GetAddOnVersion

-- Compares dot/number-separated version strings component-by-component,
-- numerically. Good enough for typical "1.2.3" / "12.1.0"-style addon versions.
-- Returns -1, 0, or 1. A missing version sorts lowest.
local function CompareVersions(a, b)
    if a == b then return 0 end
    if not a then return -1 end
    if not b then return 1 end
    local ia, ib = a:gmatch("%d+"), b:gmatch("%d+")
    while true do
        local na, nb = ia(), ib()
        if not na and not nb then return 0 end
        na, nb = tonumber(na) or 0, tonumber(nb) or 0
        if na ~= nb then return (na < nb) and -1 or 1 end
    end
end
AniMods.CompareVersions = CompareVersions

-- ── Event coalescing ──────────────────────────────────────────────────────────

-- Wraps `fn` so that a burst of calls collapses into a single deferred call on
-- the next frame.
--
-- The problem this solves: several of the events modules care about are not
-- "something changed" notifications but per-item ones, fired once per affected
-- unit/friend/member. BN_FRIEND_INFO_CHANGED fires for every friend whose
-- status, AFK flag or rich-presence text moves -- dozens of times within a
-- second or two at login -- and GROUP_ROSTER_UPDATE fires repeatedly while a
-- raid fills. Recomputing on each one does the same expensive walk N times to
-- reach exactly the state the last one would have produced on its own.
--
-- C_Timer.After(0, ...) runs on the next frame, so the whole burst is answered
-- once, after it has finished, with no added latency a player could see. This
-- is a one-shot per burst, NOT a poll: nothing is scheduled while idle.
function AniMods.Coalesce(fn)
    local scheduled = false
    return function()
        if scheduled then return end
        scheduled = true
        C_Timer.After(0, function()
            scheduled = false
            fn()
        end)
    end
end

-- ── Condition evaluation ──────────────────────────────────────────────────────

local function NormalizeRequirement(req)
    if type(req) == "string" then
        return { name = req }
    end
    return req
end

-- Returns met (bool), reason (string, only set when not met / not applicable).
local function EvaluateCondition(condition)
    if not condition then return true end

    for _, raw in ipairs(condition.requires or {}) do
        local req = NormalizeRequirement(raw)
        if not IsAddOnLoaded(req.name) then
            return false, req.name .. " is not loaded"
        end
        if req.minVersion or req.maxVersion then
            local version = GetAddOnVersion(req.name)
            if req.minVersion and CompareVersions(version, req.minVersion) < 0 then
                return false, ("%s version %s < required %s"):format(req.name, tostring(version), req.minVersion)
            end
            if req.maxVersion and CompareVersions(version, req.maxVersion) > 0 then
                return false, ("%s version %s > max %s"):format(req.name, tostring(version), req.maxVersion)
            end
        end
    end

    for _, raw in ipairs(condition.forbids or {}) do
        local forbid = NormalizeRequirement(raw)
        if IsAddOnLoaded(forbid.name) then
            return false, forbid.name .. " is loaded"
        end
    end

    if condition.check then
        local ok, why = condition.check()
        if not ok then
            return false, why or "condition not met"
        end
    end

    return true
end
AniMods.EvaluateCondition = EvaluateCondition

-- ── Requirements ──────────────────────────────────────────────────────────────

-- A module's `dependencies` are not documentation: an unmet one makes the
-- module inactive.
--
-- Each entry is HARD by default. `soft = true` marks one the module can run
-- without -- an advisory rather than a prerequisite. AniMods' own data bar is
-- the case that motivated this: "you already have a data bar" is worth
-- flagging, but it is the user's call, not a blocker.
--
-- Returns:
--   allMet   every checked requirement is satisfied
--   hardMet  every checked HARD requirement is satisfied
--   firstUnmet  text of the first failure, for the inactive reason
--
-- Entries with no `met` are informational and never fail.
function AniMods.EvaluateDependencies(deps)
    if type(deps) ~= "table" then return true, true, nil end

    local allMet, hardMet, firstUnmet = true, true, nil
    for _, dep in ipairs(deps) do
        if dep.met then
            local ok, result = pcall(dep.met)
            if not (ok and result) then
                allMet = false
                firstUnmet = firstUnmet or dep.text
                if not dep.soft then hardMet = false end
            end
        end
    end
    return allMet, hardMet, firstUnmet
end

-- Whether a module may run given its requirements and the user's override.
-- Forcing can only ever get past SOFT failures -- a missing hard requirement
-- means the module genuinely cannot work, so the override stays unavailable
-- rather than letting it fail loudly.
local function RequirementsSatisfied(module, deps, forced)
    local allMet, hardMet = AniMods.EvaluateDependencies(deps)
    if allMet then return true end
    if forced and module.forceable and hardMet then return true end
    return false
end

-- ── Module lifecycle ──────────────────────────────────────────────────────────

local function InitModules()
    -- Sorted, not pairs(): module Enable() order should be deterministic.
    -- Nothing here depends on another module today, but if that ever changes
    -- (or two modules ever touch the same Blizzard frame), a hash-order init
    -- would make the resulting bug intermittent and near-impossible to
    -- reproduce.
    local names = {}
    for name in pairs(modules) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local module = modules[name]
        local conditionMet, reason = EvaluateCondition(module.condition)

        local userEnabled
        if module.essential then
            -- Not switchable, and not stored: a saved `false` from before a
            -- module became essential must not keep it off.
            userEnabled = true
        else
            userEnabled = db.modules[name]
            if userEnabled == nil then
                userEnabled = true -- default: on
                db.modules[name] = true
            end
        end

        db.forced = db.forced or {}
        local forced = db.forced[name] == true

        -- Requirements gate activation alongside `condition`. The two answer
        -- different questions: `condition` is "does this patch apply to this
        -- install at all", requirements are "is what it needs present".
        local depsAllMet, depsHardMet, firstUnmet = AniMods.EvaluateDependencies(module.dependencies)
        local reqOK = RequirementsSatisfied(module, module.dependencies, forced)
        if conditionMet and not reqOK then
            reason = firstUnmet and ("requires: " .. firstUnmet) or "a requirement is not met"
        end

        local runnable = conditionMet and reqOK

        local active = false
        local ranEnable = false
        local errorTrace
        if runnable and userEnabled and not module.Enable then
            -- A module with nothing to run at login (registration alone is
            -- its whole job) is active, not failed -- without this it would
            -- fall through to the UI's "Failed" state with no error to show.
            active = true
        elseif runnable and userEnabled then
            -- xpcall (not pcall) so ErrorHandler runs while the stack is
            -- still live: that's what makes debugstack() useful here, rather
            -- than just the "file:line: message" a caught pcall error gives
            -- you after the stack has already unwound.
            local ok, err = xpcall(module.Enable, ErrorHandler, module)
            if ok then
                active = true
                -- Records that this module actually started this session,
                -- which is what makes a later live toggle meaningful --
                -- SetEnabled resumes something running, it cannot start
                -- something that never ran.
                ranEnable = true
            else
                errorTrace = err
                -- ErrorHandler joins "<message>\n<stack>" - the part before
                -- the first newline is the original brief message, good
                -- enough for the inline reason; the full thing is one click
                -- away via the Show Error button.
                local briefMsg = tostring(err):match("^[^\n]*") or tostring(err)
                reason = "error in Enable(): " .. briefMsg
            end
        end

        status[name] = {
            module          = module, -- reference for any future per-module UI needs
            title           = module.title or name,
            -- Sidebar sort key. Everything defaults to 100 and therefore
            -- sorts by title; only General claims a lower number, so the
            -- addon's own settings sit above the patches rather than
            -- alphabetically among them.
            order           = module.order or 100,
            essential       = module.essential == true,
            description     = module.description,
            dependencies    = module.dependencies, -- always-visible "Depends on" checklist ({ text, met } entries), distinct from conditionReason (which only shows on failure)
            conditionMet    = conditionMet,
            conditionReason = reason,
            errorTrace      = errorTrace,
            userEnabled     = userEnabled,
            active          = active,
            ranEnable       = ranEnable,
            -- Requirement state, read by the panel's header: whether the
            -- force-active override should be offered at all (forceable),
            -- whether it would help (depsHardMet), and where it stands.
            forceable       = module.forceable == true,
            forced          = forced,
            depsAllMet      = depsAllMet,
            depsHardMet     = depsHardMet,
            -- Whether the on/off switch takes effect immediately. Read by the
            -- panel to decide whether to offer a reload.
            liveToggle      = (not module.Enable) or (ranEnable and module.SetEnabled ~= nil),
        }
    end

    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

-- Used by the UI panel and by the enable/disable slash commands.
--
-- Returns true when the change took effect immediately, false when it is
-- saved but needs a reload. The caller uses that to decide whether to offer
-- one -- prompting for every toggle trains people to dismiss the prompt, so
-- it has to be accurate.
--
-- A module can be toggled live only if it says so, by defining
-- SetEnabled(self, on). That is a capability declaration rather than a flag
-- to keep in sync: a module that can genuinely stop has to implement the
-- stopping somewhere, and this is that somewhere.
--
-- Most cannot, and the reason is structural rather than laziness --
-- hooksecurefunc has no inverse in the WoW API, and a LibDataBroker object,
-- once registered, cannot be withdrawn. Modules built out of those two things
-- are only fully switchable at load.
--
-- Turning a module ON also needs a reload when its Enable() never ran this
-- session: SetEnabled resumes a module that started, it cannot retroactively
-- start one that did not.
function AniMods.SetModuleEnabled(name, enabled)
    local module = modules[name]
    if not module then return false end

    enabled = enabled and true or false
    db.modules[name] = enabled

    local entry = status[name]
    if entry then entry.userEnabled = enabled end

    local applied = false
    if not module.Enable then
        -- Nothing ever ran, so there is nothing to start or stop.
        applied = true
    elseif entry and entry.ranEnable and module.SetEnabled then
        local ok, err = pcall(module.SetEnabled, module, enabled)
        if ok then
            applied = true
            entry.active = enabled and entry.conditionMet and true or false
        elseif err then
            geterrorhandler()(err)
        end
    end

    if AniMods.RefreshUI then AniMods.RefreshUI() end
    return applied
end

-- ── Saved-variable migrations ─────────────────────────────────────────────────

-- Renaming a module changes two keys the saved variables are indexed by: its
-- entry in db.modules (the enabled flag) and its own settings sub-table. Both
-- are moved here rather than left to default, so a rename never silently
-- resets someone's configuration.
--
-- Each migration only ever runs when the old key is present and the new one
-- is not, so it is a no-op on every login after the first, and safe if a
-- module is later renamed again.
local MODULE_RENAMES = {
    -- oldModuleName -> { newModuleName, oldDBKey, newDBKey }
    RaidComposition = { "GroupRoles", "raidComposition", "groupRoles" },
}

local function MigrateRenames()
    for oldName, spec in pairs(MODULE_RENAMES) do
        local newName, oldKey, newKey = spec[1], spec[2], spec[3]

        if db.modules[oldName] ~= nil then
            if db.modules[newName] == nil then
                db.modules[newName] = db.modules[oldName]
            end
            db.modules[oldName] = nil
        end

        if db[oldKey] ~= nil then
            if db[newKey] == nil then
                db[newKey] = db[oldKey]
            end
            db[oldKey] = nil
        end
    end
end

-- Runs a module despite unmet SOFT requirements. Saved but not applied until
-- reload, for the same reason enabling is: Enable() already ran or did not.
function AniMods.SetModuleForced(name, forced)
    if not modules[name] then return false end
    db.forced = db.forced or {}
    db.forced[name] = forced and true or false
    if status[name] then status[name].forced = forced and true or false end
    if AniMods.RefreshUI then AniMods.RefreshUI() end
    return false
end

-- ── Events ─────────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        AniModsDB = AniModsDB or {}
        AniModsDB.modules = AniModsDB.modules or {}
        db = AniModsDB
        MigrateRenames()
        eventFrame:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        -- Every addon that will load this session has loaded by now, so
        -- IsAddOnLoaded() checks against other addons are reliable here
        -- regardless of alphabetical/dependency load order.
        InitModules()
        eventFrame:UnregisterEvent("PLAYER_LOGIN")
    end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────

-- Module names are registered CamelCase ("GroupRoles"), but nobody
-- wants to have to type them that way -- resolve case-insensitively, and
-- return the real registered name so messages echo it back properly.
local function ResolveModuleName(input)
    if input == "" then return nil end
    if modules[input] then return input end
    local wanted = input:lower()
    for moduleName in pairs(modules) do
        if moduleName:lower() == wanted then return moduleName end
    end
    return nil
end

_G.SLASH_ANIMODS1 = "/animods"
_G.SLASH_ANIMODS2 = "/ani"
_G.SlashCmdList["ANIMODS"] = function(msg)
    -- Only the command word is lowercased -- lowercasing the whole message
    -- (as this used to) also mangled the module name, so `/ani enable
    -- GroupRoles` looked up "grouproles" and always reported
    -- "Unknown module".
    local cmd, name = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    name = strtrim(name or "")

    if cmd == "" then
        if AniMods.ToggleUI then AniMods.ToggleUI() end

    elseif cmd == "list" then
        print("|cffffff00AniMods|r modules:")
        local names = {}
        for moduleName in pairs(status) do names[#names + 1] = moduleName end
        table.sort(names)
        for _, moduleName in ipairs(names) do
            local entry = status[moduleName]
            local state
            if entry.active then
                state = "|cff44ff44active|r"
            elseif not entry.userEnabled then
                state = "|cff888888disabled|r"
            else
                state = "|cffff4444inactive|r"
            end
            local suffix = entry.conditionReason and (" (" .. entry.conditionReason .. ")") or ""
            print(("  %s: %s%s"):format(moduleName, state, suffix))
        end

    elseif cmd == "enable" or cmd == "disable" then
        local resolved = ResolveModuleName(name)
        if not resolved then
            print("|cffff4444AniMods:|r Unknown module: " .. tostring(name))
            return
        end
        AniMods.SetModuleEnabled(resolved, cmd == "enable")
        print(("|cffffff00AniMods:|r %s %s. |cff888888/reload|r to apply.")
            :format(resolved, cmd == "enable" and "enabled" or "disabled"))

    else
        print("|cffffff00AniMods|r commands: |cffffd700/animods|r (status panel), |cffffd700list|r, |cffffd700enable <name>|r, |cffffd700disable <name>|r")
    end
end

-- ── Addon compartment ─────────────────────────────────────────────────────────

-- The minimap's addon-compartment dropdown, wired via ## AddonCompartmentFunc
-- (plus the OnEnter/OnLeave variants) in the .toc. The entry's icon is the
-- ## IconTexture we already ship, so this is what makes that icon reachable
-- rather than only visible in the AddOns list.
--
-- Contract, read off Blizzard's own AddonCompartment.lua rather than guessed:
--   _G[func](addonName, buttonName)   -- click
--   _G[func](addonName, menuButton)   -- OnEnter / OnLeave
--
-- Blizzard calls forceinsecure() before invoking these, deliberately: "Must
-- taint otherwise addons would be able to arbitrarily run global functions
-- untainted." So NOTHING PROTECTED MAY BE CALLED FROM HERE. Showing our own
-- non-secure panel is fine; anything touching secure frames or protected
-- actions would fail, and would fail only for players who opened it this way,
-- which is exactly the kind of bug that never reproduces.
--
-- Defined through _G rather than as bare globals, matching the SLASH_ pattern
-- above -- the assignment is then a table field rather than a new global,
-- which is what the linter wants to see.

-- Honours the General module's "Addon compartment entry" setting. Blizzard
-- builds the compartment list from .toc metadata at startup and gives addons
-- no way to withdraw an entry, so the entry always exists -- switching it off
-- makes it inert and says so, which is the closest thing available.
local function CompartmentEnabled()
    local g = AniModsDB and AniModsDB.general
    return not (g and g.compartment == false)
end

_G.AniMods_OnAddonCompartmentClick = function()
    if not CompartmentEnabled() then
        print("|cffffff00AniMods:|r compartment entry is switched off in General. Use |cffffd700/animods|r.")
        return
    end
    if AniMods.ToggleUI then AniMods.ToggleUI() end
end

_G.AniMods_OnAddonCompartmentEnter = function(_, menuButton)
    if not menuButton then return end

    local active, total = 0, 0
    for _, entry in pairs(status) do
        total = total + 1
        if entry.active then active = active + 1 end
    end

    GameTooltip:SetOwner(menuButton, "ANCHOR_LEFT")
    GameTooltip:AddLine("AniMods", 1, 0.82, 0)
    -- The same count the panel's tab dots convey, so the compartment answers
    -- "is everything up?" without opening anything.
    GameTooltip:AddLine(("%d of %d modules active"):format(active, total), 0.8, 0.8, 0.8)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open the panel", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

_G.AniMods_OnAddonCompartmentLeave = function()
    GameTooltip:Hide()
end
