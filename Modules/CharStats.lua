-- CharStats
-- Item level and primary stat, as lines above EllesmereUI's stats block.
--
-- EllesmereUIQoL draws a stats block (EUI_SecondaryStats) with crit, haste,
-- mastery, versatility, the three tertiaries and an optional FPS/latency pair.
-- It has no item level and no primary stat, and it cannot be given any: its row
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
-- With no EUI block to pin to, it stands alone at a saved position.
--
-- SECRET VALUES. On 12.1 the character's own figures can come back as secrets
-- in combat, and a secret cannot be inspected, formatted or compared -- reading
-- one is an error, not a wrong answer. The same discipline EUI uses applies
-- here: figures are never read in Lua, they travel as ARGUMENTS to
-- SetFormattedText and the engine fills the template with the true value. The
-- one thing that costs is measuring, since GetStringWidth on a FontString that
-- was fed a secret hands back a secret too -- so the last known size is kept
-- until the figures are readable again.

local AniMods = _G.AniMods

local CharStats = {
    title = "Character Stats",
    description = "Item level and primary stat, above EllesmereUI's stats block.",
    dbKey = "charStats",
    -- No conditions. It pins to EllesmereUI's block when there is one and
    -- stands alone when there is not, so neither case is a prerequisite.
}

local FRAME_NAME = "AniModsCharStats"
local EUI_FRAME_NAME = "EUI_SecondaryStats"

-- EllesmereUIQoL's own defaults for its block, matched so an unpinned block
-- does not look like a different addon's.
local DEFAULT_FONT_SIZE = 12
local DEFAULT_SPACING = 2
-- Gap between our block and EUI's, in the same units as the row spacing: the
-- two are one list, not two stacked panels.
local BLOCK_GAP = 2
local LABEL_GAP = "  "

local frame, text
local moduleEnabled = true
local lastSize = { w = 160, h = 40 }
local unlocked = false
local dragHandle

local function ModuleDB()
    AniModsDB.charStats = AniModsDB.charStats or {}
    local db = AniModsDB.charStats
    db.hidden = db.hidden or {}
    return db
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

-- LE_UNIT_STAT_*, which is what GetSpecializationInfo's sixth return uses.
local STAT_NAME = { [1] = "Strength", [2] = "Agility", [3] = "Stamina", [4] = "Intellect" }
local STAMINA_INDEX = 3

-- Item level first: it is the headline, and the block sits above EUI's, so the
-- eye reaches it before the secondaries either way.
local ROW_ORDER = { "ilvl", "ilvlOverall", "primary", "stamina" }
local ROW_LABEL = {
    ilvl        = "Item Level",
    ilvlOverall = "Item Level (overall)",
    primary     = "Primary stat",
    stamina     = "Stamina",
}
local ROW_HELP = {
    ilvl        = "The equipped average, which is the number that matters for "
               .. "content requirements.",
    ilvlOverall = "Blizzard's overall average, which counts what is in your "
               .. "bags. Usually the higher of the two, and usually not the "
               .. "one you want.",
    primary     = "Strength, Agility or Intellect, whichever your current "
               .. "specialization actually scales with. It follows a spec "
               .. "change on its own.",
    stamina     = "Off by default: it is the one primary that every spec "
               .. "shares, so it says less than the others.",
}
local ROW_DEFAULT_HIDDEN = { ilvlOverall = true, stamina = true }

local function RowShown(key)
    local v = ModuleDB().hidden[key]
    if v == nil then return not ROW_DEFAULT_HIDDEN[key] end
    return not v
end

-- Which stat this spec scales with. Returns the LE_UNIT_STAT index, or nil
-- before the spec is known (the first moments of a login).
local function PrimaryStatIndex()
    local specIndex = _G.C_SpecializationInfo.GetSpecialization()
    if not specIndex then return nil end
    local _, _, _, _, _, primaryStat = _G.C_SpecializationInfo.GetSpecializationInfo(specIndex)
    return STAT_NAME[primaryStat] and primaryStat or nil
end

-- ---------------------------------------------------------------------------
-- Look
-- ---------------------------------------------------------------------------

local function EUIStatsFrame()
    local f = _G[EUI_FRAME_NAME]
    if f and f:IsShown() then return f end
    return nil
end

