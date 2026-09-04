-- SocialStatus
-- Online guild/friend counts as a LibDataBroker (LDB) plugin, mirroring
-- EllesmereUIMinimap's own "friends" button (the one in its minimap extra
-- button group that shows online friends/guildies on hover) so the same
-- information can live in a databar instead.
--
-- EllesmereUIMinimap's own version is entirely unreachable from outside
-- that file: the button itself has no name (CreateIndicatorBtn does
-- `CreateFrame("Button", nil, parent)`), the table holding it
-- (_customIndicators) is a plain local, and its tooltip function
-- (ShowFriendsTooltip) is wired via HookScript, which isn't retrievable
-- through GetScript() even if the frame could be found -- there's no
-- exposed accessor the way EllesmereUIChat exposes `EllesmereUI._chatCFD`
-- or EllesmereUIQoL_RaidTools exposes `_G._EUI_RaidTools_DB()`. So this is a
-- faithful PORT of GatherOnlineFriends/ShowFriendsTooltip (both in
-- EllesmereUIMinimap.lua) rather than a call into them -- same data
-- sources, same online-filtering/dedup rules, same visual layout (dark
-- bordered popup, class-colored two-column rows, section headers with
-- accent-colored counts, dividers between sections), so it looks and
-- behaves like the same popup, just anchored to this broker instead of
-- EUI's minimap button. Deliberately NOT ported: EUI's right-click
-- whisper/invite row menu, its hover-stability grace timers, and its
-- dev-mode/protected-instance whisper guards -- interactive conveniences
-- specific to living on the minimap, not part of "look and feel", and
-- dependent on EUI-internal locals (EBS, MO_Evaluate) with no access path
-- anyway.
--
-- Only active when EllesmereUIMinimap is loaded -- the counting logic
-- itself is plain Blizzard API and needs nothing from EUI, but the whole
-- point is to be the broker-shaped equivalent of a button that's
-- specifically EUI's.

local SocialStatus = {
    title = "Social Status",
    description = "Online guild/friend counts as a broker (LDB) plugin, mirroring EllesmereUIMinimap's own friends button.",
    dependencies = {
        { text = "EllesmereUIMinimap loaded", met = function() return AniMods.IsAddOnLoaded("EllesmereUIMinimap") end },
    },
    condition = {
        requires = { "EllesmereUIMinimap" },
    },
}

local function ModuleDB()
    AniModsDB.socialStatus = AniModsDB.socialStatus or {}
    return AniModsDB.socialStatus
end

-- ---------------------------------------------------------------------------
-- Roster gathering -- faithful port of EllesmereUIMinimap.lua's
-- GatherOnlineFriends (guild / BNet favorites / BNet+character friends,
-- with dedup and sorting matching that function exactly).
-- ---------------------------------------------------------------------------

