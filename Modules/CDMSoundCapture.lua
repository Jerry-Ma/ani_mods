-- CDMSoundCapture -- THROWAWAY. Delete this file and its .toc line once the
-- table it is here to produce has been collected.
--
-- THE IDEA. The enum-to-asset mapping is C-side, so it cannot be READ. But
-- Blizzard's own settings panel previews a sound the moment you pick one in
-- the Cooldown Manager's alert dropdown -- and to do that it must call
-- PlaySound or PlaySoundFile with the real thing. So the mapping that cannot
-- be read can still be WATCHED: hook both, click through the dropdown, and
-- each preview hands over the exact id Blizzard uses.
--
-- WHY THIS BEATS LOOKING IT UP. Nothing published has these ids -- not the
-- wiki, not the listfile sites, not the three addons already working in this
-- corner. And a value captured from the client that is running is correct for
-- the client that is running, which a copied listfile is not.
--
-- WHAT THE ANSWER DECIDES. Which function fires is the whole result:
--
--   PlaySoundFile(fileDataID)  the id is a FILE. It drops straight into
--                              LibSharedMedia and every LSM addon can play it,
--                              with nothing bundled and nothing extracted --
--                              the game already owns the audio.
--   PlaySound(soundKitID)      the id is a KIT, a different number space.
--                              PlaySoundFile reads one as a file id and gives
--                              silence, so this route would still need a
--                              kit-to-file step that may not exist.
--
-- NOTE ON NOISE. Hooking these catches EVERY UI sound, and clicking a radio
-- button in a Blizzard menu makes one of its own. So the click sound appears
-- alongside each preview; the "seen" count is what tells them apart, since the
-- click repeats on every entry and a preview does not.

local AniMods = _G.AniMods

local CDMSoundCapture = {
    title = "CDM Sound Capture",
    description = "Throwaway: watches what the Cooldown Manager plays when you preview an alert sound.",
    dbKey = "cdmSoundCapture",
    category = "Addon Extras",
}

local capturing = false
local hooked = false
local log = {}        -- ordered captures: { api, value, seen }
local byKey = {}      -- "api:value" -> entry in log, for the seen count
local MAX = 200

local function Record(api, value)
    if not capturing then return end
    if value == nil then return end

    local key = api .. ":" .. tostring(value)
    local entry = byKey[key]
    if entry then
        entry.seen = entry.seen + 1
        -- Not re-ordered. Where a sound FIRST appeared is the useful fact,
        -- because that is the click that produced it.
        return
    end
    if #log >= MAX then return end

    entry = { api = api, value = value, seen = 1, index = #log + 1 }
    log[#log + 1] = entry
    byKey[key] = entry
    if AniMods.RefreshUI then AniMods.RefreshUI() end
end

-- hooksecurefunc on the globals: both are plain global functions, and a post
-- hook sees the arguments without touching what Blizzard does with them. The
-- hooks go on ONCE and stay on -- hooksecurefunc cannot be undone, so the
-- capture flag is what starts and stops recording, not the hook.
local function EnsureHooks()
    if hooked then return end
    hooked = true
    _G.hooksecurefunc("PlaySound", function(soundKitID)
        Record("PlaySound", soundKitID)
    end)
    _G.hooksecurefunc("PlaySoundFile", function(file)
        Record("PlaySoundFile", file)
    end)
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

function CDMSoundCapture:GetInfoRows()
    local rows = {}

    rows[#rows + 1] = { section = "Capture" }
    rows[#rows + 1] = {
        label = "Recording",
        get   = function() return capturing end,
        set   = function(v)
            capturing = v and true or false
            if capturing then EnsureHooks() end
        end,
        help  = "Switch on, then open the Cooldown Manager's alert settings and "
             .. "click through the sound list. Every sound the game plays while "
             .. "this is on is recorded, so do it in a quiet moment -- and "
             .. "switch it off before doing anything else.",
    }
    rows[#rows + 1] = {
        label = "Captured",
        value = ("%d"):format(#log),
        help  = "Distinct sounds, in the order they first played. A repeated "
             .. "one is almost certainly the menu's own click, not a preview.",
    }

    if #log > 0 then
        rows[#rows + 1] = { section = "Sounds" }
        for _, entry in ipairs(log) do
            rows[#rows + 1] = {
                label = ("%d. %s"):format(entry.index, entry.api),
                value = ("%s%s"):format(
                    tostring(entry.value),
                    entry.seen > 1 and ("  (x%d)"):format(entry.seen) or ""),
            }
        end
    end

    rows[#rows + 1] = { section = "Output" }
    rows[#rows + 1] = {
        kind = "button", label = "Print as Lua", button = "Print",
        help = "Writes the captures to chat as a paste-ready table.",
        onClick = function()
            AniMods.Print("-- CDM sound capture, in first-played order")
            AniMods.Print("local CAPTURED = {")
            for _, entry in ipairs(log) do
                AniMods.Print(("    { api = %q, value = %s, seen = %d },")
                    :format(entry.api, tostring(entry.value), entry.seen))
            end
            AniMods.Print("}")
        end,
    }
    rows[#rows + 1] = {
        kind = "button", label = "Dump layout data", button = "Dump",
        help = "Prints C_CooldownViewer.GetLayoutData() one level deep. If the "
            .. "alert's sound enum turns out to be in there, a later version "
            .. "could label each capture itself instead of relying on the "
            .. "order you clicked in.",
        onClick = function()
            local ns = _G.C_CooldownViewer
            local get = ns and ns.GetLayoutData
            if not get then AniMods.Print("GetLayoutData is not available."); return end
            local ok, data = _G.pcall(get)
            if not ok or type(data) ~= "table" then
                AniMods.Print("GetLayoutData returned nothing readable.")
                return
            end
            for k, v in pairs(data) do
                AniMods.Print(("  %s = %s (%s)"):format(tostring(k), tostring(v), type(v)))
                if type(v) == "table" then
                    for k2, v2 in pairs(v) do
                        AniMods.Print(("      %s = %s (%s)")
                            :format(tostring(k2), tostring(v2), type(v2)))
                    end
                end
            end
        end,
    }
    rows[#rows + 1] = {
        kind = "button", label = "Clear", button = "Clear",
        help = "Empties the list so a run can be started cleanly.",
        onClick = function()
            wipe(log)
            wipe(byKey)
            if AniMods.RefreshUI then AniMods.RefreshUI() end
        end,
    }

    return rows
end

-- No Enable. The hooks go on when recording is first switched on, and nothing
-- here should be installed on a login where it is not wanted.

AniMods.RegisterModule("CDMSoundCapture", CDMSoundCapture)