-- EUI's own FontString, found by walking the frame's regions. It is a file
-- local over there, so there is nothing to ask for it -- but the frame has
-- exactly one FontString, and copying off it means this block tracks EUI's
-- font, size and scale settings without reading any of them.
local function EUIStatsText(euiFrame)
    for _, region in ipairs({ euiFrame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            return region
        end
    end
    return nil
end

-- EUI stores the class colour it resolved on its own frame. Reading it keeps
-- the two blocks' labels the same colour even when EUI's resolution changes.
local function LabelHex(euiFrame)
    local hex = euiFrame and euiFrame._classHex
    if type(hex) == "string" then return hex end
    local _, class = _G.UnitClass("player")
    local c = class and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[class]
    if c then return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "ffffff"
end

local function ApplyFont(euiFrame)
    if not text then return end
    local euiText = euiFrame and EUIStatsText(euiFrame)
    if euiText then
        local file, size, flags = euiText:GetFont()
        if file then
            text:SetFont(file, size, flags)
            text:SetSpacing(euiText:GetSpacing() or DEFAULT_SPACING)
            return
        end
    end
    AniMods.W.SetFont(text, DEFAULT_FONT_SIZE)
    text:SetSpacing(DEFAULT_SPACING)
end

local function ApplyPosition(euiFrame)
    if not frame then return end
    frame:ClearAllPoints()
    if euiFrame then
        -- Bottom to top: our block grows upward from EUI's, so adding a row
        -- never shoves EUI's block down the screen.
        frame:SetPoint("BOTTOMLEFT", euiFrame, "TOPLEFT", 0, BLOCK_GAP)
        return
    end
    local pos = ModuleDB().pos
    if pos and pos.point then
        frame:SetPoint(pos.point, _G.UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        -- Where EUI puts its own block, so an unpinned one lands somewhere
        -- deliberate rather than in the middle of the screen.
        frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 12, -12)
    end
end

-- ---------------------------------------------------------------------------
-- Paint
-- ---------------------------------------------------------------------------

local Update

local function BuildFrame()
    if frame then return end
    frame = _G.CreateFrame("Frame", FRAME_NAME, _G.UIParent)
    frame:SetSize(lastSize.w, lastSize.h)
    frame:SetFrameStrata("LOW")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    text = frame:CreateFontString(nil, "OVERLAY")
    text:SetPoint("TOPLEFT")
    text:SetJustifyH("LEFT")

    -- Shown only while unlocked: the block is text with no background, so
    -- without something to grab there is nothing to drag.
    dragHandle = AniMods.W.Tex(frame, "BACKGROUND", 1, 1, 1, 0.18)
    dragHandle:SetAllPoints()
    dragHandle:Hide()

    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if unlocked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ModuleDB().pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)
end

Update = function()
    if not (frame and text) then return end
    if not moduleEnabled then return end

    local euiFrame = EUIStatsFrame()
    ApplyFont(euiFrame)
    ApplyPosition(euiFrame)

    local hex = LabelHex(euiFrame)

    -- One template line per row, plus the figures to fill it. NOTHING below
    -- reads a figure -- see the secret-values note at the top.
    local rows, vals = {}, {}
    local anySecret = false

    local function Row(label, body, value)
        if value == nil then
            rows[#rows + 1] = ("|cff%s%s:|r%s?"):format(hex, label, LABEL_GAP)
            return
        end
        if _G.issecretvalue(value) then anySecret = true end
        vals[#vals + 1] = value
        rows[#rows + 1] = ("|cff%s%s:|r%s%s"):format(hex, label, LABEL_GAP, body)
    end

    -- Both averages come from one call, so it is made once whether one row or
    -- two is showing.
    local overall, equipped
    if RowShown("ilvl") or RowShown("ilvlOverall") then
        overall, equipped = _G.GetAverageItemLevel()
    end

    for _, key in ipairs(ROW_ORDER) do
        if RowShown(key) then
            if key == "ilvl" then
                Row(ROW_LABEL.ilvl, "%.1f", equipped)
            elseif key == "ilvlOverall" then
                Row(ROW_LABEL.ilvlOverall, "%.1f", overall)
            elseif key == "primary" then
                local index = PrimaryStatIndex()
                if index then
                    -- The second return is the effective value, which is what
                    -- the character sheet shows.
                    local _, value = _G.UnitStat("player", index)
                    Row(STAT_NAME[index], "%d", value)
                end
            elseif key == "stamina" then
                local _, value = _G.UnitStat("player", STAMINA_INDEX)
                Row(ROW_LABEL.stamina, "%d", value)
            end
        end
    end

    if #rows == 0 then
        frame:Hide()
        return
    end

    frame:Show()
    text:SetFormattedText(table.concat(rows, "\n"), unpack(vals))

    -- Clean figures do NOT buy a clean measurement: the metrics belong to the
    -- last LAID OUT string, so the first paint after a secret one still hands
    -- back a secret width. Test what the arithmetic is about to touch.
    if not anySecret then
        local w, h = text:GetStringWidth(), text:GetStringHeight()
        if not (_G.issecretvalue(w) or _G.issecretvalue(h)) then
            lastSize.w, lastSize.h = w + 2, h + 2
        end
    end
    frame:SetSize(lastSize.w, lastSize.h)
end

-- Coalesced the way EUI coalesces its own: redraw at once so the block is not
-- half a second behind the character sheet, then once more when the burst has
-- settled. PLAYER_EQUIPMENT_CHANGED alone can fire a dozen times for one gear
-- swap.
local watcher
local burstPending = false

local function OnStatEvent()
    if burstPending then return end
    burstPending = true
    Update()
    _G.C_Timer.After(0.5, function()
        burstPending = false
        Update()
    end)
end

local function EnsureWatcher()
    if watcher then return end
    watcher = _G.CreateFrame("Frame")
    -- Engine-filtered to the player: a plain RegisterEvent here would deliver
    -- every raid member's stat changes.
    watcher:RegisterUnitEvent("UNIT_STATS", "player")
    for _, ev in ipairs({
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_AVG_ITEM_LEVEL_UPDATE",
        "PLAYER_SPECIALIZATION_CHANGED",
        "PLAYER_ENTERING_WORLD",
        -- Combat-scoped secrecy lifts here. The figures stay live through a
        -- fight because they render as arguments, but the block cannot be
        -- MEASURED while any of them is secret -- this is the edge that catches
        -- its footprint back up.
        "PLAYER_REGEN_ENABLED",
    }) do
        watcher:RegisterEvent(ev)
    end
    watcher:SetScript("OnEvent", OnStatEvent)
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

function CharStats:GetInfoRows()
    local rows = {}
    local euiFrame = EUIStatsFrame()

    rows[#rows + 1] = { section = "Placement" }
    rows[#rows + 1] = {
        label = "Pinned to EllesmereUI",
        state = euiFrame and true or false,
        help  = euiFrame
            and "Anchored above EllesmereUI's stats block, in its font, so the "
             .. "two read as one list. It follows that block wherever you move it."
            or  "EllesmereUI's stats block is not showing, so this stands alone "
             .. "at its own position. It pins itself the moment that block appears.",
    }
    if not euiFrame then
        rows[#rows + 1] = {
            label = "Unlock to move",
            get   = function() return unlocked end,
            set   = function(v)
                unlocked = v and true or false
                if dragHandle then dragHandle:SetShown(unlocked) end
            end,
            help  = "Shows a box to drag. The block is bare text otherwise, so "
                 .. "there is nothing to grab.",
        }
    end

    rows[#rows + 1] = { section = "Lines" }
    for _, key in ipairs(ROW_ORDER) do
        rows[#rows + 1] = {
            label = ROW_LABEL[key],
            help  = ROW_HELP[key],
            get   = function() return RowShown(key) end,
            set   = function(v)
                ModuleDB().hidden[key] = (not v) and true or nil
                Update()
            end,
        }
    end

    rows[#rows + 1] = { section = "Right now" }
    local index = PrimaryStatIndex()
    rows[#rows + 1] = {
        label = "Primary stat",
        value = index and STAT_NAME[index] or "unknown",
        help  = "Read from your current specialization, so it follows a spec "
             .. "change without being told.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function CharStats:Enable()
    moduleEnabled = true
    BuildFrame()
    EnsureWatcher()
    -- Deferred: EllesmereUIQoL builds its stats block during its own boot, and
    -- asking before that lands answers "no block here" and leaves this one
    -- standing alone for the session.
    AniMods.W.OnReady(function()
        Update()
        -- EUI's block is built on its own schedule and can arrive after the
        -- skin facade does. Two late looks rather than a ticker: once pinned,
        -- the anchor holds and nothing needs to check again.
        _G.C_Timer.After(2, Update)
        _G.C_Timer.After(5, Update)
    end)
end

function CharStats:SetEnabled(on)
    moduleEnabled = on and true or false
    if not moduleEnabled then
        if frame then frame:Hide() end
        return true
    end
    Update()
    return true
end

AniMods.RegisterModule("CharStats", CharStats)
