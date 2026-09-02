-- Skin
-- Re-skins extra Blizzard UI elements EllesmereUI doesn't skin itself -- a
-- landing spot for one-off "it should look like it belongs" fixes, each its
-- own independently enable/disable-able entry (see ENTRIES below) rather
-- than one bundled all-or-nothing module. Two so far:
--
--   TTS Button -- Blizzard's chat "read aloud" toggle (TextToSpeechButton),
--   re-homed into EllesmereUIChat's sidebar icon row.
--   Minimap Addon Button Icon -- AddonCompartmentFrame's icon, re-tinted to
--   match EllesmereUIMinimap's own flat/desaturated icon style.
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
        if ttsProxy then
            ttsReal:SetAlpha(0)
            ttsReal:EnableMouse(false)
            ttsProxy:Show()
            return true
        end
        local real = _G.TextToSpeechButton
        if not real then return false end
        local sbd = GetChatSidebarData()
        local sidebar = sbd and sbd.sidebar
        local scrollBtn = sbd and sbd.scrollBtn
        if not (sidebar and scrollBtn) then return false end

        ttsReal = real
        ttsProxy = BuildTTSButton(sidebar, scrollBtn, real)
        -- Suppress Blizzard's own copy now that a replacement exists.
        ttsReal:SetAlpha(0)
        ttsReal:EnableMouse(false)
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
        return {
            { label = "Blizzard TextToSpeechButton", value = _G.TextToSpeechButton and "Found" or "Not found" },
            {
                label = "Icon copied from Blizzard's button",
                value = ttsProxy and (ttsIconFound and "Yes" or "No (showing a \"T\" label instead)") or "N/A",
            },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Entry: Minimap Addon Button Icon
-- ---------------------------------------------------------------------------
-- Blizzard's addon-button collector (AddonCompartmentFrame, the button near
-- the minimap that groups addons with no dedicated minimap icon into a
-- dropdown) keeps its default raised/colorful icon look even under
-- EllesmereUIMinimap -- EllesmereUIMinimap.lua only repositions/reparents it
-- (see its "Addon Compartment" section: _ParkAddonCompartment/
-- _PositionAddonCompartment/_ApplyAddonCompartment), it never re-skins the
-- icon texture itself. This desaturates + tints it to match, using the same
-- treatment EllesmereUIMinimap's own neighboring addon-button-flyout toggle
-- already uses (CreateFlyoutToggle: SetDesaturated(true) +
-- SetVertexColor(accent)) -- the closest visual sibling, since it's
-- literally the other addon-button icon on the same minimap.

local compartmentIcon       -- the texture region we're tinting, once found
local compartmentIconFound = false
local compartmentTinted = false -- whether our skin is currently meant to be on
local compartmentHooked = false -- one-shot guard: hooksecurefunc can't be undone

-- AddonCompartmentFrame.Icon is the well-established name for this button's
-- icon region across the addon community, but verified defensively anyway
-- (same lesson as the TTS icon above): fall back to scanning regions for a
-- plain Texture if that field isn't there.
local function GetCompartmentIconRegion(real)
    if real.Icon then return real.Icon end
    for _, region in ipairs({ real:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture"
            and (region:GetTexture() or (region.GetAtlas and region:GetAtlas())) then
            return region
        end
    end
    return nil
end

-- EllesmereUIMinimap's own icons tint with the user's live EUI accent color
-- (EllesmereUI.RegAccent) -- matched here too when available; a plain light
-- gray otherwise so this still looks "flat", just not accent-colored.
local function GetFlatTint()
    local accent = _G.EllesmereUI and _G.EllesmereUI.RegAccent
    if accent and accent.r then return accent.r, accent.g, accent.b end
    return 0.9, 0.9, 0.9
end

-- Re-read the accent each time rather than caching it: EUI's accent color is
-- user-configurable and this runs again on every re-assert anyway.
local function ApplyCompartmentTint()
    if not compartmentIcon then return end
    compartmentIcon:SetDesaturated(true)
    local r, g, b = GetFlatTint()
    compartmentIcon:SetVertexColor(r, g, b, 1)
end

local CompartmentEntry = {
    key = "minimapCompartment",
    name = "Minimap Addon Button Icon",
    Available = function()
        if not AniMods.IsAddOnLoaded("EllesmereUIMinimap") then
            return false, "EllesmereUIMinimap not loaded"
        end
        return true
    end,
    Apply = function()
        local real = _G.AddonCompartmentFrame
        if not real then return false end
        local icon = GetCompartmentIconRegion(real)
        if not icon then return false end

        compartmentIcon = icon
        compartmentIconFound = true
        compartmentTinted = true
        ApplyCompartmentTint()

        -- Something does re-touch this button: EllesmereUIMinimap hooks its
        -- Show/SetParent/SetPoint/SetScale specifically to keep re-asserting
        -- its position (_ApplyAddonCompartment). If anything likewise re-sets
        -- the icon's art, a tint applied once would silently disappear. So
        -- re-assert on the actual mutation -- a hook on the two methods that
        -- can replace the art -- rather than polling for it on a timer.
        -- SetDesaturated/SetVertexColor are different methods, so
        -- re-applying from inside these hooks can't recurse.
        if not compartmentHooked then
            compartmentHooked = true
            local function Reassert()
                if compartmentTinted then ApplyCompartmentTint() end
            end
            hooksecurefunc(icon, "SetAtlas", Reassert)
            hooksecurefunc(icon, "SetTexture", Reassert)
        end

        return true
    end,
    Revert = function()
        compartmentTinted = false
        if compartmentIcon then
            compartmentIcon:SetDesaturated(false)
            compartmentIcon:SetVertexColor(1, 1, 1, 1)
        end
    end,
    GetInfoRows = function()
        return {
            { label = "Blizzard AddonCompartmentFrame", value = _G.AddonCompartmentFrame and "Found" or "Not found" },
            { label = "Icon region found", value = compartmentIconFound and "Yes" or "No" },
        }
    end,
}

-- ---------------------------------------------------------------------------
-- Entry framework
-- ---------------------------------------------------------------------------

local ENTRIES = { TTSEntry, CompartmentEntry }
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
