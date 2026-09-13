-- AniMods broker (LibDataBroker) helper.
--
-- Shared by every module that publishes an LDB plugin (GroupRoles,
-- SocialStatus, SoundSwitch), which otherwise all grow the same ~60 lines of
-- near-identical boilerplate: acquiring the library, the "Icon + Text" vs
-- "Text Only" display-mode setting, the inline-icon text builder, and the
-- "Broker Display" rows for the AniMods panel. Those had already drifted
-- apart cosmetically (one module's getter was GetBrokerDisplayMode, the
-- other's GetDisplayMode) before this was pulled out -- exactly the kind of
-- divergence that ends with two subtly different behaviours for what's
-- meant to be one shared look.
--
-- Settings live in each module's OWN saved-variables table (passed in as a
-- `getDB` function, matching the lazy `ModuleDB()` pattern the modules
-- already use), so two brokers can be configured independently -- this is
-- shared behaviour, not shared state.

local AniMods = _G.AniMods

local Broker = {}
AniMods.Broker = Broker

Broker.DISPLAY_MODE_LABEL = { icon = "Icon + Text", text = "Text Only" }
Broker.DISPLAY_MODE_ORDER = { "icon", "text" }

function Broker.GetDisplayMode(getDB)
    local mode = getDB().brokerDisplayMode
    if mode and Broker.DISPLAY_MODE_LABEL[mode] then return mode end
    return "icon"
end

-- Which family of art an icon is drawn from.
--
-- "eui" means EllesmereUI's own micromenu set: one designed family, every file
-- 128x128, solid silhouettes. "blizzard" means the game's atlases, which are
-- guaranteed present but are not a set -- their natural sizes run from 16x16 to
-- 70x70, and squeezing all of them into the same 14px box gives them visibly
-- different weight next to each other.
--
-- This is a PREFERENCE, not a requirement. Resolution always falls through to
-- whatever actually exists, and every category here terminates in a Blizzard
-- atlas, so picking "eui" on a machine without EllesmereUI quietly yields the
-- Blizzard art rather than no icon at all.
Broker.ICON_STYLE_LABEL = { eui = "EllesmereUI art", blizzard = "Blizzard atlas" }
Broker.ICON_STYLE_ORDER = { "eui", "blizzard" }

function Broker.GetIconStyle(getDB)
    local style = getDB().brokerIconStyle
    if style and Broker.ICON_STYLE_LABEL[style] then return style end
    return "eui"
end

-- What W.ResolveIcon wants: which candidate KIND to try first.
function Broker.PreferredIconKind(getDB)
    return Broker.GetIconStyle(getDB) == "blizzard" and "atlas" or "texture"
end

-- Registers a data object, or returns nil if LibDataBroker isn't available.
-- EllesmereUI ships LibStub + LibDataBroker-1.1 itself (EllesmereUI/Libs/),
-- and every module using this is already gated on some EUI component being
-- loaded, so the library is effectively guaranteed -- guarded anyway,
-- silently: GetLibrary(..., true) never errors on a miss.
function Broker.Register(objectName, spec)
    local libStub = _G.LibStub
    local ldb = libStub and libStub:GetLibrary("LibDataBroker-1.1", true)
    if not ldb then return nil end

    spec.type = spec.type or "data source"
    spec.text = spec.text or ""
    return ldb:NewDataObject(objectName, spec)
end

-- Builds a broker's `text` from an ordered list of parts:
--   { count = 3, color = "ffd700", atlas = "some-atlas" }   -- Blizzard atlas icon
--   { count = 3, color = "59c0ff", texture = "Interface\\..." } -- plain texture file
--   { text = "Headphones", atlas = "some-atlas" }           -- any label, not just a number
--
-- In "Icon + Text" mode a LEADING icon is packed directly against its count
-- with no padding (the most compact rendering, and the icon itself is enough
-- to tell the parts apart, so no separator is needed either). A TRAILING icon
-- gets a space -- see the note on `iconAfter` below. Inline escape sequences
-- are |A:name:h:w|a for an atlas, |Tpath:h|t for a texture file. In "Text
-- Only" mode there's nothing but a "/" separator to tell the numbers apart.
-- `color` is only applied when the module's own "Colored text" setting is on.
-- Height every inline icon is drawn at, so a change is one edit.
local ICON_H = 14

