## Minimal bindings for the GLib/GIO parts the global menu uses: the session
## bus, GVariant reading, and the D-Bus menu and action-group proxies
## (`GDBusMenuModel`, `GDBusActionGroup`) that speak org.gtk.Menus and
## org.gtk.Actions.

{.passL: "-l:libgobject-2.0.so.0 -l:libglib-2.0.so.0 -l:libgio-2.0.so.0".}

type
  gboolean* = cint
  GVariant* = ptr object
  GDBusConnection* = ptr object
  GMenuModel* = ptr object
  GActionGroup* = ptr object
  GError* = object
    domain*: uint32
    code*: cint
    message*: cstring

  GMainLoop* = ptr object
  GDBusNodeInfo* = ptr object
  GDBusInterfaceInfo* = ptr object
  GDBusMethodInvocation* = ptr object
  GVariantBuilder* = ptr object

  GDBusSignalCallback* = proc (conn: GDBusConnection,
      sender, path, iface, signal: cstring, params: GVariant,
      data: pointer) {.cdecl.}
  GDBusMethodCallFunc* = proc (conn: GDBusConnection,
      sender, path, iface, meth: cstring, params: GVariant,
      invocation: GDBusMethodInvocation, data: pointer) {.cdecl.}
  GBusNameCallback* = proc (conn: GDBusConnection, name: cstring,
      data: pointer) {.cdecl.}
  GDBusInterfaceVTable* = object
    methodCall*: GDBusMethodCallFunc
    getProperty*, setProperty*: pointer
    padding: array[8, pointer]

const
  G_BUS_TYPE_SESSION* = cint(2)
  G_DBUS_CALL_FLAGS_NONE* = cint(0)
  G_DBUS_PROXY_FLAGS_NONE* = cint(0)
  G_DBUS_SIGNAL_FLAGS_NONE* = cint(0)
  G_BUS_NAME_OWNER_FLAGS_NONE* = cint(0)

{.push importc, cdecl.}
proc g_free*(mem: pointer)
proc g_error_free*(error: ptr GError)
proc g_object_unref*(obj: pointer)
proc g_usleep*(microseconds: culong)
proc g_main_context_iteration*(context: pointer, mayBlock: gboolean):
    gboolean

proc g_bus_get_sync*(busType: cint, cancellable: pointer,
    error: ptr ptr GError): GDBusConnection
proc g_dbus_connection_call_sync*(connection: GDBusConnection,
    busName, objectPath, interfaceName, methodName: cstring,
    parameters: GVariant, replyType: pointer, flags, timeoutMsec: cint,
    cancellable: pointer, error: ptr ptr GError): GVariant
proc g_dbus_proxy_new_sync*(connection: GDBusConnection, flags: cint,
    info: pointer, name, objectPath, interfaceName: cstring,
    cancellable: pointer, error: ptr ptr GError): pointer
proc g_dbus_proxy_call_sync*(proxy: pointer, methodName: cstring,
    parameters: GVariant, flags: cint, timeoutMsec: cint,
    cancellable: pointer, error: ptr ptr GError): GVariant

proc g_variant_new*(format: cstring): GVariant {.varargs.}
proc g_variant_new_parsed*(format: cstring): GVariant {.varargs.}
proc g_variant_unref*(value: GVariant)
proc g_variant_n_children*(value: GVariant): csize_t
proc g_variant_get_child_value*(value: GVariant, index: csize_t): GVariant
proc g_variant_get_string*(value: GVariant, length: ptr csize_t): cstring
proc g_variant_get_uint32*(value: GVariant): uint32
proc g_variant_get_type_string*(value: GVariant): cstring
proc g_variant_get_int32*(value: GVariant): int32
proc g_variant_get_boolean*(value: GVariant): gboolean
proc g_variant_get_variant*(value: GVariant): GVariant
proc g_variant_builder_new*(typeString: pointer): GVariantBuilder
proc g_variant_builder_add*(builder: GVariantBuilder, format: cstring)
    {.varargs.}
proc g_variant_builder_end*(builder: GVariantBuilder): GVariant
proc g_variant_builder_unref*(builder: GVariantBuilder)

proc g_dbus_connection_call*(connection: GDBusConnection,
    busName, objectPath, interfaceName, methodName: cstring,
    parameters: GVariant, replyType: pointer, flags, timeoutMsec: cint,
    cancellable, callback, userData: pointer)
proc g_dbus_connection_signal_subscribe*(connection: GDBusConnection,
    sender, interfaceName, member, objectPath, arg0: cstring, flags: cint,
    callback: GDBusSignalCallback, userData, userDataFreeFunc: pointer): cuint
