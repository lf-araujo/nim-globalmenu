## xfce4-panel plugin that shows the active window's menu in the panel.
##
## Left to right: the app's name (always; it opens a small window menu with
## Minimize, Maximize and Close, which is all there is for apps that export
## no menu), then the app's own menubar when one can be found. The menubar is
## read over D-Bus (see finder.nim) and drawn as a GTK menubar whose items are
## activated over D-Bus. GTK apps export `org.gtk.Menus`, which GTK draws
## itself; Qt and other apps register a `com.canonical.dbusmenu` with the
## registrar daemon (registrar.nim), drawn by dbusmenubar.nim.
##
## While the plugin runs it owns the bus name `org.nimglobalmenu.Panel`; the
## companion GTK module (hide-module/) watches that name and hides the
## in-window menubars of apps while it is taken.
##
## Build with `--app:lib`; the panel calls `xfce_panel_module_construct`.

import std/[os, sequtils, sets, strutils, tables]
import globalmenu/[dbusmenubar, finder, gio, gtk, registrar, toplevels]

const
  constructedKey = "globalmenu-nim-constructed"
  busName = "org.nimglobalmenu.Panel"
  hideManagerPath = "/org/nimglobalmenu/HideManager"
  hideManagerIface = "org.nimglobalmenu.HideManager"
  settleMs = 60 ## Wait this long after a change before looking for a menu.
  emptyCheckMs = 400 ## An exported menu with no items by then is "empty".
  # Windows that are the panel itself (its menus, the whisker menu): they
  # take focus while a menu is used, but the menu being shown must stay.
  ignoredApps = ["xfce4-panel", ""]
  extraIgnoredVar = "GLOBALMENU_IGNORE_APPS" ## Comma-separated; for testing.
  # Our menubars carry this widget name so the hiding module (which is loaded
  # into the panel too) leaves them alone.
  keepName = "globalmenu-keep"
  # Themes paint `menubar` like an in-window bar (opaque background, dark
  # text, bottom border), which clashes with the panel. Our menubars take the
  # panel's colours instead: transparent, text colour inherited from the
  # panel, and a hover tint derived from that colour, as panel buttons do.
  # The popup menus are separate windows and keep the theme's menu style.
  panelCss = """
menubar#globalmenu-keep {
  background: none;
  border: none;
  box-shadow: none;
  color: inherit;
}
menubar#globalmenu-keep > menuitem {
  color: inherit;
  background: none;
  box-shadow: none;
  border-radius: 6px;
}
menubar#globalmenu-keep > menuitem:hover {
  color: inherit;
  background-color: alpha(currentColor, 0.15);
}
menubar#globalmenu-keep > menuitem:disabled {
  color: alpha(currentColor, 0.5);
}
"""

type
  Applet = ref object
    box, nameBar, menuBar, maximizeItem: GtkWidget
    conn: GDBusConnection
    windows: Toplevels
    owner: cuint
    timer, emptyTimer: cuint
    target: Toplevel ## The window the name menu's items act on.
    model: GMenuModel ## Model of the menubar being shown.
    emptyMenus: HashSet[string] ## `bus path` of menus found to have no items.
    nameApp, shownApp, shownBus, shownPath: string
    # Per app: its windows (arrival numbers) when its menus were looked up.
    # A window closed and opened again is a different window, and its app
    # (a new process, or a new menu object) must be looked up again.
    cache: Table[string, tuple[windows: seq[int], sources: seq[MenuSource]]]
    hiding: HashSet[string] ## Apps (bus names) asked to hide their bars.
    freed: bool ## The panel removed this instance; its widgets are gone.
    registered: seq[MenuSource] ## dbusmenu menus known to the registrar.
    registrarSub: cuint

proc toApplet(data: pointer): Applet = cast[Applet](data)

func prettyName(appId: string): string =
  ## `org.gnome.Calculator` -> `Calculator`, `thunar` -> `Thunar`.
  let name = appId[appId.rfind('.') + 1 .. ^1]
  if name.len > 0: name[0].toUpperAscii() & name[1 .. ^1] else: appId

proc shownName(appId: string): string =
  ## The name in bold: `X-GlobalMenu-Name=` from the app's desktop file if
  ## it has one (launcher names are often long, "Brave Web Browser"); for a
  ## Chromium web app (`--app-id=` in `Exec=`), whose app ID is a long code,
  ## the launcher's `Name=` ("YouTube"); else made from the app ID.
  result = desktopValue(appId, "X-GlobalMenu-Name")
  if result.len == 0 and "--app-id=" in desktopValue(appId, "Exec"):
    result = desktopValue(appId, "Name")
  if result.len == 0:
    result = prettyName(appId)

# --- The app-name menu -------------------------------------------------------

