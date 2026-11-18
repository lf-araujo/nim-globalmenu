## Command-line tool for the global menu pieces.
##
##   nim-globalmenu --windows        list windows (order, app ID, active)
##   nim-globalmenu --print          print the active window's menu
##   nim-globalmenu --registered     list menus registered with the registrar
##   nim-globalmenu --app ID [--index N --count M]
##                                   print the menu for an app ID without
##                                   asking the compositor

import std/[os, strutils]
import globalmenu/[dbusmenu, finder, gio, registrar, toplevels]

proc waitForItems(model: GMenuModel, milliseconds = 400) =
  ## GDBusMenuModel fills in asynchronously; run the main context until the
  ## first items arrive (querying the model is what asks for them).
  var waited = 0
  while g_menu_model_get_n_items(model) == 0 and waited < milliseconds:
    pump(10)
    waited += 10

proc attribute(model: GMenuModel, index: cint, name: string): string =
  stringValue(g_menu_model_get_item_attribute_value(model, index,
      cstring(name), nil))

proc printModel(model: GMenuModel, indent: string) =
  waitForItems(model)
  for i in 0 ..< g_menu_model_get_n_items(model):
    let
      section = g_menu_model_get_item_link(model, i, "section")
      submenu = g_menu_model_get_item_link(model, i, "submenu")
      label = attribute(model, i, "label")
      action = attribute(model, i, "action")
    if section != nil:
      if i > 0:
        echo indent & "---"
      printModel(section, indent)
      g_object_unref(section)
    else:
      echo indent & label & (if action.len > 0: "   [" & action & "]" else: "")
      if submenu != nil:
        printModel(submenu, indent & "    ")
        g_object_unref(submenu)

proc printNode(node: MenuNode, indent: string) =
  for item in node.children:
    if item.separator:
      echo indent & "---"
      continue
    var notes: seq[string]
    if not item.enabled: notes.add "disabled"
    if not item.visible: notes.add "hidden"
    case item.toggle
    of tkCheck: notes.add(if item.toggled: "[x]" else: "[ ]")
    of tkRadio: notes.add(if item.toggled: "(*)" else: "( )")
    of tkNone: discard
    for combo in item.shortcuts:
      notes.add combo.join("+")
    echo indent & item.label & "   #" & $item.id &
      (if notes.len > 0: "  " & notes.join(" ") else: "")
    if item.hasSubmenu:
      printNode(item, indent & "    ")

proc printMenu(conn: GDBusConnection, appId: string, index, count: int) =
  let
    sources = findMenus(conn, appId, registeredMenus(conn))
    pick = pickMenu(sources, index, count)
  if pick < 0:
    echo "no menu found for app ID '" & appId & "'"
    return
  let source = sources[pick]
  echo "app ID ", appId, ": ", sources.len, " menubar object(s); using ",
    source.busName, " ", source.path, " (", source.kind, ")"
  if source.kind == mkDbusMenu:
    let (ok, layout) = conn.fetchLayout(source.busName, source.path, 0)
    if ok:
      printNode(layout.root, "  ")
    else:
      echo "  (no answer to GetLayout)"
    return
  let model = g_dbus_menu_model_get(conn, cstring(source.busName),
      cstring(source.path))
  printModel(model, "  ")
  g_object_unref(model)

proc main() =
  let args = commandLineParams()
  var
    appId = ""
    index = 0
    count = 1
    mode = "--print"
  var i = 0
  while i < args.len:
    case args[i]
    of "--windows", "--print", "--registered": mode = args[i]
    of "--app":
      inc i
      appId = args[i]
      mode = "--app"
    of "--index":
      inc i
      index = parseInt(args[i])
    of "--count":
      inc i
      count = parseInt(args[i])
    else:
      quit("usage: nim-globalmenu --windows | --print | --registered | " &
        "--app ID " &
        "[--index N --count M]", 2)
    inc i
  let conn = sessionBus()
  if conn == nil:
    quit(1)
  if mode == "--app":
    printMenu(conn, appId, index, count)
  elif mode == "--registered":
    for source in registeredMenus(conn):
      echo source.busName, "\t", source.path, "\t",
        programNames(processId(conn, source.busName)).join(",")
  else:
    let display = connectDisplay()
    if display == nil:
      quit("cannot connect to the Wayland display", 1)
    let list = track(display)
    if list == nil:
      quit("the compositor lacks wlr-foreign-toplevel-management", 1)
    if mode == "--windows":
      for window in list.windows:
        var flags: seq[string]
        if window.active: flags.add "active"
        if window.maximized: flags.add "maximized"
        if window.minimized: flags.add "minimized"
        echo window.order, "\t", window.appId, "\t", window.title, "\t[",
          flags.join(" "), "]"
    else:
      let window = list.active
      if window == nil:
        echo "no active window"
      else:
        let same = list.sameApp(window)
        printMenu(conn, window.appId, same.find(window), same.len)

main()
