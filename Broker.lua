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
-- In "Icon + Text" mode each part's icon is packed directly against its
-- count with no padding (the most compact rendering, and the icon itself is
-- enough to tell the parts apart, so no separator is needed either); inline
-- escape sequences are |A:name:h:w|a for an atlas, |Tpath:h|t for a texture
-- file. In "Text Only" mode there's nothing but a "/" separator to tell the
-- numbers apart. `color` is only applied when the module's own "Colored
-- text" setting is on.
function Broker.BuildText(getDB, parts)
    local db = getDB()
    local showIcon = Broker.GetDisplayMode(getDB) == "icon"
    local colored = db.brokerColoredText ~= false

    local rendered = {}
    for i, part in ipairs(parts) do
        local body = part.text or tostring(part.count)
        local numText = (colored and part.color) and ("|cff%s%s|r"):format(part.color, body) or body
        if showIcon and part.atlas then
            rendered[i] = ("|A:%s:14:14|a%s"):format(part.atlas, numText)
        elseif showIcon and part.texture then
            rendered[i] = ("|T%s:14|t%s"):format(part.texture, numText)
        else
            rendered[i] = numText
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

-- The standard "Broker Display" section for a module's GetInfoRows(): a
-- Style dropdown (Icon + Text / Text Only) plus a Colored text toggle.
-- `onChange` is called after either setting changes, so the module can
-- rebuild its broker text immediately.
function Broker.DisplayRows(getDB, onChange)
    return {
        { section = "Broker Display" },
        {
            label   = "Style",
            options = Broker.DISPLAY_MODE_LABEL,
            order   = Broker.DISPLAY_MODE_ORDER,
            get     = function() return Broker.GetDisplayMode(getDB) end,
            set     = function(v) getDB().brokerDisplayMode = v; onChange() end,
        },
        {
            label = "Colored text",
            get   = function() return getDB().brokerColoredText ~= false end,
            set   = function(v) getDB().brokerColoredText = v; onChange() end,
        },
    }
end
