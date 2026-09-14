-- EllesmereUI Misc
-- The bag for small EllesmereUI-only tweaks -- one-off "it should look like it
-- belongs" fixes that are too slight to be modules of their own, each an
-- independently switchable ENTRY (see ENTRIES below) rather than one bundled
-- all-or-nothing setting. Two so far:
--
--   Chat Read Aloud -- Blizzard's chat "read aloud" toggle
--   (TextToSpeechButton), re-homed into EllesmereUIChat's sidebar icon row.
--   Minimap Group Button -- the icon on EllesmereUIMinimap's own group button
--   (the addon-icon flyout toggle in the row outside the minimap), swappable
--   and re-tinted light rather than accent-green.
--
-- It was called "Skin", which named the technique rather than the subject and
-- would have been wrong the moment something in here did not restyle anything
-- -- which is the point of a bag. What every entry has in common is that it
-- needs EllesmereUI, so that is what the module is named for.
--
-- The bar for adding an entry here: it touches EllesmereUI specifically, it is
-- small enough that a whole module would be ceremony, and it is REVERSIBLE.
-- That last one is not decoration -- these apply and revert live, which is why
-- this module escapes the framework's usual "toggling takes effect next
-- reload" rule (see README), and an irreversible entry would quietly take that
-- property away from every other entry in the bag.

local EUIMisc = {
    title = "EllesmereUI Misc",
    description = "Small tweaks to EllesmereUI's own elements.",
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

-- Settings shared by the entries below (each entry's own enable flag lives
-- in EntryDB). Declared up here because Lua only closes over locals declared
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
-- Entry: TTS Button
-- ---------------------------------------------------------------------------
-- EllesmereUIChat hides several Blizzard chat chrome buttons it replaces
-- with its own sidebar icons (QuickJoinToastButton, ChatFrameMenuButton,
-- ChatFrameChannelButton, the voice mute/deafen buttons -- see the
-- "Hide Blizzard social buttons" block in EllesmereUIChat.lua), but
-- TextToSpeechButton isn't in that list, so it's normally left floating in
-- its default Blizzard position, disconnected from EUI's redesigned chat
-- frame. This suppresses it the same way EUI suppresses the others
-- (SetAlpha(0) + EnableMouse(false) -- not :Hide(), since Blizzard's own
-- layout code can silently re-show a hidden frame; alpha+mouse is the
-- taint-free way to make a Blizzard-owned frame invisible and inert) and
-- adds an equivalent button into EUI's own sidebar icon chain instead.
--
-- The replacement doesn't reimplement TTS toggling itself -- nobody in this
-- AddOns folder references whatever CVar/API actually drives it, so
-- guessing would risk a button that silently does nothing. Instead it's a
-- thin proxy: clicking it calls TextToSpeechButton:Click() (the real
-- thing), and its icon is copied live from the real button's own
-- texture/atlas, so it shows whatever Blizzard is actually displaying
-- (including any on/off state change) without needing to know what drives
-- that state.

local function GetEllesmereUIChatNS()
    local eui = _G.EllesmereUI
    return eui and eui._ModuleNS and eui._ModuleNS["EllesmereUIChat"]
end

-- EllesmereUIChat.lua exposes `EllesmereUI._chatCFD = CFD`, its internal
-- per-chat-frame state accessor (`CFD(cf).sidebar`, `.scrollBtn`, etc.) --
-- a plain read, no different in spirit from GroupRoles reading
-- `_G.EllesmereUIRaidToolsIcon` or `_G._EUI_RaidTools_DB()`.
local function GetChatSidebarData()
    local eui = _G.EllesmereUI
    local cfd = eui and eui._chatCFD
    local cf = _G.ChatFrame1
    if not (cfd and cf) then return nil end
    return cfd(cf)
end

local function ChatModuleEnabled()
    local ns = GetEllesmereUIChatNS()
    local echat = ns and ns.ECHAT
    if not (echat and echat.DB) then return nil end -- unknown -- not loaded far enough yet
    local ok, db = pcall(echat.DB)
    if not ok or not db then return nil end
    return db.enabled ~= false
end

-- Matches EllesmereUIChat's own MakeSidebarIcon() constants exactly (that
-- function is private to EllesmereUIChat.lua, not something we can call, so
-- this just reproduces the same look rather than sharing the code).
local TTS_ICON_SIZE = 22
local TTS_ICON_SPACING = 10
local TTS_ICON_ALPHA = 0.4
local TTS_ICON_HOVER_ALPHA = 0.9

