-- IconProbe -- a throwaway diagnostic widget.
--
-- Renders the same icon several different ways in the SAME place the real
-- brokers do, because that is the only thing that has actually answered
-- anything here. Two plausible-sounding models of how WoW draws a
-- non-power-of-two texture inline both turned out to be wrong, and each cost a
-- round trip; a screenshot of this settles it.
--
-- The broker text carries the compact row (what the data bar itself shows, i.e.
-- the exact context the bug appears in). The hover popup labels each variant
-- and adds what the client reports about the atlases, which is text and so can
-- be read rather than eyeballed.
--
-- DELETE THIS MODULE once the icon rendering question is settled. It exists to
-- answer one question and has no business outliving the answer.

local IconProbe = {
    title = "Icon Probe (debug)",
    description = "Diagnostic: renders icon escapes side by side. Delete when done.",
    dbKey = "iconProbe",
}

local Broker = AniMods.Broker

local ldbObject
local popup

local function ModuleDB()
    AniModsDB.iconProbe = AniModsDB.iconProbe or {}
    return AniModsDB.iconProbe
end

-- ---------------------------------------------------------------------------
-- Subjects
-- ---------------------------------------------------------------------------

local EUI_CHAT_MEDIA = "Interface\\AddOns\\EllesmereUIChat\\Media\\"

local EUI_MEDIA = "Interface\\AddOns\\EllesmereUI\\media\\micromenu\\"

-- Two families, so the difference is visible rather than argued about.
--
-- chat_* are EllesmereUIChat's sidebar icons: 100x100, thin white LINE work.
-- menu-* are EllesmereUI's own micromenu icons: 128x128 (a power of two) and
-- solid SILHOUETTES -- the same set the EUI data bar draws for its item-level
-- block, and so the look the rest of the bar already has.
local TEXTURES = {
    { label = "chat_guild   (line art)",  path = EUI_CHAT_MEDIA .. "chat_guild.png" },
    { label = "menu-guild   (silhouette)", path = EUI_MEDIA .. "menu-guild.png" },
    { label = "menu-friends (silhouette)", path = EUI_MEDIA .. "menu-friends.png" },
    { label = "menu-group   (silhouette)", path = EUI_MEDIA .. "menu-group.png" },
}

-- Round two. The first pass settled voice and friends -- both have a solid
-- atlas, both are now used -- and killed the rendering theory outright: the
-- PNGs draw fine, they are just thin line work that dies at 14px.
--
-- What is left is GUILD, which has no solid atlas yet. Guessing names one at a
-- time is what the probe exists to avoid, so the whole shortlist goes in at
-- once and the report says which exist.
--
-- Only one of these is confirmed to exist anywhere: the delves guild banner,
-- which !KalielsTracker draws (System/Media.lua). The rest are plausible
-- shapes for how Blizzard names micro-menu and communities art -- appearing in
-- an atlas browser or in someone's addon is NOT evidence an atlas exists in
-- THIS client, which is the mistake the original guild candidate came from.
local ATLASES = {
    -- Settled, kept as controls: these are what the two fixed modules now use.
    "voicechat-icon-speaker",
    "housefinder_neighborhood-friends-icon",
    "UI-LFG-RoleIcon-Tank",

    -- The guild hunt.
    "ui-hud-minimap-guildbanner-delves-large",
    "UI-HUD-MicroMenu-Guild-Up",
    "UI-HUD-MicroMenu-GuildCommunities-Up",
    "hud-microbutton-Guild-Up",
    "communities-guildbanner-background",
    "communities-guildbanner-border",
    "GuildBanner-Background",
    "communities-icon-guildbannerbackground",
    "groupfinder-icon-guild",
    "communities-icon-addgroupplus",   -- exists, wrong meaning: a green plus
}

-- Each variant is one hypothesis about the right escape. `desc` says what it
-- would mean if this is the one that looks right.
local TEXTURE_VARIANTS = {
    { tag = "1", desc = "height only -- what ships today",
      make = function(p) return ("|T%s:14|t"):format(p) end },
    { tag = "2", desc = "explicit square 14x14",
      make = function(p) return ("|T%s:14:14|t"):format(p) end },
    { tag = "3", desc = "natural size (0)",
      make = function(p) return ("|T%s:0|t"):format(p) end },
    { tag = "4", desc = "crop 0-100 of a declared 128 -- the reverted attempt",
      make = function(p) return ("|T%s:14:14:0:0:128:128:0:100:0:100|t"):format(p) end },
    { tag = "5", desc = "crop against the file's own 100x100",
      make = function(p) return ("|T%s:14:14:0:0:100:100:0:100:0:100|t"):format(p) end },
    { tag = "6", desc = "height only, nudged down 2px (baseline test)",
      make = function(p) return ("|T%s:14:14:0:-2|t"):format(p) end },
}

