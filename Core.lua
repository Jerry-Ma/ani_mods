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

    if condition.check and not condition.check() then
        return false, "condition not met"
    end

    return true
end
AniMods.EvaluateCondition = EvaluateCondition

-- ── Module lifecycle ──────────────────────────────────────────────────────────

local function InitModules()
    for name, module in pairs(modules) do
        local conditionMet, reason = EvaluateCondition(module.condition)

        local userEnabled = db.modules[name]
        if userEnabled == nil then
            userEnabled = true -- default: on
            db.modules[name] = true
        end

        local active = false
        local errorTrace
        if conditionMet and userEnabled and module.Enable then
            -- xpcall (not pcall) so the message handler runs while the stack
            -- is still live: that's what makes debug.traceback() useful here,
            -- rather than just the "file:line: message" a caught pcall error
            -- gives you after the stack has already unwound.
            local ok, err = xpcall(module.Enable, debug.traceback, module)
            if ok then
                active = true
            else
                reason = "error in Enable() — see 'Copy Error' below for the full trace"
                errorTrace = err
            end
        end

        status[name] = {
            module          = module, -- reference for any future per-module UI needs
            title           = module.title or name,
            description     = module.description,
            conditionMet    = conditionMet,
            conditionReason = reason,
            errorTrace      = errorTrace,
            userEnabled     = userEnabled,
            active          = active,
        }
    end

    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

-- Used by the UI panel and by the enable/disable slash commands.
function AniMods.SetModuleEnabled(name, enabled)
    if not modules[name] then return end
    enabled = enabled and true or false
    db.modules[name] = enabled
    if status[name] then
        status[name].userEnabled = enabled
    end
    if AniMods.RefreshUI then AniMods.RefreshUI() end
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

_G.SLASH_ANIMODS1 = "/animods"
_G.SLASH_ANIMODS2 = "/ani"
_G.SlashCmdList["ANIMODS"] = function(msg)
    msg = strtrim((msg or ""):lower())
    local cmd, name = msg:match("^(%S*)%s*(.-)$")

    if cmd == "" then
        if AniMods.ToggleUI then AniMods.ToggleUI() end

    elseif cmd == "list" then
        print("|cffffff00AniMods|r modules:")
        for moduleName, entry in pairs(status) do
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
        if not modules[name] then
            print("|cffff4444AniMods:|r Unknown module: " .. tostring(name))
            return
        end
        AniMods.SetModuleEnabled(name, cmd == "enable")
        print(("|cffffff00AniMods:|r %s %s. |cff888888/reload|r to apply.")
            :format(name, cmd == "enable" and "enabled" or "disabled"))

    else
        print("|cffffff00AniMods|r commands: |cffffd700/animods|r (status panel), |cffffd700list|r, |cffffd700enable <name>|r, |cffffd700disable <name>|r")
    end
end
