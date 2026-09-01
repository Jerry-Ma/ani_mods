-- AniMods
-- Personal grab-bag of small UI patches / QoL tweaks, cherry-picked from other
-- addons or written from scratch. Each feature lives in its own file under
-- Modules\ and registers itself with AniMods.RegisterModule(name, module).
--
-- A module is a table with an Enable() method. Enable is called once, after
-- SavedVariables are loaded, if the module is not disabled in the DB. Most
-- WoW UI hooks (hooksecurefunc, etc.) can't be cleanly undone at runtime, so
-- there is no Disable() contract — toggling a module off just skips Enable()
-- next login/reload.

local ADDON_NAME = "AniMods"

AniMods = AniMods or {}
local AniMods = AniMods

local modules = {}
local db

function AniMods.RegisterModule(name, module)
    modules[name] = module
end

local function InitModules()
    for name, module in pairs(modules) do
        if module.Enable then
            local enabled = db.modules[name]
            if enabled == nil then
                enabled = true -- default: on
                db.modules[name] = enabled
            end
            if enabled then
                module:Enable()
            end
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        AniModsDB = AniModsDB or {}
        AniModsDB.modules = AniModsDB.modules or {}
        db = AniModsDB
        InitModules()
        eventFrame:UnregisterEvent("ADDON_LOADED")
    end
end)

-- ── Slash commands ────────────────────────────────────────────────────────────

_G.SLASH_ANIMODS1 = "/animods"
_G.SlashCmdList["ANIMODS"] = function(msg)
    msg = strtrim((msg or ""):lower())
    local cmd, name = msg:match("^(%S*)%s*(.-)$")

    if cmd == "" or cmd == "list" then
        print("|cffffff00AniMods|r modules:")
        for moduleName in pairs(modules) do
            local enabled = db and db.modules[moduleName]
            print(("  %s: %s"):format(
                moduleName,
                enabled and "|cff44ff44enabled|r" or "|cffff4444disabled|r"))
        end
        print("|cffffff00AniMods|r commands: |cffffd700/animods enable <name>|r, |cffffd700/animods disable <name>|r (reload to apply)")

    elseif cmd == "enable" or cmd == "disable" then
        if not modules[name] then
            print("|cffff4444AniMods:|r Unknown module: " .. tostring(name))
            return
        end
        db.modules[name] = (cmd == "enable")
        print(("|cffffff00AniMods:|r %s %s. |cff888888/reload|r to apply.")
            :format(name, cmd == "enable" and "enabled" or "disabled"))

    else
        print("|cffffff00AniMods|r commands: list, enable <name>, disable <name>")
    end
end