-- ── Icons ───────────────────────────────────────────────────────────────────
--
-- Icons are drawn INLINE, as escape sequences inside `text`.
--
-- LibDataBroker also has an `icon`/`iconCoords` contract, and EllesmereUI's
-- data bar implements it properly -- a real Texture, which is how its built-in
-- blocks tint on hover where ours cannot. It was tried and taken back out: LDB
-- carries ONE icon per data object, while Social Status draws two and Group
-- Roles draws three, so those two could only use it by being split into
-- separate widgets. Not worth rearranging a data bar for a hover tint.
--
-- The consequence, recorded so it is not rediscovered: inline icons cannot be
-- vertex-tinted and so cannot highlight on hover. EUI's own source says the
-- same thing in EllesmereUIDataBars_Blocks.lua.
--
-- CROPS ARE SQUARE, deliberately. Every display sizes an icon into a square
-- box, so a tight crop around a wide glyph gets stretched back into one --
-- which is the vertical squashing that kept coming back. A square region
-- CONTAINING the glyph is the only shape that survives. Candidates declare
-- `coords` as measured normalised texels, never an aspect ratio.

-- |Tpath:h:w:offX:offY:texW:texH:left:right:top:bottom|t
-- Square in and square out, for the reason above.
function Broker.TextureEscape(path, coords, canvas)
    if not (coords and canvas) then return ("|T%s:%d|t"):format(path, ICON_H) end
    return ("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t"):format(
        path, ICON_H, ICON_H, canvas, canvas,
        coords[1] * canvas, coords[2] * canvas,
        coords[3] * canvas, coords[4] * canvas)
end

-- Atlases are drawn at their OWN aspect, not forced into a square.
--
-- The candidates come from unrelated Blizzard art sets and their natural sizes
-- vary wildly -- 16x16 for the friends icon, 16x20 for the guild micro button,
-- 70x70 for a role icon. Asking for 14x14 regardless stretches every one that
-- is not square, which is half of why they looked inconsistent beside each
-- other. Fixing the HEIGHT and letting width follow keeps them all the same
-- size as the text, which is the dimension a reader compares.
--
-- Cached: GetAtlasInfo allocates a table per call, and this runs on every
-- broker text rebuild.
local atlasAspect = {}

function Broker.AtlasEscape(atlas)
    local aspect = atlasAspect[atlas]
    if aspect == nil then
        local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas)
        local w, h = info and info.width, info and info.height
        aspect = (w and h and h > 0) and (w / h) or false
        atlasAspect[atlas] = aspect
    end
    local w = aspect and math.floor(ICON_H * aspect + 0.5) or ICON_H
    if w < 1 then w = 1 end
    return ("|A:%s:%d:%d|a"):format(atlas, ICON_H, w)
end

function Broker.BuildText(getDB, parts)
    local db = getDB()
    local showIcon = Broker.GetDisplayMode(getDB) == "icon"
    local colored = db.brokerColoredText ~= false

    local rendered = {}
    for i, part in ipairs(parts) do
        local body = part.text or tostring(part.count)
        local numText = (colored and part.color) and ("|cff%s%s|r"):format(part.color, body) or body

        -- `iconAfter` puts the icon on the far side of the text. Normally the
        -- icon LABELS its number -- a tank icon before a tank count -- so it
        -- leads. SpecSwitch is the other case: its icon is a second, different
        -- fact (the loot spec) sitting beside the first (the spec being
        -- played), so it trails, and "name then icon" reads as "playing this,
        -- looting that". Borrowed from NDui's own spec infobar.
        local icon
        if showIcon and part.atlas then
            icon = Broker.AtlasEscape(part.atlas)
        elseif showIcon and part.texture then
            icon = Broker.TextureEscape(part.texture, part.coords, part.canvas)
        end

        -- One space on whichever side the icon sits, always.
        --
        -- A leading icon used to be glued to its number with nothing between
        -- them, on the theory that the icon labels the number and closing the
        -- gap binds them. In practice the gap was never zero and never equal:
        -- what showed was each icon's own transparent margin, so a tight atlas
        -- sat hard against its digit and a padded one floated. An explicit
        -- space is the only part of that distance we control, and making it
        -- the same on both sides is what makes the row look deliberate.
        --
        -- Still one space, not two: parts are separated by two, so the icon
        -- stays grouped with its own number and the hierarchy survives.
        if not icon then
            rendered[i] = numText
        elseif part.iconAfter then
            rendered[i] = numText .. " " .. icon
        else
            rendered[i] = icon .. " " .. numText
        end
    end

    return table.concat(rendered, showIcon and "  " or "/")