proc onMinimize(item: GtkWidget, data: pointer) {.cdecl.} =
  let target = data.toApplet.target
  if target != nil:
    target.minimize()

proc onMaximize(item: GtkWidget, data: pointer) {.cdecl.} =
  let target = data.toApplet.target
  if target != nil:
    target.toggleMaximized()

proc onClose(item: GtkWidget, data: pointer) {.cdecl.} =
  let target = data.toApplet.target
  if target != nil:
    target.close()

proc onNameMenuShow(menu: GtkWidget, data: pointer) {.cdecl.} =
  ## "Maximize" or "Restore", whichever applies now.
  let applet = data.toApplet
  if applet.target != nil and applet.maximizeItem != nil:
    gtk_menu_item_set_label(applet.maximizeItem,
        if applet.target.maximized: cstring"Restore" else: cstring"Maximize")

proc addItem(menu: GtkWidget, label: string, handler: GCallback,
    data: pointer): GtkWidget =
  result = gtk_menu_item_new_with_label(cstring(label))
  g_signal_connect(result, "activate", handler, data)
  gtk_menu_shell_append(menu, result)

proc newNameBar(applet: Applet, appId: string): GtkWidget =
  ## A one-item menubar: the app's name in bold, opening the window menu.
  let data = cast[pointer](applet)
  result = gtk_menu_bar_new()
  gtk_widget_set_name(result, keepName)
  let
    item = gtk_menu_item_new_with_label("")
    menu = gtk_menu_new()
    escaped = $g_markup_escape_text(cstring(shownName(appId)), -1)
  gtk_label_set_markup(gtk_bin_get_child(item), cstring("<b>" & escaped & "</b>"))
  discard addItem(menu, "Minimize", cast[GCallback](onMinimize), data)
  applet.maximizeItem = addItem(menu, "Maximize",
      cast[GCallback](onMaximize), data)
  gtk_menu_shell_append(menu, gtk_separator_menu_item_new())
  discard addItem(menu, "Close Window", cast[GCallback](onClose), data)
  g_signal_connect(menu, "show",
      cast[GCallback](onNameMenuShow), data)
  gtk_menu_item_set_submenu(item, menu)
  gtk_menu_shell_append(result, item)

proc setNameFor(applet: Applet, appId: string) =
  if applet.nameApp == appId and applet.nameBar != nil:
    return
  if applet.nameBar != nil:
    gtk_widget_destroy(applet.nameBar)
  applet.nameApp = appId
  applet.nameBar = applet.newNameBar(appId)
  gtk_box_pack_start(applet.box, applet.nameBar, 0, 0, 0)
  gtk_widget_show_all(applet.nameBar)

# --- The app's own menubar ---------------------------------------------------

proc setMenuBar(applet: Applet, widget: GtkWidget) =
  ## Replaces the app's menubar (`nil`: none).
  if applet.menuBar != nil:
    gtk_widget_destroy(applet.menuBar)
  applet.menuBar = widget
  if widget != nil:
    gtk_widget_set_name(widget, keepName)
    gtk_box_pack_start(applet.box, widget, 0, 0, 0)
    gtk_widget_show_all(widget)

proc dropModel(applet: Applet) =
  if applet.emptyTimer != 0:
    discard g_source_remove(applet.emptyTimer)
    applet.emptyTimer = 0
  if applet.model != nil:
    g_object_unref(applet.model)
    applet.model = nil

proc setHidden(applet: Applet, busName: string, hide: bool) =
  ## Asks the hiding module in the app on `busName` (the connection its menu
  ## is exported on, where the module serves the HideManager) to hide its
  ## in-window menubars, or to show them again. Apps stay registered after
  ## losing focus; the module shows the bars again when the panel goes away.
  ## Apps without the module just answer with an error, which is ignored.
  if busName.len == 0 or hide == (busName in applet.hiding):
    return
  if hide:
    applet.hiding.incl busName
  else:
    applet.hiding.excl busName
  applet.conn.callAsync(busName, hideManagerPath, hideManagerIface,
      if hide: "Register" else: "Unregister",
      g_variant_new("(s)", cstring(applet.shownApp)))

proc showNoMenu(applet: Applet, appId: string) =
  applet.dropModel()
  applet.shownBus = ""
  applet.shownPath = ""
  applet.shownApp = appId
  applet.setMenuBar(nil)


proc onEmptyCheck(data: pointer): gboolean {.cdecl.} =
  ## Firefox, Evince and others export a menubar object with nothing in it
  ## (their menus are not GTK menubars); there is nothing to show then.
  let applet = data.toApplet
  if applet.freed:
    return
  applet.emptyTimer = 0
  if applet.model != nil and g_menu_model_get_n_items(applet.model) == 0:
    applet.emptyMenus.incl applet.shownBus & " " & applet.shownPath
    applet.setHidden(applet.shownBus, false) # Nothing here to replace them.
    applet.showNoMenu(applet.shownApp)

