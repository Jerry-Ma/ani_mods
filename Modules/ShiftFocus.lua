-- ShiftFocus
-- Modifier + click on anything under the cursor sets it as your focus.
--
-- Ported from NDui_Plus (Modules/Combat/FocusMarker.lua) and
-- EllesmereUI_WindTools (Modules/UnitFrames/QuickFocus.lua). It takes TWO
-- mechanisms, and that is the whole shape of this module:
--
--   1. A hidden secure button carrying the macro, bound over the mouse:
--
--        button:SetAttribute("type*", "macro")
--        button:SetAttribute("macrotext", "/focus mouseover")
--        SetOverrideBindingClick(button, true, "SHIFT-BUTTON1", buttonName)
--
--      This covers the 3D world and nameplates.
--
--   2. The same macro as a secure attribute on each UNIT FRAME:
--
--        frame:SetAttribute("shift-type1", "macro")
--        frame:SetAttribute("shift-macrotext1", <the same text>)
--
-- Mechanism 2 is not redundant, and leaving it out is why the first version of
-- this module did nothing on unit frames. A mouse-button BINDING only fires
-- when nothing under the cursor takes the click. A unit frame is mouse-enabled
-- and handles its own clicks, so it swallows the button and the binding never
-- runs. The only thing that answers a click on a unit frame is an attribute on
-- that frame.
--
-- Finding the frames takes TWO routes, because one is not enough.
--
-- Most unit frames -- DandersFrames, Clique-compatible addons, EllesmereUI's
-- RAID frames -- announce themselves through the global ClickCastFrames
-- registry, so watching it reaches them as they spawn without walking the UI.
-- If something already owns that table's metatable (DandersFrames does exactly
-- this in its ClickCasting engine) the registry is NOT taken over: its entries
-- are walked instead, and re-walked on the events that spawn frames.
--
-- But the registry is opt-in, and EllesmereUI's UNIT frames never opt in, nor
-- do Blizzard's own. Those are reached by NAME instead -- see NAMED_FRAMES,
-- which also records how that gap was found.
--
-- WindTools sets the attribute to "focus", which sets the focus and nothing
-- else -- so its markers work from the binding and not from a unit frame.
-- "macro" with the same text is used here instead, so a click on a raid frame
-- does what a click in the world does, marker included. It costs no more
-- invasiveness: either way the modifier-click on that frame is claimed.
--
-- Three details are load-bearing, and each is a bug if missed:
--
--   * The button must be SHOWN. A hidden frame never processes a binding
--     click, so the override silently does nothing. WindTools has a comment
--     saying this cost it an off/on toggle to notice.
--   * RegisterForClicks has to match the ActionButtonUseKeyDown CVar, or the
--     binding fires on the opposite edge from every other click in the game.
--   * SetOverrideBindingClick and SetAttribute are both protected. Neither can
--     run in combat, so every path here is guarded and deferred.

local AniMods = _G.AniMods

local ShiftFocus = {
    title = "Shift Focus",
    description = "Modifier-click anything to set it as your focus.",
    dbKey = "shiftFocus",
    category = "Additions",
    conditions = {
        { text = "NDui not loaded",
          help = "NDui ships its own focus button (NDui_Plus extends it as "
              .. "FocusMarker), so this would be a second binding competing "
              .. "for the same click.",
          met = function() return not AniMods.IsAddOnLoaded("NDui") end },
        { text = "WindTools' Quick Focus is off",
          help = "EllesmereUI_WindTools ships this same feature, and two "
              .. "owners of the same modifier-click on the same unit frame "
              .. "means whichever wrote the attribute last wins. Its own "
              .. "setting is read rather than its presence, so having "
              .. "WindTools installed with Quick Focus off is fine.",
          met = function()
              local elv = _G.ElvUI
              local E = elv and elv[1]
              local wt = E and E.private and E.private.WT
              local qf = wt and wt.unitFrames and wt.unitFrames.quickFocus
              return not (qf and qf.enable)
          end },
    },
}

local BUTTON_NAME = "AniModsShiftFocusButton"

local MODIFIER_LABEL = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt" }
local MODIFIER_ORDER = { "SHIFT", "CTRL", "ALT" }

local MOUSE_LABEL = {
    BUTTON1 = "Left", BUTTON2 = "Right", BUTTON3 = "Middle",
    BUTTON4 = "Button 4", BUTTON5 = "Button 5",
}
local MOUSE_ORDER = { "BUTTON1", "BUTTON2", "BUTTON3", "BUTTON4", "BUTTON5" }

