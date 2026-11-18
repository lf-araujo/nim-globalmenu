## Draws a dbusmenu (see dbusmenu.nim) as a GtkMenuBar and keeps it in step
## with the app.
##
## GTK cannot draw a dbusmenu by itself (it only reads `org.gtk.Menus`), so
## the widgets are built here from `GetLayout`. Every item and submenu
## carries its dbusmenu id. When a submenu opens the app is told (`opened`;
## Qt fills dynamic menus then) and that submenu is read again; clicks are
## sent as `clicked` events; the app's `LayoutUpdated` rebuilds the subtree
## it names and `ItemsPropertiesUpdated` changes items in place.

import std/tables
import ./[dbusmenu, finder, gio, gtk]

const idKey = "globalmenu-dbusmenu-id"

type
  DbusMenuBar* = ref object
    conn: GDBusConnection
    source: MenuSource
    widget*: GtkWidget ## The menubar; the bar is closed when it is destroyed.
    shells: Table[int32, GtkWidget] ## id -> menu holding its items; 0: bar.
    items: Table[int32, GtkWidget]
    nodes: Table[int32, MenuNode] ## An item's properties (no children).
    layouts: Table[int32, MenuNode] ## shell id -> the subtree drawn in it.
    kids: Table[int32, seq[int32]]
    parentOf: Table[int32, int32]
    pending: seq[int32] ## Ids named by `LayoutUpdated`, not yet read.
    idle, subscription: cuint
    updating: bool ## Set while GTK widgets are changed from app state.
    closed: bool

func gbool(value: bool): gboolean = gboolean(ord(value))

proc toBar(data: pointer): DbusMenuBar = cast[DbusMenuBar](data)

proc setId(widget: GtkWidget, id: int32) =
  g_object_set_data(widget, idKey, cast[pointer](int(id) + 1))

proc idOf(widget: GtkWidget): int32 =
  int32(cast[int](g_object_get_data(widget, idKey)) - 1)

# --- Shortcuts ---------------------------------------------------------------

const qtKeyNames = {"Del": "Delete", "Ins": "Insert", "Esc": "Escape",
    "PgUp": "Page_Up", "PgDown": "Page_Down", "Backspace": "BackSpace",
    "Space": "space", "Return": "Return", "Enter": "Return"}.toTable