proc showMenu(applet: Applet, appId: string, source: MenuSource) =
  if source.busName == applet.shownBus and source.path == applet.shownPath:
    return
  applet.dropModel()
  applet.shownApp = appId
  applet.shownBus = source.busName
  applet.shownPath = source.path
  if source.kind == mkDbusMenu:
    let bar = newDbusMenuBar(applet.conn, source)
    if bar == nil or bar.isEmpty:
      if bar != nil:
        gtk_widget_destroy(bar.widget)
      applet.emptyMenus.incl source.key
      applet.showNoMenu(appId)
    else:
      applet.setMenuBar(bar.widget)
    return
  let
    model = g_dbus_menu_model_get(applet.conn, cstring(source.busName),
        cstring(source.path))
    bar = gtk_menu_bar_new_from_model(model)
    unity = g_dbus_action_group_get(applet.conn, cstring(source.busName),
        cstring(source.path))
    app = g_dbus_action_group_get(applet.conn, cstring(source.busName),
        cstring(source.appPath))
  # appmenu-gtk-module's items use `unity.*`; GApplication menubars use
  # `app.*` on the application's object path.
  gtk_widget_insert_action_group(bar, "unity", unity)
  gtk_widget_insert_action_group(bar, "app", app)
  g_object_unref(unity)
  g_object_unref(app)
  applet.model = model # Kept to see whether items ever arrive.
  applet.setMenuBar(bar)
  applet.emptyTimer = g_timeout_add(emptyCheckMs, onEmptyCheck,
      cast[pointer](applet))
  applet.setHidden(source.busName, true)

# --- Following the active window --------------------------------------------

proc isIgnored(appId: string): bool =
  appId in ignoredApps or appId in getEnv(extraIgnoredVar).split(',')

proc forgetClosedTarget(applet: Applet) =
  ## The window the name and menu were for is gone: show nothing for it.
  applet.target = nil
  applet.dropModel()
  applet.setMenuBar(nil)
  if applet.nameBar != nil:
    gtk_widget_destroy(applet.nameBar)
    applet.nameBar = nil
    applet.maximizeItem = nil
  applet.nameApp = ""
  applet.shownApp = ""
  applet.shownBus = ""
  applet.shownPath = ""

proc refresh(applet: Applet) =
  if applet.target != nil and applet.target.isClosed:
    applet.forgetClosedTarget()
  let window = applet.windows.active
  if window == nil or window.appId.isIgnored:
    return
  applet.target = window
  applet.setNameFor(window.appId)
  let
    same = applet.windows.sameApp(window)
    windows = same.mapIt(it.order)
    entry = applet.cache.getOrDefault(window.appId)
  var sources = entry.sources
  if entry.windows != windows or sources.len == 0:
    sources = findMenus(applet.conn, window.appId, applet.registered)
    applet.cache[window.appId] = (windows, sources)
    applet.emptyMenus.clear() # Windows came or went: look again.
  var pick = pickMenu(sources, same.find(window), same.len)
  if pick >= 0 and sources[pick].key in applet.emptyMenus:
    pick = -1
  if pick < 0:
    if applet.shownApp != window.appId or applet.shownBus != "":
      applet.showNoMenu(window.appId)
  else:
    applet.showMenu(window.appId, sources[pick])

proc onSettled(data: pointer): gboolean {.cdecl.} =
  let applet = data.toApplet
  if applet.freed:
    return
  applet.timer = 0
  applet.refresh()

proc onWindowsChanged(data: pointer) =
  let applet = data.toApplet
  if applet.freed:
    return
  if applet.timer == 0:
    applet.timer = g_timeout_add(settleMs, onSettled, data)

proc onRegistrarChanged(conn: GDBusConnection, sender, path, iface,
    signal: cstring, params: GVariant, data: pointer) {.cdecl.} =
  ## A Qt (or other dbusmenu) window registered or went away.
  let applet = data.toApplet
  if applet.freed:
    return
  applet.registered = registeredMenus(applet.conn)
  applet.cache.clear()
  applet.emptyMenus.clear()
  onWindowsChanged(data)

