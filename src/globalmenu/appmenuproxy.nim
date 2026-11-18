## The message handling of nim-globalmenu-appmenu-proxy: pretends that the
## compositor offers KDE's `org_kde_kwin_appmenu_manager` (labwc does not).
##
## Chromium-based browsers (Brave, Chrome) only build and export their
## `com.canonical.dbusmenu` menubar on Wayland when that global exists; they
## use it to tell the compositor where the menu is. The panel does not need
## that announcement (finder.nim finds dbusmenu objects on the app's own
## D-Bus connection), so the protocol is only pretended: the global is
## announced to the program, its requests are answered here, and every
## other message passes between program and compositor unchanged.
##
## Object ids: the compositor requires each new client object id to be the
## next unused one, so every id the program gives a pretend object is also
## created on the compositor, as a `wl_display.sync` callback (freed there
## right away; its `done` and `delete_id` events are dropped here). When the
## program releases a pretend object it gets the `delete_id` the compositor
## would have sent.
##
## Which window a menu belongs to: the program says where each window's
## menu is (`set_address` on the appmenu object made for its surface), and
## names each window (`xdg_toplevel.set_app_id`). Following `xdg_wm_base`
## → `xdg_surface` → `xdg_toplevel` links the two, so each menu is announced
## with its window's app ID; the panel then tells a browser's web-app
## windows (own app IDs, same process) from its main window.
##
## This module only transforms messages; the sockets, file descriptors and
## D-Bus calls are in nim_globalmenu_appmenu_proxy.nim.

import std/[sequtils, sets, tables]

const
  fakeName* = 0xff00a001'u32 ## Global name; the compositor counts from 1.
  appmenuManager* = "org_kde_kwin_appmenu_manager"
  appmenuVersion = 2'u32

  displayId = 1'u32 # wl_display
  displaySync = 0'u32 # request
  displayGetRegistry = 1'u32 # request
  displayDeleteId = 1'u32 # event
  registryBind = 0'u32 # request
  registryGlobal = 0'u32 # event
  managerCreate = 0'u32 # org_kde_kwin_appmenu_manager requests
  managerRelease = 1'u32
  appmenuSetAddress = 0'u32 # org_kde_kwin_appmenu requests
  appmenuRelease = 1'u32
  wmBaseGetXdgSurface = 2'u32 # xdg_wm_base request
  xdgSurfaceGetToplevel = 1'u32 # xdg_surface request
  toplevelSetAppId = 3'u32 # xdg_toplevel request

type
  Announcement* = object
    ## A window's menu appeared (`present`) or went away.
    appId*, service*, path*: string
    present*: bool

  Filter* = object
    ## The state of one program connection.
    registries, managers, menus, placeholders: HashSet[uint32]
    interfaces: Table[uint32, string] ## Followed objects -> interface.
    surfaceOf: Table[uint32, uint32] ## xdg_surface or xdg_toplevel -> wl_surface.
    appIdOf: Table[uint32, string] ## wl_surface -> app ID.
    menuSurface: Table[uint32, uint32] ## appmenu -> wl_surface.
    menuAddress: Table[uint32, (string, string)] ## appmenu -> service, path.
    announced: Table[uint32, string] ## appmenu -> app ID it was announced as.
    toServer*, toClient*: string ## Messages to write, in order.
    log*: seq[string] ## What happened with the pretend objects.
    announcements*: seq[Announcement] ## To pass on to the registrar.

# --- Wire format -------------------------------------------------------------

proc word*(msg: string, index: int): uint32 =
  ## Word `index` of a message (native byte order, as on the socket).
  copyMem(addr result, unsafeAddr msg[index * 4], 4)

proc addWords*(buf: var string, words: openArray[uint32]) =
  let start = buf.len
  buf.setLen(start + words.len * 4)
  if words.len > 0:
    copyMem(addr buf[start], unsafeAddr words[0], words.len * 4)

proc message*(objectId, opcode: uint32, args: openArray[uint32]): string =
  ## A message with plain word arguments.
  result.addWords([objectId, uint32(8 + args.len * 4) shl 16 or opcode])
  result.addWords(args)

proc stringArg*(text: string): seq[uint32] =
  ## The words of a string argument: length (with the NUL), then the text
  ## padded to a word.
  let len = text.len + 1
  result = newSeq[uint32](1 + (len + 3) div 4)
  result[0] = uint32(len)
  copyMem(addr result[1], unsafeAddr text[0], text.len)

proc messageSize*(buf: string): int =
  ## Size of the first message in `buf`: 0 if it is not complete yet, -1 if
  ## the header is not a Wayland message header.
  if buf.len < 8:
    return 0
  let size = int(buf.word(1) shr 16)
  if size < 8 or size mod 4 != 0: -1
  elif buf.len < size: 0
  else: size

proc wireString(msg: string, at: int, next: var int): (bool, string) =
  ## The string argument at word `at`; `next` gets the word after it.
  let words = msg.len div 4
  if at >= words:
    return
  let len = int(msg.word(at))
  let padded = (len + 3) div 4
  if len == 0 or at + 1 + padded > words or msg[(at + 1) * 4 + len - 1] != '\0':
    return
  next = at + 1 + padded
  result = (true, msg[(at + 1) * 4 ..< (at + 1) * 4 + len - 1])

# --- Pretend objects ---------------------------------------------------------

proc placeholder(f: var Filter, id: uint32) =
  ## Creates `id` on the compositor so the ids stay in step.
  f.toServer.add message(displayId, displaySync, [id])
  f.placeholders.incl id

proc release(f: var Filter, id: uint32) =
  f.toClient.add message(displayId, displayDeleteId, [id])

