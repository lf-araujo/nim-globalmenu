## nim-globalmenu-appmenu-proxy: runs a program behind a small Wayland proxy
## that pretends the compositor offers `org_kde_kwin_appmenu_manager` (see
## globalmenu/appmenuproxy.nim), so Chromium-based browsers export their
## menubar on labwc.
##
##   nim-globalmenu-appmenu-proxy [-v] COMMAND [ARGS...]
##
## Listens on `$XDG_RUNTIME_DIR/wayland-globalmenu-PID`, runs COMMAND with
## `WAYLAND_DISPLAY` set to that, passes each connection through to the real
## compositor (file descriptors included), registers each window's menu
## with the registrar under the window's app ID (org.nimglobalmenu.AppMenus),
## and exits with COMMAND's status
## once COMMAND has exited and its connections are closed. If the proxy is
## killed, the program loses its Wayland connection.

import std/[os, posix, sequtils, strutils]
import globalmenu/[appmenuproxy, gio, registrar]

var
  MSG_DONTWAIT {.importc, header: "<sys/socket.h>".}: cint
  MSG_CMSG_CLOEXEC {.importc, header: "<sys/socket.h>".}: cint
  SOCK_NONBLOCK {.importc, header: "<sys/socket.h>".}: cint

const
  maxFdsPerMessage = 28 ## libwayland takes at most this many per read.
  maxConnections = 32

type
  Side = object
    sock: SocketHandle
    input: string ## Read, not yet split into messages.
    inFds: seq[cint] ## Read, not yet handed to the other side.
    output: string ## To write to this side.
    outFds: seq[cint]

  Connection = ref object
    client, server: Side
    filter: Filter

var
  verbose = false
  bus: GDBusConnection ## Session bus, opened at the first announcement.

proc log(text: string) =
  if verbose:
    stderr.writeLine "nim-globalmenu-appmenu-proxy: " & text

proc closeSide(side: var Side) =
  discard posix.close(side.sock)
  for fd in side.inFds & side.outFds:
    discard posix.close(fd)
  side.inFds.setLen 0
  side.outFds.setLen 0

proc tellRegistrar(news: Announcement) =
  ## Registers or unregisters a window's menu under its app ID.
  if not news.path.startsWith("/") or news.service.len == 0:
    return
  if bus == nil:
    bus = sessionBus()
    if bus == nil:
      return
  let reply =
    if news.present:
      bus.callSync(registrarName, registrarPath, appMenusInterface,
          "Register", g_variant_new("(sso)", cstring(news.appId),
          cstring(news.service), cstring(news.path)), 1000)
    else:
      bus.callSync(registrarName, registrarPath, appMenusInterface,
          "Unregister", g_variant_new("(so)", cstring(news.service),
          cstring(news.path)), 1000)
  if reply == nil:
    log "the registrar did not take " & news.path
  else:
    g_variant_unref(reply)

proc takeOutput(conn: Connection) =
  ## Moves what the filter produced to the sides' output.
  conn.client.output.add conn.filter.toClient
  conn.server.output.add conn.filter.toServer
  conn.filter.toClient.setLen 0
  conn.filter.toServer.setLen 0
  for line in conn.filter.log:
    log line
  conn.filter.log.setLen 0
  for news in conn.filter.announcements:
    tellRegistrar(news)
  conn.filter.announcements.setLen 0

