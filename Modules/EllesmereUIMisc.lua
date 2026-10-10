-- EllesmereUI Misc
-- The bag for things that are meaningless without EllesmereUI, each an
-- independently switchable ENTRY (see ENTRIES below) rather than one bundled
-- all-or-nothing setting. Three so far:
--
--   Missing Stats -- item level and your primary stat, added to
--                    EllesmereUIQoL's stats block, which shows neither.
--   Social Status -- EllesmereUIMinimap's friends button as a data bar widget:
--                    our counts, its own popup on hover.
--   Pet Cast Bar  -- gives Blizzard's pet cast bar its events back, after oUF
--                    silenced it as collateral for the player's.
--
-- The bar for adding an entry: it touches EllesmereUI specifically, it cannot
-- work without it, and it is REVERSIBLE. That last one is not decoration --
-- these apply and revert live, which is why this module escapes the framework's
-- usual "toggling takes effect next reload" rule (see README), and an
-- irreversible entry would quietly take that property away from every other
-- entry in the bag.
--
-- The bar used to say "small enough that a whole module would be ceremony", and
-- Social Status is not that: it arrived with its own counting walk, icon
-- resolution and broker registration. The clause is gone rather than left
-- quietly broken. What actually decides membership is whether a thing is
-- meaningless without EllesmereUI; size is whatever that costs. Extra Button
-- Click-Through went the other way on the same test -- small, but about
-- Blizzard's frames, so it is a module of its own.

local AniMods = _G.AniMods

local EUIMisc = {
    title = "EllesmereUI Misc",
    description = "Small tweaks to EllesmereUI's own elements.",
    dbKey = "euiMisc",
    category = "Addon Extras",
    conditions = {
        { text = "EllesmereUI loaded",
          help = "Everything here adjusts EllesmereUI's own elements, so it "
              .. "needs EllesmereUI.",
          met = function() return AniMods.IsAddOnLoaded("EllesmereUI") end },
    },
}

-- ---------------------------------------------------------------------------
-- Per-entry enable/disable, persisted. Default on.
-- ---------------------------------------------------------------------------

-- Settings shared by the entries below (each entry's own enable flag lives in
-- EntryDB). Declared up here because Lua only closes over locals declared
-- BEFORE the function that uses them -- defined further down, every earlier
-- reference would silently resolve to a nil global instead.
local function MiscDB()
    AniModsDB.euiMisc = AniModsDB.euiMisc or {}
    return AniModsDB.euiMisc
end

local function EntryDB()
    local db = MiscDB()
    db.entries = db.entries or {}
    return db.entries
end

local function IsEntryEnabled(key)
    local v = EntryDB()[key]
    if v == nil then return true end
    return v
end

-- ---------------------------------------------------------------------------
-- Entry: Missing Stats
-- ---------------------------------------------------------------------------
-- EllesmereUIQoL draws a stats block (EUI_SecondaryStats) with crit, haste,
-- mastery, versatility, the three tertiaries and an optional FPS/latency pair.
-- It has no item level and no primary stat, and it cannot be given any: the row
-- builder is a closure, the dispatch is a hard-coded if/elseif chain over a
-- fixed set of keys, and the FontString is repainted with SetFormattedText on
-- every stat event -- so a line appended from outside is gone on the next tick.
-- Adding a key to the order EUI publishes as EllesmereUI._secondaryStatsOrder
-- renders nothing, because nothing in that chain matches it.
--
-- So this is a SECOND block that reads as part of the first: anchored to the
-- top-left of EUI's, copying its font, size, spacing and label colour straight
-- off its own FontString rather than resolving EUI's font API again. EUI sizes
-- that frame to its text and positions it, so ours follows it around for free.
--
-- There is deliberately NO standalone mode. An earlier version stood alone and
-- movable when EUI's block was absent, which was built on a misreading of what
-- this is: it is not a stats display, it is the two rows EllesmereUI's display
-- is missing. Without that block there is nothing to be missing from.
--
-- SECRET VALUES. On 12.1 the character's own figures can come back as secrets in
-- combat, and a secret cannot be inspected, formatted or compared -- reading one
-- is an error, not a wrong answer. The same discipline EUI uses applies here:
-- figures are never read in Lua, they travel as ARGUMENTS to SetFormattedText
-- and the engine fills the template with the true value. The one thing that
-- costs is measuring, since GetStringWidth on a FontString that was fed a secret
-- hands back a secret too -- so the last known size is kept until the figures
-- are readable again.

local STATS_FRAME_NAME = "AniModsMissingStats"
local EUI_FRAME_NAME = "EUI_SecondaryStats"

-- EllesmereUIQoL's own constants, copied rather than read: they are file-locals
-- over there with nothing exported, so the only way to match them is to match
-- them. Every one of these is a value the rows are measured against, and being
-- off by one makes these two rows visibly not part of the list they sit in --
-- LABEL_GAP was two spaces against EllesmereUI's one, which is exactly what
-- made the item level and primary stat sit further from their colons than every
-- row below them.
--
-- EllesmereUIQoL.lua: ROW_GAP = 3, LABEL_GAP = " ", font size 12.
local DEFAULT_FONT_SIZE = 12
local DEFAULT_SPACING = 3
local LABEL_GAP = " "
-- Gap between our rows and EUI's, in the same units as the row spacing: the two
-- are one list, not two stacked panels.
local BLOCK_GAP = 2

local statsFrame, statsText
local lastSize = { w = 160, h = 40 }

-- ── Labels ──────────────────────────────────────────────────────────────────
--
-- LOCALISED, unlike the settings panel. This text is drawn in the world inside
-- EllesmereUI's block, which reads the player's language, so an English word in
-- the middle of it would be the odd one out. The panel is a different audience
-- and stays English with the rest of AniMods.
--
-- The client is asked first and answers for most of it: SPELL_STAT<N>_NAME is
-- the stat name the character sheet shows. What the client does NOT give is
-- short forms -- SPELL_STAT4_NAME is "Intellect", and ITEM_LEVEL_ABBR is "ilvl"
-- on every locale including zhCN. So there are two small tables for exactly
-- those gaps, and nothing else.
local function ClientString(global, fallback)
    local v = _G[global]
    return (type(v) == "string" and v ~= "" and v) or fallback
end

