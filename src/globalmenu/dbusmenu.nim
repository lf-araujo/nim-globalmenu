## Client side of `com.canonical.dbusmenu`, the menu protocol Qt, Electron,
## JetBrains IDEs and libdbusmenu apps export their menubars with (they find
## the consumer through `com.canonical.AppMenu.Registrar`, see registrar.nim).
##
## A menu is a tree of items with integer ids; `GetLayout` returns a subtree
## with each item's properties, `Event` reports clicks and menus opening or
## closing, and the app announces changes with the `LayoutUpdated` and
## `ItemsPropertiesUpdated` signals. This module only reads and calls; the
## GTK widgets are built in dbusmenubar.nim.

import ./gio

const
  dbusmenuInterface* = "com.canonical.dbusmenu"
  # The properties read (see applyProperty). Asked for by name: an empty
  # list should mean "all", but Chromium answers that with an error.
  wantedProperties = "['label', 'type', 'enabled', 'visible', " &
    "'toggle-type', 'toggle-state', 'children-display', 'shortcut']"

type
  ToggleKind* = enum
    tkNone, tkCheck, tkRadio

  MenuNode* = object
    id*: int32
    label*: string ## With `_` mnemonics (`__` is a literal underscore).
    separator*: bool
    enabled*, visible*: bool
    toggle*: ToggleKind
    toggled*: bool
    submenu*: bool ## Declared a submenu; its items may arrive only on open.
    shortcuts*: seq[seq[string]] ## e.g. `@[@["Control", "Q"]]`.
    children*: seq[MenuNode]

  Layout* = object
    revision*: uint32
    root*: MenuNode

func newNode*(id: int32): MenuNode =
  ## An item with the protocol's default properties.
  MenuNode(id: id, enabled: true, visible: true)

func hasSubmenu*(node: MenuNode): bool =
  node.submenu or node.children.len > 0

func `==`*(a, b: MenuNode): bool =
  ## Same item, properties and subtree.
  if a.id != b.id or a.label != b.label or a.separator != b.separator or
      a.enabled != b.enabled or a.visible != b.visible or
      a.toggle != b.toggle or a.toggled != b.toggled or
      a.submenu != b.submenu or a.shortcuts != b.shortcuts or
      a.children.len != b.children.len:
    return false
  for i in 0 ..< a.children.len:
    if not (a.children[i] == b.children[i]):
      return false
  true

# --- Properties --------------------------------------------------------------

proc stringOf(value: GVariant): string =
  if value.typeString == "s": $g_variant_get_string(value, nil) else: ""

proc boolOf(value: GVariant, default: bool): bool =
  if value.typeString == "b": g_variant_get_boolean(value) != 0 else: default

proc shortcutsOf(value: GVariant): seq[seq[string]] =
  if value.typeString == "aas":
    for i in 0 ..< value.len:
      let keys = value.child(i)
      var combo: seq[string]
      for j in 0 ..< keys.len:
        combo.add stringValue(keys.child(j))
      g_variant_unref(keys)
      result.add combo

proc applyProperty*(node: var MenuNode, name: string, value: GVariant) =
  ## Sets property `name` from its (unboxed) value; `nil` resets it to the
  ## protocol default, as when the app reports the property removed.
  let fresh = newNode(node.id)
  case name
  of "label":
    node.label = if value == nil: fresh.label else: stringOf(value)
  of "type":
    node.separator = value != nil and stringOf(value) == "separator"
  of "enabled":
    node.enabled = if value == nil: true else: boolOf(value, true)
  of "visible":
    node.visible = if value == nil: true else: boolOf(value, true)
  of "toggle-type":
    let kind = if value == nil: "" else: stringOf(value)
    node.toggle = case kind
      of "checkmark": tkCheck
      of "radio": tkRadio
      else: tkNone
  of "toggle-state":
    node.toggled = value != nil and value.typeString == "i" and
        g_variant_get_int32(value) == 1
  of "children-display":
    node.submenu = value != nil and stringOf(value) == "submenu"
  of "shortcut":
    node.shortcuts = if value == nil: @[] else: shortcutsOf(value)
  else:
    discard # Icons, accessibility text, dispositions: not shown.

