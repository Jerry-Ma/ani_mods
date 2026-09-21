# AniMods

Ani's personal collection of small WoW UI patches and QoL tweaks — a "patch system":
a landing spot for one-off ideas cherry-picked from other addons (or written from
scratch) that don't warrant their own standalone addon, each gated behind a load
condition so it only activates when it actually applies.

Personal/local use — not published to CurseForge.

---

## Checks

```powershell
.\Tools\check.ps1             # all three layers
.\Tools\check.ps1 -Fast       # Lua 5.1 parse only, while iterating
.\Tools\check.ps1 -SkipTypes  # layers 1-2, if the VS Code extensions aren't installed
```

Three layers, because each catches what the previous cannot:

1. **`luac -p`** — a real **Lua 5.1** parse of every file `AniMods.toc` loads, in load
   order. WoW runs 5.1; luacheck's own bundled runtime is 5.4 and its parser accepts a
   syntax superset, so this is the only step that actually rejects what 5.1 can't
   compile. It also cross-checks the `.toc` against the files on disk in both directions
   — a file listed but missing is an error, a `.lua` on disk that nothing loads is
   reported as an orphan. A rename that updates one but not the other is otherwise a
   silent no-load in game.
2. **`luacheck`** — static analysis against the **full** Blizzard globals list: typo'd or
   undefined globals, accidental global writes, unused and shadowed locals.