-- LE_UNIT_STAT_*, which is what GetSpecializationInfo's sixth return uses.
local STAT_GLOBAL = {
    [1] = "SPELL_STAT1_NAME", -- Strength
    [2] = "SPELL_STAT2_NAME", -- Agility
    [4] = "SPELL_STAT4_NAME", -- Intellect
}
local STAT_FALLBACK = { [1] = "Strength", [2] = "Agility", [4] = "Intellect" }

-- English only, and deliberately: the CJK names are already two characters and
-- cannot be shortened, and inventing an abbreviation for "Beweglichkeit" would
-- be guessing at someone else's language. Every locale not listed gets the
-- client's full name, which is long but correct.
local STAT_SHORT = {
    enUS = { [1] = "Str", [2] = "Agi", [4] = "Int" },
}
STAT_SHORT.enGB = STAT_SHORT.enUS

local LOCALE = _G.GetLocale()

local function StatLabel(index)
    local short = STAT_SHORT[LOCALE]
    if short and short[index] then return short[index] end
    return ClientString(STAT_GLOBAL[index], STAT_FALLBACK[index] or "?")
end

-- ITEM_LEVEL_ABBR is NOT localised: it is "ilvl" on a zhCN client too, because
-- Blizzard translates the long STAT_AVERAGE_ITEM_LEVEL and leaves the
-- abbreviation alone. The Chinese addons all carry their own for this reason --
-- NDui has 装等 and 裝等 in its own locale files rather than reading a global.
-- Only the two that can be verified from a source in this folder are listed.
local ILVL_SHORT = {
    zhCN = "装等",
    zhTW = "裝等",
}

local function ItemLevelLabel()
    if ILVL_SHORT[LOCALE] then return ILVL_SHORT[LOCALE] end
    -- STAT_AVERAGE_ITEM_LEVEL is the long form and the last resort: a block of
    -- abbreviations with "Item Level" in it reads as a different list.
    return ClientString("ITEM_LEVEL_ABBR",
        ClientString("STAT_AVERAGE_ITEM_LEVEL", "ilvl"))
end

-- ── Rows ────────────────────────────────────────────────────────────────────

-- Item level first: it is the headline, and the block sits above EUI's, so the
-- eye reaches it before the secondaries either way.
local ROW_ORDER = { "ilvl", "primary" }
local ROW_LABEL = {
    ilvl    = "Item level",
    primary = "Primary stat",
}
local ROW_HELP = {
    ilvl    = "The equipped average, which is the number that matters for "
           .. "content requirements. Labelled short and in your client's "
           .. "language where that is known -- Blizzard's own ITEM_LEVEL_ABBR "
           .. "is \"ilvl\" on every locale, so the Chinese clients carry their "
           .. "own here the way the Chinese addons do.",
    primary = "Strength, Agility or Intellect, whichever your current "
           .. "specialization actually scales with. It follows a spec change "
           .. "on its own, and is abbreviated on English clients only -- the "
           .. "CJK names are already two characters.",
}

local function RowShown(key)
    return not MiscDB().hiddenStats or not MiscDB().hiddenStats[key]
end

local function SetRowShown(key, shown)
    local db = MiscDB()
    db.hiddenStats = db.hiddenStats or {}
    db.hiddenStats[key] = (not shown) and true or nil
end

-- Which stat this spec scales with. Returns the LE_UNIT_STAT index, or nil
-- before the spec is known (the first moments of a login).
local function PrimaryStatIndex()
    local specIndex = _G.C_SpecializationInfo.GetSpecialization()
    if not specIndex then return nil end
    local _, _, _, _, _, primaryStat = _G.C_SpecializationInfo.GetSpecializationInfo(specIndex)
    return STAT_GLOBAL[primaryStat] and primaryStat or nil
end

-- ── Look ────────────────────────────────────────────────────────────────────

local function EUIStatsFrame()
    local f = _G[EUI_FRAME_NAME]
    if f and f:IsShown() then return f end
    return nil
end