local function AtlasInfo(atlas)
    if not (C_Texture and C_Texture.GetAtlasInfo) then return nil end
    return C_Texture.GetAtlasInfo(atlas)
end

-- ---------------------------------------------------------------------------
-- Broker
-- ---------------------------------------------------------------------------

-- Deliberately one texture only: the data bar divides its width between
-- widgets, and a row of eighteen samples would be squeezed to nothing. This is
-- the in-bar view; the popup carries the full matrix.
local function UpdateBroker()
    if not ldbObject then return end
    local p = TEXTURES[1].path
    local out = {}
    for _, v in ipairs(TEXTURE_VARIANTS) do
        out[#out + 1] = v.tag .. v.make(p)
    end
    out[#out + 1] = "A|A:voicechat-icon-speaker:14:14|a"
    Broker.SetText(ldbObject, table.concat(out, " "))
end

-- ---------------------------------------------------------------------------
-- Popup
-- ---------------------------------------------------------------------------

local function ShowTooltip(tt)
    tt:AddLine("Icon Probe", 1, 0.82, 0)
    tt:AddLine("Each row draws the same file a different way.", 0.6, 0.6, 0.6)
    tt:AddLine(" ")

    for _, tex in ipairs(TEXTURES) do
        tt:AddLine(tex.label, 0.55, 0.78, 1)
        for _, v in ipairs(TEXTURE_VARIANTS) do
            -- Sample on the left, what it would prove on the right.
            tt:AddDoubleLine(v.tag .. "  " .. v.make(tex.path) .. "  |cff808080" .. v.tag .. "|r",
                v.desc, 1, 1, 1, 0.5, 0.5, 0.5)
        end
        tt:AddLine(" ")
    end

    tt:AddLine("Atlases", 1, 0.82, 0)
    for _, atlas in ipairs(ATLASES) do
        local info = AtlasInfo(atlas)
        if info then
            tt:AddDoubleLine(("|A:%s:14:14|a  %s"):format(atlas, atlas),
                ("%dx%d"):format(info.width or 0, info.height or 0),
                1, 1, 1, 0.45, 0.9, 0.45)
        else
            tt:AddDoubleLine("     " .. atlas, "MISSING", 0.6, 0.6, 0.6, 1, 0.35, 0.35)
        end
    end
    tt:AddLine(" ")
    tt:AddLine("Natural-size atlases, for comparison:", 0.6, 0.6, 0.6)
    for _, atlas in ipairs(ATLASES) do
        if AtlasInfo(atlas) then
            tt:AddLine(("|A:%s:0:0|a  %s"):format(atlas, atlas), 1, 1, 1)
        end
    end
end

local function ShowPopup(anchor)
    popup = popup or AniMods.W.Tooltip()
    popup:Clear()
    ShowTooltip(popup)
    popup:Show(anchor)
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsIconProbe", {
        label = "AniMods: Icon Probe",
        OnEnter = ShowPopup,
        OnLeave = function() if popup then popup:Hide() end end,
        OnTooltipShow = ShowTooltip,
    })
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function IconProbe:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "What this is" }
    rows[#rows + 1] = {
        label = "Purpose",
        value = "Diagnostic",
        help  = "Enable this widget in the data bar, hover it, and screenshot "
             .. "the popup. Every row draws the same file a different way, so "
             .. "the one that looks right names the fix. Delete the module "
             .. "afterwards.",
    }
    rows[#rows + 1] = { label = "Texture files probed", value = tostring(#TEXTURES) }
    rows[#rows + 1] = { label = "Escape variants", value = tostring(#TEXTURE_VARIANTS) }

    rows[#rows + 1] = { section = "Atlases" }
    for _, atlas in ipairs(ATLASES) do
        local info = AtlasInfo(atlas)
        rows[#rows + 1] = {
            label = atlas,
            state = info and true or false,
            note  = info and ("%dx%d"):format(info.width or 0, info.height or 0) or nil,
        }
    end

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsIconProbe")) do
        rows[#rows + 1] = row
    end

    return rows
end

function IconProbe:Enable()
    InitLDB()
    UpdateBroker()
end

function IconProbe:SetEnabled()
    return true
end

AniMods.RegisterModule("IconProbe", IconProbe)
