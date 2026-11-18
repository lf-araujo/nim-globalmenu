import std/unittest
import ../src/globalmenu/appmenuproxy

proc words(buf: string): seq[uint32] =
  for i in 0 ..< buf.len div 4:
    result.add buf.word(i)

proc withString(objectId, opcode: uint32, before: seq[uint32], text: string,
    after: seq[uint32]): string =
  message(objectId, opcode, before & stringArg(text) & after)

const
  registry = 2'u32
  manager = 5'u32
  appmenu = 6'u32

suite "appmenu proxy filter":
  setup:
    var f: Filter
    f.clientMessage message(1, 1, [registry]) # wl_display.get_registry

  test "get_registry is forwarded and the global is announced":
    check f.toServer == message(1, 1, [registry])
    let announced = f.toClient
    check announced.messageSize == announced.len
    check announced.word(0) == registry
    check announced.word(2) == fakeName
    check announced == withString(registry, 0, @[fakeName], appmenuManager,
        @[2'u32])

  test "binding the pretend global creates a placeholder, not a bind":
    f.toServer.setLen 0
    f.clientMessage withString(registry, 0, @[fakeName], appmenuManager,
        @[2'u32, manager])
    check f.toServer == message(1, 0, [manager]) # wl_display.sync
    check f.log.len == 1

  test "appmenu objects are answered here; releases get delete_id":
    f.clientMessage withString(registry, 0, @[fakeName], appmenuManager,
        @[2'u32, manager])
    f.toServer.setLen 0
    f.toClient.setLen 0
    f.clientMessage message(manager, 0, [appmenu, 9'u32]) # create(id, surface)
    check f.toServer == message(1, 0, [appmenu])
    f.toServer.setLen 0
    f.clientMessage message(appmenu, 0, # set_address(service, path)
        stringArg(":1.5") & stringArg("/com/canonical/menu/1"))
    check f.toServer.len == 0
    check f.log[^1] == "appmenu 6: :1.5 /com/canonical/menu/1"
    f.clientMessage message(appmenu, 1, []) # release
    check f.toServer.len == 0
    check f.toClient == message(1, 1, [appmenu]) # delete_id

  test "placeholder events from the compositor are dropped":
    f.clientMessage withString(registry, 0, @[fakeName], appmenuManager,
        @[2'u32, manager])
    f.toClient.setLen 0
    f.serverMessage message(manager, 0, [1234'u32]) # wl_callback.done
    f.serverMessage message(1, 1, [manager]) # delete_id
    check f.toClient.len == 0
    # Once the placeholder is gone, events for a reused id pass.
    f.serverMessage message(manager, 0, [1'u32])
    check f.toClient == message(manager, 0, [1'u32])

  test "other traffic passes unchanged":
    f.toServer.setLen 0
    f.toClient.setLen 0
    let request = message(3, 2, [7'u32, 8])
    f.clientMessage request
    check f.toServer == request
    let event = withString(registry, 0, @[1'u32], "wl_compositor", @[6'u32])
    f.serverMessage event
    check f.toClient == event

  test "a real appmenu global from the compositor is hidden":
    f.toClient.setLen 0
    f.serverMessage withString(registry, 0, @[40'u32], appmenuManager,
        @[2'u32])
    check f.toClient.len == 0

  test "message framing":
    let m = message(3, 2, [7'u32, 8])
    check messageSize(m) == m.len
    check messageSize(m[0 ..< 6]) == 0
    check messageSize(m & m) == m.len
    var bad = m
    bad[6] = '\x05' # size 5: not a multiple of 4
    bad[7] = '\x00'
    check messageSize(bad) == -1
    check words(m) == @[3'u32, (16'u32 shl 16) or 2, 7, 8]
