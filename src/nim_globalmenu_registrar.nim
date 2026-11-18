## nim-globalmenu-registrar: a `com.canonical.AppMenu.Registrar` for the
## session (see globalmenu/registrar.nim for why it is a daemon).
##
## Apps call `RegisterWindow(windowId, menuPath)`; the registrar keeps the
## sender's unique bus name with it and drops the entries when the sender
## leaves the bus. Window IDs are kept as given: on Wayland they mean nothing
## outside the app (Qt numbers its own windows, so two apps can both send 1),
## which is why entries are keyed by sender and ID, and why the panel matches
## menus to windows by process (finder.nim), not by ID.
##
## It also serves `org.nimglobalmenu.AppMenus` (see registrar.nim): menus
## registered on an app's behalf with their window's app ID, by
## nim-globalmenu-appmenu-proxy. Those entries are kept under the app's bus
## name, so they too go when the app leaves the bus.
##
##   nim-globalmenu-registrar [--verbose]

import std/os
import globalmenu/[gio, registrar]

type
  Entry = object
    windowId: uint32 ## 0 for AppMenus entries.
    sender, path: string ## `sender`: the app's unique bus name.
    appId: string ## Only for AppMenus entries.

var
  entries: seq[Entry]
  verbose = false
  loop: GMainLoop
  vtable, appMenusVtable: GDBusInterfaceVTable

proc log(message: string) =
  if verbose:
    stderr.writeLine "nim-globalmenu-registrar: " & message

proc emit(conn: GDBusConnection, signal: string, params: GVariant) =
  var error: ptr GError
  if g_dbus_connection_emit_signal(conn, nil, registrarPath,
      registrarInterface, cstring(signal), params, addr error) == 0:
    log "cannot emit " & signal & ": " & takeMessage(error)

proc forget(conn: GDBusConnection, sender: string, windowId: uint32) =
  ## Drops the sender's entry for `windowId`, if any.
  for i in countdown(entries.high, 0):
    if entries[i].sender == sender and entries[i].windowId == windowId and
        entries[i].appId.len == 0:
      entries.delete i
      conn.emit("WindowUnregistered", g_variant_new("(u)", windowId))

proc register(conn: GDBusConnection, sender: string, windowId: uint32,
    path: string) =
  conn.forget(sender, windowId)
  # The same menubar registered again under a new ID replaces the old one.
  for i in countdown(entries.high, 0):
    if entries[i].sender == sender and entries[i].path == path:
      conn.emit("WindowUnregistered", g_variant_new("(u)",
          entries[i].windowId))
      entries.delete i
  entries.add Entry(windowId: windowId, sender: sender, path: path)
  log "registered " & sender & " " & path & " (window " & $windowId & ")"
  conn.emit("WindowRegistered", g_variant_new("(uso)", windowId,
      cstring(sender), cstring(path)))

proc registerApp(conn: GDBusConnection, appId, service, path: string) =
  for i in countdown(entries.high, 0):
    if entries[i].sender == service and entries[i].path == path:
      entries.delete i
  entries.add Entry(sender: service, path: path, appId: appId)
  log "registered " & service & " " & path & " for " & appId
  conn.emit("WindowRegistered", g_variant_new("(uso)", 0'u32,
      cstring(service), cstring(path)))