local function GatherOnlineFriends()
    local guild, favorites, friends = {}, {}, {}
    local seenBNet = {}
    local myName = UnitName("player")

    if IsInGuild and IsInGuild() then
        local total = GetNumGuildMembers() or 0
        for i = 1, total do
            local name, _, _, level, _, zone, _, _, online, _, classFile = GetGuildRosterInfo(i)
            if online and name then
                local short = name:match("^([^%-]+)") or name
                if short ~= myName then
                    guild[#guild + 1] = { name = short, full = name, class = classFile, zone = zone or "", level = level }
                end
            end
        end
    end

    local numBNet = BNGetNumFriends and BNGetNumFriends() or 0
    for i = 1, numBNet do
        local acct = C_BattleNet and C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendAccountInfo(i)
        if acct then
            local gameInfo = acct.gameAccountInfo
            if gameInfo and gameInfo.isOnline and gameInfo.clientProgram == "WoW" then
                local charName = gameInfo.characterName
                local classFile = gameInfo.className and gameInfo.className:upper():gsub(" ", "")
                if gameInfo.classID and C_CreatureInfo and C_CreatureInfo.GetClassInfo then
                    local ci = C_CreatureInfo.GetClassInfo(gameInfo.classID)
                    if ci and ci.classFile then classFile = ci.classFile end
                end
                local zone = gameInfo.areaName or ""
                local realm = gameInfo.realmName
                local full = charName
                if charName and realm and realm ~= "" then
                    full = charName .. "-" .. realm
                end
                local rawTag = acct.battleTag or acct.accountName
                local tagName = rawTag and rawTag:match("^([^#]+)") or rawTag
                local entry = {
                    name = charName or tagName or "???",
                    full = full,
                    class = classFile,
                    zone = zone,
                    level = gameInfo.characterLevel,
                    bnetTag = tagName,
                    bnetName = acct.accountName or acct.battleTag,
                }
                if charName then seenBNet[charName] = true end
                if acct.isFavorite then
                    favorites[#favorites + 1] = entry
                else
                    friends[#friends + 1] = entry
                end
            end
        end
    end

    local numChar = C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0
    for i = 1, numChar do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected then
            local charName = info.name
            if charName and not seenBNet[charName] then
                friends[#friends + 1] = {
                    name = charName:match("^([^%-]+)") or charName,
                    full = charName,
                    class = info.className and info.className:upper():gsub(" ", ""),
                    zone = info.area or "",
                    level = info.level,
                }
            end
        end
    end

    -- Guild members are removed from the friends lists to avoid duplicates.
    local guildSet = {}
    for _, g in ipairs(guild) do guildSet[g.name] = true end
    for i = #friends, 1, -1 do
        if guildSet[friends[i].name] then table.remove(friends, i) end
    end
    for i = #favorites, 1, -1 do
        if guildSet[favorites[i].name] then table.remove(favorites, i) end
    end

    local function byZone(a, b)
        local az, bz = a.zone or "", b.zone or ""
        if (az == "") ~= (bz == "") then return az ~= "" end
        if az ~= bz then return az < bz end
        return (a.name or "") < (b.name or "")
    end
    local function byTag(a, b)
        return (a.bnetTag or a.name or ""):lower() < (b.bnetTag or b.name or ""):lower()
    end
    table.sort(guild, byZone)
    table.sort(favorites, byTag)
    table.sort(friends, byTag)

    return guild, favorites, friends
end

-- ---------------------------------------------------------------------------
-- Custom tooltip -- ported layout from ShowFriendsTooltip: dark bordered
-- popup, section headers ("Title (count)", count in accent color), two
-- column rows (class-colored name [+ BNet tag prefix] [+ level suffix] on
-- the left, zone on the right), dividers between sections, sized to fit its
-- content. `anchor` is the frame this is shown next to (see OnEnter below).
-- ---------------------------------------------------------------------------

local FTT_PAD, FTT_ROW_H, FTT_HDR_H, FTT_GAP, FTT_DIV_PAD = 8, 14, 16, 2, 5
local MAX_ROWS_PER_SECTION = 30 -- EUI's own hard cap; its user-configurable friendsMaxRows setting isn't reachable from here

-- Every bridge into EllesmereUI goes through AniMods.W: it's the one place
-- that knows which members are actually exported and what to fall back to.
-- Duplicating those lookups here is how this module ended up reading .r off
-- RegAccent (a function) in a sibling module and crashing on login.
local function TTFont()
    -- "minimap": this popup mirrors EllesmereUIMinimap's own, so it should
    -- use whatever font that module is configured with, not the global one.
    return AniMods.W.FontPath("minimap")
end

local socialTT
local ttRows, ttHeaders, ttDividers = {}, {}, {}

local function GetSocialTT()
    if socialTT then return socialTT end
    local f = AniMods.W.Panel(UIParent, { 0.067, 0.067, 0.067, 0.92 }, 0.15)
    f:SetFrameStrata("TOOLTIP")
    f:SetFrameLevel(200)
    f:SetClampedToScreen(true)
    f:Hide()
    socialTT = f
    return f
end

local function EnsureTTRow(idx)
    if ttRows[idx] then return ttRows[idx] end
    local tt = GetSocialTT()
    local row = CreateFrame("Frame", nil, tt)
    row:SetHeight(FTT_ROW_H)
    local nameFS = row:CreateFontString(nil, "OVERLAY")
    nameFS:SetJustifyH("LEFT")
    nameFS:SetPoint("LEFT", row, "LEFT", 0, 0)
    local zoneFS = row:CreateFontString(nil, "OVERLAY")
    zoneFS:SetJustifyH("RIGHT")
    zoneFS:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    ttRows[idx] = { frame = row, name = nameFS, zone = zoneFS }
    return ttRows[idx]
end

local function EnsureTTHeader(idx)
    if ttHeaders[idx] then return ttHeaders[idx] end
    local tt = GetSocialTT()
    local fs = tt:CreateFontString(nil, "OVERLAY")
    fs:SetJustifyH("CENTER")
    fs:SetTextColor(1, 1, 1, 0.9)
    ttHeaders[idx] = fs
    return fs
end

local function EnsureTTDivider(idx)
    if ttDividers[idx] then return ttDividers[idx] end
    local tt = GetSocialTT()
    local tex = tt:CreateTexture(nil, "ARTWORK")
    tex:SetColorTexture(1, 1, 1, 0.12)
    tex:SetHeight(1)
    ttDividers[idx] = tex
    return tex
end

local function ShowSocialTooltip(anchor)
    local guild, favorites, friends = GatherOnlineFriends()
    local tt = GetSocialTT()
    local total = #guild + #favorites + #friends
    local font = TTFont()

    for i = 1, #ttRows do
        ttRows[i].frame:Hide()
        ttRows[i].name:Hide()
        ttRows[i].zone:Hide()
    end
    for i = 1, #ttHeaders do ttHeaders[i]:Hide() end
    for i = 1, #ttDividers do ttDividers[i]:Hide() end

    tt:ClearAllPoints()
    tt:SetPoint("TOP", anchor, "BOTTOM", 0, -4)

    if total == 0 then
        local row = EnsureTTRow(1)
        row.name:SetFont(font, 10, "")
        row.name:SetText("|cff888888No friends online|r")
        row.zone:SetText("")
        row.frame:ClearAllPoints()
        row.frame:SetPoint("TOPLEFT", tt, "TOPLEFT", FTT_PAD, -FTT_PAD)
        row.frame:SetPoint("TOPRIGHT", tt, "TOPRIGHT", -FTT_PAD, -FTT_PAD)
        row.frame:Show()
        row.name:Show()
        tt:SetSize(FTT_PAD * 2 + 140, FTT_PAD + FTT_ROW_H + FTT_PAD)
        tt:Show()
        return
    end

    local sections = {}
    if #favorites > 0 then sections[#sections + 1] = { title = "Favorites", list = favorites } end
    if #guild > 0 then sections[#sections + 1] = { title = "Guild", list = guild } end
    if #friends > 0 then sections[#sections + 1] = { title = "Friends", list = friends } end

    local rowIdx, hdrIdx, divIdx = 0, 0, 0
    local maxNameW, maxZoneW = 0, 0
    local curY = -FTT_PAD

    -- AniMods.W.Accent() rather than reading a color table off EllesmereUI
    -- directly: it goes through GetAccentColor(), which resolves the ACTIVE
    -- theme (class-colored, custom, faction) instead of just the default
    -- green, and it's the single place that knows the fallback.
    local ar, ag, ab = AniMods.W.Accent()
    local acHex = ("%02x%02x%02x"):format(ar * 255, ag * 255, ab * 255)

    for si, sec in ipairs(sections) do
        if si > 1 then
            curY = curY - FTT_DIV_PAD
            divIdx = divIdx + 1
            local div = EnsureTTDivider(divIdx)
            div:ClearAllPoints()
            div:SetPoint("TOPLEFT", tt, "TOPLEFT", FTT_PAD, curY)
            div:SetPoint("TOPRIGHT", tt, "TOPRIGHT", -FTT_PAD, curY)
            div:Show()
            curY = curY - div:GetHeight() - FTT_DIV_PAD
        end

        curY = curY - 5
        hdrIdx = hdrIdx + 1
        local hdr = EnsureTTHeader(hdrIdx)
        hdr:SetFont(font, 12, "")
        hdr:SetText(sec.title .. " (|cff" .. acHex .. #sec.list .. "|r)")
        hdr:ClearAllPoints()
        hdr:SetPoint("TOP", tt, "TOP", 0, curY)
        hdr:Show()
        curY = curY - FTT_HDR_H - 5

        local shown = math.min(#sec.list, MAX_ROWS_PER_SECTION)
        for i = 1, shown do
            local e = sec.list[i]
            rowIdx = rowIdx + 1
            local row = EnsureTTRow(rowIdx)
            row.name:SetFont(font, 10, "")
            row.zone:SetFont(font, 10, "")

            local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
            local colored = cc and cc:WrapTextInColorCode(e.name) or e.name
            if e.bnetTag then
                colored = "|cffffd100" .. e.bnetTag .. "|r (" .. colored .. ")"
            end
            local lvl = tonumber(e.level)
            if lvl and lvl > 0 then
                colored = colored .. " |cffb0b0b0" .. lvl .. "|r"
            end
            row.name:SetText(colored)
            row.name:SetTextColor(1, 1, 1, 0.85)

            local zone = e.zone or ""
            row.zone:SetText(zone ~= "" and ("|cff888888" .. zone .. "|r") or "")

            row.frame:ClearAllPoints()
            row.frame:SetPoint("TOPLEFT", tt, "TOPLEFT", FTT_PAD, curY)
            row.frame:SetPoint("TOPRIGHT", tt, "TOPRIGHT", -FTT_PAD, curY)
            row.frame:Show()
            row.name:Show()
            row.zone:Show()

            local nw = row.name:GetStringWidth() or 0
            local zw = row.zone:GetStringWidth() or 0
            if nw > maxNameW then maxNameW = nw end
            if zw > maxZoneW then maxZoneW = zw end

            curY = curY - (FTT_ROW_H + FTT_GAP)
        end

        if #sec.list > MAX_ROWS_PER_SECTION then
            rowIdx = rowIdx + 1
            local row = EnsureTTRow(rowIdx)
            row.name:SetFont(font, 10, "")
            row.name:SetText("|cff888888...and " .. (#sec.list - MAX_ROWS_PER_SECTION) .. " more|r")
            row.zone:SetText("")
            row.frame:ClearAllPoints()
            row.frame:SetPoint("TOPLEFT", tt, "TOPLEFT", FTT_PAD, curY)
            row.frame:SetPoint("TOPRIGHT", tt, "TOPRIGHT", -FTT_PAD, curY)
            row.frame:Show()
            row.name:Show()
            curY = curY - (FTT_ROW_H + FTT_GAP)
        end
    end

    local contentW = FTT_PAD + maxNameW + 16 + maxZoneW + FTT_PAD
    local ttW = math.max(contentW, 160)
    local ttH = -curY + FTT_PAD

    tt:SetSize(ttW, ttH)
    tt:Show()
end

local function HideSocialTooltip()
    if socialTT then socialTT:Hide() end
end

-- Plain-GameTooltip fallback for any LDB display that doesn't support the
-- OnEnter contract (see InitLDB below) -- same data and grouping, just
-- rendered with AddLine/AddDoubleLine since a foreign GameTooltip can't
-- host our own bordered frame.
local function ShowSocialTooltipPlain(tt)
    local guild, favorites, friends = GatherOnlineFriends()
    if #guild + #favorites + #friends == 0 then
        tt:AddLine("No friends online", 0.6, 0.6, 0.6)
        return
    end
    local sections = {}
    if #favorites > 0 then sections[#sections + 1] = { title = "Favorites", list = favorites } end
    if #guild > 0 then sections[#sections + 1] = { title = "Guild", list = guild } end
    if #friends > 0 then sections[#sections + 1] = { title = "Friends", list = friends } end
    for si, sec in ipairs(sections) do
        if si > 1 then tt:AddLine(" ") end
        tt:AddLine(("%s (%d)"):format(sec.title, #sec.list), 1, 0.82, 0)
        for _, e in ipairs(sec.list) do
            local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
            local r, g, b = 1, 1, 1
            if cc then r, g, b = cc.r, cc.g, cc.b end
            local label = e.bnetTag and (e.bnetTag .. " (" .. e.name .. ")") or e.name
            tt:AddDoubleLine(label, e.zone or "", r, g, b, 0.6, 0.6, 0.6)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Broker (LDB) plugin
-- ---------------------------------------------------------------------------

local Broker = AniMods.Broker

local ldbObject
local CATEGORY_COLOR = { GUILD = "ffd700", FRIENDS = "59c0ff" }

-- Ordered candidates per category; the first usable one wins (see
-- W.ResolveIcon). EllesmereUIChat's own sidebar art is preferred because it
-- is known to render -- that addon draws it today -- and because a matched
-- pair of its flat line-art icons reads better together than one line-art
-- icon beside a Blizzard silhouette. It is REFERENCED on disk, never copied,
-- so there is no redistribution question; the atlas entries below cover the
-- case where that addon isn't installed.
--
-- The guild atlas was previously used on its own and rendered as nothing:
-- its name came from DandersFrames_Options' atlas browser list, which that
-- browser itself filters through C_Texture.GetAtlasInfo at runtime -- so
-- appearing there never meant the atlas exists in this client.
local EUI_CHAT_MEDIA = "Interface\\AddOns\\EllesmereUIChat\\Media\\"
local ICON_CANDIDATES = {
    GUILD = {
        { texture = EUI_CHAT_MEDIA .. "chat_guild.png", addon = "EllesmereUIChat" },
        { atlas = "UI-HUD-Minimap-GuildBanner-Up" },
        { atlas = "communities-icon-addgroupplus" },
    },
    FRIENDS = {
        { texture = EUI_CHAT_MEDIA .. "chat_friends.png", addon = "EllesmereUIChat" },
        -- EllesmereUIMinimap's own friends button draws this one, so it is
        -- known good even though the rest of the list isn't.
        { atlas = "housefinder_neighborhood-friends-icon" },
    },
}

-- Resolved once, on first use: C_Texture.GetAtlasInfo needs the client up,
-- so this can't be decided at file-load time. `false` caches a genuine miss.
local resolvedIcons = {}
local function CategoryIcon(category)
    if resolvedIcons[category] == nil then
        resolvedIcons[category] = AniMods.W.ResolveIcon(ICON_CANDIDATES[category]) or false
    end
    return resolvedIcons[category] or nil
end

local function InitLDB()
    ldbObject = Broker.Register("AniModsSocialStatus", {
        label = "AniMods: Social Status",
        OnClick = function()
            if InCombatLockdown() then return end
            ToggleFriendsFrame()
        end,
        -- EllesmereUIDataBars (and other LDB displays following the same
        -- convention) call OnEnter(anchorFrame) instead of OnTooltipShow
        -- when both are present, handing full control of the tooltip to the
        -- plugin -- confirmed in EllesmereUIDataBars_Blocks.lua's ShowTip:
        -- `if obj.OnEnter then ... pcall(obj.OnEnter, button); return end`.
        -- That's what makes the custom bordered popup above possible; a
        -- plain GameTooltip can't be given a border/second-frame layout
        -- like this. OnTooltipShow stays as a fallback for displays that
        -- only support the plain GameTooltip path.
        OnEnter = function(anchor) ShowSocialTooltip(anchor) end,
        OnLeave = function() HideSocialTooltip() end,
        OnTooltipShow = ShowSocialTooltipPlain,
    })
end

-- The shared builder (AniMods.Broker) owns the icon/text formatting and the
-- display-mode setting; this only has to say what the parts are.
local function BrokerPart(category, count)
    local part = { count = count, color = CATEGORY_COLOR[category] }
    local icon = CategoryIcon(category)
    if icon then
        part.atlas = icon.atlas
        part.texture = icon.texture
    end
    return part
end

local function UpdateBroker()
    if not ldbObject then return end
    local guild, favorites, friends = GatherOnlineFriends()
    ldbObject.text = Broker.BuildText(ModuleDB, {
        BrokerPart("GUILD", #guild),
        BrokerPart("FRIENDS", #favorites + #friends),
    })
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function SocialStatus:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    local guild, favorites, friends = GatherOnlineFriends()
    rows[#rows + 1] = { label = "Guild online", value = tostring(#guild) }
    rows[#rows + 1] = { label = "Friends online", value = tostring(#favorites + #friends) }
    rows[#rows + 1] = { label = "Broker (LDB) plugin", value = ldbObject and "Registered" or "Not available" }

    for _, row in ipairs(Broker.DisplayRows(ModuleDB, UpdateBroker)) do
        rows[#rows + 1] = row
    end

    return rows
end

function SocialStatus:Enable()
    InitLDB()
    UpdateBroker()

    local eventFrame = CreateFrame("Frame")
    for _, event in ipairs({
        "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE",
        "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
        "PLAYER_ENTERING_WORLD",
    }) do
        eventFrame:RegisterEvent(event)
    end
    eventFrame:SetScript("OnEvent", function()
        UpdateBroker()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)
end

AniMods.RegisterModule("SocialStatus", SocialStatus)
