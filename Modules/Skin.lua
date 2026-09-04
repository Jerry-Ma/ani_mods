-- Skin
-- Re-skins extra Blizzard UI elements EllesmereUI doesn't skin itself -- a
-- landing spot for one-off "it should look like it belongs" fixes, each its
-- own independently enable/disable-able entry (see ENTRIES below) rather
-- than one bundled all-or-nothing module. Two so far:
--
--   TTS Button -- Blizzard's chat "read aloud" toggle (TextToSpeechButton),
--   re-homed into EllesmereUIChat's sidebar icon row.
--   Minimap Group Button Icon -- the icon on EllesmereUIMinimap's own group
--   button (the addon-icon flyout toggle in the row outside the minimap),
--   swappable and re-tinted light rather than accent-green.
--
-- Both entries are cheap and genuinely reversible (unlike most of AniMods'
-- other hooksecurefunc-based patches), so unlike the rest of the framework's
-- "no Disable() contract, toggle takes effect next reload" convention (see
-- README), these actually apply/revert live.

local Skin = {
    title = "Skin",
    description = "Re-skins extra Blizzard UI elements EllesmereUI doesn't skin itself. Each entry below can be toggled independently.",
    dependencies = {
        { text = "EllesmereUI loaded", met = function() return AniMods.IsAddOnLoaded("EllesmereUI") end },
    },
    condition = {
        requires = { "EllesmereUI" },
    },
}

-- ---------------------------------------------------------------------------
-- Per-entry enable/disable, persisted. Default on.
-- ---------------------------------------------------------------------------

-- Settings shared by the entries below (each entry's own enable flag lives
-- in EntryDB). Declared up here because Lua only closes over locals declared
-- BEFORE the function that uses them -- defined further down, every earlier
-- reference would silently resolve to a nil global instead.
local function SkinDB()
    AniModsDB.skin = AniModsDB.skin or {}
    return AniModsDB.skin
end

local function EntryDB()
    AniModsDB.skin = AniModsDB.skin or {}
    AniModsDB.skin.entries = AniModsDB.skin.entries or {}
    return AniModsDB.skin.entries
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
-- a plain read, no different in spirit from RaidComposition reading
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
local TTS_MODE_LABEL = { hide = "Hide it", sidebar = "Move to EUI sidebar" }
local TTS_MODE_ORDER = { "hide", "sidebar" }

local function GetTTSMode()
    local mode = SkinDB().ttsMode
    if mode and TTS_MODE_LABEL[mode] then return mode end
    return "hide"
end

-- Forward-declared so the Mode dropdown below can re-run it; assigned right
-- after the entry table is built.
local ApplyTTS

local TTSEntry = {
    key = "tts",
    name = "TTS Button",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIChat") then
            return false, "EllesmereUIChat not loaded"
        end
        if ChatModuleEnabled() == false then
            return false, "EllesmereUI's chat module is disabled"
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
            { label = "Blizzard TextToSpeechButton", value = _G.TextToSpeechButton and "Found" or "Not found" },
            {
                label   = "Mode",
                options = TTS_MODE_LABEL,
                order   = TTS_MODE_ORDER,
                get     = GetTTSMode,
                set     = function(v)
                    SkinDB().ttsMode = v
                    if ApplyTTS then ApplyTTS() end
                end,
            },
        }
        if GetTTSMode() == "sidebar" then
            rows[#rows + 1] = {
                label = "Icon copied from Blizzard's button",
                value = ttsProxy and (ttsIconFound and "Yes" or "No (showing a \"T\" label instead)") or "N/A",
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
-- All verified present in DandersFrames_Options' atlas browser list.
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

local function GetFlyoutIcon()
    local key = SkinDB().flyoutIcon
    if key and FLYOUT_ICON_ATLAS[key] then return key end
    return "gear"
end

local function GetFlyoutTint()
    local key = SkinDB().flyoutTint
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
    name = "Minimap Group Button Icon",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIMinimap") then
            return false, "EllesmereUIMinimap not loaded"
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
            { label = "EllesmereUI group button", value = flyoutBtn and "Found" or "Not found yet" },
        }
        if not flyoutBtn then return rows end

        rows[#rows + 1] = {
            label   = "Icon",
            options = FLYOUT_ICON_LABEL,
            order   = FLYOUT_ICON_ORDER,
            get     = GetFlyoutIcon,
            set     = function(v) SkinDB().flyoutIcon = v; ApplyFlyoutSkin() end,
            atlas   = FLYOUT_ICON_ATLAS[GetFlyoutIcon()],
        }
        rows[#rows + 1] = {
            label   = "Tint",
            options = FLYOUT_TINT_LABEL,
            order   = FLYOUT_TINT_ORDER,
            get     = GetFlyoutTint,
            set     = function(v) SkinDB().flyoutTint = v; ApplyFlyoutSkin() end,
        }
        return rows
    end,
}

-- ---------------------------------------------------------------------------
-- Entry framework
-- ---------------------------------------------------------------------------

local ENTRIES = { TTSEntry, GroupButtonEntry }
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

function Skin:GetInfoRows()
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
            rows[#rows + 1] = { label = "Available", value = "No (" .. (reason or "prerequisite not met") .. ")" }
        else
            local applied
            if entryApplied[entry.key] then
                applied = "Yes"
            elseif not IsEntryEnabled(entry.key) then
                -- Distinct from "waiting": nothing is being waited on, the
                -- entry is simply switched off above.
                applied = "No (disabled)"
            else
                applied = "No (waiting for its target)"
            end
            rows[#rows + 1] = { label = "Applied", value = applied }
            if entry.GetInfoRows then
                for _, r in ipairs(entry.GetInfoRows()) do
                    rows[#rows + 1] = r
                end
            end
        end
    end

    return rows
end

function Skin:Enable()
    local function PollAll()
        for _, entry in ipairs(ENTRIES) do
            PollEntry(entry)
        end
    end
    PollAll()
    for _, delay in ipairs({ 2, 5, 10, 20 }) do
        C_Timer.After(delay, PollAll)
    end
end

AniMods.RegisterModule("Skin", Skin)
