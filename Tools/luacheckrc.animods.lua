-- AniMods-specific luacheck configuration.
--
-- This file is APPENDED to the generated Blizzard globals list by
-- Tools\update-luacheckrc.ps1 to produce the .luacheckrc in the addon root.
-- Edit THIS file, never .luacheckrc -- that one is a build artifact and any
-- edit to it is lost the next time the globals list is regenerated.

-- ---------------------------------------------------------------------------
-- What not to check
-- ---------------------------------------------------------------------------
-- The generated part already excludes Libs/ (third-party code we don't own and
-- can't fix). Tools/ is excluded because this very file lives there: it is
-- luacheck CONFIGURATION, evaluated in luacheck's own config environment where
-- `globals` and `read_globals` are the API, so checking it as ordinary addon
-- code reports every one of those as an undefined or non-standard global.
exclude_files[#exclude_files + 1] = "Tools/"

-- ---------------------------------------------------------------------------
-- Globals AniMods itself owns
-- ---------------------------------------------------------------------------
-- `globals` (not `read_globals`) because we assign to both: Core.lua does
-- `AniMods = AniMods or {}`, and AniModsDB is our SavedVariables table, which
-- the client creates but we initialise and mutate.
globals = {
    "AniMods",
    "AniModsDB",
}

-- ---------------------------------------------------------------------------
-- Foreign addon globals
-- ---------------------------------------------------------------------------
-- EllesmereUI is a hard dependency (## Dependencies in the .toc), and
-- Widgets.lua reads it bare rather than through _G to register for the
-- skinning API. This is the luacheck twin of Tools\meta\externals.lua, which
-- declares the same thing for the Lua Language Server; the two lists are
-- separate only because the tools are.
--
-- Everything else AniMods borrows from other addons is reached as `_G.Name`,
-- which luacheck sees as a table field rather than a global, so it needs no
-- entry here.
local foreignGlobals = {
    "EllesmereUI",
}

-- ---------------------------------------------------------------------------
-- Blizzard globals missing from the generated list
-- ---------------------------------------------------------------------------
-- The list is parsed from Ketho/BlizzardInterfaceResources, which covers the
-- documented API surface and the global strings but not every global FrameXML
-- happens to define. Everything below is real, current, and in use in this
-- addon today -- each was added only after confirming the call site works in
-- game, NOT to silence a warning. If something here ever stops existing, the
-- right fix is to stop calling it, not to keep the entry.
local extraReadGlobals = {
    "RAID_CLASS_COLORS",              -- class color table, used for name/square tinting
    "ChatFontNormal",                 -- font object, used to size the error-trace box
    "UISpecialFrames",                -- Escape-closes-frame registry
    "AudioOptionsFrame_AudioRestart", -- pre-10.0 sound restart, SoundSwitch's fallback path
}

for i = 1, #foreignGlobals do
    read_globals[#read_globals + 1] = foreignGlobals[i]
end

for i = 1, #extraReadGlobals do
    read_globals[#read_globals + 1] = extraReadGlobals[i]
end