proc announce(f: var Filter, registry: uint32) =
  var args = @[fakeName]
  args.add stringArg(appmenuManager)
  args.add appmenuVersion
  f.toClient.add message(registry, registryGlobal, args)

# --- Which window a menu is for ---------------------------------------------

proc announceMenu(f: var Filter, menu: uint32) =
  ## Announces `menu` once both its address and its window's app ID are known
  ## (again if the app ID changed).
  if menu notin f.menuAddress:
    return
  let appId = f.appIdOf.getOrDefault(f.menuSurface.getOrDefault(menu))
  if appId.len == 0 or f.announced.getOrDefault(menu) == appId:
    return
  let (service, path) = f.menuAddress[menu]
  if menu in f.announced: # Same menu, renamed window.
    f.announcements.add Announcement(appId: f.announced[menu],
        service: service, path: path, present: false)
  f.announced[menu] = appId
  f.announcements.add Announcement(appId: appId, service: service,
      path: path, present: true)
  f.log.add "menu " & service & " " & path & " is " & appId

proc forgetMenu(f: var Filter, menu: uint32) =
  if menu in f.announced:
    let (service, path) = f.menuAddress[menu]
    f.announcements.add Announcement(appId: f.announced[menu],
        service: service, path: path, present: false)
  f.announced.del menu
  f.menuAddress.del menu
  f.menuSurface.del menu

proc followWindows(f: var Filter, msg: string, id, opcode: uint32,
    words: int) =
  ## Notes the objects that lead from a surface to its window's app ID.
  case f.interfaces.getOrDefault(id)
  of "xdg_wm_base":
    if opcode == wmBaseGetXdgSurface and words >= 4:
      f.interfaces[msg.word(2)] = "xdg_surface"
      f.surfaceOf[msg.word(2)] = msg.word(3)
  of "xdg_surface":
    if opcode == xdgSurfaceGetToplevel and words >= 3 and id in f.surfaceOf:
      f.interfaces[msg.word(2)] = "xdg_toplevel"
      f.surfaceOf[msg.word(2)] = f.surfaceOf[id]
  of "xdg_toplevel":
    var next: int
    if opcode == toplevelSetAppId and id in f.surfaceOf:
      let (ok, appId) = msg.wireString(2, next)
      if ok:
        let surface = f.surfaceOf[id]
        f.appIdOf[surface] = appId
        for (menu, menuSurface) in f.menuSurface.pairs.toSeq:
          if menuSurface == surface:
            f.announceMenu(menu)
  else:
    discard

proc forgetObject(f: var Filter, id: uint32) =
  ## The compositor freed `id`; the program may reuse it for anything.
  f.interfaces.del id
  f.surfaceOf.del id
  f.appIdOf.del id

# --- Messages ----------------------------------------------------------------

proc clientMessage*(f: var Filter, msg: string) =
  ## A request from the program.
  let
    words = msg.len div 4
    id = msg.word(0)
    opcode = msg.word(1) and 0xffff
  if id == displayId and opcode == displayGetRegistry and words >= 3:
    f.toServer.add msg
    f.registries.incl msg.word(2)
    f.announce(msg.word(2))
  elif id in f.registries and opcode == registryBind and words >= 3 and
      msg.word(2) != fakeName:
    var next: int
    let (ok, iface) = msg.wireString(3, next)
    if ok and iface == "xdg_wm_base" and next + 1 < words:
      f.interfaces[msg.word(next + 1)] = iface
    f.toServer.add msg
  elif id in f.registries and opcode == registryBind and words >= 3 and
      msg.word(2) == fakeName:
    var next: int
    let (ok, iface) = msg.wireString(3, next)
    if ok and next + 1 < words:
      let newId = msg.word(next + 1)
      f.managers.incl newId
      f.placeholder(newId)
      f.log.add "bound " & iface & " v" & $msg.word(next) & " as " & $newId
  elif id in f.managers:
    if opcode == managerCreate and words >= 4:
      f.menus.incl msg.word(2)
      f.menuSurface[msg.word(2)] = msg.word(3)
      f.placeholder(msg.word(2))
      f.log.add "appmenu " & $msg.word(2) & " for surface " & $msg.word(3)
    elif opcode == managerRelease:
      f.managers.excl id
      f.release(id)
  elif id in f.menus:
    if opcode == appmenuSetAddress:
      var next: int
      let (okService, service) = msg.wireString(2, next)
      let (okPath, path) =
        if okService: msg.wireString(next, next) else: (false, "")
      if okService and okPath:
        f.log.add "appmenu " & $id & ": " & service & " " & path
        f.menuAddress[id] = (service, path)
        f.announceMenu(id)
    elif opcode == appmenuRelease:
      f.menus.excl id
      f.forgetMenu(id)
      f.release(id)
  else:
    f.followWindows(msg, id, opcode, words)
    f.toServer.add msg

proc serverMessage*(f: var Filter, msg: string) =
  ## An event from the compositor.
  let
    words = msg.len div 4
    id = msg.word(0)
    opcode = msg.word(1) and 0xffff
  if id == displayId and opcode == displayDeleteId and words >= 3 and
      msg.word(2) in f.placeholders:
    f.placeholders.excl msg.word(2)
  elif id == displayId and opcode == displayDeleteId and words >= 3:
    f.forgetObject(msg.word(2))
    f.toClient.add msg
  elif id in f.placeholders:
    discard # wl_callback.done of a placeholder.
  elif id in f.registries and opcode == registryGlobal:
    var next: int
    let (ok, iface) = msg.wireString(3, next)
    if not (ok and iface == appmenuManager): # Ours is already announced.
      f.toClient.add msg
  else:
    f.toClient.add msg