-- The eight raid target icons, as pictures. Blizzard ships them as individual
-- files, which is what a swatch wants -- the combined sheet would need
-- texcoords per marker for no gain.
local MARKER_ORDER, MARKER_TEXTURE = {}, {}
for i = 1, 8 do
    MARKER_ORDER[i] = i
    MARKER_TEXTURE[i] = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. i
end

local button
local moduleEnabled = true
local deferred = false
local watcher
local registryHooked = false

-- Frames seen during combat lockdown wait here; weak keys let a frame
-- destroyed mid-combat drop out instead of leaking.
local pending = setmetatable({}, { __mode = "k" })
-- Every frame carrying our attribute, and what we wrote, so cleanup and
-- rebinding touch our own frames instead of walking the UI.
local tracked = setmetatable({}, { __mode = "k" })

local function ModuleDB()
    AniModsDB.shiftFocus = AniModsDB.shiftFocus or {}
    return AniModsDB.shiftFocus
end

local function GetModifier()
    local v = ModuleDB().modifier
    return MODIFIER_LABEL[v] and v or "SHIFT"
end

local function GetMouseButton()
    local v = ModuleDB().button
    return MOUSE_LABEL[v] and v or "BUTTON1"
end

local function GetMark()
    local db = ModuleDB()
    if not db.mark then return nil end
    local v = db.markNumber
    if type(v) == "number" and v >= 1 and v <= 8 then return v end
    return 1
end

-- NDui_Plus's defaults, kept: marking is opt-in, and once on, the three
-- qualifiers are all on. They are the behaviours you would want if you thought
-- about each one, which is why that addon ships them true.
local function Opt(key)
    local v = ModuleDB()[key]
    if v == nil then return true end
    return v and true or false
end

-- ---------------------------------------------------------------------------
-- The macro
-- ---------------------------------------------------------------------------

