-- SocialStatus
-- Online guild/friend counts as a LibDataBroker (LDB) plugin, mirroring
-- EllesmereUIMinimap's own "friends" button (the one in its minimap extra
-- button group that shows online friends/guildies on hover) so the same
-- information can live in a databar instead.
--
-- The COUNTS are a port of EllesmereUIMinimap's GatherOnlineFriends: same data
-- sources, same online-filtering and dedup rules. The POPUP is not a port any
-- more -- it is EllesmereUI's own, shown through the Friends Popup entry in
-- EllesmereUI Misc (which owns the reach into it) and anchored at this widget.
--
-- This header used to claim EllesmereUI's popup was "entirely unreachable": the
-- button unnamed, and ShowFriendsTooltip "wired via HookScript, which isn't
-- retrievable through GetScript()". Both halves were wrong, and about two
-- hundred lines of ported layout rested on them. The button is unnamed but
-- carries `_indicatorKey == "_friends"`, the same structural probe the flyout
-- toggle is found by; and its handler is installed with SetScript, so GetScript
-- returns that exact closure -- a HookScript'd one would come back composed and
-- work too. The lesson worth keeping: "there is no accessor" is a claim about
-- an API, and a frame's scripts are not an API you have to be given.
--
-- What is still not reached, and does not need to be: EUI's right-click
-- whisper/invite row menu, its hover-stability grace timers, and its
-- dev-mode/protected-instance whisper guards. Those come with its popup now
-- rather than being reimplemented here.
--
-- Only active when EllesmereUIMinimap is loaded -- the counting logic
-- itself is plain Blizzard API and needs nothing from EUI, but the whole
-- point is to be the broker-shaped equivalent of a button that's
-- specifically EUI's.

