-- ActionBarSwap -- say so when the main action bar is not on page 1.
--
-- /swapactionbar 1 2 is a toggle, and a toggle has no memory. You press it to
-- reach your second page, something happens, and the only thing that tells you
-- which page you are on is recognising your own buttons -- which is exactly
-- what you cannot do at a glance when the pages are deliberately similar.
-- Pressing the swap again to check is a coin toss that costs you a global.
--
-- So this watches the page and says, in the same place Gear Sync says a set is
-- wrong, that the bar is swapped. It is the same shape of mistake: a thing
-- that is quietly true, that you set yourself, and that you will not notice
-- until it matters.
--
-- WHAT COUNTS AS SWAPPED. Page 1 is home and anything else is not, rather than
-- page 2 specifically. The swap macro names a pair, but the page can also move
-- for reasons that have nothing to do with it -- a bonus bar from a vehicle or
-- a form, another addon's paging -- and "you are not on your own bar" is true
-- and worth saying in every one of those cases. Naming the page in the message
-- means a reason that is not the swap macro still reads correctly.
--
-- ACTIONBAR_PAGE_CHANGED is the whole event list. The page is a single number
-- the game changes and announces; there is nothing to poll and nothing to
-- derive.

local AniMods = _G.AniMods

local HOME_PAGE = 1

local ActionBarSwap = {
    title = "Action Bar Swap",
    description = "Warns when your main action bar is on a swapped page.",
    dbKey = "actionBarSwap",
    category = "At a Glance",
    -- No conditions: the page is Blizzard's and exists whatever else is
    -- loaded. Whether the warning goes anywhere is the warning channel's
    -- business, and it says so itself when there is nowhere to put it.
}

local moduleEnabled = true
local warning = AniMods.Warn.New("AniModsActionBarSwap")

local function ModuleDB()
    AniModsDB.actionBarSwap = AniModsDB.actionBarSwap or {}
    return AniModsDB.actionBarSwap
end

local function WarnEnabled()
    return ModuleDB().warn ~= false
end

--- The page the main bar is set to, which is what the swap macro changes.
local function CurrentPage()
    return _G.GetActionBarPage() or HOME_PAGE
end

local function IsSwapped()
    return CurrentPage() ~= HOME_PAGE
end

local function Update()
    if not (moduleEnabled and WarnEnabled() and IsSwapped()) then
        warning:Show(nil)
        return
    end
    warning:Show(("Action bar swapped: page %d"):format(CurrentPage()))
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

function ActionBarSwap:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Action bar page",
        value = IsSwapped()
            and ("|cffffa640%d, swapped|r"):format(CurrentPage())
            or "1",
        help  = "Page 1 is your own bar. /swapactionbar 1 2 moves you to "
             .. "another page and back, and the page can also move on its own "
             .. "-- a vehicle, a form, another addon's paging.",
    }

    for _, row in ipairs(AniMods.Warn.SectionRows(ModuleDB, Update,
        "Says so while the bar is on any page but 1. The swap is a toggle "
        .. "with no memory, so the only other way to tell is to recognise "
        .. "your own buttons -- which is the thing you cannot do at a glance "
        .. "when the pages are deliberately similar.")) do
        rows[#rows + 1] = row
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ActionBarSwap:Enable()
    moduleEnabled = true

    local watcher = _G.CreateFrame("Frame")
    watcher:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
    -- The page survives a reload, so the first answer has to come from asking
    -- rather than from waiting for it to change.
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function()
        Update()
        if AniMods.RefreshUI then AniMods.RefreshUI() end
    end)

    AniMods.W.OnReady(Update)
end

--- Switching off takes the line down rather than leaving it standing: the
--- module is the only thing that would ever clear it.
function ActionBarSwap:SetEnabled(on)
    moduleEnabled = on and true or false
    Update()
    return true
end

AniMods.RegisterModule("ActionBarSwap", ActionBarSwap)