-- Follows NDui_Plus (FocusMarker:GetMacroText) rather than inventing one.
-- Every clause earns its place:
--
--   /stopmacro [group:raid]   In a raid, markers are the leader's to manage
--                             and one person re-marking is actively unhelpful.
--                             Stopping here still leaves the focus SET -- only
--                             the marking is skipped.
--   [@focus,exists,harm,nodead]   Marks only a living hostile. Marking a
--                             friendly or a corpse is never what was meant.
--   ~N                        The tilde tells /tm to leave an existing marker
--                             alone rather than replace it, so a mark someone
--                             else placed survives.
local function MacroText()
    local lines = { "/focus mouseover" }
    local mark = GetMark()
    if mark then
        if Opt("disableInRaid") then
            lines[#lines + 1] = "/stopmacro [group:raid]"
        end
        local index = Opt("keepExisting") and ("~" .. mark) or tostring(mark)
        lines[#lines + 1] = "/tm [@focus,exists,harm,nodead] " .. index
    end
    return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Ready-check announcement
-- ---------------------------------------------------------------------------

-- NDui_Plus announces the focus marker on a ready check, which is the moment
-- everyone is looking at chat anyway. {rtN} is the client's own markup and
-- expands to the icon in the message.
--
-- Guarded on IsInGroup as well as NDui_Plus's not-IsInRaid: it sends to PARTY,
-- and SendChatMessage to a channel you are not in throws a UI error. Solo is
-- the common case for a stray ready check while testing.
local function AnnounceMarker()
    if not moduleEnabled then return end
    if not Opt("announce") then return end
    local mark = GetMark()
    if not mark then return end
    if _G.IsInRaid() or not _G.IsInGroup() then return end
    if not (_G.C_ChatInfo and _G.C_ChatInfo.SendChatMessage) then return end
    _G.C_ChatInfo.SendChatMessage(("My focus marker is {rt%d}"):format(mark), "PARTY")
end

-- ---------------------------------------------------------------------------
-- Unit frames
-- ---------------------------------------------------------------------------

-- Secure attribute prefixes are lowercase, and the click suffix is the digit
-- off the end of BUTTON1..BUTTON5 -- so SHIFT + BUTTON1 becomes "shift-type1".
local function AttrNames(modifier, mouseButton)
    local prefix = modifier:lower() .. "-"
    local suffix = mouseButton:sub(7, 7)
    return prefix .. "type" .. suffix, prefix .. "macrotext" .. suffix
end

local function ClearFrameAttributes(frame, binding)
    local typeAttr, textAttr = AttrNames(binding.modifier, binding.button)
    frame:SetAttribute(typeAttr, nil)
    frame:SetAttribute(textAttr, nil)
end

local function SetupFrame(frame)
    if not moduleEnabled then return end
    if type(frame) ~= "table" then return end
    if not (frame.GetAttribute and frame.SetAttribute and frame.GetName) then return end

    -- Nameplates are already covered by the binding, and they are recycled
    -- across units -- an attribute on one is the wrong tool. WindTools skips
    -- the same oUF nameplate prefix.
    local name = frame:GetName()
    if type(name) == "string" and name:match("oUF_NPs") then return end

    -- No unit, nothing to focus. Some registry entries are containers.
    if not frame.unit and not frame:GetAttribute("unit") then return end

    local modifier, mouseButton = GetModifier(), GetMouseButton()
    local text = MacroText()
    local binding = tracked[frame]
    if binding and binding.modifier == modifier and binding.button == mouseButton
        and binding.text == text then
        return
    end

    if _G.InCombatLockdown() then
        pending[frame] = true
        return
    end

    -- The modifier or button changed since this frame was set up: drop the
    -- stale attribute before writing the new one, or the old combination keeps
    -- working forever.
    if binding and (binding.modifier ~= modifier or binding.button ~= mouseButton) then
        ClearFrameAttributes(frame, binding)
    end

    local typeAttr, textAttr = AttrNames(modifier, mouseButton)
    frame:SetAttribute(typeAttr, "macro")
    frame:SetAttribute(textAttr, text)
    tracked[frame] = { modifier = modifier, button = mouseButton, text = text }
    pending[frame] = nil
end

local function TeardownFrame(frame)
    local binding = tracked[frame]
    if not binding or not frame.SetAttribute then return end
    pending[frame] = nil
    -- In combat the owner is almost certainly discarding the frame anyway, and
    -- the attribute goes with it.
    if _G.InCombatLockdown() then return end
    ClearFrameAttributes(frame, binding)
    tracked[frame] = nil
end

local function ClearAllFrames()
    if _G.InCombatLockdown() then return end
    for frame, binding in pairs(tracked) do
        if frame.SetAttribute then ClearFrameAttributes(frame, binding) end
        tracked[frame] = nil
    end
end

-- The frames that never announce themselves, reached by name.
--
-- ClickCastFrames only reaches frames whose author opts in, and two whole
-- families do not:
--
--   * EllesmereUI's UNIT frames -- player, target, focus, pet, the two
--     target-of-targets and the boss set. Its RAID frames do register, and even
--     those only while EUI's own click-casting is switched off (its
--     AddFrameToClickCast no-ops once its proxy owns the table), but the unit
--     frames are spawned by EUI_UnitFrames_Engine's SpawnUnitFrame and never
--     touch the registry at all. That is why shift-click did nothing on them
--     while working perfectly on raid frames.
--   * Blizzard's own, which predate the convention entirely -- so the module
--     was quietly failing its own promise on a stock UI too.
--
-- Both families are GLOBALLY NAMED, which keeps this a fixed list of lookups
-- rather than the walk of the UI this module set out to avoid: a name nothing
-- defines is simply nil and costs a hash miss.
local NAMED_FRAMES = {
    -- EllesmereUI, exactly the names its SpawnUnitFrame calls pass.
    "EllesmereUIUnitFrames_Player",
    "EllesmereUIUnitFrames_Target",
    "EllesmereUIUnitFrames_Focus",
    "EllesmereUIUnitFrames_Pet",
    "EllesmereUIUnitFrames_TargetTarget",
    "EllesmereUIUnitFrames_FocusTarget",
    -- Blizzard's.
    "PlayerFrame",
    "TargetFrame",
    "FocusFrame",
    "PetFrame",
    "TargetFrameToT",
    "FocusFrameToT",
}
-- Boss frames, both families. Counted past what either currently spawns
-- because an absent name is free and a new one would otherwise be missed.
for i = 1, 8 do
    NAMED_FRAMES[#NAMED_FRAMES + 1] = "EllesmereUIUnitFrames_Boss" .. i
    NAMED_FRAMES[#NAMED_FRAMES + 1] = "Boss" .. i .. "TargetFrame"
end

local function RefreshFrames()
    for frame in pairs(tracked) do SetupFrame(frame) end
    local registry = _G.ClickCastFrames
    if type(registry) == "table" then
        for frame, value in pairs(registry) do
            if value ~= nil and value ~= false then SetupFrame(frame) end
        end
    end
    -- After the registry, not instead of it: a frame reached both ways is set
    -- up once, since SetupFrame returns immediately when the attribute it would
    -- write is already there.
    for _, name in ipairs(NAMED_FRAMES) do
        local frame = _G[name]
        if frame then SetupFrame(frame) end
    end
end

-- The registry is shared ground. Taking over a metatable someone else installed
-- would cut their consumer out of their own registrations, so an existing owner
-- is left alone and its entries are read instead -- which is the live case
-- here, since DandersFrames installs one for its click-casting engine.
local function InstallRegistryHook()
    if registryHooked then return end
    registryHooked = true

    local registry = _G.ClickCastFrames

    if type(registry) == "table" and getmetatable(registry) then
        RefreshFrames()
        return
    end

    -- The local has to exist before the closure is defined, or `proxy` inside
    -- __newindex resolves to a nil global at runtime.
    local proxy = {}
    setmetatable(proxy, {
        __newindex = function(_, frame, value)
            -- Persisted, so a consumer that takes the table over later can
            -- still discover what was registered while we held it.
            rawset(proxy, frame, value)
            -- This runs inside other addons' frame-spawn paths, so an error
            -- here would surface as a bug in THEIR code. Never let one escape.
            if value == nil or value == false then
                xpcall(TeardownFrame, geterrorhandler(), frame)
            else
                xpcall(SetupFrame, geterrorhandler(), frame)
            end
        end,
    })

    _G.ClickCastFrames = proxy

    if type(registry) == "table" then
        for frame, value in pairs(registry) do proxy[frame] = value end
    end
end

-- ---------------------------------------------------------------------------
-- Binding
-- ---------------------------------------------------------------------------

local Apply

-- One watcher for everything, deliberately. An earlier version gave the
-- deferred rebind its own frame whose handler called UnregisterAllEvents, which
-- is a trap waiting for the second thing to be registered on it.
local function EnsureWatcher()
    if watcher then return end
    watcher = _G.CreateFrame("Frame")
    watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    watcher:RegisterEvent("READY_CHECK")
    -- Frames spawn and re-spawn with the group. Cheap to re-walk: SetupFrame
    -- returns immediately for a frame already carrying the right attribute.
    watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function(_, event)
        if event == "READY_CHECK" then
            AnnounceMarker()
        elseif event == "PLAYER_REGEN_ENABLED" then
            if deferred then
                deferred = false
                Apply()
            end
            for frame in pairs(pending) do SetupFrame(frame) end
        else
            RefreshFrames()
        end
    end)
end

Apply = function()
    if not button then return end
    if _G.InCombatLockdown() then
        deferred = true
        return
    end

    _G.ClearOverrideBindings(button)
    if not moduleEnabled then
        ClearAllFrames()
        return
    end

    button:SetAttribute("macrotext", MacroText())
    -- Matching the CVar matters: with ActionButtonUseKeyDown on, every other
    -- click in the game acts on press, and a binding that acts on release
    -- feels broken rather than different.
    local useKeyDown = _G.C_CVar.GetCVarBool("ActionButtonUseKeyDown")
    button:RegisterForClicks(useKeyDown and "AnyDown" or "AnyUp")
    _G.SetOverrideBindingClick(button, true,
        GetModifier() .. "-" .. GetMouseButton(), BUTTON_NAME)

    InstallRegistryHook()
    RefreshFrames()
end

local function Build()
    if button then return end
    button = _G.CreateFrame("Button", BUTTON_NAME, _G.UIParent, "SecureActionButtonTemplate")
    -- Shown, and deliberately so: a hidden frame never processes a binding
    -- click. Sized to nothing and anchored off-screen instead of hidden, so it
    -- takes no space and intercepts no real clicks.
    button:SetSize(1, 1)
    button:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", -100, -100)
    button:Show()
    button:SetAttribute("type*", "macro")
end

-- ---------------------------------------------------------------------------
-- Status panel
-- ---------------------------------------------------------------------------

local function CountTracked()
    local n = 0
    for _ in pairs(tracked) do n = n + 1 end
    return n
end

function ShiftFocus:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Binding" }
    rows[#rows + 1] = {
        label   = "Modifier",
        options = MODIFIER_LABEL,
        order   = MODIFIER_ORDER,
        get     = function() return GetModifier() end,
        set     = function(v) ModuleDB().modifier = v; Apply() end,
    }
    rows[#rows + 1] = {
        label   = "Mouse button",
        options = MOUSE_LABEL,
        order   = MOUSE_ORDER,
        get     = function() return GetMouseButton() end,
        set     = function(v) ModuleDB().button = v; Apply() end,
        help    = "The override only takes this click while the modifier is "
               .. "held, so the button keeps its normal job otherwise.",
    }
    rows[#rows + 1] = {
        label = "Currently bound",
        value = GetModifier() .. "-" .. GetMouseButton(),
    }
    rows[#rows + 1] = {
        label = "Unit frames wired",
        value = tostring(CountTracked()),
        help  = "A mouse-button binding only fires when nothing under the "
             .. "cursor takes the click, and a unit frame takes its own -- so "
             .. "each one needs the macro as an attribute of its own. This "
             .. "counts the frames carrying it, found two ways: the "
             .. "click-cast registry below, and a list of known names for the "
             .. "frames that never register -- EllesmereUI's unit frames and "
             .. "Blizzard's. Raid frames do not exist until there is a raid, "
             .. "so this number grows when you join one.",
    }

    rows[#rows + 1] = { section = "Raid marker" }
    rows[#rows + 1] = {
        label = "Mark the focus",
        get   = function() return ModuleDB().mark and true or false end,
        set   = function(v) ModuleDB().mark = v and true or false; Apply() end,
        help  = "Puts a raid target icon on whatever you just focused. Needs "
             .. "assist or lead in a group, and does nothing without.",
    }
    if ModuleDB().mark then
        -- The markers themselves, not their numbers. A row of eight digits
        -- asks you to remember that 8 is the skull; a row of eight icons does
        -- not ask anything.
        rows[#rows + 1] = {
            kind       = "swatches",
            label      = "Marker",
            order      = MARKER_ORDER,
            textures   = MARKER_TEXTURE,
            swatchSize = 20,
            get        = function() return GetMark() or 1 end,
            set        = function(v) ModuleDB().markNumber = v; Apply() end,
        }
        rows[#rows + 1] = {
            label = "Keep a marker already there",
            get   = function() return Opt("keepExisting") end,
            set   = function(v) ModuleDB().keepExisting = v; Apply() end,
            help  = "Adds the tilde to the macro, which tells the game to "
                 .. "leave an existing icon alone rather than replace it -- so "
                 .. "a mark someone else placed survives.",
        }
        rows[#rows + 1] = {
            label = "Do not mark in a raid",
            get   = function() return Opt("disableInRaid") end,
            set   = function(v) ModuleDB().disableInRaid = v; Apply() end,
            help  = "Markers are the leader's to manage in a raid, and one "
                 .. "person re-marking is actively unhelpful. The focus is "
                 .. "still set -- only the marking is skipped.",
        }
        rows[#rows + 1] = {
            label = "Announce on ready check",
            get   = function() return Opt("announce") end,
            set   = function(v) ModuleDB().announce = v end,
            help  = "Says which marker is your focus in party chat when a "
                 .. "ready check starts, as NDui_Plus does. Party only, and "
                 .. "only while actually in one.",
        }
    end

    rows[#rows + 1] = { section = "Status" }
    rows[#rows + 1] = {
        label = "Waiting for combat to end",
        state = deferred,
        help  = "Changing an override binding or a secure attribute is blocked "
             .. "in combat, so a change made mid-fight is applied when it ends.",
    }
    rows[#rows + 1] = {
        label = "Click-cast registry",
        value = getmetatable(_G.ClickCastFrames or {}) and "shared" or "none",
        help  = "Unit frames announce themselves through the global "
             .. "ClickCastFrames table. Another addon owning its metatable is "
             .. "the normal case and is never fought: its entries are read and "
             .. "re-read when the group changes instead.",
    }

    return rows
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function ShiftFocus:Enable()
    moduleEnabled = true
    Build()
    EnsureWatcher()
    AniMods.W.OnReady(Apply)
end

-- Toggles live: the binding is cleared outright and every frame attribute is
-- removed, so the click goes back to whatever it does normally the moment this
-- is switched off.
function ShiftFocus:SetEnabled(on)
    moduleEnabled = on and true or false
    Apply()
    return true
end

AniMods.RegisterModule("ShiftFocus", ShiftFocus)