-- EUI's own FontString, found by walking the frame's regions. It is a file local
-- over there, so there is nothing to ask for it -- but the frame has exactly one
-- FontString, and copying off it means these rows track EUI's font, size and
-- scale settings without reading any of them.
local function EUIStatsText(euiFrame)
    for _, region in ipairs({ euiFrame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            return region
        end
    end
    return nil
end

-- EUI stores the class colour it resolved on its own frame. Reading it keeps the
-- two halves' labels the same colour even when EUI's resolution changes.
local function LabelHex(euiFrame)
    local hex = euiFrame and euiFrame._classHex
    if type(hex) == "string" then return hex end
    local _, class = _G.UnitClass("player")
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "ffffff"
end

local function ApplyFont(euiFrame)
    if not statsText then return end
    local euiText = euiFrame and EUIStatsText(euiFrame)
    if euiText then
        local file, size, flags = euiText:GetFont()
        if file then
            statsText:SetFont(file, size, flags)
            statsText:SetSpacing(euiText:GetSpacing() or DEFAULT_SPACING)
            return
        end
    end
    AniMods.W.SetFont(statsText, DEFAULT_FONT_SIZE)
    statsText:SetSpacing(DEFAULT_SPACING)
end

-- ── Paint ───────────────────────────────────────────────────────────────────

local statsEnabled = false

local function BuildStatsFrame()
    if statsFrame then return end
    statsFrame = _G.CreateFrame("Frame", STATS_FRAME_NAME, _G.UIParent)
    statsFrame:SetSize(lastSize.w, lastSize.h)
    statsFrame:SetFrameStrata("LOW")
    statsFrame:Hide()

    statsText = statsFrame:CreateFontString(nil, "OVERLAY")
    statsText:SetPoint("TOPLEFT")
    statsText:SetJustifyH("LEFT")
end

local function UpdateStats()
    if not statsFrame then return end

    local euiFrame = EUIStatsFrame()
    if not (statsEnabled and euiFrame) then
        statsFrame:Hide()
        return
    end

    ApplyFont(euiFrame)
    statsFrame:ClearAllPoints()
    -- Bottom to top: these rows grow upward from EUI's block, so adding one
    -- never shoves EUI's block down the screen.
    statsFrame:SetPoint("BOTTOMLEFT", euiFrame, "TOPLEFT", 0, BLOCK_GAP)

    local hex = LabelHex(euiFrame)

    -- One template line per row, plus the figures to fill it. NOTHING below
    -- reads a figure -- see the secret-values note above.
    local rows, vals = {}, {}
    local anySecret = false

    -- The label is TEMPLATE text, not an argument: it is baked into the string
    -- that SetFormattedText then fills, so a "%" inside it would be read as a
    -- format spec and eat one of the figures. These labels come from the
    -- client, and no locale has one today -- but EllesmereUI escapes its own
    -- for this exact reason, and a crash that waits for a translation is worse
    -- than one that happens now.
    local function Esc(text)
        return (text:gsub("%%", "%%%%"))
    end

    local function Row(label, body, value)
        label = Esc(label)
        if value == nil then
            rows[#rows + 1] = ("|cff%s%s:|r%s?"):format(hex, label, LABEL_GAP)
            return
        end
        if _G.issecretvalue(value) then anySecret = true end
        vals[#vals + 1] = value
        rows[#rows + 1] = ("|cff%s%s:|r%s%s"):format(hex, label, LABEL_GAP, body)
    end

    for _, key in ipairs(ROW_ORDER) do
        if RowShown(key) then
            if key == "ilvl" then
                -- Second return, not the first: the first is the overall
                -- average, which counts what is sitting in your bags.
                local _, equipped = _G.GetAverageItemLevel()
                Row(ItemLevelLabel(), "%.1f", equipped)
            elseif key == "primary" then
                local index = PrimaryStatIndex()
                if index then
                    -- The second return is the effective value, which is what
                    -- the character sheet shows.
                    local _, value = _G.UnitStat("player", index)
                    Row(StatLabel(index), "%d", value)
                end
            end
        end
    end

    if #rows == 0 then
        statsFrame:Hide()
        return
    end

    statsFrame:Show()
    statsText:SetFormattedText(table.concat(rows, "\n"), unpack(vals))

    -- Clean figures do NOT buy a clean measurement: the metrics belong to the
    -- last LAID OUT string, so the first paint after a secret one still hands
    -- back a secret width. Test what the arithmetic is about to touch.
    if not anySecret then
        local w, h = statsText:GetStringWidth(), statsText:GetStringHeight()
        if not (_G.issecretvalue(w) or _G.issecretvalue(h)) then
            lastSize.w, lastSize.h = w + 2, h + 2
        end
    end
    statsFrame:SetSize(lastSize.w, lastSize.h)
end

-- Coalesced the way EUI coalesces its own: redraw at once so the rows are not
-- half a second behind the character sheet, then once more when the burst has
-- settled. PLAYER_EQUIPMENT_CHANGED alone can fire a dozen times for one gear
-- swap.
local statsWatcher
local burstPending = false

local function OnStatEvent()
    if burstPending then return end
    burstPending = true
    UpdateStats()
    _G.C_Timer.After(0.5, function()
        burstPending = false
        UpdateStats()
    end)
end

local function EnsureStatsWatcher()
    if statsWatcher then return end
    statsWatcher = _G.CreateFrame("Frame")
    -- Engine-filtered to the player: a plain RegisterEvent here would deliver
    -- every raid member's stat changes.
    statsWatcher:RegisterUnitEvent("UNIT_STATS", "player")
    -- And the same for this one, which the PLAYER_ prefix hides: it carries a
    -- unit too, and fires for party and raid members as their specs become
    -- known. It sat in the plain list below until a filling raid was found to
    -- be re-laying-out these rows once per arriving member.
    statsWatcher:RegisterUnitEvent("PLAYER_SPECIALIZATION_CHANGED", "player")
    for _, ev in ipairs({
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_AVG_ITEM_LEVEL_UPDATE",
        "PLAYER_ENTERING_WORLD",
        -- Combat-scoped secrecy lifts here. The figures stay live through a
        -- fight because they render as arguments, but the rows cannot be
        -- MEASURED while any of them is secret -- this is the edge that catches
        -- their footprint back up.
        "PLAYER_REGEN_ENABLED",
    }) do
        statsWatcher:RegisterEvent(ev)
    end
    statsWatcher:SetScript("OnEvent", OnStatEvent)
end

local MissingStatsEntry = {
    key = "missingStats",
    -- Named for the gap it fills rather than for what it draws. "Character
    -- Stats" sounded like a stats display of its own, which is the misreading
    -- that produced a standalone mode nobody wanted.
    name = "Missing Stats",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIQoL") then
            return false, "EllesmereUIQoL is not loaded, so there is no stats "
                       .. "block to add rows to."
        end
        if not EUIStatsFrame() then
            return false, "EllesmereUI's stats block is not showing. Switch it "
                       .. "on in EllesmereUI's Extras settings and these rows "
                       .. "appear above it."
        end
        return true
    end,
    Apply = function()
        statsEnabled = true
        BuildStatsFrame()
        EnsureStatsWatcher()
        UpdateStats()
        return true
    end,
    Revert = function()
        statsEnabled = false
        if statsFrame then statsFrame:Hide() end
    end,
    GetInfoRows = function()
        local rows = {}
        for _, key in ipairs(ROW_ORDER) do
            rows[#rows + 1] = {
                label = ROW_LABEL[key],
                help  = ROW_HELP[key],
                get   = function() return RowShown(key) end,
                set   = function(v) SetRowShown(key, v); UpdateStats() end,
            }
        end

        local index = PrimaryStatIndex()
        rows[#rows + 1] = {
            label = "Primary stat",
            -- The client's full name rather than the drawn abbreviation: this
            -- row answers "which stat did it pick?", and "Int" is a worse answer
            -- to that question even though it is the better label.
            value = index and ClientString(STAT_GLOBAL[index], STAT_FALLBACK[index])
                 or "unknown",
            help  = "Read from your current specialization, so it follows a "
                 .. "spec change without being told.",
        }
        rows[#rows + 1] = {
            label = "Labels drawn as",
            value = ("%s / %s"):format(ItemLevelLabel(),
                index and StatLabel(index) or StatLabel(1)),
            help  = "What the rows themselves say, in your client's language. "
                 .. "The settings panel stays English; the rows do not, because "
                 .. "they sit in EllesmereUI's list and have to read like part "
                 .. "of it.",
        }
        return rows
    end,
}

-- ---------------------------------------------------------------------------
-- Entry: Friends Popup
-- ---------------------------------------------------------------------------
-- Lends EllesmereUIMinimap's own online-friends popup to anything in AniMods
-- that wants it -- today, Social Status' data bar widget.
--
-- Social Status used to PORT that popup: a copy of its two-column layout,
-- section headers, dividers and row cap, roughly two hundred lines that had to
-- be kept looking like something another addon owns. It does not have to.
--
-- The button is found by shape, the way the flyout toggle is: EllesmereUI gives
-- every indicator button an `_indicatorKey`, and the friends one is "_friends".
-- Its OnEnter is then read straight off the frame -- which is possible, contrary
-- to what Social Status' header used to claim. It is installed with SetScript,
-- not HookScript, and GetScript returns that exact closure; even a HookScript'd
-- handler comes back composed, so the claim was wrong either way.
--
-- CALLED WITH OUR FRAME, not EllesmereUI's. The closure ends in
-- ShowFriendsTooltip(self), so whatever frame is passed becomes the anchor --
-- which is the whole trick, and it is safe because everything the handler does
-- first is guarded on fields only its own button has:
--
--   if self._overAtlas and self._icon then ...   -- nil on ours, no-op
--   if self._icon then self._icon:SetAlpha(1) end -- nil on ours, no-op
--   if GetFFD(self).freeMoveJustDragged then      -- weak table, mints {} for
--                                                 -- any frame
--
-- So the popup that appears is EllesmereUI's, drawn by EllesmereUI, anchored
-- where we asked. It cannot drift from the original because it IS the original.

local FRIENDS_INDICATOR_KEY = "_friends"

local friendsButton

local function FindFriendsButton()
    if friendsButton and friendsButton:GetScript("OnEnter") then return friendsButton end
    local minimap = _G.Minimap
    if not minimap then return nil end
    for _, child in ipairs({ minimap:GetChildren() }) do
        ---@diagnostic disable-next-line: undefined-field
        if child._indicatorKey == FRIENDS_INDICATOR_KEY then
            friendsButton = child
            return child
        end
    end
    return nil
end

local friendsPopupEnabled = false

-- EllesmereUI anchors that popup by its MINIMAP button row's grow direction
-- (EBS._Grow.edge[EBS._Grow.Dir()]). Beside the minimap that is right; for a
-- widget on a data bar it is not. With the row growing left, the popup's
-- TOPRIGHT pins to the widget's TOPLEFT -- so it hangs off the side of a
-- top-right widget instead of dropping below it.
--
-- The frame comes from EllesmereUI's own addon registry. Its module table is a
-- file-local, but Lite.GetAddon is the accessor EllesmereUI itself uses to
-- reach sibling modules -- and that table carries `_friendsTT`, assigned
-- beside the file-local precisely so it can be reached.
--
-- An earlier version hunted for the frame among UIParent's children by looking
-- for one anchored to our widget. That found nothing -- the popup is not
-- parented there -- and the failure was silent, which is how the placement
-- looked untouched rather than broken.
local function PopupFrame()
    local lite = _G.EllesmereUI and _G.EllesmereUI.Lite
    if not (lite and lite.GetAddon) then return nil end
    local ebs = lite.GetAddon("EllesmereUIMinimap", true)
    local frame = ebs and ebs._friendsTT
    return (type(frame) == "table" and frame.SetPoint) and frame or nil
end

local function RepositionPopup(anchor)
    local popup = PopupFrame()
    if not popup then return end
    -- Re-anchored on every show, because EllesmereUI clears and re-points it
    -- each time. The same rule every other AniMods popup follows: open downward
    -- from a widget in the top half of the screen, upward from one in the
    -- bottom, and align by screen thirds horizontally so it never runs off the
    -- side.
    AniMods.W.AnchorNear(popup, anchor, 4)
end

local function ShowPopup(anchor)
    if not friendsPopupEnabled then return false end
    local button = FindFriendsButton()
    if not (button and anchor) then return false end
    local onEnter = button:GetScript("OnEnter")
    if not onEnter then return false end
    -- xpcall: this runs another addon's handler from inside a data bar's hover
    -- path, and an error escaping would read as the bar being broken.
    if not _G.xpcall(onEnter, _G.geterrorhandler(), anchor) then return false end
    RepositionPopup(anchor)
    return true
end

local function HidePopup()
    local button = FindFriendsButton()
    if not button then return end
    local onLeave = button:GetScript("OnLeave")
    if onLeave then _G.xpcall(onLeave, _G.geterrorhandler(), button) end
end

-- ── The counts ──────────────────────────────────────────────────────────────
--
-- The only thing here that is ours. EllesmereUI's GatherOnlineFriends is a
-- file-local called from one place and its result is stored nowhere, so unlike
-- the popup there is no surface to borrow -- a count hangs off no frame script.
--
-- It does not matter: this is plain Blizzard API with nothing clever in it, so
-- there is no EllesmereUI-specific judgement to drift away from. If that ever
-- stops being true the symptom is the number disagreeing with the list the
-- popup shows, and the list is the one to believe.

local guildNameScratch, seenBNetScratch = {}, {}

local function CountOnline()
    local guildCount, friendCount = 0, 0
    local guildSet, seenBNet = guildNameScratch, seenBNetScratch
    -- Not `local t = wipe(x)`: wipe() is a Blizzard C function and its return
    -- value isn't something to depend on. Clear, then use.
    _G.wipe(guildSet)
    _G.wipe(seenBNet)
    local myName = _G.UnitName("player")

    if _G.IsInGuild and _G.IsInGuild() then
        local total = _G.GetNumGuildMembers() or 0
        for i = 1, total do
            local name, _, _, _, _, _, _, _, online = _G.GetGuildRosterInfo(i)
            if online and name then
                local short = name:match("^([^%-]+)") or name
                if short ~= myName then
                    guildCount = guildCount + 1
                    guildSet[short] = true
                end
            end
        end
    end

    local numBNet = _G.BNGetNumFriends and _G.BNGetNumFriends() or 0
    for i = 1, numBNet do
        local acct = _G.C_BattleNet and _G.C_BattleNet.GetFriendAccountInfo
            and _G.C_BattleNet.GetFriendAccountInfo(i)
        local gameInfo = acct and acct.gameAccountInfo
        if acct and gameInfo and gameInfo.isOnline and gameInfo.clientProgram == "WoW" then
            local charName = gameInfo.characterName
            if charName then seenBNet[charName] = true end
            local key = charName
            if not key then
                local rawTag = acct.battleTag or acct.accountName
                key = (rawTag and rawTag:match("^([^#]+)")) or rawTag or "???"
            end
            -- A guildmate reached through Battle.net is one person, counted
            -- under Guild rather than twice.
            if not guildSet[key] then
                friendCount = friendCount + 1
            end
        end
    end

    local numChar = _G.C_FriendList and _G.C_FriendList.GetNumFriends
        and _G.C_FriendList.GetNumFriends() or 0
    for i = 1, numChar do
        local info = _G.C_FriendList.GetFriendInfoByIndex(i)
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

-- ── The widget ──────────────────────────────────────────────────────────────

local Broker = AniMods.Broker
local CATEGORY_COLOR = { GUILD = "ffd700", FRIENDS = "59c0ff" }

-- Ordered candidates per category; the first usable one wins (W.ResolveIcon).
-- Atlas art is preferred over EllesmereUI's own line-art PNGs: at 14px thin
-- white strokes read as a scratch where an atlas is solid filled colour, which
-- is what every other icon on the bar is.
--
-- Guild is the one category with no usable atlas of its own -- the guild-ish
-- ones that exist are either the wrong thing (communities-icon-addgroupplus is
-- a green plus meaning "add a group") or frame furniture -- so it leads with
-- EllesmereUI's micromenu art. `coords` is a SQUARE region containing the
-- glyph, measured from the opaque pixels: menu-guild's art is a wide band in
-- the bottom half of a 128x128 canvas, and every display draws an icon in a
-- square box, so a tight crop gets stretched back. See Broker.lua's Icons note.
local EUI_MEDIA = "Interface\\AddOns\\EllesmereUI\\media\\"
local ICON_CANDIDATES = {
    GUILD = {
        { texture = EUI_MEDIA .. "micromenu\\menu-guild.png", addon = "EllesmereUI",
          coords = { 0.0859, 0.9063, 0.1797, 1.0000 }, canvas = 128 },
        -- Last on purpose: a Blizzard atlas is the one thing guaranteed to be
        -- there, so every list ends in one and no category can go iconless.
        { atlas = "UI-HUD-MicroMenu-GuildCommunities-Up" },
    },
    FRIENDS = {
        { texture = EUI_MEDIA .. "micromenu\\menu-friends.png", addon = "EllesmereUI",
          coords = { 0.0938, 0.9141, 0.1797, 1.0000 }, canvas = 128 },
        -- EllesmereUIMinimap's own friends button draws this one too.
        { atlas = "housefinder_neighborhood-friends-icon" },
    },
}

local OBJECT_NAME = "AniModsSocialStatus"

local socialObject
local socialEnabled = false
local guildOnline, friendsOnline = 0, 0
local socialEvents

-- Its own sub-table, so the Icon style and Display mode settings the shared
-- Broker helpers read and write stay separate from the entry's on/off flag.
local function SocialDB()
    local db = MiscDB()
    db.social = db.social or {}
    return db.social
end

-- Resolved once, on first use: C_Texture.GetAtlasInfo needs the client up, so
-- this cannot be decided at file-load time. `false` caches a genuine miss.
-- Keyed by style as well as category, because the Icon style setting changes
-- which candidate wins and a cache keyed on category alone would keep serving
-- the art from before the switch.
local resolvedIcons = {}

local function CategoryIcon(category)
    local key = category .. ":" .. Broker.GetIconStyle(SocialDB)
    if resolvedIcons[key] == nil then
        resolvedIcons[key] = AniMods.W.ResolveIcon(ICON_CANDIDATES[category],
            Broker.PreferredIconKind(SocialDB)) or false
    end
    return resolvedIcons[key] or nil
end

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

local function UpdateBroker()
    if not socialObject then return end
    if not socialEnabled then
        -- Blanked rather than unregistered: LibDataBroker has no unregister,
        -- and a bar lays out by measured width, so an empty widget takes no
        -- share and leaves without being removed from anything.
        Broker.SetText(socialObject, "")
        return
    end
    Broker.SetText(socialObject, Broker.BuildText(SocialDB, {
        BrokerPart("GUILD", guildOnline),
        BrokerPart("FRIENDS", friendsOnline),
    }))
end

local function InitSocialBroker()
    if socialObject then return end
    socialObject = Broker.Register(OBJECT_NAME, {
        label = "AniMods: Social Status",
        OnClick = function()
            if _G.InCombatLockdown() then return end
            _G.ToggleFriendsFrame()
        end,
        -- EllesmereUIDataBars, and other displays following the same
        -- convention, call OnEnter(anchorFrame) in preference to
        -- OnTooltipShow -- confirmed in EllesmereUIDataBars_Blocks.lua's
        -- ShowTip. That is what lets the hover hand over to EllesmereUI's own
        -- popup rather than a GameTooltip.
        --
        -- There is deliberately NO OnTooltipShow fallback. This entry only
        -- exists where EllesmereUIMinimap does, so the popup is always the
        -- answer; a second renderer would be a second thing to keep looking
        -- like EllesmereUI's, which is exactly what was just deleted.
        OnEnter = function(anchor) ShowPopup(anchor) end,
        OnLeave = function() HidePopup() end,
    })
end

local SocialStatusEntry = {
    key = "socialStatus",
    name = "Social Status",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIMinimap") then
            return false, "EllesmereUIMinimap is not loaded. This widget is "
                       .. "its friends button in data bar form, and its popup "
                       .. "on hover is EllesmereUI's own."
        end
        if not FindFriendsButton() then
            return false, "EllesmereUI's friends indicator is not on the "
                       .. "minimap. Switch it on in EllesmereUI's minimap "
                       .. "settings and this finds it."
        end
        return true
    end,
    Apply = function()
        socialEnabled = true
        friendsPopupEnabled = true
        InitSocialBroker()
        guildOnline, friendsOnline = CountOnline()
        UpdateBroker()

        if socialEvents then return true end
        -- Coalesced: BN_FRIEND_INFO_CHANGED alone fires once per friend whose
        -- status, AFK flag or rich-presence blurb changes, arriving in bursts
        -- of dozens at login and whenever a group logs on together, and
        -- GUILD_ROSTER_UPDATE fires repeatedly per roster query. Answering each
        -- separately meant running the full walk N times to produce the number
        -- the last one alone would have produced.
        local Refresh = AniMods.Coalesce(function()
            if not socialEnabled then return end
            guildOnline, friendsOnline = CountOnline()
            UpdateBroker()
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end)

        socialEvents = _G.CreateFrame("Frame")
        for _, event in ipairs({
            "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE",
            "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE",
            "PLAYER_ENTERING_WORLD",
        }) do
            socialEvents:RegisterEvent(event)
        end
        socialEvents:SetScript("OnEvent", Refresh)
        return true
    end,
    Revert = function()
        socialEnabled = false
        friendsPopupEnabled = false
        UpdateBroker()
    end,
    GetInfoRows = function()
        local rows = {
            -- Read, not recounted: the event handler already did the walk.
            { label = "Guild online", value = tostring(guildOnline) },
            { label = "Friends online", value = tostring(friendsOnline) },
        }
        for _, row in ipairs(Broker.SectionRows(SocialDB, UpdateBroker, OBJECT_NAME)) do
            rows[#rows + 1] = row
        end
        return rows
    end,
}

-- ── Pet Cast Bar ────────────────────────────────────────────────────────────
--
-- EllesmereUI gives the focus frame a cast bar and the pet frame none. Pet,
-- target-of-target and focus-target all go through StyleSimpleFrame, which
-- builds Health, Power and Portrait and stops; only the full, focus and boss
-- builders call CreateCastBar.
--
-- WHAT IT IS FOR: Mind Control. A charmed unit is your `pet`, and what it is
-- casting is the entire reason you took it. (The Shadowfiend sort of pet never
-- casts, which is why an earlier attempt looked broken when it was not.)
--
-- ── Two routes tried and rejected, so neither gets tried again ──────────────
--
-- BLIZZARD'S OWN BAR. PetCastingBarFrame exists, and oUF silences it as
-- collateral when its Castbar element enables on the PLAYER frame
-- (PetCastingBarFrame:UnregisterAllEvents() ... :Hide(), oUF/Elements/castbar.lua).
-- EllesmereUI even publishes RearmBlizzCastBars to hand both bars back. Armed
-- it and nothing appeared.
--
-- ELLESMEREUI'S BUILDER. CreateCastBar is reachable (ns._internals), but it
-- IGNORES the settings table it is handed and re-reads GetSettingsForUnit(unit)
-- itself -- and db.profile.pet has no cast keys, because EllesmereUI never
-- meant it to have a cast bar. That function is a file-local upvalue in their
-- Castbar.lua, so it cannot be swapped either. Driving their builder for the
-- pet unit therefore REQUIRES writing cast settings into their saved profile,
-- which is not ours to write.
--
-- ── So: our frame, our settings, their mover ────────────────────────────────
--
-- The bar is ours, which is the same shape Missing Stats above already uses --
-- a frame of our own that reads as part of EllesmereUI by copying its look off
-- the live article rather than by being built out of their parts. It survived
-- their 9.2.1 -> 9.4 restructure untouched, which is the argument.
--
-- The LOOK is read from EllesmereUI's focus cast bar settings at build time.
-- Reading is not writing: nothing is stored anywhere of theirs, and the bar
-- tracks their styling if it changes.
--
-- The POSITION AND SIZE are registered with EllesmereUI's unlock mode through
-- MakeUnlockElement / RegisterUnlockElements -- a published extension point
-- whose whole design is that the CALLER owns storage: getSize, setWidth,
-- setHeight, savePos, loadPos, clearPos and applyPos are all callbacks into
-- us. So the mover, the nudge keys, the anchor links and the size-matching are
-- EllesmereUI's, and every value they produce is written into AniModsDB. That
-- is what makes this neither an injection nor a second positioning system.
--
-- ── Taint ───────────────────────────────────────────────────────────────────
--
-- There is none to worry about, and the reason is structural rather than
-- careful. The bar is parented to UIParent, never to the pet frame: it only
-- SetPoint-anchors to it, and anchoring reads a rect rather than executing
-- anything of theirs -- the same argument GroupRoles' docked badge makes. It
-- calls no protected function and touches no secure frame, so there is nothing
-- for combat lockdown to block and nothing to taint. Cast events are ordinary
-- unit events; UnitCastingInfo and UnitChannelInfo are unrestricted and their
-- values are not secret.

local PET_UNLOCK_KEY = "AniMods_PetCastBar"

local petCastEnabled = false
local petCastBar          -- our frame, built on first use
local petCastRegistered = false

local function PetCastDB()
    local db = MiscDB()
    db.petCastBar = db.petCastBar or {}
    return db.petCastBar
end

-- EllesmereUI's unit-frame namespace, published at their file scope as
-- EllesmereUI._ModuleNS[addonName] with the comment that other files read it.
local function UFInternals()
    local eui = _G.EllesmereUI
    local reg = eui and eui._ModuleNS
    local ns = reg and reg["EllesmereUIUnitFrames"]
    local I = ns and ns._internals
    return (type(I) == "table") and I or nil
end

local function EUIPetFrame()
    local I = UFInternals()
    local frames = I and I.frames
    return frames and frames.pet or nil
end

-- Their focus cast bar's settings, read only, as the source of our look. Falls
-- back to nothing rather than to invented numbers: every read below carries its
-- own default, so an EllesmereUI without a focus table simply yields our
-- defaults instead of a half-styled bar.
local function FocusCastSettings()
    local I = UFInternals()
    if not I then return nil end
    local s = I.GetSettingsForUnit("focus")
    return (type(s) == "table") and s or nil
end

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 101, 14

-- Width defaults to the PET FRAME's width, not the focus bar's. Inheriting the
-- focus look is the point; inheriting its width is the one part that must not
-- be, since the pet frame is narrower and the bar would hang off both ends.
local function BarSize()
    local own = PetCastDB()
    local focus = FocusCastSettings()
    local pet = EUIPetFrame()
    local w = own.width or (pet and pet:GetWidth()) or DEFAULT_WIDTH
    local h = own.height or (focus and focus.castbarHeight) or DEFAULT_HEIGHT
    return math.floor(w + 0.5), math.floor(h + 0.5)
end

local function ApplyBarLook()
    if not petCastBar then return end
    local focus = FocusCastSettings()
    local w, h = BarSize()
    petCastBar:SetSize(w, h)

    local bg = focus and focus.castBgColor
    petCastBar.bg:SetColorTexture(bg and bg.r or 0, bg and bg.g or 0, bg and bg.b or 0,
        (focus and focus.castBgAlpha) or 0.5)

    local fill = focus and focus.castbarFillColor
    petCastBar.fill:SetStatusBarColor(fill and fill.r or 0.863,
        fill and fill.g or 0.820, fill and fill.b or 0.639)

    AniMods.W.SetFont(petCastBar.name, (focus and focus.castSpellNameSize) or 11)
    AniMods.W.SetFont(petCastBar.time, (focus and focus.castDurationSize) or 11)
end

local function ApplyBarPosition()
    if not petCastBar then return end
    petCastBar:ClearAllPoints()

    local pos = PetCastDB().pos
    if pos then
        -- Unlock mode hands back CENTER/CENTER screen coordinates.
        petCastBar:SetPoint("CENTER", _G.UIParent, "CENTER", pos.x or 0, pos.y or 0)
        return
    end

    -- Default: under EllesmereUI's pet frame. ANCHORED, never parented -- see
    -- the taint note in this entry's header.
    local pet = EUIPetFrame()
    if pet then
        petCastBar:SetPoint("TOP", pet, "BOTTOM", 0, -2)
    else
        petCastBar:SetPoint("CENTER", _G.UIParent, "CENTER", 0, -160)
    end
end

-- Cast state. Milliseconds, as Blizzard reports them.
local castStart, castEnd, castChannel = 0, 0, false

local function OnBarUpdate(self)
    local now = _G.GetTime() * 1000
    local span = castEnd - castStart
    if span <= 0 or now >= castEnd then
        self:SetScript("OnUpdate", nil)
        self:Hide()
        return
    end
    local pct = (now - castStart) / span
    -- A channel drains rather than fills: the bar shows what is LEFT.
    self.fill:SetValue(castChannel and (1 - pct) or pct)
    self.time:SetFormattedText("%.1f", (castEnd - now) / 1000)
end

local function BuildBar()
    if petCastBar then return petCastBar end

    -- Parented to UIParent on purpose. Anchoring to the pet frame reads its
    -- rect; parenting to it would make us a child of a secure unit button and
    -- put our Show/Hide inside their frame's world.
    local f = _G.CreateFrame("Frame", "AniModsPetCastBar", _G.UIParent)
    f:SetFrameStrata("MEDIUM")
    f:Hide()

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()

    f.fill = _G.CreateFrame("StatusBar", nil, f)
    f.fill:SetAllPoints()
    f.fill:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.fill:SetMinMaxValues(0, 1)
    f.fill:SetValue(0)

    f.name = f.fill:CreateFontString(nil, "OVERLAY")
    f.name:SetPoint("LEFT", f, "LEFT", 3, 0)
    f.name:SetJustifyH("LEFT")

    f.time = f.fill:CreateFontString(nil, "OVERLAY")
    f.time:SetPoint("RIGHT", f, "RIGHT", -3, 0)
    f.time:SetJustifyH("RIGHT")

    petCastBar = f
    ApplyBarLook()
    ApplyBarPosition()
    return f
end

local function ShowCast(channel)
    local bar = BuildBar()
    -- Declared local, not left implicit: `_` in a plain multiple ASSIGNMENT is
    -- a global write, which is how the same idiom that is fine in a `local`
    -- statement leaks seven globals here.
    local _
    local name, startMS, endMS, notInterruptible
    if channel then
        name, _, _, startMS, endMS, _, notInterruptible = _G.UnitChannelInfo("pet")
    else
        name, _, _, startMS, endMS, _, _, notInterruptible = _G.UnitCastingInfo("pet")
    end
    if not (name and startMS and endMS) then
        bar:SetScript("OnUpdate", nil)
        bar:Hide()
        return
    end

    castStart, castEnd, castChannel = startMS, endMS, channel and true or false
    bar.name:SetText(name)

    local focus = FocusCastSettings()
    local c = notInterruptible
        and (focus and focus.castbarUninterruptibleColor)
        or  (focus and focus.castbarFillColor)
    if notInterruptible then
        bar.fill:SetStatusBarColor(c and c.r or 0.5, c and c.g or 0.5, c and c.b or 0.5)
    else
        bar.fill:SetStatusBarColor(c and c.r or 0.863, c and c.g or 0.820, c and c.b or 0.639)
    end

    bar:SetScript("OnUpdate", OnBarUpdate)
    bar:Show()
end

local function HideCast()
    if not petCastBar then return end
    petCastBar:SetScript("OnUpdate", nil)
    petCastBar:Hide()
end

local petCastWatcher

local function EnsurePetCastWatcher()
    if petCastWatcher then return end
    petCastWatcher = _G.CreateFrame("Frame")
    -- RegisterUnitEvent, so a raid full of casters never reaches this handler
    -- at all. These fire for every unit otherwise.
    for _, ev in ipairs({
        "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_DELAYED",
        "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
        "UNIT_SPELLCAST_INTERRUPTIBLE", "UNIT_SPELLCAST_NOT_INTERRUPTIBLE",
        "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP",
        "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    }) do
        petCastWatcher:RegisterUnitEvent(ev, "pet")
    end
    petCastWatcher:SetScript("OnEvent", function(_, event)
        if not petCastEnabled then return end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_DELAYED" then
            ShowCast(false)
        elseif event == "UNIT_SPELLCAST_CHANNEL_START"
            or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
            ShowCast(true)
        elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE"
            or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
            -- Re-read rather than recolour in place: the same path that chose
            -- the colour at the start gets it right for a channel too.
            ShowCast(castChannel)
        else
            HideCast()
        end
    end)
end

-- EllesmereUI's unlock mode, through its published extension point. Every
-- callback here reads and writes AniModsDB: the mover is theirs, the values
-- are ours. That is the whole reason this is not an injection.
local function RegisterPetCastUnlock()
    if petCastRegistered then return end
    local eui = _G.EllesmereUI
    if not (eui and eui.RegisterUnlockElements and eui.MakeUnlockElement) then return end
    petCastRegistered = true

    local MK = eui.MakeUnlockElement
    eui:RegisterUnlockElements({
        MK({
            key   = PET_UNLOCK_KEY,
            label = "Pet Cast Bar",
            group = "AniMods",
            order = 100,
            isHidden = function() return not petCastEnabled end,
            getFrame = function() return BuildBar() end,
            getSize  = function() return BarSize() end,
            setWidth = function(_, w)
                PetCastDB().width = math.max(40, math.floor(w + 0.5))
                ApplyBarLook()
            end,
            setHeight = function(_, h)
                PetCastDB().height = math.max(6, math.floor(h + 0.5))
                ApplyBarLook()
            end,
            -- Never read the live position here: on Cancel the frame is still
            -- sitting where it was dragged, which is the note their own
            -- Battle Res element leaves about this exact callback.
            savePos = function(_, _, _, x, y)
                PetCastDB().pos = { x = x, y = y }
            end,
            loadPos = function()
                local pos = PetCastDB().pos
                if not pos then return nil end
                return "CENTER", "CENTER", pos.x, pos.y
            end,
            clearPos = function()
                PetCastDB().pos = nil
                ApplyBarPosition()
            end,
            applyPos = function() ApplyBarPosition() end,
        }),
    })
end

local PetCastBarEntry = {
    key = "petCastBar",
    name = "Pet Cast Bar",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIUnitFrames") then
            return false, "EllesmereUIUnitFrames is not loaded, so there is no "
                       .. "pet frame to sit under and no cast bar styling to "
                       .. "read."
        end
        if not EUIPetFrame() then
            return false, "EllesmereUI is not drawing the pet frame -- its Pet "
                       .. "frame source is set to Blizzard or Hidden, so there "
                       .. "is nothing to anchor to."
        end
        return true
    end,
    Apply = function()
        petCastEnabled = true
        BuildBar()
        ApplyBarLook()
        ApplyBarPosition()
        EnsurePetCastWatcher()
        RegisterPetCastUnlock()
        return true
    end,
    Revert = function()
        petCastEnabled = false
        HideCast()
        -- The watcher stays registered and the unlock element stays declared;
        -- both are inert while the flag is false (the handler returns at once,
        -- isHidden() takes the mover away), and neither can be undone -- a
        -- RegisterUnitEvent could be, but tearing it down to rebuild it on the
        -- next toggle buys nothing.
    end,
    GetInfoRows = function()
        local own = PetCastDB()
        return {
            {
                label = "Width", min = 40, max = 400, step = 1,
                get   = function() local w = BarSize(); return w end,
                set   = function(v) own.width = v; ApplyBarLook() end,
                help  = "Defaults to the pet frame's own width. The focus cast "
                     .. "bar's width is deliberately not inherited: the pet "
                     .. "frame is narrower, and the bar would hang off it.",
            },
            {
                label = "Height", min = 6, max = 40, step = 1,
                get   = function() local _, h = BarSize(); return h end,
                set   = function(v) own.height = v; ApplyBarLook() end,
            },
            {
                label = "Position",
                value = own.pos and "moved" or "under the pet frame",
                help  = "Registered with EllesmereUI's unlock mode as \"Pet Cast "
                     .. "Bar\" under the AniMods group, so it drags, nudges and "
                     .. "size-matches like any of its own elements -- but every "
                     .. "value it produces is stored here rather than in "
                     .. "EllesmereUI's settings.",
            },
            {
                kind = "button", label = "Reset position", button = "Reset",
                help = "Puts it back under the pet frame.",
                onClick = function()
                    own.pos = nil
                    ApplyBarPosition()
                    if AniMods.RefreshUI then AniMods.RefreshUI() end
                end,
            },
            {
                kind = "button", label = "Preview", button = "Show",
                help = "Runs a three second fake cast. Worth having: the real "
                    .. "trigger is a Mind Controlled caster, which is not "
                    .. "something you can arrange while fiddling with sizes.",
                onClick = function()
                    local bar = BuildBar()
                    castStart = _G.GetTime() * 1000
                    castEnd, castChannel = castStart + 3000, false
                    bar.name:SetText("Preview")
                    bar.fill:SetValue(0)
                    bar:SetScript("OnUpdate", OnBarUpdate)
                    bar:Show()
                end,
            },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Entry framework
-- ---------------------------------------------------------------------------

local ENTRIES = { MissingStatsEntry, SocialStatusEntry, PetCastBarEntry }
local entryApplied = {} -- key -> true once Apply() has actually succeeded

local function PollEntry(entry)
    if entryApplied[entry.key] then return end
    if not IsEntryEnabled(entry.key) then return end
    local avail = entry.Available()
    if not avail then return end
    if entry.Apply() then
        entryApplied[entry.key] = true
    end
end

local function SetEntryEnabled(key, enabled)
    EntryDB()[key] = enabled and true or false

    local entry
    for _, e in ipairs(ENTRIES) do
        if e.key == key then entry = e; break end
    end
    if not entry then return end

    if enabled then
        PollEntry(entry)
    elseif entryApplied[key] then
        entry.Revert()
        entryApplied[key] = false
    end
end

function EUIMisc:GetInfoRows()
    local rows = {}

    for _, entry in ipairs(ENTRIES) do
        rows[#rows + 1] = { section = entry.name }
        rows[#rows + 1] = {
            label = "Enabled",
            get   = function() return IsEntryEnabled(entry.key) end,
            set   = function(v) SetEntryEnabled(entry.key, v) end,
        }

        local avail, reason = entry.Available()
        if not avail then
            rows[#rows + 1] = {
                label = "Available",
                state = false,
                help  = reason or "A prerequisite for this entry is not met.",
            }
        else
            local effectHelp
            if not entryApplied[entry.key] then
                -- "Switched off" is distinct from "waiting": nothing is being
                -- waited on, the entry is simply off by the row above.
                effectHelp = (not IsEntryEnabled(entry.key))
                    and "Switched off by the setting above."
                    or  "Waiting for the EllesmereUI frame it attaches to."
            end
            rows[#rows + 1] = {
                -- "Applied" described what the code did. "In effect" describes
                -- what the player can see, which is what they came to check.
                label = "In effect",
                state = entryApplied[entry.key] and true or false,
                help  = effectHelp,
            }
            if entry.GetInfoRows then
                for _, r in ipairs(entry.GetInfoRows()) do
                    rows[#rows + 1] = r
                end
            end
        end
    end

    return rows
end

function EUIMisc:Enable()
    local function PollAll()
        for _, entry in ipairs(ENTRIES) do
            PollEntry(entry)
        end
    end

    -- Gated on the skin API rather than fired at PLAYER_LOGIN: EllesmereUI
    -- dispatches that callback after its OWN boot, so it is the first moment
    -- both the facade and EllesmereUI's frames are guaranteed to exist. The
    -- ladder covers only what is genuinely created later -- EllesmereUIQoL
    -- builds its stats block on its own schedule.
    AniMods.W.OnReady(function()
        PollAll()
        for _, delay in ipairs({ 2, 5, 10, 20 }) do
            _G.C_Timer.After(delay, PollAll)
        end
    end)
end

AniMods.RegisterModule("EllesmereUIMisc", EUIMisc)
