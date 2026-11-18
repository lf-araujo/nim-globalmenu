## `com.canonical.AppMenu.Registrar`: where apps that export a dbusmenu
## (Qt, Electron, JetBrains IDEs, libdbusmenu apps) announce it. Qt only
## exports its menubar (and hides its in-window one) when this name is owned
## at the time the app starts.
##
## The service is the separate `nim-globalmenu-registrar` daemon, not the
## panel plugin, so registrations survive panel restarts (Qt never registers
## again). This module is the shared description plus the client side.

import ./[finder, gio]

const
  registrarName* = "com.canonical.AppMenu.Registrar"
  registrarPath* = "/com/canonical/AppMenu/Registrar"
  registrarInterface* = "com.canonical.AppMenu.Registrar"
  # Our own addition: menus registered on an app's behalf together with the
  # app ID of their window (by nim-globalmenu-appmenu-proxy, which sees it).
  appMenusInterface* = "org.nimglobalmenu.AppMenus"
  registrarXml* = """
<node>
  <interface name="com.canonical.AppMenu.Registrar">
    <method name="RegisterWindow">
      <arg name="windowId" type="u" direction="in"/>
      <arg name="menuObjectPath" type="o" direction="in"/>
    </method>
    <method name="UnregisterWindow">
      <arg name="windowId" type="u" direction="in"/>
    </method>
    <method name="GetMenuForWindow">
      <arg name="windowId" type="u" direction="in"/>
      <arg name="service" type="s" direction="out"/>
      <arg name="menuObjectPath" type="o" direction="out"/>
    </method>
    <method name="GetMenus">
      <arg name="menus" type="a(uso)" direction="out"/>
    </method>
    <signal name="WindowRegistered">
      <arg name="windowId" type="u"/>
      <arg name="service" type="s"/>
      <arg name="menuObjectPath" type="o"/>
    </signal>
    <signal name="WindowUnregistered">
      <arg name="windowId" type="u"/>
    </signal>
  </interface>
  <interface name="org.nimglobalmenu.AppMenus">
    <method name="Register">
      <arg name="appId" type="s" direction="in"/>
      <arg name="service" type="s" direction="in"/>
      <arg name="menuObjectPath" type="o" direction="in"/>
    </method>
    <method name="Unregister">
      <arg name="service" type="s" direction="in"/>
      <arg name="menuObjectPath" type="o" direction="in"/>
    </method>
    <method name="List">
      <arg name="menus" type="a(sso)" direction="out"/>
    </method>
  </interface>
</node>
"""

proc appMenus(conn: GDBusConnection): seq[MenuSource] =
  ## The menus registered together with their window's app ID.
  let reply = conn.callSync(registrarName, registrarPath, appMenusInterface,
      "List")
  if reply != nil:
    if reply.typeString == "(a(sso))":
      let menus = reply.child(0)
      for i in 0 ..< menus.len:
        let entry = menus.child(i)
        result.add MenuSource(kind: mkDbusMenu,
            appId: stringValue(entry.child(0)),
            busName: stringValue(entry.child(1)),
            path: stringValue(entry.child(2)))
        g_variant_unref(entry)
      g_variant_unref(menus)
    g_variant_unref(reply)

proc registeredMenus*(conn: GDBusConnection): seq[MenuSource] =
  ## The menus apps have registered, oldest first, with the app ID where it
  ## is known. Starts the registrar through D-Bus activation when it is
  ## installed but not running; empty when there is no registrar.
  result = appMenus(conn)
  let withApp = result
  let reply = conn.callSync(registrarName, registrarPath, registrarInterface,
      "GetMenus")
  if reply != nil:
    if reply.typeString == "(a(uso))":
      let menus = reply.child(0)
      for i in 0 ..< menus.len:
        let
          entry = menus.child(i)
          service = stringValue(entry.child(1))
          path = stringValue(entry.child(2))
        var known = false
        for menu in withApp:
          known = known or (menu.busName == service and menu.path == path)
        if not known:
          result.add MenuSource(kind: mkDbusMenu, busName: service, path: path)
        g_variant_unref(entry)
      g_variant_unref(menus)
    g_variant_unref(reply)