proc accelOf(shortcuts: seq[seq[string]]): (cuint, cuint) =
  ## Key and modifier mask of the first shortcut, for display; (0, 0) if
  ## there is none or the key is unknown.
  const voidSymbol = cuint(0xffffff)
  if shortcuts.len == 0 or shortcuts[0].len == 0:
    return
  let combo = shortcuts[0]
  var mods: cuint
  for part in combo[0 ..< combo.high]:
    case part
    of "Control": mods = mods or (1'u32 shl 2)
    of "Shift": mods = mods or 1'u32
    of "Alt": mods = mods or (1'u32 shl 3)
    of "Super": mods = mods or (1'u32 shl 26)
    else: discard
  let name = qtKeyNames.getOrDefault(combo[^1], combo[^1])
  var key = gdk_keyval_from_name(cstring(name))
  if (key == voidSymbol or key == 0) and name.len == 1:
    key = gdk_unicode_to_keyval(uint32(ord(name[0])))
  if key != voidSymbol and key != 0:
    result = (gdk_keyval_to_lower(key), mods)

# --- Building ----------------------------------------------------------------

proc showNode(bar: DbusMenuBar, widget: GtkWidget, node: MenuNode) =
  ## Sets the widget's label, state and visibility from `node`.
  if not node.separator:
    gtk_menu_item_set_label(widget, cstring(node.label))
    if node.toggle != tkNone:
      bar.updating = true # set_active emits "activate".
      gtk_check_menu_item_set_active(widget, gbool(node.toggled))
      bar.updating = false
    let label = gtk_bin_get_child(widget)
    if label != nil and
        g_type_check_instance_is_a(label, gtk_accel_label_get_type()) != 0:
      let (key, mods) = accelOf(node.shortcuts)
      gtk_accel_label_set_accel(label, key, mods)
  gtk_widget_set_sensitive(widget, gbool(node.enabled))
  gtk_widget_set_visible(widget, gbool(node.visible))

proc dropIds(bar: DbusMenuBar, id: int32) =
  ## Forgets everything below `id` (not `id` itself).
  for kid in bar.kids.getOrDefault(id):
    bar.dropIds(kid)
    bar.items.del kid
    bar.nodes.del kid
    bar.parentOf.del kid
    bar.shells.del kid
    bar.layouts.del kid
  bar.kids.del id

proc clear(bar: DbusMenuBar, parent: int32) =
  var widgets: seq[GtkWidget]
  for kid in bar.kids.getOrDefault(parent):
    widgets.add bar.items.getOrDefault(kid)
  bar.dropIds(parent)
  for widget in widgets:
    if widget != nil:
      gtk_widget_destroy(widget)

proc onActivate(item: GtkWidget, data: pointer) {.cdecl.} =
  let bar = data.toBar
  if not bar.closed and not bar.updating:
    bar.conn.sendEvent(bar.source.busName, bar.source.path, item.idOf,
        "clicked", gtk_get_current_event_time())

proc refreshShell(bar: DbusMenuBar, id: int32)

proc onShow(menu: GtkWidget, data: pointer) {.cdecl.} =
  let bar = data.toBar
  if bar.closed:
    return
  let id = menu.idOf
  discard bar.conn.aboutToShow(bar.source.busName, bar.source.path, id)
  bar.conn.sendEventSync(bar.source.busName, bar.source.path, id, "opened",
      gtk_get_current_event_time())
  bar.refreshShell(id)

proc onHide(menu: GtkWidget, data: pointer) {.cdecl.} =
  let bar = data.toBar
  if not bar.closed:
    bar.conn.sendEvent(bar.source.busName, bar.source.path, menu.idOf,
        "closed", gtk_get_current_event_time())

proc populate(bar: DbusMenuBar, parent: int32, node: MenuNode)

proc build(bar: DbusMenuBar, node: MenuNode, parent: int32): GtkWidget =
  let data = cast[pointer](bar)
  result =
    if node.separator: gtk_separator_menu_item_new()
    elif node.toggle != tkNone:
      gtk_check_menu_item_new_with_mnemonic(cstring(node.label))
    else: gtk_menu_item_new_with_mnemonic(cstring(node.label))
  if node.toggle == tkRadio and not node.separator:
    gtk_check_menu_item_set_draw_as_radio(result, 1)
  # Visibility is the app's to decide, not the panel's show_all.
  gtk_widget_set_no_show_all(result, 1)
  result.setId(node.id)
  var own = node
  own.children = @[]
  bar.items[node.id] = result
  bar.nodes[node.id] = own
  bar.parentOf[node.id] = parent
  bar.showNode(result, own)
  if not node.separator:
    if node.hasSubmenu:
      let menu = gtk_menu_new()
      menu.setId(node.id)
      bar.shells[node.id] = menu
      g_signal_connect(menu, "show", cast[GCallback](onShow), data)
      g_signal_connect(menu, "hide", cast[GCallback](onHide), data)
      gtk_menu_item_set_submenu(result, menu)
      bar.populate(node.id, node)
    else:
      g_signal_connect(result, "activate", cast[GCallback](onActivate), data)

proc populate(bar: DbusMenuBar, parent: int32, node: MenuNode) =
  ## Replaces the items shown under `parent` with `node`'s children.
  let shell = bar.shells.getOrDefault(parent)
  if shell == nil:
    return
  bar.clear(parent)
  bar.layouts[parent] = node
  var ids: seq[int32]
  for child in node.children:
    gtk_menu_shell_append(shell, bar.build(child, parent))
    ids.add child.id
  bar.kids[parent] = ids

proc refreshShell(bar: DbusMenuBar, id: int32) =
  ## Reads the subtree under `id` again and redraws it if it changed.
  if id notin bar.shells:
    return
  let (ok, layout) = bar.conn.fetchLayout(bar.source.busName,
      bar.source.path, id)
  if ok and (id notin bar.layouts or bar.layouts[id] != layout.root):
    bar.populate(id, layout.root)

# --- Following the app -------------------------------------------------------

proc onIdle(data: pointer): gboolean {.cdecl.} =
  let bar = data.toBar
  bar.idle = 0
  if bar.closed:
    return 0
  let pending = move bar.pending
  bar.pending = @[]
  for id in pending:
    let target =
      if id in bar.shells: id
      elif id in bar.parentOf: bar.parentOf[id]
      else: 0'i32
    bar.refreshShell(target)

proc schedule(bar: DbusMenuBar, id: int32) =
  if id notin bar.pending:
    bar.pending.add id
  if bar.idle == 0:
    bar.idle = g_idle_add(onIdle, cast[pointer](bar))

proc changeItem(bar: DbusMenuBar, id: int32, node: MenuNode) =
  let old = bar.nodes[id]
  if old.separator != node.separator or old.toggle != node.toggle or
      old.submenu != node.submenu:
    bar.schedule(bar.parentOf.getOrDefault(id)) # A different widget.
  else:
    bar.nodes[id] = node
    bar.showNode(bar.items[id], node)

proc updateProperties(bar: DbusMenuBar, params: GVariant) =
  ## `ItemsPropertiesUpdated(a(ia{sv}) updated, a(ias) removed)`.
  let updated = params.child(0)
  for i in 0 ..< updated.len:
    let
      entry = updated.child(i)
      idValue = entry.child(0)
      props = entry.child(1)
      id = g_variant_get_int32(idValue)
    if id in bar.nodes:
      var node = bar.nodes[id]
      node.applyProperties(props)
      bar.changeItem(id, node)
    g_variant_unref(props)
    g_variant_unref(idValue)
    g_variant_unref(entry)
  g_variant_unref(updated)
  let removed = params.child(1)
  for i in 0 ..< removed.len:
    let
      entry = removed.child(i)
      idValue = entry.child(0)
      names = entry.child(1)
      id = g_variant_get_int32(idValue)
    if id in bar.nodes:
      var node = bar.nodes[id]
      for j in 0 ..< names.len:
        node.applyProperty(stringValue(names.child(j)), nil)
      bar.changeItem(id, node)
    g_variant_unref(names)
    g_variant_unref(idValue)
    g_variant_unref(entry)
  g_variant_unref(removed)

proc onSignal(conn: GDBusConnection, sender, path, iface, signal: cstring,
    params: GVariant, data: pointer) {.cdecl.} =
  let bar = data.toBar
  if bar.closed:
    return
  case $signal
  of "LayoutUpdated":
    if params.typeString == "(ui)":
      let parent = params.child(1)
      bar.schedule(g_variant_get_int32(parent))
      g_variant_unref(parent)
  of "ItemsPropertiesUpdated":
    if params.typeString == "(a(ia{sv})a(ias))":
      bar.updateProperties(params)
  else:
    discard

# --- Life cycle --------------------------------------------------------------

proc close(bar: DbusMenuBar) =
  if bar.closed:
    return
  bar.closed = true
  if bar.subscription != 0:
    g_dbus_connection_signal_unsubscribe(bar.conn, bar.subscription)
    bar.subscription = 0
  if bar.idle != 0:
    discard g_source_remove(bar.idle)
    bar.idle = 0

proc onRelease(data: pointer): gboolean {.cdecl.} =
  GC_unref(data.toBar)

proc onDestroy(widget: GtkWidget, data: pointer) {.cdecl.} =
  ## The submenus are destroyed after this runs and still emit "hide";
  ## `closed` makes those no-ops, and the bar is freed only afterwards.
  data.toBar.close()
  discard g_idle_add(onRelease, data)

proc newDbusMenuBar*(conn: GDBusConnection,
    source: MenuSource): DbusMenuBar =
  ## A menubar showing `source`'s menu; `nil` if the app does not answer.
  let (ok, layout) = conn.fetchLayout(source.busName, source.path, 0)
  if not ok:
    return nil
  result = DbusMenuBar(conn: conn, source: source)
  result.widget = gtk_menu_bar_new()
  result.shells[0] = result.widget
  let data = cast[pointer](result)
  GC_ref(result) # Referenced from widget and D-Bus callbacks.
  g_signal_connect(result.widget, "destroy", cast[GCallback](onDestroy), data)
  result.populate(0, layout.root)
  result.subscription = g_dbus_connection_signal_subscribe(conn,
      cstring(source.busName), dbusmenuInterface, nil, cstring(source.path),
      nil, G_DBUS_SIGNAL_FLAGS_NONE, onSignal, data, nil)

proc isEmpty*(bar: DbusMenuBar): bool =
  bar.kids.getOrDefault(0).len == 0
