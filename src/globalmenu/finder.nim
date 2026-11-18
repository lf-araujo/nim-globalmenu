## Finds the D-Bus menu that belongs to a window.
##
## Neither labwc nor the wlr protocols say which D-Bus connection owns a
## window's menu, so it is found by matching: the window's app ID against the
## programs behind the session bus connections (process name, executable,
## the desktop file's Exec), then looking for `org.gtk.Menus` objects on the
## matching connections. Menus in the other protocol, `com.canonical.dbusmenu`
## (Qt and others), are normally announced to the registrar (registrar.nim)
## and those announcements are matched the same way; dbusmenu objects found
## on matching connections count too, because some apps export one without
## being able to announce it (Firefox on Wayland only announces through a
## KDE Wayland protocol that labwc lacks).

import std/[algorithm, os, sequtils, sets, strutils, tables]
import ./[dbusmenu, gio]

type
  MenuKind* = enum
    mkGtk ## `org.gtk.Menus` + `org.gtk.Actions` (GTK, appmenu-gtk-module).
    mkDbusMenu ## `com.canonical.dbusmenu` (Qt and others, via the registrar).

  MenuSource* = object
    kind*: MenuKind
    busName*: string ## Unique bus name of the application.
    path*: string ## Object path of the menubar.
    appId*: string ## The window's app ID, when the registrar was told it.

const
  menusInterface = "org.gtk.Menus"
  maxWalkCalls = 300
  walkDepth = 8

func key*(source: MenuSource): string =
  ## Identifies a menu object: `bus path`.
  source.busName & " " & source.path

func appPath*(source: MenuSource): string =
  ## The application's own object path (where its `app.*` actions live):
  ## the menubar path minus `/menus/menubar...`.
  let pos = source.path.find("/menus/")
  if pos > 0: source.path[0 ..< pos] else: "/"

proc call(conn: GDBusConnection, bus, path, iface, meth: string,
    params: GVariant = nil): GVariant =
  conn.callSync(bus, path, iface, meth, params)

proc uniqueNames*(conn: GDBusConnection): seq[string] =
  let reply = call(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "ListNames")
  if reply != nil:
    let names = g_variant_get_child_value(reply, 0)
    for i in 0 ..< int(g_variant_n_children(names)):
      let name = stringValue(g_variant_get_child_value(names, csize_t(i)))
      if name.startsWith(":"):
        result.add name
    g_variant_unref(names)
    g_variant_unref(reply)

proc processId*(conn: GDBusConnection, busName: string): int =
  let reply = call(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "GetConnectionUnixProcessID",
      g_variant_new("(s)", cstring(busName)))
  if reply != nil:
    let value = g_variant_get_child_value(reply, 0)
    result = int(g_variant_get_uint32(value))
    g_variant_unref(value)
    g_variant_unref(reply)

# --- Matching a window to a program ----------------------------------------

func baseName(path: string): string =
  path[path.rfind('/') + 1 .. ^1]

proc programNames*(pid: int): seq[string] =
  ## Lower-cased names a process goes by: its `comm`, its executable and its
  ## first command-line word.
  try:
    result.add readFile("/proc/" & $pid & "/comm").strip().toLowerAscii()
  except IOError, OSError:
    discard
  try:
    result.add baseName(expandSymlink("/proc/" & $pid & "/exe")).toLowerAscii()
  except OSError:
    discard
  try:
    let argv = readFile("/proc/" & $pid & "/cmdline").split('\0')
    if argv.len > 0 and argv[0].len > 0:
      result.add baseName(argv[0]).toLowerAscii()
  except IOError, OSError:
    discard

proc desktopValue*(appId, key: string): string =
  ## `key` from the `[Desktop Entry]` group of the app's desktop file (the
  ## first one found on the XDG data path); "" if there is none.
  var dirs = @[getEnv("XDG_DATA_HOME", getHomeDir() / ".local/share")]
  for dir in getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':'):
    dirs.add dir
  for dir in dirs:
    for id in [appId, appId.toLowerAscii()]:
      let path = dir / "applications" / (id & ".desktop")
      if fileExists(path):
        var inEntry = false
        try:
          for line in lines(path):
            if line.startsWith("["):
              inEntry = line.strip() == "[Desktop Entry]"
            elif inEntry and line.startsWith(key & "="):
              return line[key.len + 1 .. ^1].strip()
        except IOError:
          discard
        return

proc desktopExecNames(appId: string): seq[string] =
  ## The program in `Exec=` of the app's desktop file, if there is one.
  let words = desktopValue(appId, "Exec").split(' ')
  if words.len > 0 and words[0].len > 0:
    result.add baseName(words[0]).toLowerAscii()

func wantedNames*(appId: string, execNames: seq[string]): seq[string] =
  ## Program names that would belong to a window with this app ID.
  let id = appId.toLowerAscii()
  result = @[id] & execNames
  let dot = id.rfind('.')
  if dot >= 0:
    result.add id[dot + 1 .. ^1]
  if id.startsWith("libreoffice"):
    result.add ["soffice", "soffice.bin", "oosplash"]

func matches*(wanted, programs: seq[string]): bool =
  for name in programs:
    if name in wanted:
      return true
    # A program whose app ID adds a suffix: process `brave`, app ID
    # `brave-browser`. Short names are left out (too many false matches).
    if name.len >= 4:
      for want in wanted:
        if want.startsWith(name & "-"):
          return true
    # `comm` is cut at 15 characters.
    if name.len == 15:
      for want in wanted:
        if want.startsWith(name):
          return true