proc applyProperties*(node: var MenuNode, dict: GVariant) =
  ## Applies an `a{sv}` property dictionary.
  for i in 0 ..< dict.len:
    let
      entry = dict.child(i)
      name = stringValue(entry.child(0))
      boxed = entry.child(1)
      value = g_variant_get_variant(boxed)
    node.applyProperty(name, value)
    g_variant_unref(value)
    g_variant_unref(boxed)
    g_variant_unref(entry)

# --- Layout ------------------------------------------------------------------

proc parseNode*(value: GVariant): MenuNode =
  ## Reads one `(ia{sv}av)` layout item and its children.
  let id = value.child(0)
  result = newNode(g_variant_get_int32(id))
  g_variant_unref(id)
  let props = value.child(1)
  result.applyProperties(props)
  g_variant_unref(props)
  let children = value.child(2)
  for i in 0 ..< children.len:
    let
      boxed = children.child(i)
      item = g_variant_get_variant(boxed)
    if item.typeString == "(ia{sv}av)":
      result.children.add parseNode(item)
    g_variant_unref(item)
    g_variant_unref(boxed)
  g_variant_unref(children)

proc parseLayout*(reply: GVariant): Layout =
  ## Reads a `GetLayout` reply, `(u(ia{sv}av))`.
  let revision = reply.child(0)
  result.revision = g_variant_get_uint32(revision)
  g_variant_unref(revision)
  let root = reply.child(1)
  result.root = parseNode(root)
  g_variant_unref(root)

proc fetchLayout*(conn: GDBusConnection, bus, path: string, parent: int32,
    depth = -1, timeoutMs = 1000): (bool, Layout) =
  ## The subtree under item `parent` (0: the whole menu), `depth` levels
  ## deep (-1: all). The flag is false when the app did not answer.
  let reply = conn.callSync(bus, path, dbusmenuInterface, "GetLayout",
      g_variant_new_parsed(cstring("(%i, %i, @as " & wantedProperties & ")"),
          parent, int32(depth)),
      timeoutMs)
  if reply != nil:
    if reply.typeString == "(u(ia{sv}av))":
      result = (true, parseLayout(reply))
    g_variant_unref(reply)

proc hasItems*(conn: GDBusConnection, bus, path: string): bool =
  ## Whether the menu has any top-level items now.
  let (ok, layout) = conn.fetchLayout(bus, path, 0, depth = 1)
  ok and layout.root.children.len > 0

# --- Telling the app ---------------------------------------------------------

proc aboutToShow*(conn: GDBusConnection, bus, path: string, id: int32): bool =
  ## Tells the app a submenu is opening; true if it says its layout under
  ## `id` should be read again.
  let reply = conn.callSync(bus, path, dbusmenuInterface, "AboutToShow",
      g_variant_new_parsed("(%i,)", id), 500)
  if reply != nil:
    let value = reply.child(0)
    result = g_variant_get_boolean(value) != 0
    g_variant_unref(value)
    g_variant_unref(reply)

proc eventParams(id: int32, event: string, timestamp: uint32): GVariant =
  g_variant_new_parsed("(%i, %s, <int32 0>, %u)", id, cstring(event),
      timestamp)

proc sendEvent*(conn: GDBusConnection, bus, path: string, id: int32,
    event: string, timestamp: uint32 = 0) =
  ## `clicked`, `opened`, `closed` or `hovered`, without waiting.
  conn.callAsync(bus, path, dbusmenuInterface, "Event",
      eventParams(id, event, timestamp))

proc sendEventSync*(conn: GDBusConnection, bus, path: string, id: int32,
    event: string, timestamp: uint32 = 0) =
  ## Like `sendEvent`, but returns once the app has handled it (Qt fills
  ## dynamic menus while handling `opened`).
  let reply = conn.callSync(bus, path, dbusmenuInterface, "Event",
      eventParams(id, event, timestamp), 500)
  if reply != nil:
    g_variant_unref(reply)