proc readSide(conn: Connection, src, dst: var Side, fromClient: bool): bool =
  ## Reads what is waiting on `src` and passes its complete messages through
  ## the filter. False when `src` is closed or broken.
  var
    data: array[8192, char]
    control: array[160, uint64] # Room for 255 descriptors, aligned.
    iov = IOVec(iov_base: addr data[0], iov_len: csize_t(data.len))
    msg = Tmsghdr(msg_iov: addr iov, msg_iovlen: 1,
        msg_control: addr control[0], msg_controllen: csize_t(sizeof control))
  let n = recvmsg(src.sock, addr msg, MSG_DONTWAIT or MSG_CMSG_CLOEXEC)
  if n < 0:
    return errno == EAGAIN or errno == EINTR
  if n == 0:
    return false
  var cm = CMSG_FIRSTHDR(addr msg)
  while cm != nil:
    if cm.cmsg_level == SOL_SOCKET and cm.cmsg_type == SCM_RIGHTS:
      let
        count = (int(cm.cmsg_len) - int(CMSG_LEN(0))) div sizeof(cint)
        fds = cast[ptr UncheckedArray[cint]](CMSG_DATA(cm))
      for i in 0 ..< count:
        src.inFds.add fds[i]
    cm = CMSG_NXTHDR(addr msg, cm)
  let start = src.input.len
  src.input.setLen(start + n)
  copyMem(addr src.input[start], addr data[0], n)

  var used = 0
  while true:
    let size = messageSize(src.input[used .. ^1])
    if size < 0:
      return false
    if size == 0:
      break
    let message = src.input[used ..< used + size]
    if fromClient:
      conn.filter.clientMessage(message)
    else:
      conn.filter.serverMessage(message)
    used += size
  src.input = src.input[used .. ^1]
  conn.takeOutput()
  # Descriptors go with (or ahead of) the messages they came with; the
  # messages the filter answers or drops carry none.
  dst.outFds.add src.inFds
  src.inFds.setLen 0
  true

proc flushSide(side: var Side): bool =
  ## Writes what is queued for `side`. False when it is broken.
  while side.output.len > 0:
    let nfds = min(side.outFds.len, maxFdsPerMessage)
    var len = side.output.len
    if side.outFds.len > nfds and len > 4:
      len = 4 # Leave bytes for the next batch of descriptors to go with.
    var
      control: array[24, uint64] # Room for 28 descriptors, aligned.
      iov = IOVec(iov_base: addr side.output[0], iov_len: csize_t(len))
      msg = Tmsghdr(msg_iov: addr iov, msg_iovlen: 1)
    if nfds > 0:
      let bytes = csize_t(nfds * sizeof(cint))
      msg.msg_control = addr control[0]
      msg.msg_controllen = CMSG_SPACE(bytes)
      let cm = CMSG_FIRSTHDR(addr msg)
      cm.cmsg_level = SOL_SOCKET
      cm.cmsg_type = SCM_RIGHTS
      cm.cmsg_len = CMSG_LEN(bytes)
      copyMem(CMSG_DATA(cm), addr side.outFds[0], int(bytes))
    let n = sendmsg(side.sock, addr msg, MSG_DONTWAIT or MSG_NOSIGNAL)
    if n < 0:
      return errno == EAGAIN or errno == EINTR
    if nfds > 0:
      for i in 0 ..< nfds:
        discard posix.close(side.outFds[i])
      side.outFds.delete(0 ..< nfds)
    side.output = side.output[n .. ^1]
  true

proc unixAddress(path: string): Sockaddr_un =
  result.sun_family = TSa_Family(AF_UNIX)
  if path.len >= result.sun_path.len:
    quit("socket path too long: " & path, 1)
  for i, c in path:
    result.sun_path[i] = c

proc connectCompositor(path: string): SocketHandle =
  ## A connection to the real compositor; `InvalidSocket` if it fails.
  result = posix.socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC, 0)
  if result == InvalidSocket:
    return
  var address = unixAddress(path)
  if posix.connect(result, cast[ptr SockAddr](addr address),
      SockLen(sizeof address)) != 0:
    discard posix.close(result)
    result = InvalidSocket

proc listenOn(path: string): SocketHandle =
  result = posix.socket(AF_UNIX, SOCK_STREAM or SOCK_CLOEXEC or SOCK_NONBLOCK,
      0)
  var address = unixAddress(path)
  discard posix.unlink(cstring(path))
  if result == InvalidSocket or bindSocket(result,
      cast[ptr SockAddr](addr address), SockLen(sizeof address)) != 0 or
      posix.listen(result, 8) != 0:
    quit("cannot listen on " & path & ": " & $strerror(errno), 1)