# --- Walking a connection's objects -----------------------------------------

func xmlNames(xml, tag: string): seq[string] =
  ## The `name` attributes of every `<tag name="...">` in `xml`.
  let marker = "<" & tag & " name=\""
  var pos = xml.find(marker)
  while pos >= 0:
    let start = pos + marker.len
    let stop = xml.find('"', start)
    if stop < 0:
      break
    result.add xml[start ..< stop]
    pos = xml.find(marker, stop)

proc menuObjects(conn: GDBusConnection, busName: string): seq[MenuSource] =
  ## The objects on `busName` that implement org.gtk.Menus or
  ## com.canonical.dbusmenu.
  var
    queue = @[("/", 0)]
    calls = 0
    head = 0
  while head < queue.len and calls < maxWalkCalls:
    let (path, depth) = queue[head]
    inc head
    inc calls
    let reply = call(conn, busName, path,
        "org.freedesktop.DBus.Introspectable", "Introspect")
    if reply != nil:
      let xml = stringValue(g_variant_get_child_value(reply, 0))
      g_variant_unref(reply)
      let interfaces = xmlNames(xml, "interface")
      if menusInterface in interfaces:
        result.add MenuSource(kind: mkGtk, busName: busName, path: path)
      elif dbusmenuInterface in interfaces or (interfaces.len == 0 and
          path.startsWith("/com/canonical/menu/")):
        # Chromium's menu objects do not list their interfaces; whether
        # there is a menu is checked with GetLayout (hasItems).
        result.add MenuSource(kind: mkDbusMenu, busName: busName, path: path)
      if depth < walkDepth:
        for child in xmlNames(xml, "node"):
          queue.add ((if path == "/": "/" & child else: path & "/" & child),
              depth + 1)

proc hasItems(conn: GDBusConnection, source: MenuSource): bool =
  ## Whether the menu object has any items right now. An app can export
  ## several menubar objects and leave some empty (Thunar has an empty
  ## `/org/appmenu/...` next to its real one; Firefox and Evince export
  ## only empty ones); empty ones must not be paired with a window.
  if source.kind == mkDbusMenu:
    return conn.hasItems(source.busName, source.path)
  let reply = call(conn, source.busName, source.path, menusInterface,
      "Start", g_variant_new_parsed("([uint32 0],)"))
  if reply != nil:
    let groups = g_variant_get_child_value(reply, 0)
    result = g_variant_n_children(groups) > 0
    g_variant_unref(groups)
    g_variant_unref(reply)
    # Start subscribes this connection to the group; undo that.
    let ended = call(conn, source.busName, source.path, menusInterface, "End",
        g_variant_new_parsed("([uint32 0],)"))
    if ended != nil:
      g_variant_unref(ended)

func trailingNumber(path: string): int =
  ## The number a path ends with (`.../menubar/3` -> 3), else -1.
  let tail = path[path.rfind('/') + 1 .. ^1]
  if tail.len > 0 and tail.allCharsInSet(Digits): parseInt(tail) else: -1

proc findMenus*(conn: GDBusConnection, appId: string,
    registered: seq[MenuSource] = @[]): seq[MenuSource] =
  ## Every menubar object with items exported by programs that match
  ## `appId`, ordered by path (numbered menubars by number). `registered`
  ## are the dbusmenu menus known to the registrar; those whose program
  ## matches are included too.
  let wanted = wantedNames(appId, desktopExecNames(appId))
  # Menus registered with their window's app ID belong to that app only,
  # even when the process also has windows of other app IDs (a browser and
  # its web apps).
  var claimed: HashSet[string]
  for source in registered:
    if source.appId.len > 0:
      claimed.incl source.key
  var matching: Table[string, bool] # bus name -> its program matches
  for name in uniqueNames(conn):
    let pid = processId(conn, name)
    matching[name] = pid > 0 and wanted.matches(programNames(pid))
    if matching[name]:
      for source in menuObjects(conn, name):
        # GTK apps export other org.gtk.Menus objects (app menus, context
        # menus); only menubars live under `/menus/`.
        if (source.kind == mkDbusMenu or "/menus/" in source.path) and
            source.key notin claimed and conn.hasItems(source):
          result.add source
  for source in registered:
    let mine =
      if source.appId.len > 0: cmpIgnoreCase(source.appId, appId) == 0
      else: matching.getOrDefault(source.busName)
    if mine and result.allIt(it.key != source.key) and conn.hasItems(source):
      result.add source
  result.sort(proc (a, b: MenuSource): int =
    result = cmp(a.busName, b.busName)
    if result == 0:
      let (na, nb) = (trailingNumber(a.path), trailingNumber(b.path))
      result = if na >= 0 and nb >= 0 and na != nb: cmp(na, nb)
               else: cmp(a.path, b.path))

func pickMenu*(sources: seq[MenuSource], index, count: int): int =
  ## Which of `sources` goes with the window at `index` among `count`
  ## windows of the same app (both in creation order); -1 if none. Menus
  ## and windows are paired from the newest end, so an app that has closed
  ## windows but kept their menus still lines up.
  if sources.len == 0 or count <= 0:
    return -1
  max(0, min(sources.high, sources.len - (count - index)))