proc start(data: pointer): gboolean {.cdecl.} =
  ## Runs once from the main loop after the plugin is on screen.
  let applet = data.toApplet
  if applet.freed:
    return
  let display = gdk_display_get_default()
  if not display.onWayland:
    gtk_box_pack_start(applet.box, gtk_label_new("Global menu needs Wayland"),
        0, 0, 0)
    gtk_widget_show_all(applet.box)
    return
  applet.conn = sessionBus()
  applet.windows = track(cast[WlDisplay](
      gdk_wayland_display_get_wl_display(display)))
  if applet.conn == nil or applet.windows == nil:
    gtk_box_pack_start(applet.box, gtk_label_new("Global menu unavailable"),
        0, 0, 0)
    gtk_widget_show_all(applet.box)
    return
  # Taking the name tells the hiding module that this menu is on screen.
  applet.owner = g_bus_own_name(G_BUS_TYPE_SESSION, busName, 0, nil, nil, nil,
      nil, nil)
  applet.windows.onChange = onWindowsChanged
  applet.windows.onChangeData = data
  # Asking for the registered menus also starts the registrar daemon.
  applet.registered = registeredMenus(applet.conn)
  applet.registrarSub = g_dbus_connection_signal_subscribe(applet.conn,
      registrarName, registrarInterface, nil, registrarPath, nil,
      G_DBUS_SIGNAL_FLAGS_NONE, onRegistrarChanged, data, nil)
  applet.refresh()

proc onFreeData(plugin: XfcePanelPlugin, data: pointer) {.cdecl.} =
  ## The applet is being removed: its widgets are destroyed, so nothing may
  ## touch them any more (a pending refresh once crashed the panel here).
  let applet = data.toApplet
  applet.freed = true
  if applet.timer != 0:
    discard g_source_remove(applet.timer)
    applet.timer = 0
  applet.dropModel()
  if applet.windows != nil:
    applet.windows.onChange = nil
  applet.nameBar = nil
  applet.menuBar = nil
  applet.maximizeItem = nil
  applet.target = nil
  if applet.registrarSub != 0:
    g_dbus_connection_signal_unsubscribe(applet.conn, applet.registrarSub)
    applet.registrarSub = 0
  if applet.owner != 0:
    g_bus_unown_name(applet.owner)
    applet.owner = 0

var cssInstalled = false

proc installPanelCss() =
  ## Once per panel process: the provider applies to every instance.
  if cssInstalled:
    return
  cssInstalled = true
  let provider = gtk_css_provider_new()
  var error: ptr GError
  if gtk_css_provider_load_from_data(provider, panelCss, panelCss.len,
      addr error) == 0:
    stderr.writeLine "globalmenu-nim: panel CSS: " & takeMessage(error)
  else:
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(),
        provider, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
  g_object_unref(provider)

proc keepMenubarsShown(settings: pointer) =
  ## `gtk-shell-shows-menubar` off in the panel process. appmenu-gtk-module
  ## (loaded into the panel through GTK_MODULES) turns it on when an AppMenu
  ## registrar appears and then collapses the menubars it sees, which would
  ## include ours.
  var shown: gboolean
  g_object_get(settings, "gtk-shell-shows-menubar", addr shown, nil)
  if shown != 0:
    g_object_set(settings, "gtk-shell-shows-menubar", gboolean(0), nil)

proc onShellShowsMenubar(settings: pointer, spec: pointer,
    data: pointer) {.cdecl.} =
  keepMenubarsShown(settings)

proc guardMenubars() =
  ## Once per panel process.
  let settings = gtk_settings_get_default()
  if settings != nil and g_object_get_data(settings, constructedKey) == nil:
    g_object_set_data(settings, constructedKey, cast[pointer](1))
    keepMenubarsShown(settings)
    g_signal_connect(settings, "notify::gtk-shell-shows-menubar",
        cast[GCallback](onShellShowsMenubar))

proc construct(plugin: XfcePanelPlugin) =
  let applet = Applet()
  GC_ref(applet) # Referenced from C callbacks for the life of the panel.
  applet.box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
  gtk_container_add(cast[GtkWidget](plugin), applet.box)
  gtk_widget_show(applet.box)
  xfce_panel_plugin_set_expand(plugin, 0)
  installPanelCss()
  guardMenubars()
  g_signal_connect(plugin, "free-data", cast[GCallback](onFreeData),
      cast[pointer](applet))
  discard g_idle_add(start, cast[pointer](applet))

proc onRealize(plugin: XfcePanelPlugin, data: pointer) {.cdecl.} =
  if g_object_get_data(plugin, constructedKey) == nil:
    g_object_set_data(plugin, constructedKey, cast[pointer](1))
    construct(plugin)

proc xfce_panel_module_construct(name: cstring, uniqueId: cint,
    displayName, comment: cstring, arguments: ptr cstring,
    screen: GdkScreen): XfcePanelPlugin {.exportc, dynlib, cdecl.} =
  ## Called by xfce4-panel to create one instance of the plugin.
  if screen != nil and name != nil and uniqueId != -1:
    result = cast[XfcePanelPlugin](g_object_new(xfce_panel_plugin_get_type(),
        "name", name, "unique-id", uniqueId, "display-name", displayName,
        "comment", comment, "arguments", arguments, nil))
    g_signal_connect_after(result, "realize", cast[GCallback](onRealize))