proc unregisterApp(conn: GDBusConnection, service, path: string) =
  for i in countdown(entries.high, 0):
    if entries[i].sender == service and entries[i].path == path:
      log "unregistered " & service & " " & path
      entries.delete i
      conn.emit("WindowUnregistered", g_variant_new("(u)", 0'u32))

proc onAppMenusCall(conn: GDBusConnection, sender, path, iface,
    meth: cstring, params: GVariant, invocation: GDBusMethodInvocation,
    data: pointer) {.cdecl.} =
  case $meth
  of "Register":
    conn.registerApp(stringValue(params.child(0)),
        stringValue(params.child(1)), stringValue(params.child(2)))
    g_dbus_method_invocation_return_value(invocation, nil)
  of "Unregister":
    conn.unregisterApp(stringValue(params.child(0)),
        stringValue(params.child(1)))
    g_dbus_method_invocation_return_value(invocation, nil)
  of "List":
    let builder = g_variant_builder_new(cast[pointer](cstring"a(sso)"))
    for entry in entries:
      if entry.appId.len > 0:
        g_variant_builder_add(builder, "(sso)", cstring(entry.appId),
            cstring(entry.sender), cstring(entry.path))
    let menus = g_variant_builder_end(builder)
    g_variant_builder_unref(builder)
    g_dbus_method_invocation_return_value(invocation,
        g_variant_new("(@a(sso))", menus))
  else:
    g_dbus_method_invocation_return_dbus_error(invocation,
        "org.freedesktop.DBus.Error.UnknownMethod", "unknown method")

proc windowIdArg(params: GVariant): uint32 =
  let value = params.child(0)
  result = g_variant_get_uint32(value)
  g_variant_unref(value)

proc onMethodCall(conn: GDBusConnection, sender, path, iface, meth: cstring,
    params: GVariant, invocation: GDBusMethodInvocation,
    data: pointer) {.cdecl.} =
  case $meth
  of "RegisterWindow":
    let menuPath = stringValue(params.child(1))
    conn.register($sender, windowIdArg(params), menuPath)
    g_dbus_method_invocation_return_value(invocation, nil)
  of "UnregisterWindow":
    conn.forget($sender, windowIdArg(params))
    g_dbus_method_invocation_return_value(invocation, nil)
  of "GetMenuForWindow":
    let windowId = windowIdArg(params)
    for i in countdown(entries.high, 0):
      if entries[i].windowId == windowId:
        g_dbus_method_invocation_return_value(invocation,
            g_variant_new("(so)", cstring(entries[i].sender),
            cstring(entries[i].path)))
        return
    g_dbus_method_invocation_return_dbus_error(invocation,
        cstring(registrarInterface & ".Error.NoSuchWindow"),
        cstring("no menu registered for window " & $windowId))
  of "GetMenus":
    let builder = g_variant_builder_new(cast[pointer](cstring"a(uso)"))
    for entry in entries:
      g_variant_builder_add(builder, "(uso)", entry.windowId,
          cstring(entry.sender), cstring(entry.path))
    let menus = g_variant_builder_end(builder)
    g_variant_builder_unref(builder)
    g_dbus_method_invocation_return_value(invocation,
        g_variant_new("(@a(uso))", menus))
  else:
    g_dbus_method_invocation_return_dbus_error(invocation,
        "org.freedesktop.DBus.Error.UnknownMethod", "unknown method")

proc onNameOwnerChanged(conn: GDBusConnection, sender, path, iface,
    signal: cstring, params: GVariant, data: pointer) {.cdecl.} =
  ## An app left the bus: its menus are gone.
  let
    name = stringValue(params.child(0))
    newOwner = stringValue(params.child(2))
  if newOwner.len == 0:
    for i in countdown(entries.high, 0):
      if entries[i].sender == name:
        log "dropped " & name & " " & entries[i].path & " (app left)"
        conn.emit("WindowUnregistered", g_variant_new("(u)",
            entries[i].windowId))
        entries.delete i

proc onNameLost(conn: GDBusConnection, name: cstring,
    data: pointer) {.cdecl.} =
  stderr.writeLine "nim-globalmenu-registrar: cannot own " & $name &
    " (another registrar is running, or no session bus)"
  g_main_loop_quit(loop)

proc onNameAcquired(conn: GDBusConnection, name: cstring,
    data: pointer) {.cdecl.} =
  log "running as " & $name

proc main() =
  for arg in commandLineParams():
    case arg
    of "--verbose", "-v": verbose = true
    else: quit("usage: nim-globalmenu-registrar [--verbose]", 2)
  let conn = sessionBus()
  if conn == nil:
    quit(1)
  var error: ptr GError
  let info = g_dbus_node_info_new_for_xml(registrarXml, addr error)
  if info == nil:
    quit("bad interface description: " & takeMessage(error), 1)
  vtable.methodCall = onMethodCall
  if g_dbus_connection_register_object(conn, registrarPath,
      g_dbus_node_info_lookup_interface(info, registrarInterface),
      addr vtable, nil, nil, addr error) == 0:
    quit("cannot export the registrar: " & takeMessage(error), 1)
  appMenusVtable.methodCall = onAppMenusCall
  if g_dbus_connection_register_object(conn, registrarPath,
      g_dbus_node_info_lookup_interface(info, appMenusInterface),
      addr appMenusVtable, nil, nil, addr error) == 0:
    quit("cannot export " & appMenusInterface & ": " & takeMessage(error), 1)
  discard g_dbus_connection_signal_subscribe(conn, "org.freedesktop.DBus",
      "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
      nil, G_DBUS_SIGNAL_FLAGS_NONE, onNameOwnerChanged, nil, nil)
  loop = g_main_loop_new(nil, 0)
  discard g_bus_own_name_on_connection(conn, registrarName,
      G_BUS_NAME_OWNER_FLAGS_NONE, onNameAcquired, onNameLost, nil, nil)
  g_main_loop_run(loop)
  quit(1) # Only reached when the name was lost.

main()
