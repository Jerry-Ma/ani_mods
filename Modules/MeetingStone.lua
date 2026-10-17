-- MeetingStone -- make its main window the size you want it.
--
-- The window is 922x447 and always has been: MeetingStone sets it once, in
-- MainPanel.lua's OnInitialize, and offers no setting for it. There is a
-- `uiscale` setting, which is not the same thing -- scaling makes the window
-- bigger AND the text bigger, so the activity list still shows the same
-- number of rows, just larger. Size is what changes how much you can see.
--
-- THREE THINGS HAD TO BE TRUE for this to be worth doing rather than a resize
-- that leaves a broken window, and all three were checked in their source
-- rather than assumed:
--
--   The frame art stretches. NetEaseGUI's Frame.xml anchors every border bar
--   by two points -- TOPLEFT to the left corner, TOPRIGHT to the right one --
--   with only the corners at a fixed 60x60. That is the ordinary nine-slice
--   arrangement, and it is what makes a wider window keep its border instead
--   of tearing it.
--
--   The content follows. Panel:SetTopHeight and SetBottomHeight place the
--   inset by offsets from the panel's own edges, and each content panel does
--   SetAllPoints on it, so everything inside is edge-relative already.
--
--   The lists actually use the room. ListView:OnSizeChanged clears maxCount
--   and re-lays out, so a taller window draws more activity rows rather than
--   the same rows with blank space under them. That is the entire point: a
--   resize that showed no more than before would be a worse-looking window.
--
-- Nothing else in MeetingStone, MeetingStoneEX or the EllesmereUI skin reads
-- 922 or 447, so there is no second place holding the old number.
--
-- The size is re-applied when the window opens, not just once at login. The
-- window is not ours, and a skin or an update that sets its own size gets the
-- last word at load; applying on show means this does.

local AniMods = _G.AniMods

local W = AniMods.W

-- What MeetingStone itself uses. The floor as well as the default: the top
-- band is a fixed 80 units and the tab strip sits below the inset, so a window
-- shorter than this is one with its own chrome clipping the list it is for.
local NATIVE_W, NATIVE_H = 922, 447

local MeetingStone = {
    title = "Meeting Stone",
    description = "Resize Meeting Stone's main window.",
    dbKey = "meetingStone",
    category = "Addon Extras",
    conditions = {
        { text = "MeetingStone loaded",
          help = "This resizes MeetingStone's own window, so it needs it.",
          met = function() return AniMods.IsAddOnLoaded("MeetingStone") end },
    },
}

local moduleEnabled = true
local hooked = false

local function ModuleDB()
    AniModsDB.meetingStone = AniModsDB.meetingStone or {}
    return AniModsDB.meetingStone
end

--- The window, or nil before MeetingStone has built it.
---
--- A presence check on ANOTHER ADDON's frame, which is the kind that earns
--- one: MeetingStone publishes it as a global at the end of its own
--- OnInitialize, so there is a window in which it is legitimately not there.
local function Panel()
    return _G.MeetingStoneMainPanel
end

--- The size to use: what is set, or what MeetingStone would have used.
--- Stored as nil rather than as the native number when unset, so a future
--- MeetingStone that ships a different default is followed rather than pinned
--- to today's.
local function Wanted()
    local db = ModuleDB()
    return db.width or NATIVE_W, db.height or NATIVE_H
end

local function Apply()
    local panel = Panel()
    if not panel then return end

    local w, h = Wanted()
    if not moduleEnabled then w, h = NATIVE_W, NATIVE_H end

    -- Compared before writing: SetSize on an unchanged frame still fires
    -- OnSizeChanged, and every list inside rebuilds its rows when it does.
    local curW, curH = panel:GetWidth(), panel:GetHeight()
    if math.abs(curW - w) < 0.5 and math.abs(curH - h) < 0.5 then return end
    panel:SetSize(w, h)
end

--- Re-apply whenever the window opens. HookScript rather than a replacement,
--- so MeetingStone's own OnShow -- which restores the saved position and asks
--- its blockers to update -- still runs.
local function Hook()
    local panel = Panel()
    if hooked or not panel then return end
    hooked = true
    panel:HookScript("OnShow", Apply)
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

--- The biggest the window can usefully be: the screen it has to fit on.
--- Read fresh rather than kept, because it changes with resolution and with
--- the UI scale, and a slider that still offers last session's ceiling is
--- offering a size that no longer fits.
local function Ceiling()
    local scale = Panel() and Panel():GetScale() or 1
    if scale <= 0 then scale = 1 end
    return math.max(NATIVE_W, math.floor(_G.UIParent:GetWidth() / scale)),
           math.max(NATIVE_H, math.floor(_G.UIParent:GetHeight() / scale))
end

function MeetingStone:GetInfoRows()
    local rows = {}
    local db = ModuleDB()
    local panel = Panel()
    local maxW, maxH = Ceiling()

    rows[#rows + 1] = { section = "Window" }
    rows[#rows + 1] = {
        label = "Current size",
        value = panel
            and ("%d x %d"):format(panel:GetWidth() + 0.5, panel:GetHeight() + 0.5)
            or "not built yet",
        help  = "What the window is right now. MeetingStone's own default is "
             .. NATIVE_W .. " x " .. NATIVE_H .. ".",
    }
    rows[#rows + 1] = {
        label = "Width",
        min = NATIVE_W, max = maxW, step = 2,
        get = function() return db.width or NATIVE_W end,
        set = function(v)
            db.width = (v > NATIVE_W) and v or nil
            Apply()
        end,
    }
    rows[#rows + 1] = {
        label = "Height",
        min = NATIVE_H, max = maxH, step = 2,
        help = "Taller shows more activities: the list works out how many rows "
            .. "fit each time the window changes size.",
        get = function() return db.height or NATIVE_H end,
        set = function(v)
            db.height = (v > NATIVE_H) and v or nil
            Apply()
        end,
    }
    rows[#rows + 1] = {
        kind = "button", button = "Back to MeetingStone's own size",
        help = "Forgets both settings. The window then follows whatever "
            .. "MeetingStone ships, rather than being pinned to today's "
            .. "numbers.",
        onClick = function()
            db.width, db.height = nil, nil
            Apply()
        end,
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MeetingStone:Enable()
    moduleEnabled = true
    -- Deferred: MeetingStone publishes the window during its own load, so
    -- asking at file scope finds nothing on a login where it loads after us.
    W.OnReady(function()
        Hook()
        Apply()
    end)
end

--- Switching off puts the window back to MeetingStone's size rather than
--- leaving it at whatever this last set. The settings are kept, so switching
--- on again restores them.
function MeetingStone:SetEnabled(on)
    moduleEnabled = on and true or false
    Apply()
    return true
end

AniMods.RegisterModule("MeetingStone", MeetingStone)