3. **`lua-language-server --check`** — type-aware diagnostics against the WoW API
   annotations from the [WoW API](https://marketplace.visualstudio.com/items?itemName=ketho.wow-api)
   VS Code extension. This is the only layer that knows what WoW functions *return*, so
   it's the only one that catches a possibly-nil value passed somewhere that can't take
   nil, a wrong argument type, or a call into an API the client no longer has. It earned
   its place on the first run by finding `badge.text:SetFont(badge.text:GetFont(), ...)`
   in `GroupRoles.lua` — `GetFont()` can return nil and `SetFont(nil, ...)` is a hard
   error. Neither of the layers above can see that.

   It uses the language server binary bundled with the `sumneko.lua` extension, so
   there's nothing extra to install. Both extensions are located by glob with the newest
   match winning, so upgrading either doesn't need an edit to the script.

Setup (one-off):

```powershell
scoop install lua-for-windows luacheck   # Lua 5.1.5 + luac, and the linter
.\Tools\update-luacheckrc.ps1            # generates .luacheckrc
```

Plus the two VS Code extensions for layer 3 (and for live in-editor diagnostics):
**Lua** (`sumneko.lua`) and **WoW API** (`ketho.wow-api`) — the latter ships LuaLS
annotations for ~8,000 functions with signatures and return types, 260 `C_` namespaces,
860+ widget types, 843 enums, and deprecated functions with their replacements. It
activates automatically on a folder containing a `.toc`.

`.luarc.json` configures LuaLS for both the editor and layer 3.
`Tools\meta\externals.lua` is a `---@meta` stub — not loaded by the game, not in the
`.toc` — declaring the foreign globals AniMods deliberately reaches for
(`EllesmereUI`, `NDui`, `EllesmereUIRaidToolsIcon`, `_EUI_RaidTools_DB`) plus the
superseded Blizzard ones kept as guarded fallbacks (`IsAddOnLoaded`,
`GetAddOnMetadata`, `AudioOptionsFrame_AudioRestart`). Without it, reaching into another
addon's globals — most of what this addon does — is an "undefined field" warning at
every site, and a checker that cries wolf on the core idiom is one nobody reads. Types
there are deliberately loose (`any`): these are foreign, undocumented, version-dependent
objects, and pretending to know their shape would invent a contract nothing enforces.
Warnings are suppressed **inline at the exact line**, never by loosening a check
globally. The one worth knowing about is `SpecSwitch.lua`'s
`C_SpecializationInfo.SetSpecialization`, which neither the LuaLS annotations nor the
generated globals list knows about even though it is the current call and four addons in
this folder use it. It needs a directive for *each* checker (`-- luacheck: push ignore
143` and `---@diagnostic disable-next-line`), since silencing one says nothing to the
other — worth knowing before assuming a suppression took.

`.luacheckrc` is a **generated artifact and is gitignored** — it is the ~44,000-entry
Blizzard globals list from [Jayrgo/wow-luacheckrc](https://github.com/Jayrgo/wow-luacheckrc)
(branch `mainline`, itself parsed from
[Ketho/BlizzardInterfaceResources](https://github.com/Ketho/BlizzardInterfaceResources))
with `Tools\luacheckrc.animods.lua` appended. Edit **that** file, never `.luacheckrc`.
Completeness is the point: with every Blizzard global known, an "undefined variable"
warning is a real finding rather than something to skim past — and the list is worth
regenerating rather than hand-extending, so the habit of silencing warnings by adding
globals never starts. The handful of genuinely-missing entries in
`luacheckrc.animods.lua` were each confirmed working in game first.

**What none of this catches.** It does not run the addon. A wrong event name, a
nonexistent atlas, a loop that iterates zero times — all invisible here, and all of them
have shipped in this addon at least once. Headless
runners exist ([wowless](https://github.com/wowless/wowless) is the serious one) but it
is pre-alpha and its own README says errors it reports are probably its own bugs, so it
isn't a gate. **A `/reload` is still the real test** — this only makes one worth doing.

---

## Structure

Each patch is a self-contained module under `Modules\`, registered with `Core.lua`'s
module registry:

```lua
local MyFeature = {
    title        = "My Feature",              -- optional, defaults to the registered name
    description  = "One-line summary shown in the status panel.",

    -- Optional: gates whether Enable() runs at all, and renders as the panel's
    -- "Conditions" card -- one row per entry with a Met / Not met badge, so
    -- "why is this inactive" is answered by a column of colours rather than
    -- prose. Evaluated at PLAYER_LOGIN, so IsAddOnLoaded() checks against
    -- *other* addons are reliable no matter the load order.
    --
    -- Each `text` is phrased as a STATEMENT that is true or false, which is
    -- what makes the badge read correctly against it. An entry with no `met`
    -- never fails.
    conditions = {
        -- Required (the default): unmet means the module cannot run.
        { text = "SomeAddon loaded",
          help = "The long explanation, revealed by the row's ? marker.",
          met  = function() return AniMods.IsAddOnLoaded("SomeAddon") end },

        -- Soft: unmet still deactivates, but the panel offers "Run anyway"
        -- (requires `forceable = true` on the module).
        { text = "No other data bar", soft = true,
          met  = function() return not AniMods.IsAddOnLoaded("Titan") end },
    },
    forceable = true,
}

function MyFeature:Enable()
    -- hook stuff, create frames, etc. Only called if the conditions passed AND
    -- the module is user-enabled.
end

AniMods.RegisterModule("MyFeature", MyFeature)
```

Add the new file to `AniMods.toc` after the framework files (`Core.lua`, `Broker.lua`,
`Compat.lua`, `Widgets.lua`, `UI.lua`) to load it. Layer 1 of the checks cross-checks the
`.toc` against disk in both directions, so a file added to one and not the other is an
error rather than a silent no-load.

Modules are enabled by default (once their conditions pass). Most WoW UI hooks can't be
cleanly undone at runtime, so there's no `Disable()` contract — toggling a module off
in the status panel just skips its `Enable()` next login/reload. A module that genuinely
*can* apply a toggle live implements `SetEnabled(on)`; the panel then applies the change
immediately instead of asking for a reload.

**Conditions gate; they do not describe.** Something that enables only *part* of a
module belongs with that part, not here — a row that can never change whether the module
runs turns a gating checklist into a mixed list of facts, and needs its own badge
wording to avoid claiming something is broken when nothing is. GroupRoles reports
EllesmereUIQoL in its own Integration section beside the docked badge's settings, and
`Broker.SectionRows` reports LibDataBroker beside the broker's display options. Both say
more than a condition row could: not whether the host is installed, but whether the
feature actually attached.

### Shared broker helper (`Broker.lua`)

Any module publishing a LibDataBroker plugin uses `AniMods.Broker` rather than growing
its own copy of the same boilerplate (GroupRoles and SocialStatus had already
drifted to differently-named copies of the same getter before this was pulled out):

- `Broker.Register(objectName, spec)` — registers a data object, or returns `nil` if
  LibDataBroker isn't available. Fills in `type = "data source"` and an empty `text`.
- `Broker.BuildText(getDB, parts)` — renders the broker's `text` from an ordered list
  of `{ count, color, atlas | texture }` parts, honouring the module's own display-mode
  and colored-text settings. "Icon + Text" packs each icon directly against its count
  (inline `|A:name:h:w|a` for an atlas, `|Tpath:h|t` for a texture file) with no
  separator, since the icons already tell the parts apart; "Text Only" falls back to a
  `/` separator.
- `Broker.SectionRows(getDB, onChange, objectName)` — the whole "Broker widget" section
  for `GetInfoRows()`: whether the widget was published, under what name, and how it
  draws (a Style dropdown — Icon + Text / Text Only — and a Colored text toggle, both
  only once there is something to draw).

  Status and options live together because they are one feature. They used to be split
  across a "Broker (LDB) plugin: Registered" line among a module's Status rows and a
  separate "Broker Display" section further down, which read as two unrelated things and
  left the display options with no visible connection to what they styled. It is also
  where LibDataBroker belongs: it is not a dependency of these *modules*, which work
  without it — it is what this one *feature* needs, so a red condition row would have
  claimed the module was broken when only its broker was unavailable.

`getDB` is the module's own lazy settings accessor (its `ModuleDB` function), so each
broker's settings live in that module's own saved-variables table — shared *behaviour*,
not shared state.

### Broker hover popups (`W.Tooltip`)

Every broker's hover popup is `W.Tooltip` — a themed panel, so it follows the user's
window colours on a stock UI instead of wearing Blizzard's tooltip art. Under
EllesmereUI a plain `GameTooltip` happens to look right, because EUI reskins the global
tooltip; that's worse rather than better, since it means the same code renders
consistently only when a particular other addon is installed.

**`AddLine` and `AddDoubleLine` take `GameTooltip`'s exact signatures**, deliberately. A
module writes *one* tooltip body and hands it either the themed popup or a real
`GameTooltip`, because the second sink isn't optional: LDB displays that don't support
the `OnEnter(anchor)` contract call `OnTooltipShow(tt)` with their own tooltip. Without a
shared signature every broker would carry two copies of its tooltip body — the exact
divergence that rots. So a broker registers `OnEnter`/`OnLeave` *and* `OnTooltipShow`,
all three pointing at the same render function.

**Placement is chosen from the widget's own position on screen**, on both axes, and the
click menus use the same rule so a widget's menu and its tooltip never appear on
opposite sides of it. A data bar can sit anywhere: a widget in the top half opens
downward, one in the bottom half upward; one in the left third aligns left edges so the
popup extends *right*, one in the right third aligns right edges so it extends *left*,
and the middle is centred. Thirds horizontally rather than halves, because that axis is
about overflow rather than direction — a widget near the middle has room either way and
looks best centred. `SetClampedToScreen` stays on as a backstop, but it's the wrong
primary mechanism: clamping a popup that opened the wrong way shoves it back *over* the
widget the cursor is on. GroupRoles' docked badge overrides the rule with its own
setting, since which way it opens decides what it covers.

There was once a second mode: Social Status used only the *shell*, through an exposed
`.inner`, because its body was a bespoke two-column layout no line-based API expresses.
That went with the popup itself — Social Status now shows EllesmereUI's own — and `.inner`
went with it, since nothing else ever used it. Every caller is on the line API now.

Each caller still owns its own lazily-built instance, which is now convention rather than
requirement: only one popup can be hovered at a time, so a shared one would work. Left
alone because four lazily-built frames cost nothing and sharing would couple the modules.

A module can optionally expose `GetInfoRows()`, returning an ordered list of rows
rendered in its detail pane — this is the "debug + options" section every module gets
for free:

```lua
function MyFeature:GetInfoRows()
    return {
        { section = "Status" },                                                  -- section header
        { label = "Some live value", value = tostring(someState) },              -- status (a measurement)
        { label = "In group", state = IsInGroup(), help = "why not" },           -- statement + Yes/No badge
        { section = "Options" },
        { label = "Include X", get = GetX, set = SetX, note = "Active" },        -- checkbox + status badge
        { label = "Style", options = { a = "Style A", b = "Style B" },
          order = { "a", "b" }, get = GetStyle, set = SetStyle,
          atlas = { "some-atlas-1", "some-atlas-2" } },                          -- dropdown, w/ optional icon preview(s)
        { label = "Spacing", min = 0, max = 4, step = 1, get = G, set = S },     -- slider
        { label = "Accent", swatches = COLORS, order = KEYS, get = G, set = S }, -- colour squares
        { label = "Show widgets", picker = ITEMS, summary = "2 of 7",            -- multi-select dropdown
          isChecked = IsOn, onToggle = SetOn },
        { strip = ORDER, labels = LABELS, onReorder = Apply, onDrop = Apply },   -- drag-to-reorder preview
        { label = "Silence all", button = "Apply", onClick = DoIt },             -- action button
    }
end
```

**Every yes/no fact is a `state` row**, and they all render identically — `<claim>
[Yes|No] ?` — whether they come from a module's `GetInfoRows()` or from its `conditions`
(the Conditions card builds with the same primitive). Use `value` only for a
*measurement* ("Tanks: 2", "Version: 1.4"); a boolean dressed as a value string is what
produced four vocabularies for one question — Met/Not met, Found/Not found, `No (Raid
Tools disabled, mode: never)`, and `N/A` — with the reason smuggled into the value as a
parenthetical. The reason belongs in `help`. Yes is green and No is red, always — there
is no per-caller tone. A grey/red split briefly existed (grey for an informational No,
red only where the failure stops a module), but the rule lived in whether a row happened
to be a condition, which the reader can't see, so it just looked inconsistent. A
rendering difference nobody can decode is worse than a distinction not drawn.

Any row may carry `help`, which attaches a `?` marker revealing the long explanation on
hover. That is what keeps the panel scannable: the label states the setting, the
reasoning lives one hover away rather than as a paragraph under every control. The
corollary is that the label must stand alone. On an **option** row the marker sits
straight after the label, because it explains the setting; on a **statement** row it sits
after the badge, because it explains the answer.

`note` is a live *status* about a row ("Active", "Current") and renders as the same green
badge, beside the label — never a second name for the same thing, and never the accent
colour, which belongs to the panel's own furniture rather than to facts about the game.

A row with `section` renders as a divider header, grouping an otherwise-flat scrolling
list into skimmable chunks (a module with several kinds of info — live status,
integration facts, a style picker — should section them rather than dumping everything
in one list); each section becomes its own titled card. A row with `options` (+ `order`)
renders as a Dropdown — the right choice once there are more than two or three
mutually-exclusive options, since a wall of radio-style checkboxes doesn't scale; adding
`atlas` (a single atlas name, or an array of them for a role-icon-set style) puts small
icon preview(s) of the *currently selected* option beside it, each checked with
`C_Texture.GetAtlasInfo()` first because a missing atlas draws nothing at all with no
error. A row with `min` renders as a Slider, committed on mouse-up rather than while
dragging — for a setting that is genuinely a number, like Data Bar's width. A row with
plain `get`/`set` renders as a checkbox, for real booleans. Everything else is a plain
read-only label/value line, for a *measurement*; a yes/no belongs in `state` instead.

**An inactive module's `GetInfoRows()` is never called**, and its tab ends at the
Conditions card. That is correctness before performance: these rows report *live* state,
and a module that never ran has none — `Enable()` didn't fire, so its frames don't exist
and anything it reported would be a default or a lie. The cost is real too: `GetInfoRows`
runs on every refresh while its tab is open, and EllesmereUI Misc' walks the entire guild
roster and both friend lists. The test is `active`, which is false for conditions unmet,
for user-disabled, and for an `Enable()` that threw — in all three the module isn't
running. The tradeoff is that a switched-off module's settings aren't reachable until
it's switched back on, which is the right way round: settings shown for something that
isn't running invite changes that quietly do nothing.

Refreshes are **in place**, not rebuilds. `AniMods.RefreshUI()` (called by a toggle, or
by a module's own event handler noticing its data changed) updates the text of existing
widgets, so a counter ticking over never disturbs an open dropdown or the scroll
position. Only when a section's row *shape* changes — a row genuinely appearing or
disappearing — is that one section rebuilt, and a section holding an open dropdown is
skipped until the menu closes (`openDropdownSection` in `UI.lua`). Nothing polls; there
is no timer behind any of it.

This is deliberately one generic row vocabulary rather than a widget framework — extend
it when a module needs something `GetInfoRows()` can't express, which is how `state`,
`picker` and `strip` got here.

### Why conditions?

Some patches only make sense in the *absence* of another addon that already does the
same thing (ChatContextSwitch below stands down while NDui's chat module — which ships
this exact behaviour — is handling it). Others only make sense *with* a specific addon
present: NSRT Misc adjusts Northern Sky Raid Tools' own settings, so without it there is
nothing to adjust. `conditions` makes that explicit and inspectable instead of silently
double-hooking or crashing on a missing global, and the panel can then answer "why is
this off" with a checklist rather than silence.

The rule that decides whether something belongs here: **a condition is right when another
addon already _does_ this, and wrong when another addon merely _inspired_ it.**

Say **"loaded", never "installed"** — every one of these is an `AniMods.IsAddOnLoaded`
check, and an addon sitting on disk but switched off in the addon list is installed yet
not loaded. "Not installed" would tell someone a folder they can see doesn't exist. It's
also the more precise word for the third case: an enabled load-on-demand addon isn't
loaded until something demands it.

Both halves have been learned the hard way. GroupRoles and SocialStatus each carried a
"requires EllesmereUIQoL" / "requires EllesmereUIMinimap" for a while, which gated the
*data* on a *presentation* concern — the counts are plain Blizzard API and the brokers
work on a stock UI, so those conditions denied a working feature to anyone without the
addon they merely resembled. Both are gone. Both now instead carry "NDui not loaded",
which is the other half of the rule: NDui genuinely ships the same counts
(`Modules/Misc/RaidTool.lua`, `Modules/Infobar/Friends.lua`), so running alongside it
means two widgets showing one number.

GroupRoles' NDui condition was in fact removed once, on the argument that NDui shows its
counts on a *different surface* so suppressing a databar widget over it was the user's
call rather than the addon's. That argument was sound; the call was subsequently made.
It is recorded in the module so the next reader doesn't undo it a third time.

### Doing nothing when nothing happened

The addon runs **no periodic work of any kind** — no `OnUpdate`, no `NewTicker`. Every
module is woken by an event, and the only `C_Timer` calls left are bounded one-shots
(the 2/5/10/20s retry ladders that wait for an EllesmereUI frame that is genuinely
created later, which stop once it appears) and next-frame deferrals. Load-order waiting
is not one of those cases any more — that goes through `W.OnReady`, see the UI section.
Three rules keep it that way, and all three were learned by getting them wrong first:

- **Register the event that means what you want.** GroupRoles listened on `UNIT_FLAGS`
  for role-count changes. `UNIT_FLAGS` fires when a unit's PvP / combat / AFK flags
  change, for any unit the client tracks — many times a second in a raid — and has
  nothing to do with `UnitGroupRolesAssigned`. Each firing paid for a full roster walk
  and a broker-text rebuild to arrive at identical numbers. The event that actually
  means "someone's assigned role changed" is `PLAYER_ROLES_ASSIGNED`.
- **Coalesce per-item event bursts.** `AniMods.Coalesce(fn)` (`Core.lua`) wraps a
  handler so a burst collapses into one deferred call on the next frame. Several of the
  events modules care about aren't "something changed" notifications but per-item ones:
  `BN_FRIEND_INFO_CHANGED` fires once per friend whose status, AFK flag or
  rich-presence text moves — dozens of times within a second or two at login — and
  `GUILD_ROSTER_UPDATE` fires repeatedly per roster query. Answering each separately
  redoes the same walk N times to reach the state the last one alone would have
  produced. This is a one-shot per burst, **not** a poll: nothing is scheduled while
  idle. Its deferred body is built once per coalescer rather than once per burst —
  building it inside the scheduler is the obvious way and means the helper that exists
  to avoid N walks produces garbage on the same schedule as the bursts it's damping.
- **Compute what the caller actually needs.** Social Status' broker needs two integers,
  and recomputed them on every friend/guild event through the same full gather its
  tooltip used — allocating a 7-field table per online guild member (700+ in a large
  guild), resolving each one's class through `C_CreatureInfo`, and running three
  `table.sort`s, only to call `#` on the results. `CountOnline()` does the same three
  walks and the same de-duplication without any of that. The gather itself is gone
  entirely now, along with the hand-built popup it fed — EllesmereUI draws that list —
  so `CountOnline` is all that remains, and the de-dup rules it once had to keep in step
  with a second implementation have nothing left to disagree with.

- **Normalise once, not per access.** `Bar`'s `ModuleDB()` ran its migration check,
  duplicate repair and defaults on *every* call — and it's called from `Relayout`, from
  `Refresh`'s per-widget loop, from `BarColor`, `ApplyAppearance`, `IsLocked` and every
  settings row, so one bar repaint allocated a dozen throwaway tables deduplicating a
  list that hadn't changed since the last time it was deduplicated. One-time work needs
  a one-time guard. The repair also has to mutate **in place**: returning a fresh table
  replaced `db.order` on every read, and the preview strip holds a reference to that
  array and edits it as you drag.
- **Count once, read many.** `SocialStatus` had two readers of the same two integers —
  the broker text and the panel's Status rows — and each called `CountOnline()` itself,
  so with that tab open every friend event walked the guild roster and both friend lists
  *twice* in one frame. The walk happens where the event is handled; both readers take
  its result. Safe to serve to a panel opened later, because those numbers can only
  change through the events the module listens to.

Two smaller ones in the same spirit: hot loops reuse their scratch tables and their unit
tokens rather than rebuilding a set of 40 identical strings per walk (`RAID_UNITS` /
`PARTY_UNITS` in `GroupRoles.lua`, the `wipe()`d scratch sets behind `CountOnline`);
and `Broker.SetText(obj, text)` assigns only on an actual change, because LDB data
objects are proxy tables whose `__newindex` fires
`LibDataBroker_AttributeChanged_<name>` unconditionally — it never compares against the
current value, so re-assigning an identical string still walks the callback list and
makes every subscribed databar repaint for nothing. Since most of what wakes these
modules leaves the displayed numbers unchanged, that no-op repaint was the common case.

## UI

`/ani` — the only slash command — opens the settings panel, drawn with `AniMods.W`
(`Widgets.lua`) on EllesmereUI's public skinning API, so it wears the same window dress
as the rest of the suite and follows the user's theme live.

A **sidebar** lists the modules, each row carrying a colored status dot (green = active,
gray = user-disabled, orange = inactive/condition unmet, red = failed) and a **power
button** that switches the module on or off. Both live in the list rather than inside
each tab, so the whole set is switchable without opening any of them. Switching a module
that cannot apply the change live raises a reload prompt and a "Reload needed" badge on
its tab; one that implements `SetEnabled(on)` just applies.

Rows are grouped under **categories**, declared per module as `category` and ordered by
`CATEGORY_ORDER` in `UI.lua`. Each heading answers one question, which is what keeps a
module from having two plausible homes:

| Category | What earns a place in it |
| --- | --- |
| **At a Click** | Something you change often, without opening anything. |
| **At a Glance** | Something you read, without opening anything. |
| **Automation** | Something that runs itself, at the moment it matters. |
| **Additions** | Behaviour the base game doesn't give you — either something new, or something it should do and doesn't. |
| **Addon Extras** | What another addon doesn't offer itself. |

The order is by how much you interact with a group, not alphabetical: the ones always
doing something sit high, and **Addon Extras** sits last because it is the group most
likely to be greyed out, depending on what else is installed. A module with no `category`
sorts above every heading — that is General's place and nothing else's, since the addon's
own settings are not one of the patches.

The last two are the real axis: **Additions** is the base-game shelf and **Addon Extras**
is the other-addons shelf. Everything else is a question of how you interact with it.
An earlier cut split Additions into new-capability and fixed-misbehaviour halves, which
was a finer line than the shelf needs and cost two categories of one member each.

Each tab shows: the module's title, a `?` for its description, a state badge, and — for
a `forceable` module held back only by soft conditions — a "Run anyway" switch. Below
that, its **Conditions** card (one row per entry, each with a Yes / No badge and its
own `?`) — which is the whole explanation of why a module is inactive, so there is no
prose reason line beside it — then, **only if the module is actually running**, its
`GetInfoRows()` (see above),
grouped into titled cards. If a
module's `Enable()` threw an error (state "Failed"), a **Show Error** button opens a
popup with the full traceback (message + `debugstack()`) — not just the one-line `pcall`
message. (WoW's addon sandbox doesn't expose the `debug` table at all — only specific
whitelisted globals like `debugstack()`, which is what this actually uses.)

### Built on EllesmereUI's public skinning API

`Widgets.lua` draws nothing itself. It registers once —

```lua
EllesmereUI.RegisterSkin("AniMods", function(S) ... end)
```

— and every surface is painted by `S`, the facade EllesmereUI hands third-party addons
over its window-skin engine (`EllesmereUIBlizzardSkin_SkinAPI.lua`). `S.Shell` dresses the
panel as a native EllesmereUI window, `S.Panel` / `S.Button` / `S.Checkbox` / `S.Dropdown`
paint the controls, and `S.GetFont` / `S.GetAccentColor` / `S.GetPanelColor` report the
live theme.

This replaced eight undocumented couplings into EllesmereUI internals — `MakeBorder`,
`PanelPP`, `RegAccent`, `DisablePixelSnap`, `MakeDropdownArrow`, `GetFontPath`,
`EXPRESSWAY`, plus a copied palette — with one published contract. The facade's own
header states the terms: it is the public surface (never raw `WSkin`), its entries are
late-bound pass-throughs so engine internals stay free to change, its signatures are
additive-only and versioned by `S.apiVersion`, and each callback is `pcall`-isolated so a
mistake here cannot break EllesmereUI or vice versa. One of the replaced internals,
`RegAccent`, had already crashed this addon on login because its shape was guessed wrong.

What that buys beyond safety: the panel now **live-follows the user's window style**.
`S.Shell` registers it with the engine, so switching between the "eui" atlas look and the
flat "modern" colour — and editing the Modern colour — applies with no reload. Accent
changes propagate through `S.OnLooksChanged` into a weak-keyed registry of the things
AniMods colours by hand — the window title, card headers, `?` markers, the slider fill,
the sidebar's selection marker, and the Data Bar's drag handle. A few can't be a flat
recolour and re-run their own paint instead (`W.OnLooksChanged`): the toggle's track and
the power button both depend on the accent *and* on their on/off state.

`W.RefreshLooks()` is public for a reason worth stating, because getting it wrong looked
exactly like a broken colour picker: two different things must be able to trigger a
repaint — the host theme changing, and AniMods' own accent setting changing — and only
the first comes from the provider. It also reads `W.Accent()` rather than
`S.GetAccentColor()`, or it would repaint in the host's colour and discard the user's
choice.

**There is no provider test anywhere in `Widgets.lua`.** `Compat.lua` picks one at load —
EllesmereUI's facade when it's there, an AniMods-owned implementation of the same
interface when it isn't — and every constructor just calls `S`. That's what keeps this
from being the fallback pattern it replaced: the old code asked "is EllesmereUI loaded?"
at eight call sites and carried a hand-drawn branch behind each, so every widget had two
renderings to keep looking alike.

The second rendering does still exist — a stock Blizzard UI needs one — and it's worth
naming rather than glossing. The difference is that it's one file behind one boundary,
implementing someone else's published contract, instead of a branch inside every widget.

**Consequence: AniMods has no hard dependency on EllesmereUI.** The panel, the brokers and
every module work on a stock UI. `Compat.lua` implements only the members `Widgets.lua`
actually calls (`Shell`, `Panel`, `Button`, `Checkbox`, `Dropdown`, `Font`, plus
`GetAccentColor`, `GetPanelColor`, `GetFont`, `GetStyle`, `OnLooksChanged`, `IsEnabled`
and `apiVersion`) — implementing the rest of EllesmereUI's facade unused would be
inventing a contract nothing exercises.

**Which provider answered is also what decides whether AniMods' own accent setting
applies.** The stock provider's `GetAccentColor` reads the colour picked in **General**
(defaulting to EllesmereUI's own green, so both providers look like the same addon);
EllesmereUI's facade answers from the user's EllesmereUI theme and knows nothing about
our setting. So "EllesmereUI wins when it is present" is structural — enforced by which
implementation is in play — rather than something a settings control has to remember to
honour. The swatches in General grey themselves out to match, which is a *reflection* of
that rule, not the mechanism.

#### The restrip rule

This applies to EllesmereUI's provider; `Compat.lua` has no such registry. `Widgets.lua`
follows the rule unconditionally anyway, which is what lets one set of constructors serve
both providers — don't "optimise" it away for the stock path.

`S.Panel` and `S.Shell` enrol their frame in the engine's **restrip registry**.
`WSkin.Restrip()` is a global sweep — called from ~20 places whenever a Blizzard window
repaints (Collections, Spellbook, Guild, Calendar, Loot, Item Upgrade, …) — and it
alpha-zeroes every direct texture region on every registered frame except the engine's own
protected keys.

So **never add a texture directly to a frame passed to `S.Panel` or `S.Shell`**; it
silently vanishes the first time the player opens their collections. Our art goes on a
child frame instead. That is why `W.Window` returns `.content` rather than letting callers
draw on the window, why `W.Dropdown` and `W.Button` hold their label on an `inner` child,
and why `W.CheckMark` puts its fill on a child of the box. This is the one non-obvious part of the
contract, and the developer guide (`EllesmereUI\SKINNING_API.md`, which does ship) is
worth reading alongside it.

The Data Bar is the single exception in the addon: its frame is a plain `CreateFrame`
that never goes through `S.Panel`, because its background is a user setting rather than
frame dress — so it is not registered, and its fill, border and drag handle live directly
on it.

#### Sequencing, not polling

`W.OnReady(fn)` runs `fn` when the facade arrives, or immediately if it already has.
EllesmereUI dispatches at `PLAYER_LOGIN` *after its own boot*, so that callback is the
first moment both the skin engine and EllesmereUI's frames are guaranteed to exist —
which is why `GroupRoles:Enable()` hangs its first pass off `OnReady` instead of firing
during `PLAYER_LOGIN` and relying on a retry ladder to catch up. The ladder that remains
covers only what EllesmereUI genuinely creates later.

Layout stays a deliberate non-engine: `W.ResetStack`/`W.Stack` place children
top-to-bottom with a running cursor, which is all this panel needs and is far easier to
verify than a generic solver. `Widgets.lua` keeps only alpha and metric tokens — every
colour now comes from the theme, so there is no copied palette left to drift. Only
`Libs\LibStub` remains bundled (for LibDataBroker lookups).

## Commands

`/ani` — open the panel. That is the whole surface.

`list`, `enable` and `disable` existed before the panel did and duplicated it
afterwards — badly: `list` printed a state the sidebar's status dots already show at a
glance, and `enable`/`disable` wrote the same saved variable as the module switch while
always reporting "/reload to apply", whether or not that was true. The switch now
determines that properly (see `SetModuleEnabled`), so the commands were removed rather
than fixed twice.

The panel is also reachable from the minimap button and the addon compartment entry,
both toggleable in **General**.

## Current modules

- **General** — AniMods' own settings rather than a patch: the minimap button, the addon
  compartment entry, and the accent colour. `order = 0` so it heads the sidebar instead
  of sorting alphabetically into the middle, and `essential = true` so it has no power
  button — there is no coherent meaning to switching off the tab that contains the
  switches.

  The minimap button is hand-rolled rather than LibDBIcon-driven (one button does not
  justify the library), but borrows its geometry exactly — radius
  `Minimap:GetWidth()/2 + 5`, a 31×31 button, 24×24 background, 18×18 icon, and the
  `GetMinimapShape` convention with the diagonal clamp — because that is what makes it
  sit on the same ring as every other addon's button instead of near it.

  The accent swatches are colour squares, not a dropdown: the list they replaced named
  `0.047/0.824/0.616` "Green" when it is a mint, and carried a separate "Teal" that was
  nearly the same colour. Showing the colours removes both the naming and the question of
  whether the name is accurate. They grey out under EllesmereUI, which supplies the accent
  itself — see the provider note in the UI section.

  **Saved settings** reports what is in `AniModsDB` that nothing owns any more — the
  leavings of a module renamed, removed or split — and offers to remove it. AniMods owns
  two top-level keys itself (`modules`, `forced`); every other one belongs to a module,
  which says so by declaring `dbKey`. That is *declared*, not derived: the obvious
  derivation (lowercase the module name's first letter) gives `nSRTMisc` for NSRTMisc and
  never had a hope with the old `euiMisc`, and a wrong guess here doesn't misreport
  anything — it deletes live settings.

  The cleanup is **never automatic**. A module commented out of the `.toc` for an
  afternoon looks exactly like one deleted for good, and pruning at login would throw its
  settings away the first time that happened, silently, on the login where nobody expects
  to lose anything. A **Show** button lists what would go and a **Remove** button does it.
  Renames are separate and still automatic (`MODULE_RENAMES` in `Core.lua`), because a
  rename knows where the settings should land; this only handles what has nowhere to go.
- **Data Bar** — a minimal LibDataBroker display bar, so AniMods' own broker widgets (and
  any other addon's) have somewhere to live on a stock Blizzard UI. Off by default: if a
  real data bar is installed, that one should be used. Its "no other data bar" condition
  is therefore `soft` — advice, not a prerequisite — so the panel offers **Run anyway**
  when that is the only thing holding it back.

  Widgets are picked from a multi-select dropdown and ordered by dragging a preview strip
  whose cells show each widget's *live output* (the same string the bar renders), with the
  registered name in the cell's tooltip. Layout is EllesmereUIDataBars' "even" sizing
  mode: equal shares of the bar, with cumulative rounding so the last slot lands exactly
  on the edge, and a widget measuring zero taking no share. That is what makes ORDER the
  only spatial choice left — and why there is no per-widget position setting, and no
  maximum-width cap, since each widget is bounded by its share already.

  Appearance is deliberately three controls (colour with alpha, texture, border) plus
  lock and width. A lightweight bar with a heavyweight options tab is not lightweight.
  Textures come from LibSharedMedia when something has registered it — a registry, not a
  dependency, so it offers whatever the user's other addons contributed and simply has
  nothing to offer when nothing has.

  It does **no periodic work**, unlike AbstractBar (the closest comparable, and the source
  of the good ideas here: a generic `DataObjectIterator` + `LibDataBroker_DataObjectCreated`
  subscription rather than a private list, and dirty-checking before touching a
  FontString). AbstractBar's refresh is an unconditional `C_Timer.NewTicker(1.0)` running
  all session even when the bar is hidden — defensible for its own clock and FPS widgets,
  which have no events, but AniMods has no sampled widgets at all. Every broker here
  *pushes*, so the bar listens to `LibDataBroker_AttributeChanged` and does nothing
  otherwise.
- **ChatContextSwitch** — cycle chat channel (SAY → PARTY → RAID → INSTANCE_CHAT →
  GUILD → OFFICER → world CHANNEL) with Tab / Shift+Tab in the chat edit box. Ported
  from NDui's chat module (`NDui/Modules/Chat/Core.lua`). Each channel in the cycle can
  be individually enabled/disabled from its detail pane ("Channels in the cycle"
  section), which also shows which ones are eligible right now (an **Active** badge). OFFICER
  and the world CHANNEL default to off (most players aren't guild officers or in a
  custom world channel — by default they'd just be two usually-dead stops every lap);
  the rest default on. Only active when NDui is *not currently handling this itself* —
  NDui's own chat module installs the identical hook, but only when enabled
  (`C.db["Chat"]["Disable"]` is falsy); if NDui is installed with its chat module turned
  off, this still applies. Migrated from the standalone ChatContextSwitch addon (now
  removed). Half-baked / not fully tested — bugs may remain from the original.
- **GroupRoles** — Tank/Healer/DPS role counts while in a group; its detail pane's
  "Status" section leads with **In group [Yes|No]** and shows the live counts under it
  when there are any. EllesmereUI's QoL Raid Tools panel has no composition display the
  way NDui's raid tool does, so this fills the gap.

  **One condition: NDui not loaded** — its raid tool draws the same three counts
  (`Modules/Misc/RaidTool.lua`, `M:RaidTool_RoleCount`), so this stands down rather than
  showing them twice.

  EllesmereUIQoL is deliberately *not* a condition, though it once was. That requirement
  denied a stock UI its role counts over a badge it wasn't going to show anyway — the
  counts come from `UnitGroupRolesAssigned`, a plain Blizzard call, and the broker works
  in any data bar. Only the *docked badge* needs EllesmereUIQoL, and that's handled where
  it happens: `TryDockToEUIIcon` returns when the icon doesn't exist, so the module
  degrades to broker-only by itself and the Integration section reports whether it
  actually docked. Named for what it
  reports — assigned *roles*, in a party as well as a raid; it was called
  `RaidComposition` until the rename, which was wrong twice over (it works in 5-mans,
  and "composition" normally means the class/spec makeup rather than the role split).
  `Core.lua`'s `MODULE_RENAMES` migrates the old saved-variable keys
  (`db.modules.RaidComposition`, `db.raidComposition`) on first login after the rename,
  so no setting is lost; the LDB object name changed too, which does orphan an existing
  databar block (see below). Two display surfaces, both driven by the same counts:

  - **Docked badge** — a compact count badge anchored just below Raid Tools' own
    collapsed icon (the global frame `EllesmereUIRaidToolsIcon`), reading as part of
    that minimized display rather than a separate floating thing. Docking is the only
    display mode (no floating fallback window) — the detail pane's "Integration"
    section reports **Docked to EllesmereUI icon [Yes|No]**, with the reason why not in
    its `?`, since
    EllesmereUIQoL only builds that icon on first use of Raid Tools with a non-"never"
    mode ("never" is its own default), so there may briefly (or permanently) be nothing
    to dock to. Anchored via `SetPoint` (just reads its rect) and synced two ways:
    `HookScript("OnShow"/"OnHide", ...)` on the icon, and an `OnClick` hook on it for
    zero-latency feedback on the expand action specifically
    (`SecureHandlerClickTemplate`'s secure `_onclick` attribute is a separate execution
    path from the button's ordinary `OnClick` script, which still fires too).

    The `OnShow`/`OnHide` **scripts** are load-bearing here, as opposed to
    `hooksecurefunc(iconBtn, "Show"/"Hide", ...)` — which is what this used to do. Both
    see EUI's own visibility changes even though those run through a secure
    `SecureHandlerStateTemplate` snippet rather than a plain Lua call, but only the
    script handlers fire on *effective* visibility changes, i.e. when the icon is
    hidden or shown because an **ancestor** was. A parent's `Hide()` never calls the
    child's, so the method hooks silently missed that whole class of transition —
    which is exactly why a permanent `C_Timer.NewTicker(0.15, ...)` used to sit here as
    a backstop, waking ~7 times a second for the entire session to poll `IsShown()`.
    The script hooks close the gap properly and the ticker is gone; this module now
    does no periodic work at all. (The visibility check is `IsVisible()`, not
    `IsShown()`, for the same reason: `IsShown()` reports only the button's own flag
    and stays true under a hidden ancestor.) No taint risk (never touches EUI's secure
    frames, only observes and anchors to them). Can be hidden entirely (**"Show docked
    badge"**, on by default) while staying hooked/tracking underneath — useful together
    with the broker plugin below, so the same counts aren't shown twice (once docked,
    once in a databar) for anyone who'd rather rely on just the broker. No tooltip by default — a second popup
    fighting for the same screen space as EUI's own Raid Tools UI can be more annoying
    than useful — but opt-in via **"Show tooltip on docked badge"** in the "Integration"
    section, sharing the exact same tooltip as the broker plugin below, anchored via a
    **"Tooltip anchor"** `Dropdown` picking one of the 8 standard `GameTooltip` anchor
    points (`ANCHOR_TOP`/`ANCHOR_BOTTOMLEFT`/etc.) relative to the badge — defaults to
    Right so it doesn't pop out overlapping EUI's own icon sitting directly above the
    tiny (36x12) badge. The detail pane shows EUI's actual configured mode directly
    (`_G._EUI_RaidTools_DB()`, the plain read-only getter
    `EllesmereUIQoL_RaidTools.lua` exposes for its own options panel) as part of the
    dock-status line when not yet docked.
  - **Broker (LDB) plugin** — registers as a LibDataBroker data source
    (`AniModsGroupRoles`, labelled "AniMods: Group Roles"), pickable as a widget in
    EllesmereUIDataBars (or any other LDB-consuming data bar). **The object name is an
    ID, not a label**: EllesmereUIDataBars stores it verbatim in its own saved variables
    as the block's `source` and shows it in the data-source picker, so the rename from
    `AniModsRaidComposition` orphans any databar block that already pointed at the old
    name — re-pick it once from the picker. That's also why it shouldn't be renamed
    again casually. EUI ships LibStub + LibDataBroker-1.1 itself
    (`EllesmereUI/Libs/`), and AniMods bundles LibStub for the lookup, so no copy of LDB
    is embedded; when it genuinely isn't there, `Broker.Register` returns nil and the
    "Broker widget" section says so. `text` goes empty — not "N/A" — when solo, so a
    transparent-background databar can just disappear. Otherwise built from two
    independent options in the "Broker widget" section: a `Dropdown` "Style" —
    **Icon + Text** (an inline texture escape — `|A:atlas:h:w|a` for an atlas style,
    `|Tpath:h|t` for a texture-file one — styled to match whichever icon style is
    selected, packed with no padding — the icon alone tells the three roles apart, so no
    separator either) or **Text Only** (falls back to a `/` separator between roles,
    since there's no icon to lean on there) — and colored text (role-tinted numbers,
    matching the docked badge's blue/green/red). Hovering shows a headcount-bearing
    header (e.g. "Raid (13)", not just "Raid"), a one-line composition summary ("2 Tank
    5 Healer  6 DPS"), and a per-role breakdown of class-colored squares (one per member
    in that role) below that. Left-clicking opens Blizzard's own raid roster/role/
    ready-check frame (`ToggleRaidFrame()`, the same global SavedInstances uses — lazy-
    loads `Blizzard_RaidUI`, guarded against combat lockdown) — the actual
    raid-management UI, not this module's settings; right- or middle-clicking opens the
    AniMods panel switched straight to this module's own tab
    (`AniMods.OpenModuleTab("GroupRoles")`), whether or not the panel was already
    open on a different one.

  Role icons ("Icon Style" section, a `Dropdown` with a live preview of the selected
  style's Tank/Healer/DPS icons via three `W.Icon` widgets alongside it) default to
  matching EllesmereUI's own look, but other addons' looks are offered too since there's
  no reason to force just one. Each style is either `kind = "atlas"` (a plain Blizzard
  atlas name — nothing to embed, the art lives in the game client) or
  `kind = "texture"` (a bundled `.tga` file, an actual asset AniMods ships, rendered via
  `|Tpath:h|t` / a plain `Icon:SetImage(path)` rather than the atlas path):

  - *Atlas styles* — 5 of EllesmereUIRaidFrames's 7 `ROLE_ICON_STYLES` are plain
    Blizzard atlas name references (Modern Circle/Styled/Classic Circle/Classic/Blizzard
    Default) — no license concern, since the atlas art lives in the game client, not in
    any addon's files. Its other 2 styles ("modern", EUI's actual default, and
    "blizzLight") point at EUI's own custom PNGs, not reproduced here since EUI's
    license is all-rights-reserved. "NDui" uses the same atlas set NDui's own
    raid-frame/roster UI shows (`groupfinder-icon-role-micro-*`, from
    `B:ReskinSmallRole` in `NDui/Core/Functions.lua`) — again a plain Blizzard atlas
    reference, not a copy of an NDui-authored asset.
  - *Texture styles* — NDui_Plus overrides that same `B.ReskinSmallRole` with a choice
    of genuinely different custom icon art instead of the plain atlas
    (`NDui_Plus/Media/Media.lua`, `P.RoleList`, 5 sets). NDui_Plus is MIT-licensed
    (`Copyright (c) 2021 Witnesscm`), so its `.tga` files are copied into
    `Media\RoleIcons\` (with the license text alongside them,
    `Media\RoleIcons\LICENSE.txt`) rather than merely referenced — same as any other
    bundled Lib, this module doesn't depend on NDui_Plus being installed. Only 4 of
    NDui_Plus's 5 `RoleList` sets have real backing files in this install
    (`ToxiUI/Stylized*` is a dead reference with no texture behind it there), so only
    those 4 are offered: **NDui_Plus: LynUI**, **NDui_Plus: ElvUI**,
    **NDui_Plus: ToxiUI White**, **NDui_Plus: ToxiUI New**.

  Selecting a style applies live, no reload needed.
- **Extra Button Click-Through** — the zone/extra ability button draws a decorative
  surround much larger than the button itself, and that surround takes the mouse: clicks
  landing on the art near the button hit nothing, and anything underneath it — an action
  bar, a unit frame — is unreachable while the button is up. This switches the mouse off
  on the decoration (`ExtraActionBarFrame`, `ExtraAbilityContainer`, `ZoneAbilityFrame`
  and its `Style` child) and leaves the button itself alone, so it stays clickable.

  Ported from EUI_Kogotool's `BlizzUIEnhance.lua`, with three deliberate differences.
  Its apply function ignores its own setting, so switching the option off still disabled
  the mouse; here the revert actually puts it back. It guards combat on one of the three
  frames only, while all of them are protected — `EnableMouse` on a protected frame in
  combat is blocked, so every one is guarded and the work is deferred to
  `PLAYER_REGEN_ENABLED`. And its list is incomplete: it silences
  `ZoneAbilityFrame.Style` but not `ZoneAbilityFrame`, which is mouse-enabled in its own
  right and sits *above* `Style` in the stack — `/framestack` over the surround names
  `ZoneAbilityFrame` as the frame taking the click, so silencing only the child changes
  nothing there.

  Disabling the parent doesn't reach the spell button: `EnableMouse` is per frame, and
  the button is a child of `ZoneAbilityFrame.SpellButtonContainer` with its own mouse
  still on. Edit Mode keeps working too — dragging that system goes through
  `ExtraAbilityContainer.Selection`, an overlay with its own mouse.

  The frames are built on demand, so the setting is re-asserted rather than applied once:
  `UPDATE_EXTRA_ACTIONBAR`, `ZONE_CHANGED_NEW_AREA`, `PLAYER_ENTERING_WORLD` and
  `PLAYER_REGEN_ENABLED`, plus `OnShow` and `UpdateDisplayedZoneAbilities` hooked on the
  frame itself once it exists. The events alone say "something changed", not "the frame
  is there now" — the zone ability is built the first time the game has one to show,
  which can land after all of them. EllesmereUI's own skin hooks the same pair.

  This lived in a bag called **EllesmereUI Misc** (originally **Skin**) alongside two
  entries that are now gone: a re-home of Blizzard's `TextToSpeechButton` into
  EllesmereUIChat's sidebar, and a re-skin of EllesmereUIMinimap's addon-icon flyout
  toggle. That bag gated everything in it on EllesmereUI being loaded, which was wrong
  on its own terms for this one: the frames are Blizzard's, the problem is Blizzard's,
  and a stock UI has it just as much. So it is a module with no gate. The bag itself
  came back later for **Missing Stats**, which genuinely is EllesmereUI-only.
- **EllesmereUI Misc** — the bag for small EllesmereUI-only tweaks, each an
  independently switchable **entry** rather than one bundled setting: its detail pane has
  a section per entry, each with its own "Enabled" checkbox, "Available" statement
  (whether that entry's prerequisites are met, independent of the toggle) and "In effect"
  statement.

  The bar for an entry: it is **meaningless without EllesmereUI**, and it's
  **reversible**. That second one isn't decoration — these apply and revert live, which
  is what exempts this module from the framework's usual "toggle takes effect next
  reload" convention, and one irreversible entry would quietly take that property away
  from every other entry in the bag.

  The bar used to include "small enough that a whole module would be ceremony". That
  clause was removed rather than left quietly broken when Social Status folded in:
  it arrives with its own counting walk, icon resolution and broker, and is plainly not
  small. Membership is decided by being meaningless without EllesmereUI; size is
  whatever that costs.

  - **Missing Stats** — EllesmereUIQoL draws a stats block (`EUI_SecondaryStats`) with
    crit, haste, mastery, versatility, the three tertiaries and an optional FPS/latency
    pair. It has no item level and no primary stat, and it *cannot be given any*: the row
    builder is a closure, the dispatch is a hard-coded `if`/`elseif` over a fixed key
    set, and the FontString is repainted with `SetFormattedText` on every stat event, so
    an appended line is gone on the next tick. Adding a key to the order EUI publishes as
    `EllesmereUI._secondaryStatsOrder` renders nothing, because nothing in that chain
    matches it.

    So this is a second block that reads as part of the first: anchored `BOTTOMLEFT` to
    EUI's `TOPLEFT` so it grows upward and never shoves that block down, copying font,
    size, spacing and label colour straight off EUI's own FontString rather than
    resolving its font API again. EUI sizes and positions that frame, so these rows
    follow it around for free.

    There is deliberately **no standalone mode**. An earlier version stood alone and
    movable when EUI's block was absent, built on a misreading of what this is: it isn't
    a stats display, it's the two rows EllesmereUI's display is missing. Without that
    block there is nothing to be missing from.

    Labels are **localised**, unlike the settings panel — this text is drawn inside
    EllesmereUI's block, which reads the player's language. The client answers for most
    of it (`SPELL_STAT<N>_NAME`); what it doesn't give is short forms, since
    `SPELL_STAT4_NAME` is "Intellect" and `ITEM_LEVEL_ABBR` is "ilvl" on *every* locale
    including zhCN. So there are two small tables for exactly those gaps: English stat
    abbreviations (the CJK names are already two characters and can't be shortened, and
    inventing one for "Beweglichkeit" would be guessing at someone else's language), and
    装等 / 裝等 for item level, which is what NDui carries in its own locale files for
    the same reason.

    Secret values are handled the way EUI handles its own — figures are never read in
    Lua, they travel as arguments to `SetFormattedText` and the engine fills the
    template. The one cost is measuring: `GetStringWidth` on a FontString fed a secret
    hands back a secret, so the last known size is kept until the figures are readable,
    and the test is on what the arithmetic is about to touch rather than on what was fed
    in — the metrics belong to the last *laid out* string.

  - **Social Status** — EllesmereUIMinimap's friends button as a data bar widget: online
    guild and friend counts on the bar, and **its own popup** on hover.

    It was a standalone module once, and a much bigger one. The header then claimed EUI's
    button and its tooltip were "entirely unreachable from outside
    EllesmereUIMinimap.lua" — the button unnamed, the table holding it a plain `local`,
    the tooltip wired with `HookScript` and so not retrievable via `GetScript()` — and
    concluded with a **faithful port**: `GatherOnlineFriends` and the whole custom
    bordered popup, reproduced line for line.

    **Both halves of that were false.** `HookScript` composes into the script, so
    `GetScript` returns the wrapper including the hook; and the tooltip is wired with
    plain `SetScript` anyway. The button is findable by *shape* rather than by name — it
    carries `_indicatorKey == "_friends"` among `Minimap`'s children — and the popup
    frame itself is reachable as `_friendsTT` on the module namespace that
    `EllesmereUI.Lite.GetAddon("EllesmereUIMinimap", true)` returns. So the hover now
    calls EUI's own `OnEnter` under `xpcall`, positioned by `W.AnchorNear`, and the port
    is gone — around 170 lines of it, along with the plain-`GameTooltip` renderer that
    only existed to serve a stock UI this no longer targets. There is no `OnTooltipShow`.

    The lesson, recorded because it cost two rewrites: **a frame's scripts are not an API
    you have to be given.** Identify by relationship and shape, not by name.

    What stays ours is the **counts**, and only because there is nothing to borrow: a
    count hangs off no frame script the way a popup does. It is plain Blizzard API with
    no EllesmereUI-specific judgement in it, so there is nothing to drift from — and if
    that ever stops being true, the symptom is the number disagreeing with the list the
    popup shows, and the list is the one to believe.

    Gated on EllesmereUIMinimap being loaded **and** its friends indicator existing, so
    the popup is always the answer. It merged with what was briefly a separate "Friends
    Popup" entry rather than sitting beside it: that one existed only to serve this
    widget, so two entries meant one silently depending on the other being switched on,
    and hovering with the wrong one off would have shown nothing.
- **NSRT Misc** — the bag for small Northern Sky Raid Tools tweaks: things its own UI
  can't do, either because they're batch edits it only offers one row at a time, or
  because it offers no setting at all.

  **Countdown voice.** NSRT counts down in its own bundled voice with no way to change
  it; this borrows the one you already chose in **BigWigs** or **EXBoss**. Unavailable
  sources are greyed in the dropdown rather than dropped.

  **Nothing is replaced until a non-NSRT source is chosen.** On the default setting this
  module doesn't touch `NSAPI` at all — reads no field, assigns none. That isn't
  politeness, it's the property that makes the feature *diagnosable*: setting the source
  back to NSRT returns AniMods to zero footprint on NSRT, so "is this addon involved?" is
  answerable by one dropdown change rather than by disabling things and reloading. A
  status row reports whether the replacement is currently installed.

  It matters because `NSAPI.TTSCountdown` has other claimants —
  `NSRT_Countdown_Companion` replaces the same function when enabled, and a function has
  room for exactly one owner: whoever installs second wraps the first, decided by load
  order. Installing lazily keeps us out of that contest unless asked in.

  Each addon is asked at its *highest* level, since a shape of our own would be a third
  opinion about how their settings work: `BigWigsAPI:GetCountdownSound(voice, n)` returns
  a path we play, while EXBoss **plays the digit itself** via
  `ExBoss.Voice.Countdown:TryPlayDigit(n)`, resolving its pack, per-digit switches and any
  LibSharedMedia override. Neither is cached, so neither needs a listener — reconfiguring
  either is picked up by the very next countdown.

  A trap worth recording: `BigWigsAPI` is **colon-defined**, so a dot call passes the
  voice id as `self` and the digit as `id`, looks up a voice *named* "5", and returns nil
  every time — silence, no error. BigWigs' own code reads
  `BigWigsAPI.GetCountdownList()` with a dot in places, which works only because that one
  ignores `self`.

  The replacement is a **router**: the original is kept and called for every case the
  override doesn't claim, so NSRT's behaviour is the default branch rather than something
  reimplemented. It also honours `NSRT.Settings.TTS`.

  **Silence every boss-alert countdown.** NSRT's encounter alerts each carry a
  `countdown` field, and what matters is what it means when *absent*
  (`Reminders.lua:112`): `nil` means **inherit the global setting**. Every built-in boss
  alert ships without the key, so switching TTS countdowns on for your own note reminders
  switches them on for all ~200 boss alerts too — one setting, two populations. This
  separates them.

  It writes `false`, not `0`, and that distinction is the whole reason to read NSRT's
  source rather than guess. NSRT's own UI writes `false` when you type 0
  (`EncounterAlerts.lua:2980`: `(v and v > 0) and v or false`), so "countdown for 0
  seconds" in that UI *is* `countdown = false` in the data — writing the same value is
  what makes the button equivalent to doing it by hand rather than merely similar. A
  literal `0` would look right and behave differently: `0` is truthy in Lua, so it skips
  the inherit branch as intended but survives to `Reminders.lua:1293`'s
  `if info.countdown then`, scheduling a timer that fires at the end of the alert and
  calls `TTSCountdown(0)` — a no-op loop (`for i = 0, 1, -1`), so harmless, but pointless
  work per alert per pull. `false` fails `tonumber` at line 119, becomes nil, and no timer
  is scheduled at all.

  **Restore to default** clears the key again so alerts follow the global setting — the
  state they ship in, which is not the same as "countdowns off". Worth having rather than
  leaving the batch one-way: this edits a couple of hundred rows of another addon's saved
  settings at a click, and the only other way back is NSRT's own per-alert reset, one
  alert at a time.

  Every level of `NSRT.EncounterAlerts[encID][diffID][key]` is type-checked on the walk.
  It is another addon's saved data — it has to survive that addon's upgrades, migrations
  and profile imports, and an unexpected shape must make this do nothing rather than error
  halfway through a batch edit. The module has no `Enable()`: it owns no frames, hooks
  nothing and registers no events, since everything it does happens on a click in its own
  tab.
- **SpecSwitch** — switch specialization and loot spec from a data bar. **Left-click**
  opens a menu of specs, **right-click** a menu of loot specs (led by "Follow current
  spec", Blizzard's default and the state you want back after borrowing one for a boss).
  Settings live at the bottom of the spec menu rather than claiming right-click.

  That's the whole click surface. EllesmereUIDataBars' block also puts a loadout menu on
  Ctrl+left-click and the talent frame on Shift+left-click, and those are deliberately
  **not** copied: a modifier-click on a data bar widget is a poor place for an action —
  nothing on the bar advertises it, so it's undiscoverable to anyone who hasn't read the
  tooltip, and it's reachable by accident by anyone holding a modifier for another
  reason. The talent frame already has a keybind. Left and right for the two things the
  widget *displays* needs no explanation: you click what you're looking at.

  Reimplemented, not copied — EllesmereUI's licence is all-rights-reserved, the same
  reason its role-icon PNGs are referenced rather than bundled (see GroupRoles). What is
  taken is the *design*: which click does what, and which Blizzard APIs answer it.

  The popups follow EUI's look and interaction too (`W.Menu`, modelled on its
  `BuildPopup`): white title, the **accent reserved for the active row** rather than a
  check mark, hover tinting the label accent *and* washing the whole row white at 0.10,
  icons cropped `4/64..60/64` to trim Blizzard's baked border, and a footer of
  left/right hint pairs. Selection-by-accent is the right idiom for mutually exclusive
  choices — it reads as "you are here", where a tick reads as "these are on".

  This is why `W.Menu` does **not** reuse the dropdown menu: they are two different
  controls in EUI as well. Its dropdowns already look like ours (the `DD_ITEM_*`
  constants came from EUI's), while its data bar popups are their own thing.

  The bar can show the applied **loadout name before the spec** (`Raid  Frost🔹`) —
  optional, on by default, and absent when the character has saved none. Loadout first
  because it's the narrower thing: "Raid" qualifies "Frost", not the reverse. It's a
  setting because it's the one part of this widget that makes it wider, and loadout names
  are user-chosen — a bar with three widgets and a loadout called "Single Target Cleave
  Build" has a different opinion about that than one with two and "Raid". The tooltip
  shows it either way, where there's no width pressure.

  Displaying that name is what forces the module's one hook, and it's worth knowing why
  the obvious approach fails: Blizzard writes the "last selected loadout" pointer *after*
  the talent-commit events fire, so `TRAIT_CONFIG_UPDATED` and `SPELLS_CHANGED` both race
  it and read the name that was current a moment ago — listening to them gives a display
  reliably one swap behind. So the **write** is hooked instead
  (`C_ClassTalents.UpdateLastSelectedSavedConfigID`), which every path funnels through:
  Blizzard's talent UI and any loadout addon. EllesmereUIDataBars reaches the same
  conclusion for the same display (its `HookLoadoutPointer`). With loadout *switching*
  removed, that hook is the only way this module learns of a swap — there's no local
  action to update from. Unlike EUI's, the handler needs no combat guard or
  `PLAYER_REGEN_ENABLED` catch-up: theirs re-measures and re-anchors frames, which is
  protected, while this assigns a string to an LDB object and repaints a panel we own.

  It **cycled** at first, and that was wrong. With four specs, reaching a known
  destination took up to three clicks *and three intermediate spec changes* — and a spec
  change is a cast on the global cooldown, so the intermediates aren't free the way
  cycling a sound device is. It also forced a whole "specs in the cycle" settings section
  into existence whose only job was to make cycling less bad. A menu names the
  destination and goes there; both the section and the cycle are gone. Cycling still
  suits SoundSwitch, where switching is instant, reversible, and usually between two.

  **Stock UI only** — its conditions are "EllesmereUI not loaded" and "NDui not
  loaded", both hard. Each ships this exact widget already (EllesmereUIDataBars' spec
  block, `NDui/Modules/Infobar/Spec.lua`) and EUI's is better: it offers loadout
  switching and a talent-frame shortcut from the same button. Hard rather than soft
  because a soft condition is an advisory the user may overrule with **Run anyway**, and
  that only makes sense when running both is merely odd — here the alternative is
  strictly better, so there's nothing to overrule.

  Modelled on EUI's block, including its spec **cache** (`BuildSpecCache`): the list only
  changes when a character learns a spec, while the broker text, tooltip and cycler read
  it on every hover and click. The first version rebuilt it inside each, so one broker
  update walked `GetSpecializationInfo` three times to answer an unchanged question. Not
  copied are the events that exist for EUI's loadout *name* — `TRAIT_CONFIG_UPDATED`,
  `SPELLS_CHANGED`, `CONFIG_COMMIT_FAILED` — which are there because that display races
  Blizzard's last-selected pointer; showing no loadout means inheriting neither the
  problem nor the events.

  Spec switching is guarded on `InCombatLockdown()` and reports why it refused, because
  the API simply does nothing in lockdown and the click would otherwise look broken.
  Loot spec switching is combat-legal (a server preference), so it isn't guarded.

  **The text is the spec you play; the icon beside it is the spec you loot** — NDui's
  scheme (`Modules/Infobar/Spec.lua`), and a better answer than anything with labels in
  it. The two roles are told apart by *medium* rather than by wording, so no "S:"/"L:" is
  needed in any language; width is constant, because the icon is always present and
  falls back to the active spec's own when loot follows it, so the widget doesn't grow
  and shove its neighbours along the bar the moment you pin a loot spec; and the common
  case reads as decoration while the odd case reads as odd — a *different* icon sitting
  beside the name is exactly the state worth noticing, the one that silently gives you
  the wrong loot. Text Only mode drops the icon and so drops the loot spec entirely,
  which is the right degradation: it loses information rather than becoming ambiguous the
  way "Frost/Fire" would.
- **SoundSwitch** — switch the game's sound output device from a databar.
  **Left-click** cycles to the next device; **right-click** opens this module's tab,
  where each detected device has an in-the-cycle checkbox (the active one carries a
  **Current** badge), so you can skip outputs you never want to land on. The tooltip lists every
  device, highlighting the active one and dimming skipped ones.

  The core is lifted from **SoundManager** (by Zax), reduced to just the switching part —
  that addon also does per-device volume presets, its own movable frame and keybinds,
  none of which are wanted here. Only Blizzard API is used
  (`Sound_GameSystem_GetNumOutputDrivers` / `…GetOutputDriverNameByIndex`, the
  `Sound_OutputDriverIndex` CVar, and `Sound_GameSystem_RestartSoundSystem` with
  `AudioOptionsFrame_AudioRestart` as the pre-10.0 fallback), so nothing needs to be
  installed. Two non-obvious details are kept from SoundManager, both called out in its
  own comments: the **last** driver is a system-default pseudo-device rather than a real
  output and is left out of the cycle (its loop runs to `count - 1`), and driver
  **indices go stale** when the OS adds or removes an output — so settings are keyed by
  device *name* and indices are re-read fresh at the moment of switching, never stored.

  Refreshes on `CVAR_UPDATE`, which is how SoundManager notices the output being changed
  from outside (the OS, Blizzard's audio options, another addon). That's the broadest
  event registration in the addon — it fires for *every* cvar — so the handler's first
  job is to establish the event isn't ours as cheaply as possible: `strcmputf8i`, a
  Blizzard C function that compares case-insensitively **without building a lowered
  copy**. The obvious `cvar:lower() == "..."` would allocate a string per unrelated cvar
  change just to discard it, and the payload's casing isn't worth relying on.