end

-- Assigns a data object's `text` only when it actually differs.
--
-- LibDataBroker's data objects are proxy tables: every assignment to a field
-- goes through its __newindex and fires
-- LibDataBroker_AttributeChanged_<name>, unconditionally -- it does not
-- compare against the current value. EllesmereUIDataBars subscribes to that
-- callback per block and re-renders on it, so re-assigning an identical
-- string still walks the callback list and repaints the FontString for
-- nothing. Since most of what wakes these modules is a roster/friend-list
-- event that leaves the displayed numbers unchanged, that no-op repaint was
-- the common case rather than the rare one.
function Broker.SetText(obj, text)
    if not obj or obj.text == text then return end
    obj.text = text
end

-- The whole "Broker widget" section for a module's GetInfoRows(): whether the
-- widget was published, under what name, and how it draws.
--
-- Status and display options live together because they are one feature. They
-- used to be split -- a "Broker (LDB) plugin: Registered" line among a
-- module's Status rows, and a separate "Broker Display" section further down
-- -- which read as two unrelated things and left the display options with no
-- visible connection to what they styled.
--
-- It also puts LibDataBroker in the right place. It is not a dependency of
-- these MODULES, which work without it; it is what this one feature needs. A
-- red requirement row would have said the module was broken when only its
-- broker was unavailable.
--
-- `objectName` is reported verbatim, because that is the string to look for
-- in a data bar's widget picker -- more use than a yes/no.
function Broker.SectionRows(getDB, onChange, objectName)
    local ldb = _G.LibStub and _G.LibStub:GetLibrary("LibDataBroker-1.1", true)
    local published = ldb and objectName and ldb:GetDataObjectByName(objectName)

    -- Two rows, because these are two facts and one of them is a yes/no. They
    -- were one row whose value was either a name or the words "Not published",
    -- which meant the same cell answered two different questions depending on
    -- which answer it was giving.
    local rows = {
        { section = "Broker widget" },
        {
            label = "Published",
            state = published and true or false,
            help  = (not published)
                and "Needs LibDataBroker, which EllesmereUI and most data bars ship."
                or nil,
        },
    }

    -- The name is reported verbatim, because that is the string to look for in
    -- a data bar's widget picker.
    if published then
        rows[#rows + 1] = {
            label = "Widget name",
            value = objectName,
            help  = "Pick this name in your data bar's widget list.",
        }
    end

    -- Display options only matter once there is something to display.
    if published then
        rows[#rows + 1] = {
            label   = "Style",
            options = Broker.DISPLAY_MODE_LABEL,
            order   = Broker.DISPLAY_MODE_ORDER,
            get     = function() return Broker.GetDisplayMode(getDB) end,
            set     = function(v) getDB().brokerDisplayMode = v; onChange() end,
        }
        -- Only meaningful while icons are being drawn at all.
        if Broker.GetDisplayMode(getDB) == "icon" then
            rows[#rows + 1] = {
                label   = "Icon style",
                options = Broker.ICON_STYLE_LABEL,
                order   = Broker.ICON_STYLE_ORDER,
                get     = function() return Broker.GetIconStyle(getDB) end,
                set     = function(v) getDB().brokerIconStyle = v; onChange() end,
                help    = AniMods.IsAddOnLoaded("EllesmereUI")
                    and "EllesmereUI's micromenu art is one designed set, so the "
                     .. "icons match each other. Blizzard's atlases are guaranteed "
                     .. "present, but their natural sizes vary enough that they "
                     .. "carry visibly different weight side by side."
                    or "EllesmereUI is not loaded, so both settings currently give "
                     .. "the Blizzard atlas -- every icon falls back to one rather "
                     .. "than going missing.",
            }
        end

        rows[#rows + 1] = {
            label = "Colored text",
            get   = function() return getDB().brokerColoredText ~= false end,
            set   = function(v) getDB().brokerColoredText = v; onChange() end,
        }
    end

    return rows
end