local ttsProxy       -- our sidebar-styled button, once built
local ttsReal         -- the real Blizzard button, cached once found
local ttsIconFound = false -- true if we managed to copy a real icon (see GetInfoRows)

-- Not every Blizzard icon button sets its icon via SetNormalTexture/
-- SetCheckedTexture/SetPushedTexture -- some just draw a plain child Texture
-- region instead, which those getters won't see. Falling back to scanning
-- the button's regions for the first real Texture covers that case too,
-- without needing to know exactly how TextToSpeechButton itself is built.
local function GetRealTTSTexture(real)
    if real.GetNormalTexture and real:GetNormalTexture() then return real:GetNormalTexture() end
    if real.GetCheckedTexture and real:GetCheckedTexture() then return real:GetCheckedTexture() end
    if real.GetPushedTexture and real:GetPushedTexture() then return real:GetPushedTexture() end
    for _, region in ipairs({ real:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture"
            and (region:GetTexture() or (region.GetAtlas and region:GetAtlas())) then
            return region
        end
    end
    return nil
end

-- Returns true if an icon was actually copied over.
local function SyncTTSIcon(icon, real)
    local tex = GetRealTTSTexture(real)
    if not tex then return false end
    local atlas = tex.GetAtlas and tex:GetAtlas()
    if atlas and atlas ~= "" then
        icon:SetAtlas(atlas)
        return true
    end
    local file = tex:GetTexture()
    if file then
        icon:SetTexture(file)
        icon:SetTexCoord(tex:GetTexCoord())
        return true
    end
    return false
end

local function BuildTTSButton(sidebar, anchorTo, real)
    local btn = CreateFrame("Button", nil, sidebar)
    btn:SetSize(TTS_ICON_SIZE, TTS_ICON_SIZE)
    btn:SetPoint("BOTTOM", anchorTo, "TOP", 0, TTS_ICON_SPACING)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetDesaturated(true)
    ttsIconFound = SyncTTSIcon(icon, real)
    icon:SetShown(ttsIconFound)

    -- Fallback if the real button's icon couldn't be located/copied (its
    -- exact internal texture setup isn't something to rely on) -- better a
    -- plain "T" label than an invisible, unexplained dead click zone.
    local label
    if not ttsIconFound then
        label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetText("T")
    end

    local function SetFade(a)
        icon:SetVertexColor(1, 1, 1, a)
        if label then label:SetTextColor(1, 1, 1, a) end
    end
    SetFade(TTS_ICON_ALPHA)

    btn:HookScript("OnEnter", function() SetFade(TTS_ICON_HOVER_ALPHA) end)
    btn:HookScript("OnLeave", function() SetFade(TTS_ICON_ALPHA) end)

    btn:SetScript("OnClick", function()
        if not real.IsEnabled or real:IsEnabled() then
            real:Click()
        end
        -- Resync next frame in case the click flipped an on/off state that
        -- changes the real button's own texture (only matters once an icon
        -- was found at all -- the fallback label doesn't track state).
        if label then return end
        C_Timer.After(0, function()
            if SyncTTSIcon(icon, real) then icon:Show() end
        end)
    end)

    return btn
end

-- Two ways to deal with the button, because rehoming it turned out not to
-- look good: Blizzard's icon is a filled speech-bubble glyph, and even
-- desaturated and alpha-matched it reads as a foreign blob next to
-- EllesmereUIChat's thin line-art sidebar icons. Hiding it is the default --
-- that is what EUI itself does with every other Blizzard chat chrome button
-- it doesn't want (QuickJoinToastButton, ChatFrameMenuButton, ...).
-- "EUI" spelled out: the panel says EllesmereUI everywhere else, and one
-- abbreviation in one dropdown reads as a different thing being named.
local TTS_MODE_LABEL = { hide = "Hide", sidebar = "Move to chat sidebar" }
local TTS_MODE_ORDER = { "hide", "sidebar" }

local function GetTTSMode()
    local mode = MiscDB().ttsMode
    if mode and TTS_MODE_LABEL[mode] then return mode end
    return "hide"
end

-- Forward-declared so the Mode dropdown below can re-run it; assigned right
-- after the entry table is built.
local ApplyTTS

local TTSEntry = {
    key = "tts",
    -- Named for what it is to the player, not for the API. "TTS Button" was the
    -- Blizzard frame's name; nobody looking for this thinks of it that way.
    name = "Chat Read Aloud",
    -- Reasons are whole sentences: they are the "?" tooltip on the Available
    -- row now, not a parenthetical crammed into a value.
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIChat") then
            return false, "EllesmereUIChat is not loaded, so there is no chat "
                       .. "sidebar to move the button into."
        end
        if ChatModuleEnabled() == false then
            return false, "EllesmereUI's chat module is switched off, so it "
                       .. "builds no sidebar."
        end
        return true
    end,
    -- Idempotent, and safe to call again after Revert() to re-apply live.
    Apply = function()
        local real = ttsReal or _G.TextToSpeechButton
        if not real then return false end
        ttsReal = real

        local wantSidebar = GetTTSMode() == "sidebar"

        if wantSidebar and not ttsProxy then
            -- Only needs EUI's sidebar for this mode; hiding works whether or
            -- not the sidebar has been built yet.
            local sbd = GetChatSidebarData()
            local sidebar = sbd and sbd.sidebar
            local scrollBtn = sbd and sbd.scrollBtn
            if not (sidebar and scrollBtn) then return false end
            ttsProxy = BuildTTSButton(sidebar, scrollBtn, real)
        end

        if ttsProxy then ttsProxy:SetShown(wantSidebar) end

        -- Suppressed either way: hidden outright, or replaced by the proxy.
        real:SetAlpha(0)
        real:EnableMouse(false)
        return true
    end,
    Revert = function()
        if ttsProxy then ttsProxy:Hide() end
        if ttsReal then
            ttsReal:SetAlpha(1)
            ttsReal:EnableMouse(true)
        end
    end,
    GetInfoRows = function()
        local rows = {
            {
                label = "Blizzard's button found",
                state = _G.TextToSpeechButton and true or false,
                help  = (not _G.TextToSpeechButton)
                    and "This client has no TextToSpeechButton to re-home."
                    or nil,
            },
            {
                -- "Mode" said nothing on its own. The label names the thing
                -- being decided about, and the options say what happens to it.
                label   = "Blizzard's button",
                options = TTS_MODE_LABEL,
                order   = TTS_MODE_ORDER,
                get     = GetTTSMode,
                set     = function(v)
                    MiscDB().ttsMode = v
                    if ApplyTTS then ApplyTTS() end
                end,
            },
        }
        -- Only once there is a proxy to have copied an icon ONTO. This row used
        -- to render "N/A" in that gap, which is not an answer to the question
        -- it asks -- a question that does not apply yet is better not asked.
        if GetTTSMode() == "sidebar" and ttsProxy then
            rows[#rows + 1] = {
                label = "Icon copied from Blizzard",
                state = ttsIconFound,
                help  = (not ttsIconFound)
                    and "Blizzard's button had no icon texture to copy, so the "
                     .. "sidebar entry shows a \"T\" label instead."
                    or nil,
            }
        end
        return rows
    end,
}
ApplyTTS = TTSEntry.Apply

-- ---------------------------------------------------------------------------
-- Entry: Minimap Group Button Icon
-- ---------------------------------------------------------------------------
-- EllesmereUIMinimap's "group button" -- the toggle in its extra-button row
-- just outside the minimap that collapses addon minimap icons into a flyout
-- (EllesmereUIMinimap.lua's CreateFlyoutToggle; its config key is literally
-- `hideExtraBtns.groupButton`, commented there as "EUI group button for addon
-- icons"). It draws with the `Map-Filter-Button` atlas -- a map FILTER funnel,
-- which reads as borrowed rather than designed for this -- accent-tinted.
--
-- Not to be confused with Blizzard's AddonCompartmentFrame: that is the
-- addon *collector* in MinimapCluster, and an earlier version of this entry
-- skinned it by mistake. EllesmereUIMinimap only repositions that one; this
-- is the button actually visible in the row outside the minimap.
--
-- The button is unnamed (`CreateFrame("Button", nil, Minimap)`) and its
-- reference is a file-local, so it's found by structure instead: it's the
-- only child of Minimap carrying all three of `_norm`/`_pushed`/`_hl` (the
-- indicator buttons in the same row use `_icon`/`_upAtlas`/`_indicatorKey`).

local FLYOUT_ICON_LABEL = {
    filter = "EllesmereUI default (filter)",
    gear   = "Gear",
    group  = "Group",
    bag    = "Bag",
}
local FLYOUT_ICON_ORDER = { "filter", "gear", "group", "bag" }
-- Candidates, not guarantees: these names came from DandersFrames_Options'
-- atlas browser list, which that browser itself filters through
-- C_Texture.GetAtlasInfo at runtime -- so appearing there never meant the
-- atlas exists in this client, and a missing one draws nothing at all with
-- no error. The dropdown below only offers the ones that actually resolve.
-- "filter" is EUI's own and is known to render, since EUI draws it today.
local FLYOUT_ICON_ATLAS = {
    filter = "Map-Filter-Button",
    gear   = "options-icon",
    group  = "communities-icon-addgroupplus",
    bag    = "bags-icon-addslots",
}
-- Only EUI's own icon ships a distinct pressed variant.
local FLYOUT_PUSHED_ATLAS = { filter = "Map-Filter-Button-down" }

local FLYOUT_TINT_LABEL = { light = "Light", accent = "EllesmereUI accent" }
local FLYOUT_TINT_ORDER = { "light", "accent" }

-- Only the styles whose atlas actually exists in this client, so the picker
-- can't offer one that would render as an empty button.
local function UsableFlyoutIcons()
    local order = {}
    for _, key in ipairs(FLYOUT_ICON_ORDER) do
        if AniMods.W.AtlasExists(FLYOUT_ICON_ATLAS[key]) then order[#order + 1] = key end
    end
    return order
end

local function GetFlyoutIcon()
    local key = MiscDB().flyoutIcon
    if key and AniMods.W.AtlasExists(FLYOUT_ICON_ATLAS[key]) then return key end
    -- Fall back to the first that resolves, preferring the configured
    -- default; "filter" (EUI's own) is last-resort since it always works.
    local usable = UsableFlyoutIcons()
    for _, preferred in ipairs({ "gear", "group", "bag" }) do
        -- `candidate`, not `key`: shadowing the configured-key local above
        -- makes this read as though it were still about that value.
        for _, candidate in ipairs(usable) do
            if candidate == preferred then return candidate end
        end
    end
    return usable[1] or "filter"
end

local function GetFlyoutTint()
    local key = MiscDB().flyoutTint
    if key and FLYOUT_TINT_LABEL[key] then return key end
    return "light"
end

local flyoutBtn            -- EUI's group button, once found
local flyoutSkinned = false -- whether our skin is currently meant to be on
local flyoutHooked = false  -- one-shot guard: hooksecurefunc can't be undone
local applyingFlyout = false -- re-entrancy guard for the re-assert hooks

local function FindFlyoutToggle()
    local minimap = _G.Minimap
    if not minimap then return nil end
    for _, child in ipairs({ minimap:GetChildren() }) do
        -- _norm/_pushed/_hl are EllesmereUI's own private fields on its
        -- flyout toggle. Probing for them IS the identification: the button
        -- is created unnamed, so its field shape is the only handle on it.
        -- LuaLS is right that they aren't part of any widget type -- that is
        -- the point, so the warning is suppressed at exactly this line
        -- rather than by loosening the check everywhere.
        ---@diagnostic disable-next-line: undefined-field
        if child._norm and child._pushed and child._hl then return child end
    end
    return nil
end

local function FlyoutTextures()
    if not flyoutBtn then return {} end
    return { flyoutBtn._norm, flyoutBtn._pushed, flyoutBtn._hl }
end

local function ApplyFlyoutSkin()
    if not flyoutBtn or applyingFlyout then return end
    applyingFlyout = true

    local iconKey = GetFlyoutIcon()
    local normal = FLYOUT_ICON_ATLAS[iconKey]
    local pushed = FLYOUT_PUSHED_ATLAS[iconKey] or normal

    local r, g, b
    if GetFlyoutTint() == "accent" then
        r, g, b = AniMods.W.Accent()
    else
        r, g, b = 0.9, 0.9, 0.9
    end

    for i, tex in ipairs(FlyoutTextures()) do
        if tex then
            tex:SetAtlas(i == 2 and pushed or normal)
            tex:SetDesaturated(true)
            tex:SetVertexColor(r, g, b, 1)
        end
    end

    applyingFlyout = false
end

local GroupButtonEntry = {
    key = "minimapGroupButton",
    -- "Icon" dropped from the name: the entry's own rows already say Icon and
    -- Tint, so the section header only has to say which button.
    name = "Minimap Group Button",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIMinimap") then
            return false, "EllesmereUIMinimap is not loaded, so its group "
                       .. "button does not exist."
        end
        return true
    end,
    Apply = function()
        flyoutBtn = flyoutBtn or FindFlyoutToggle()
        if not flyoutBtn then return false end

        flyoutSkinned = true
        ApplyFlyoutSkin()

        -- EUI re-asserts this button's accent on its own (CreateFlyoutToggle
        -- re-tints all three textures on a later ApplyAll, and each is in
        -- EUI's RegAccent registry, so a theme change calls SetVertexColor on
        -- them too). Re-assert on the actual mutation rather than polling;
        -- applyingFlyout keeps our own writes from re-entering the hook.
        if not flyoutHooked then
            flyoutHooked = true
            for _, tex in ipairs(FlyoutTextures()) do
                if tex then
                    local function Reassert()
                        if flyoutSkinned then ApplyFlyoutSkin() end
                    end
                    hooksecurefunc(tex, "SetAtlas", Reassert)
                    hooksecurefunc(tex, "SetVertexColor", Reassert)
                end
            end
        end

        return true
    end,
    Revert = function()
        flyoutSkinned = false
        if not flyoutBtn then return end
        applyingFlyout = true
        local r, g, b = AniMods.W.Accent()
        for i, tex in ipairs(FlyoutTextures()) do
            if tex then
                tex:SetAtlas(i == 2 and "Map-Filter-Button-down" or "Map-Filter-Button")
                tex:SetDesaturated(true)
                tex:SetVertexColor(r, g, b, 1)
            end
        end
        applyingFlyout = false
    end,
    GetInfoRows = function()
        local rows = {
            {
                label = "EllesmereUI group button found",
                state = flyoutBtn and true or false,
                help  = (not flyoutBtn)
                    and "Appears once EllesmereUIMinimap has built its "
                     .. "extra-button row beside the minimap."
                    or nil,
            },
        }
        if not flyoutBtn then return rows end

        rows[#rows + 1] = {
            label   = "Icon",
            options = FLYOUT_ICON_LABEL,
            order   = UsableFlyoutIcons(),
            get     = GetFlyoutIcon,
            set     = function(v) MiscDB().flyoutIcon = v; ApplyFlyoutSkin() end,
            atlas   = FLYOUT_ICON_ATLAS[GetFlyoutIcon()],
        }
        rows[#rows + 1] = {
            label   = "Tint",
            options = FLYOUT_TINT_LABEL,
            order   = FLYOUT_TINT_ORDER,
            get     = GetFlyoutTint,
            set     = function(v) MiscDB().flyoutTint = v; ApplyFlyoutSkin() end,
        }
        return rows
    end,
}

-- ---------------------------------------------------------------------------
-- Extra action button: stop its artwork eating clicks
-- ---------------------------------------------------------------------------
-- The zone/extra ability button draws a decorative surround that is much
-- larger than the button, and that surround takes the mouse. Clicks landing on
-- the art near the button hit nothing, and anything underneath it -- an action
-- bar, a unit frame -- is unreachable while the button is up.
--
-- Ported from EUI_Kogotool (Core/Gameplay/BlizzUIEnhance.lua), which switches
-- the mouse off on three frames: the bar frame, the container, and the zone
-- ability's Style. The BUTTON itself is untouched and stays clickable -- only
-- the decoration stops intercepting.
--
-- Two things NOT copied from the source. Its apply function ignores its own
-- setting, so switching the option off still disabled the mouse; here Revert
-- actually puts it back. And it guards combat on one of the three frames only,
-- while all three are protected -- EnableMouse on a protected frame in combat
-- is blocked, so every one is guarded and the work is deferred.

local EXTRA_FRAMES = {
    { name = "ExtraActionBarFrame" },
    { name = "ExtraAbilityContainer" },
    -- The zone ability's surround is a child, not the frame itself.
    { name = "ZoneAbilityFrame", child = "Style" },
}

local extraWanted = false
local extraWatcher

local function ForEachExtraFrame(fn)
    for _, spec in ipairs(EXTRA_FRAMES) do
        local frame = _G[spec.name]
        if spec.child then frame = frame and frame[spec.child] end
        if frame and frame.EnableMouse then fn(frame) end
    end
end

local ApplyExtraMouse

-- The frames are created on demand and Blizzard re-shows them per zone or
-- encounter, so this has to re-assert rather than run once at login.
local function EnsureExtraWatcher()
    if extraWatcher then return end
    extraWatcher = CreateFrame("Frame")
    extraWatcher:RegisterEvent("UPDATE_EXTRA_ACTIONBAR")
    extraWatcher:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    extraWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
    extraWatcher:SetScript("OnEvent", function() ApplyExtraMouse() end)
end

ApplyExtraMouse = function()
    -- Deferred rather than skipped: PLAYER_REGEN_ENABLED is in the watcher's
    -- event list, so leaving combat runs this again.
    if InCombatLockdown() then return end
    ForEachExtraFrame(function(frame) frame:EnableMouse(not extraWanted) end)
end

local ExtraButtonClickEntry = {
    key = "extraButtonClicks",
    name = "Extra Button Click-Through",
    Available = function()
        -- Nothing to check for: the frames appear only when the game hands you
        -- a zone or extra ability, and the entry simply has no effect until
        -- then. Reporting unavailable would be reporting on the zone.
        return true
    end,
    Apply = function()
        extraWanted = true
        EnsureExtraWatcher()
        ApplyExtraMouse()
        return true
    end,
    Revert = function()
        extraWanted = false
        ApplyExtraMouse()
    end,
    GetInfoRows = function()
        local found, silenced = 0, 0
        ForEachExtraFrame(function(frame)
            found = found + 1
            if not frame:IsMouseEnabled() then silenced = silenced + 1 end
        end)
        return {
            {
                label = "Decoration frames present",
                value = tostring(found),
                help  = "The surround is built on demand, so this reads zero "
                     .. "until the game gives you a zone or extra ability.",
            },
            {
                label = "Click-through now",
                value = ("%d of %d"):format(silenced, found),
                help  = "The button itself is never touched -- only the art "
                     .. "around it stops taking the mouse.",
            },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Entry framework
-- ---------------------------------------------------------------------------

local ENTRIES = { TTSEntry, GroupButtonEntry, ExtraButtonClickEntry }
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
    -- first pass used to run at an arbitrary point during PLAYER_LOGIN and
    -- rely on the retry ladder below to eventually catch up; now the ladder
    -- only covers what is genuinely created later (the chat sidebar and the
    -- minimap flyout are built by EllesmereUI on its own schedule).
    AniMods.W.OnReady(function()
        PollAll()
        for _, delay in ipairs({ 2, 5, 10, 20 }) do
            C_Timer.After(delay, PollAll)
        end
    end)
end

AniMods.RegisterModule("EllesmereUIMisc", EUIMisc)