local SocialStatus = {
    title = "Social Status",
    description = "Online guild and friend counts.",
    dbKey = "socialStatus",
    category = "At a Glance",
    -- One condition, and it is about a DUPLICATE rather than a prerequisite:
    -- NDui's infobar ships both of these counts already
    -- (Modules/Infobar/Friends.lua and Guild.lua), so with NDui installed this
    -- is a second widget showing the same two numbers.
    --
    -- Nothing here NEEDS another addon -- the roster gathering calls only
    -- Blizzard APIs (GetGuildRosterInfo, C_BattleNet, C_FriendList) and the
    -- broker is a plain LibDataBroker object any data bar can display. That is
    -- why EllesmereUIMinimap is deliberately not listed: it is where the popup's
    -- look was copied from, not where any of the information comes from, and
    -- requiring it once cost a stock UI its friend counts for no reason.
    --
    -- The distinction that matters: a condition is right when another addon
    -- already DOES this, and wrong when another addon merely INSPIRED it.
    conditions = {
        { text = "NDui not loaded",
          help = "NDui's infobar shows the same guild and friend counts, so "
              .. "this stands down rather than displaying them twice.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
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

-- Counts only -- the same three walks and the same de-duplication as
-- GatherOnlineFriends, but without building a table per online player,
-- reading their zone/level/class, or sorting anything.
--
-- Why this exists as a separate function: the broker text needs exactly two
-- integers, and it is recomputed on every friend/guild event -- which is by
-- far the most frequent thing this module does. Doing it through
-- GatherOnlineFriends meant, on each of those events, allocating one 7-field
-- table per online guild member (700+ in a large guild), resolving each one's
-- class through C_CreatureInfo, and then running THREE table.sorts, purely to
-- call `#` on the results and throw all of it away. The full gather is now
-- reached only from the two tooltip paths, which run on hover.
--
-- The de-dup rules are duplicated here rather than shared, because sharing
-- them would mean materialising the lists again -- the exact cost being
-- avoided. That makes this the one thing to keep in step: if the guild/BNet/
-- character-friend filtering in GatherOnlineFriends changes, change it here
-- too, or the broker's numbers will silently disagree with its own tooltip.
--
-- Both scratch tables are reused across calls: wipe() keeps the hash capacity
-- already allocated, so a big guild roster stops re-growing a fresh table on
-- every event.
local guildNameScratch, seenBNetScratch = {}, {}

local function CountOnline()
    local guildCount, friendCount = 0, 0
    local guildSet, seenBNet = guildNameScratch, seenBNetScratch
    -- Not `local t = wipe(x)`: wipe() is a Blizzard C function and its return
    -- value isn't something to depend on. Clear, then use.
    wipe(guildSet)
    wipe(seenBNet)
    local myName = UnitName("player")

    if IsInGuild and IsInGuild() then
        local total = GetNumGuildMembers() or 0
        for i = 1, total do
            local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if online and name then
                local short = name:match("^([^%-]+)") or name
                if short ~= myName then
                    guildCount = guildCount + 1
                    guildSet[short] = true
                end
            end
        end
    end

    local numBNet = BNGetNumFriends and BNGetNumFriends() or 0
    for i = 1, numBNet do
        local acct = C_BattleNet and C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendAccountInfo(i)
        local gameInfo = acct and acct.gameAccountInfo
        -- `acct and` is redundant (gameInfo can only be non-nil if acct was),
        -- but it states the narrowing outright for both the reader and the
        -- type checker instead of making either infer it through the
        -- `acct and acct.x` above.
        if acct and gameInfo and gameInfo.isOnline and gameInfo.clientProgram == "WoW" then
            local charName = gameInfo.characterName
            if charName then seenBNet[charName] = true end
            -- Mirrors the `name` field GatherOnlineFriends builds for a BNet
            -- entry, since that is the key its guild filter matches on.
            local key = charName
            if not key then
                local rawTag = acct.battleTag or acct.accountName
                key = (rawTag and rawTag:match("^([^#]+)")) or rawTag or "???"
            end
            if not guildSet[key] then
                friendCount = friendCount + 1
            end
        end
    end

    local numChar = C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0
    for i = 1, numChar do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.connected then
            local charName = info.name
            if charName and not seenBNet[charName] then
                local short = charName:match("^([^%-]+)") or charName
                if not guildSet[short] then
                    friendCount = friendCount + 1
                end
            end
        end
    end

    return guildCount, friendCount
end

-- ---------------------------------------------------------------------------
-- The popup: EllesmereUI's own
-- ---------------------------------------------------------------------------
-- This used to be a PORT of EllesmereUIMinimap's friends popup -- its
-- two-column layout, section headers, dividers and row cap, rebuilt here in
-- about two hundred lines. The header above it claimed EllesmereUI's version
-- was unreachable: the button unnamed, and its tooltip wired with HookScript,
-- "which isn't retrievable through GetScript()".
--
-- Both halves were wrong. The button is unnamed but not unfindable -- every
-- EllesmereUI indicator carries an `_indicatorKey`, and this one is "_friends",
-- the same structural probe the flyout toggle is found by. And it is wired with
-- SetScript, not HookScript, so GetScript hands back that exact closure; a
-- HookScript'd one would come back composed and work too.
--
-- So the popup is now EllesmereUI's, drawn by EllesmereUI, anchored at our
-- widget -- see the Friends Popup entry in EllesmereUI Misc, which owns the
-- reach into it. It cannot drift from the original because it IS the original,
-- and two hundred lines of layout that had to be kept looking like someone
-- else's are gone.
--
-- The plain renderer below stays. It is not a second copy of the popup: it is
-- what a data bar that cannot anchor a foreign frame gets instead, and what is
-- shown when the entry is switched off.

local MAX_ROWS_PER_SECTION = 30 -- EUI's own hard cap; its user-configurable friendsMaxRows setting isn't reachable from here

--- @return boolean shown  false when nothing lent us a popup
local function ShowSocialTooltip(anchor)
    local popup = AniMods.EUIFriendsPopup
    return (popup and popup.Show(anchor)) and true or false
end

local function HideSocialTooltip()
    local popup = AniMods.EUIFriendsPopup
    if popup then popup.Hide() end
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
        -- Capped the way EllesmereUI caps its own, so the two render the same
        -- list rather than this one running down the screen in a big guild.
        local shown = math.min(#sec.list, MAX_ROWS_PER_SECTION)
        for i = 1, shown do
            local e = sec.list[i]
            local cc = e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
            local r, g, b = 1, 1, 1
            if cc then r, g, b = cc.r, cc.g, cc.b end
            local label = e.bnetTag and (e.bnetTag .. " (" .. e.name .. ")") or e.name
            tt:AddDoubleLine(label, e.zone or "", r, g, b, 0.6, 0.6, 0.6)
        end
        if #sec.list > shown then
            tt:AddLine(("...and %d more"):format(#sec.list - shown), 0.6, 0.6, 0.6)
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
-- Atlas first, because the art matters more than the match. The PNGs were
-- preferred once on the theory that EllesmereUIChat's flat line-art reads as
-- a matched pair -- but a throwaway probe widget (IconProbe, since deleted)
-- put them side by side with the
-- atlases in the data bar, and at 14px the line work loses badly: thin white
-- strokes look like a scratch where an atlas is solid filled colour, which is
-- what every other icon on the bar is. Nothing was wrong with how they
-- rendered; they were simply the wrong art at this size.
--
-- UI-HUD-Minimap-GuildBanner-Up is confirmed MISSING on this client (the probe
-- reported it so), which is what the note above always suspected.
local EUI_MEDIA = "Interface\\AddOns\\EllesmereUI\\media\\"
local ICON_CANDIDATES = {
    GUILD = {
        -- EllesmereUI's OWN guild icon, from the same micromenu set its data
        -- bar draws for the item-level block (menu-character.png). A solid
        -- silhouette, 128x128, and it matches the look the rest of the bar has
        -- -- which is the whole reason to prefer it over the chat sidebar's
        -- line art.
        --
        -- Guild is the one category with no usable atlas: the probe found
        -- UI-HUD-Minimap-GuildBanner-Up MISSING, and the guild-ish atlases that
        -- DO exist are either the wrong thing entirely
        -- (communities-icon-addgroupplus is a green plus meaning "add a group")
        -- or frame furniture rather than an icon
        -- (communities-guildbanner-background/-border, 74x69).
        -- `coords` is a SQUARE region of the file containing the glyph, from
        -- measuring the opaque pixels: menu-guild's art is 105x67 sitting at
        -- (11,58) on a 128x128 canvas, i.e. a wide band in the bottom half
        -- with nothing above it. Drawing the whole canvas rendered it at half
        -- height; cropping it tightly then got stretched back, because every
        -- display draws the icon in a SQUARE box. A square crop is the only
        -- shape that survives that. See the Icons section in Broker.lua.
        { texture = EUI_MEDIA .. "micromenu\\menu-guild.png", addon = "EllesmereUI",
          coords = { 0.0859, 0.9063, 0.1797, 1.0000 }, canvas = 128 },
        -- 16x20 and present: the real guild micro-button icon. Last on purpose
        -- -- a Blizzard atlas is the one thing guaranteed to be there, so every
        -- list ends in one and no category can go iconless.
        { atlas = "UI-HUD-MicroMenu-GuildCommunities-Up" },
    },
    FRIENDS = {
        { texture = EUI_MEDIA .. "micromenu\\menu-friends.png", addon = "EllesmereUI",
          coords = { 0.0938, 0.9141, 0.1797, 1.0000 }, canvas = 128 },
        -- 16x16 and present, and EllesmereUIMinimap's own friends button draws
        -- this one too.
        { atlas = "housefinder_neighborhood-friends-icon" },
    },
}

-- Resolved once, on first use: C_Texture.GetAtlasInfo needs the client up,
-- so this can't be decided at file-load time. `false` caches a genuine miss.
-- Keyed by style as well as category: the Icon style setting changes which
-- candidate wins, so a cache keyed on category alone would keep serving the
-- art from before the switch.
local resolvedIcons = {}
local function CategoryIcon(category)
    local key = category .. ":" .. AniMods.Broker.GetIconStyle(ModuleDB)
    if resolvedIcons[key] == nil then
        resolvedIcons[key] = AniMods.W.ResolveIcon(ICON_CANDIDATES[category],
            AniMods.Broker.PreferredIconKind(ModuleDB)) or false
    end
    return resolvedIcons[key] or nil
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
        -- EllesmereUI's own popup when the Friends Popup entry is lending it,
        -- and GameTooltip with the same names when it is not -- switched off,
        -- or EllesmereUIMinimap's friends indicator hidden. A widget that shows
        -- nothing on hover because one setting is off would read as broken.
        OnEnter = function(anchor)
            if ShowSocialTooltip(anchor) then return end
            _G.GameTooltip:SetOwner(anchor, "ANCHOR_NONE")
            _G.GameTooltip:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
            ShowSocialTooltipPlain(_G.GameTooltip)
            _G.GameTooltip:Show()
        end,
        OnLeave = function()
            HideSocialTooltip()
            _G.GameTooltip:Hide()
        end,
        OnTooltipShow = ShowSocialTooltipPlain,
    })
end

-- The shared builder (AniMods.Broker) owns the icon/text formatting and the
-- display-mode setting; this only has to say what the parts are.
local function BrokerPart(category, count)
    local part = { count = count, color = CATEGORY_COLOR[category] }
    local icon = CategoryIcon(category)
    if icon then
        part.atlas   = icon.atlas
        part.texture = icon.texture
        part.coords  = icon.coords
        part.canvas  = icon.canvas
    end
    return part
end

-- The last counted pair, so one event produces ONE walk.
--
-- The broker text and the panel's Status rows both want these two numbers, and
-- both used to call CountOnline themselves -- so with the panel open on this
-- tab, every friend or guild event walked the guild roster and both friend
-- lists TWICE, once for each reader, in the same frame. They are recounted
-- where the event is handled and read from here.
--
-- Safe to serve a cached pair to a panel opened much later: these numbers can
-- only change through one of the events this module listens to, and Enable
-- primes them.
local guildOnline, friendsOnline = 0, 0

local function RecountOnline()
    guildOnline, friendsOnline = CountOnline()
end

local function UpdateBroker()
    if not ldbObject then return end
    local guildCount, friendCount = guildOnline, friendsOnline
    Broker.SetText(ldbObject, Broker.BuildText(ModuleDB, {
        BrokerPart("GUILD", guildCount),
        BrokerPart("FRIENDS", friendCount),
    }))
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function SocialStatus:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    -- Read, not recounted: the event handler already did the walk this frame.
    rows[#rows + 1] = { label = "Guild online", value = tostring(guildOnline) }
    rows[#rows + 1] = { label = "Friends online", value = tostring(friendsOnline) }

    for _, row in ipairs(Broker.SectionRows(ModuleDB, UpdateBroker, "AniModsSocialStatus")) do
        rows[#rows + 1] = row
    end

    return rows
end

function SocialStatus:Enable()
    InitLDB()
    RecountOnline()
    UpdateBroker()

    -- Coalesced: BN_FRIEND_INFO_CHANGED alone fires once per friend whose
    -- status, AFK flag or rich-presence blurb changes, arriving in bursts of
    -- dozens at login and whenever a group of people log on together, and
    -- GUILD_ROSTER_UPDATE fires repeatedly per roster query. Answering each
    -- one separately meant running the full online-count walk N times to
    -- produce the number the last one alone would have produced. One walk per
    -- frame, at most, is enough.
    local Refresh = AniMods.Coalesce(function()
        -- One walk, then both readers take their numbers from it.
        RecountOnline()
        UpdateBroker()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)

    local eventFrame = CreateFrame("Frame")
    for _, event in ipairs({
        "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE",
        "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
        "PLAYER_ENTERING_WORLD",
    }) do
        eventFrame:RegisterEvent(event)
    end
    eventFrame:SetScript("OnEvent", Refresh)
end

AniMods.RegisterModule("SocialStatus", SocialStatus)