proc g_dbus_connection_signal_unsubscribe*(connection: GDBusConnection,
    subscriptionId: cuint)
proc g_dbus_connection_emit_signal*(connection: GDBusConnection,
    destination, objectPath, interfaceName, signalName: cstring,
    parameters: GVariant, error: ptr ptr GError): gboolean
proc g_dbus_connection_register_object*(connection: GDBusConnection,
    objectPath: cstring, interfaceInfo: GDBusInterfaceInfo,
    vtable: ptr GDBusInterfaceVTable, userData, userDataFreeFunc: pointer,
    error: ptr ptr GError): cuint
proc g_dbus_node_info_new_for_xml*(xml: cstring,
    error: ptr ptr GError): GDBusNodeInfo
proc g_dbus_node_info_lookup_interface*(info: GDBusNodeInfo,
    name: cstring): GDBusInterfaceInfo
proc g_dbus_method_invocation_return_value*(
    invocation: GDBusMethodInvocation, parameters: GVariant)
proc g_dbus_method_invocation_return_dbus_error*(
    invocation: GDBusMethodInvocation, errorName, errorMessage: cstring)
proc g_bus_own_name_on_connection*(connection: GDBusConnection, name: cstring,
    flags: cint, nameAcquired, nameLost: GBusNameCallback,
    userData, userDataFreeFunc: pointer): cuint
proc g_main_loop_new*(context: pointer, isRunning: gboolean): GMainLoop
proc g_main_loop_run*(loop: GMainLoop)
proc g_main_loop_quit*(loop: GMainLoop)

proc g_bus_own_name*(busType: cint, name: cstring, flags: cint,
    busAcquired, nameAcquired, nameLost: pointer, userData: pointer,
    userDataFreeFunc: pointer): cuint
proc g_bus_unown_name*(ownerId: cuint)
proc g_dbus_menu_model_get*(connection: GDBusConnection,
    busName, objectPath: cstring): GMenuModel
proc g_dbus_action_group_get*(connection: GDBusConnection,
    busName, objectPath: cstring): GActionGroup
proc g_menu_model_get_n_items*(model: GMenuModel): cint
proc g_menu_model_get_item_attribute_value*(model: GMenuModel, itemIndex: cint,
    attribute: cstring, expectedType: pointer): GVariant
proc g_menu_model_get_item_link*(model: GMenuModel, itemIndex: cint,
    link: cstring): GMenuModel
{.pop.}

proc takeMessage*(error: ptr GError): string =
  ## The message of `error`, which is then freed; `""` for `nil`.
  if error != nil:
    result = $error.message
    g_error_free(error)

proc stringValue*(value: GVariant): string =
  ## A string (or object path) GVariant's text, taking ownership of
  ## `value`; `""` if `value` is `nil` or not a string.
  if value != nil:
    if $g_variant_get_type_string(value) in ["s", "o"]:
      result = $g_variant_get_string(value, nil)
    g_variant_unref(value)

proc typeString*(value: GVariant): string =
  $g_variant_get_type_string(value)

proc child*(value: GVariant, index: int): GVariant =
  ## A new reference to child `index` of a container value.
  g_variant_get_child_value(value, csize_t(index))

proc len*(value: GVariant): int = int(g_variant_n_children(value))

proc callSync*(conn: GDBusConnection, bus, path, iface, meth: string,
    params: GVariant = nil, timeoutMs = 2000): GVariant =
  ## A blocking method call; the reply, or `nil` on any error. `params`
  ## (usually floating) is consumed.
  var error: ptr GError
  result = g_dbus_connection_call_sync(conn, cstring(bus), cstring(path),
      cstring(iface), cstring(meth), params, nil, G_DBUS_CALL_FLAGS_NONE,
      cint(timeoutMs), nil, addr error)
  if result == nil and error != nil:
    g_error_free(error)

proc callAsync*(conn: GDBusConnection, bus, path, iface, meth: string,
    params: GVariant, timeoutMs = 2000) =
  ## A method call whose reply is not wanted.
  g_dbus_connection_call(conn, cstring(bus), cstring(path), cstring(iface),
      cstring(meth), params, nil, G_DBUS_CALL_FLAGS_NONE, cint(timeoutMs),
      nil, nil, nil)

proc sessionBus*(): GDBusConnection =
  var error: ptr GError
  result = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, addr error)
  if result == nil:
    stderr.writeLine "cannot reach the session bus: " & takeMessage(error)

proc pump*(milliseconds: int) =
  ## Runs pending main-context events for about `milliseconds`, so GDBus
  ## proxies can receive their data.
  for _ in 0 .. milliseconds div 5:
    while g_main_context_iteration(nil, 0) != 0:
      discard
    g_usleep(5000)