proc startProgram(args: seq[string], display: string): Pid =
  ## Runs `args` with WAYLAND_DISPLAY set to the proxy's socket.
  putEnv("WAYLAND_DISPLAY", display)
  delEnv("WAYLAND_SOCKET")
  let argv = allocCStringArray(args)
  result = fork()
  if result == 0:
    discard execvp(cstring(args[0]), argv)
    stderr.writeLine "nim-globalmenu-appmenu-proxy: cannot run " & args[0]
    exitnow(127)
  deallocCStringArray(argv)
  if result < 0:
    quit("cannot fork", 1)

proc main() =
  var args = commandLineParams()
  if args.len > 0 and args[0] == "-v":
    verbose = true
    args.delete(0)
  if args.len == 0:
    quit("usage: nim-globalmenu-appmenu-proxy [-v] COMMAND [ARGS...]", 2)
  let runtime = getEnv("XDG_RUNTIME_DIR")
  if runtime.len == 0:
    quit("XDG_RUNTIME_DIR is not set", 1)
  let
    display = getEnv("WAYLAND_DISPLAY", "wayland-0")
    realPath = if display.isAbsolute: display else: runtime / display
    name = "wayland-globalmenu-" & $getCurrentProcessId()
    path = runtime / name
    listener = listenOn(path)
    child = startProgram(args, name)
  log path & " -> " & realPath & ", running " & args[0] & " (pid " &
    $child & ")"

  var
    conns: seq[Connection]
    childRunning = true
    status: cint
  while childRunning or conns.len > 0:
    if childRunning and waitpid(child, status, WNOHANG) == child:
      childRunning = false
      log "program exited"
    var fds = @[TPollfd(fd: cint(listener), events: POLLIN)]
    for conn in conns:
      fds.add TPollfd(fd: cint(conn.client.sock), events: POLLIN or
          (if conn.client.output.len > 0: POLLOUT else: 0))
      fds.add TPollfd(fd: cint(conn.server.sock), events: POLLIN or
          (if conn.server.output.len > 0: POLLOUT else: 0))
    if poll(addr fds[0], Tnfds(fds.len), 500) < 0 and errno != EINTR:
      break
    let polled = conns.len # A connection accepted below waits for next poll.

    if (fds[0].revents and POLLIN) != 0:
      let client = accept4(listener, nil, nil, SOCK_CLOEXEC)
      if client != InvalidSocket:
        let server = connectCompositor(realPath)
        if server == InvalidSocket or conns.len >= maxConnections:
          discard posix.close(client)
          if server != InvalidSocket:
            discard posix.close(server)
        else:
          conns.add Connection(client: Side(sock: client),
              server: Side(sock: server))
          log "new connection"
    var closed: seq[Connection]
    for i in 0 ..< polled:
      let
        conn = conns[i]
        clientEvents = fds[1 + 2 * i].revents
        serverEvents = fds[2 + 2 * i].revents
        hangup = POLLHUP or POLLERR
      var ok = true
      if (clientEvents and POLLIN) != 0:
        ok = conn.readSide(conn.client, conn.server, true)
      if ok and (serverEvents and POLLIN) != 0:
        ok = conn.readSide(conn.server, conn.client, false)
      if ok and ((clientEvents or serverEvents) and hangup) != 0 and
          ((clientEvents or serverEvents) and POLLIN) == 0:
        ok = false
      if ok:
        ok = flushSide(conn.server) and flushSide(conn.client)
      if not ok:
        closed.add conn
    for conn in closed:
      conn.client.closeSide()
      conn.server.closeSide()
      log "connection closed"
    conns.keepItIf(it notin closed)

  discard posix.close(listener)
  discard posix.unlink(cstring(path))
  quit(if WIFEXITED(status): int(WEXITSTATUS(status)) else: 1)

main()
