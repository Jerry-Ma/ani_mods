-- EllesmereUI Misc
-- The bag for small EllesmereUI-only tweaks -- one-off "it should look like it
-- belongs" fixes too slight to be modules of their own, each an independently
-- switchable ENTRY (see ENTRIES below) rather than one bundled all-or-nothing
-- setting. Two so far:
--
--   Missing Stats -- item level and your primary stat, added to
--   EllesmereUIQoL's stats block, which shows neither.
--   Lettered Plugin Buttons -- addon minimap icons redrawn as their initial in
--   one weight and size, so EllesmereUIMinimap's flyout grid stops being eight
--   unrelated pieces of art.
--
-- The bar for adding an entry: it touches EllesmereUI specifically, it is small
-- enough that a whole module would be ceremony, and it is REVERSIBLE. That last
-- one is not decoration -- these apply and revert live, which is why this module
-- escapes the framework's usual "toggling takes effect next reload" rule (see
-- README), and an irreversible entry would quietly take that property away from
-- every other entry in the bag.
--
-- This bag existed before, was emptied down to one non-EllesmereUI entry, and
-- was deleted; the entry that was left became its own module (Extra Button
-- Click-Through, which is about Blizzard's frames and needs no EllesmereUI).
-- It is back because Missing Stats genuinely is EllesmereUI-only: it adds rows
-- to EllesmereUI's block and has nothing to say without one.

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

-- EllesmereUIQoL's own defaults for its block, used only if its FontString
-- cannot be read for some reason.
local DEFAULT_FONT_SIZE = 12
local DEFAULT_SPACING = 2
-- Gap between our rows and EUI's, in the same units as the row spacing: the two
-- are one list, not two stacked panels.
local BLOCK_GAP = 2
local LABEL_GAP = "  "

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

    local function Row(label, body, value)
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
    for _, ev in ipairs({
        "PLAYER_EQUIPMENT_CHANGED",
        "PLAYER_AVG_ITEM_LEVEL_UPDATE",
        "PLAYER_SPECIALIZATION_CHANGED",
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
-- Entry: Lettered Plugin Buttons
-- ---------------------------------------------------------------------------
-- EllesmereUIMinimap gathers addon minimap buttons into a flyout grid, and a
-- grid is exactly where their art stops working: every addon drew its icon for
-- a 32px button sitting alone on the map ring, so eight of them side by side at
-- 24px is eight different styles, crops and brightnesses in one panel. This
-- replaces the art with the addon's initial, which unifies shape, size and
-- weight and leaves colour to do the identifying.
--
-- THE ICON'S OWN HUE IS NOT AVAILABLE. WoW has no pixel-sampling API -- nothing
-- can look at a texture's art and report what colour it is -- so the letter's
-- colour has to be declared rather than measured. LibDataBroker objects may
-- carry iconR/iconG/iconB, which is the colour the addon's own author chose for
-- its icon, and that is what this uses. Most objects do not set it, so those
-- fall back to a hue hashed from the addon's name: stable for the life of the
-- install, distinct between neighbours, and never the same answer twice for one
-- addon.
--
-- Buttons come from LibDBIcon's public API rather than from EllesmereUI. Its
-- own collected list and flyout panel are file-locals with nothing exported, so
-- there is no supported way to ask it what it grouped -- and no need, since
-- LibDBIcon owns the buttons it groups. That does mean a button you have
-- ungrouped onto the ring is lettered too. It looks deliberate either way, and
-- guessing at grouping from a frame's current parent would flicker with the
-- flyout's own lazy build.

local MIN_LUMA = 0.45   -- see ReadableColor
local LETTER_SCALE = 0.62

local letterEnabled = false
local letterHooked = {}
local letterCallbackOwner = {}

local function LDBIcon()
    return _G.LibStub and _G.LibStub("LibDBIcon-1.0", true) or nil
end

-- A hand-picked spread rather than a generated one: evenly spaced hues at a
-- fixed saturation produce muddy olives and near-blacks that read as "broken"
-- next to the declared colours they sit beside.
local PALETTE = {
    { 0.90, 0.36, 0.33 }, { 0.95, 0.57, 0.20 }, { 0.94, 0.79, 0.27 },
    { 0.55, 0.80, 0.33 }, { 0.30, 0.78, 0.35 }, { 0.20, 0.80, 0.62 },
    { 0.20, 0.74, 0.89 }, { 0.32, 0.58, 0.92 }, { 0.51, 0.47, 0.92 },
    { 0.68, 0.42, 0.88 }, { 0.89, 0.40, 0.68 }, { 0.80, 0.55, 0.42 },
}

-- Position-weighted so anagrams and shared prefixes land apart: plain byte sums
-- put "Details" and "Deadly" on neighbouring entries, which is the one case
-- where two buttons sitting next to each other must not match.
local function PaletteColor(name)
    local sum = 0
    for i = 1, #name do sum = sum + name:byte(i) * i end
    local c = PALETTE[(sum % #PALETTE) + 1]
    return c[1], c[2], c[3]
end

-- A declared colour can be anything, including values chosen to sit on a bright
-- icon rather than to be read as text on a dark panel. Hue and relative balance
-- are kept; the whole colour is lifted until it clears a legibility floor. An
-- unreadable letter is a bug, not fidelity.
local function ReadableColor(r, g, b)
    local luma = 0.299 * r + 0.587 * g + 0.114 * b
    if luma >= MIN_LUMA or luma <= 0 then return r, g, b end
    local lift = MIN_LUMA / luma
    return math.min(1, r * lift), math.min(1, g * lift), math.min(1, b * lift)
end

local function LetterColor(button, name)
    local obj = button.dataObject
    if type(obj) == "table" and (obj.iconR or obj.iconG or obj.iconB) then
        -- LibDBIcon's own defaulting: a partially declared colour fills the
        -- missing channels with white, exactly as Icon_UpdateIcon does.
        return ReadableColor(obj.iconR or 1, obj.iconG or 1, obj.iconB or 1)
    end
    return PaletteColor(name)
end

-- The first character that is actually a letter or digit. Names like
-- "!KalielsTracker" and "_NPCScan" sort themselves to the top of addon lists on
-- purpose, and their punctuation is not what anyone identifies them by.
local function ButtonLetter(name)
    local ch = name:match("[%a%d]")
    return (ch or name:sub(1, 1) or "?"):upper()
end

local function ApplyLetter(button, name)
    if not (button and button.icon) then return end

    local fs = button.AniModsLetter
    if not fs then
        fs = button:CreateFontString(nil, "OVERLAY")
        fs:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.AniModsLetter = fs
    end

    -- Sized off the button, not fixed: EllesmereUIMinimap has a button-size
    -- setting, and a letter that ignored it would be the one thing in the grid
    -- that did.
    local size = math.max(8, math.floor((button:GetHeight() or 24) * LETTER_SCALE + 0.5))
    AniMods.W.SetFont(fs, size, "OUTLINE")
    fs:SetText(ButtonLetter(name))
    fs:SetTextColor(LetterColor(button, name))
    fs:Show()

    button.icon:Hide()
end

local function RevertLetter(button)
    if not button then return end
    if button.AniModsLetter then button.AniModsLetter:Hide() end
    if button.icon then button.icon:Show() end
end

local function ForEachPluginButton(fn)
    local icons = LDBIcon()
    if not icons then return 0 end
    local n = 0
    for _, name in ipairs(icons:GetButtonList()) do
        -- GetButtonList returns NAMES -- it walks lib.objects and collects the
        -- keys (LibDBIcon-1.0.lua:451). The bundled annotations type it as
        -- returning buttons, which makes the lookup below look like a type
        -- error; it is the annotation that is wrong, so the suppression sits on
        -- this line rather than loosening anything.
        ---@diagnostic disable-next-line: param-type-mismatch
        local button = icons:GetMinimapButton(name)
        if button then
            n = n + 1
            fn(button, name)
        end
    end
    return n
end

local function ApplyAllLetters()
    if not letterEnabled then
        ForEachPluginButton(RevertLetter)
        return
    end
    ForEachPluginButton(function(button, name)
        ApplyLetter(button, name)
        -- Re-asserted when the button is shown rather than polled: the flyout
        -- shows and hides these, and an addon that swaps its icon later leaves
        -- our FontString alone but may put its own texture back.
        if not letterHooked[button] then
            letterHooked[button] = true
            button:HookScript("OnShow", function(self)
                if letterEnabled then ApplyLetter(self, name) end
            end)
        end
    end)
end

-- Addons that load late register their icon late, and LibDBIcon says so rather
-- than leaving it to be noticed. Registered once; the flag decides what it does.
local function EnsureLetterCallback()
    local icons = LDBIcon()
    if not icons or letterCallbackOwner.registered then return end
    if type(icons.RegisterCallback) ~= "function" then return end
    letterCallbackOwner.registered = true
    icons.RegisterCallback(letterCallbackOwner, "LibDBIcon_IconCreated",
        function(_, button, name)
            if letterEnabled then ApplyLetter(button, name) end
        end)
end

local LetteredButtonsEntry = {
    key = "letterButtons",
    name = "Lettered Plugin Buttons",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIMinimap") then
            return false, "EllesmereUIMinimap is not loaded, so there is no "
                       .. "button group to unify."
        end
        if not LDBIcon() then
            return false, "LibDBIcon is not loaded. It is what owns addon "
                       .. "minimap buttons, and nothing here can find them "
                       .. "without it."
        end
        return true
    end,
    Apply = function()
        letterEnabled = true
        EnsureLetterCallback()
        ApplyAllLetters()
        return true
    end,
    Revert = function()
        letterEnabled = false
        ForEachPluginButton(RevertLetter)
    end,
    GetInfoRows = function()
        local total, declared = 0, 0
        ForEachPluginButton(function(button)
            total = total + 1
            local obj = button.dataObject
            if type(obj) == "table" and (obj.iconR or obj.iconG or obj.iconB) then
                declared = declared + 1
            end
        end)
        return {
            {
                label = "Buttons lettered",
                value = tostring(total),
                help  = "Every addon minimap button LibDBIcon owns, which is "
                     .. "what EllesmereUI groups into its flyout. One you have "
                     .. "ungrouped onto the ring is lettered too -- there is no "
                     .. "supported way to ask EllesmereUI what it grouped.",
            },
            {
                label = "Using the addon's own colour",
                value = ("%d of %d"):format(declared, total),
                help  = "An icon's hue cannot be read -- WoW has no way to look "
                     .. "at a texture's art -- so the colour is the one the "
                     .. "addon declared through LibDataBroker. The rest get a "
                     .. "hue hashed from their name, stable for the life of the "
                     .. "install.",
            },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Entry framework
-- ---------------------------------------------------------------------------

local ENTRIES = { MissingStatsEntry, LetteredButtonsEntry }
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
