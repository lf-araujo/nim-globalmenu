## Follows the compositor's window list through wlr-foreign-toplevel-
## management: which windows exist, in the order they appeared, and which
## one is active.

import std/os

const protoDir = currentSourcePath().parentDir() / "proto"

{.passC: "-I" & protoDir.}
{.passL: "-lwayland-client".}
# C field names are kept as generated (snake_case) in the listener structs.
# Listener callbacks take `cstring` where the generated structs say
# `const char *`; same ABI, but GCC 14 rejects the mismatch.
{.passC: "-Wno-incompatible-pointer-types".}
{.compile: protoDir / "wlr-foreign-toplevel-management-unstable-v1-protocol.c".}

const
  coreHeader = "<wayland-client.h>"
  wlrHeader = "wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
  stateMaximized = 0'u32
  stateMinimized = 1'u32
  stateActivated = 2'u32

type
  WlDisplay* = ptr object
  WlRegistryObj {.importc: "struct wl_registry", header: coreHeader,
      incompleteStruct.} = object
  WlRegistry = ptr WlRegistryObj
  WlInterface {.importc: "struct wl_interface", header: coreHeader,
      incompleteStruct.} = object
  WlOutputObj {.importc: "struct wl_output", header: coreHeader,
      incompleteStruct.} = object
  WlOutput = ptr WlOutputObj
  WlArray {.importc: "struct wl_array", header: coreHeader, bycopy.} = object
    size, alloc: csize_t
    data: pointer
  ManagerObj {.importc: "struct zwlr_foreign_toplevel_manager_v1",
      header: wlrHeader, incompleteStruct.} = object
  Manager = ptr ManagerObj
  HandleObj {.importc: "struct zwlr_foreign_toplevel_handle_v1",
      header: wlrHeader, incompleteStruct.} = object
  Handle = ptr HandleObj

  RegistryListener {.importc: "struct wl_registry_listener",
      header: coreHeader.} = object
    global: proc (data: pointer, registry: WlRegistry, name: uint32,
        iface: cstring, version: uint32) {.cdecl.}
    global_remove: proc (data: pointer, registry: WlRegistry,
        name: uint32) {.cdecl.}
  ManagerListener {.importc: "struct zwlr_foreign_toplevel_manager_v1_listener",
      header: wlrHeader.} = object
    toplevel: proc (data: pointer, manager: Manager, handle: Handle) {.cdecl.}
    finished: proc (data: pointer, manager: Manager) {.cdecl.}
  HandleListener {.importc: "struct zwlr_foreign_toplevel_handle_v1_listener",
      header: wlrHeader.} = object
    title: proc (data: pointer, handle: Handle, title: cstring) {.cdecl.}
    app_id: proc (data: pointer, handle: Handle, appId: cstring) {.cdecl.}
    output_enter: proc (data: pointer, handle: Handle, output: WlOutput)
        {.cdecl.}
    output_leave: proc (data: pointer, handle: Handle, output: WlOutput)
        {.cdecl.}
    state: proc (data: pointer, handle: Handle, state: ptr WlArray) {.cdecl.}
    done: proc (data: pointer, handle: Handle) {.cdecl.}
    closed: proc (data: pointer, handle: Handle) {.cdecl.}
    parent: proc (data: pointer, handle: Handle, parent: Handle) {.cdecl.}

var zwlr_foreign_toplevel_manager_v1_interface
    {.importc, header: wlrHeader.}: WlInterface

{.push importc, cdecl, header: coreHeader.}
proc wl_display_connect(name: cstring): WlDisplay
proc wl_display_roundtrip(display: WlDisplay): cint
proc wl_display_flush(display: WlDisplay): cint
proc wl_display_dispatch(display: WlDisplay): cint
proc wl_display_get_registry(display: WlDisplay): WlRegistry
proc wl_registry_add_listener(registry: WlRegistry,
    listener: ptr RegistryListener, data: pointer): cint
proc wl_registry_bind(registry: WlRegistry, name: uint32,
    iface: ptr WlInterface, version: uint32): pointer
{.pop.}

{.push importc, cdecl, header: wlrHeader.}
proc zwlr_foreign_toplevel_manager_v1_add_listener(manager: Manager,
    listener: ptr ManagerListener, data: pointer): cint
proc zwlr_foreign_toplevel_handle_v1_add_listener(handle: Handle,
    listener: ptr HandleListener, data: pointer): cint
proc zwlr_foreign_toplevel_handle_v1_destroy(handle: Handle)
proc zwlr_foreign_toplevel_handle_v1_set_maximized(handle: Handle)
proc zwlr_foreign_toplevel_handle_v1_unset_maximized(handle: Handle)
proc zwlr_foreign_toplevel_handle_v1_set_minimized(handle: Handle)
proc zwlr_foreign_toplevel_handle_v1_close(handle: Handle)
{.pop.}

type
  Toplevel* = ref object
    owner: Toplevels
    handle: Handle
    order*: int ## Arrival order; windows of one app keep their order.
    title*, appId*: string
    active*, maximized*, minimized*: bool
  Toplevels* = ref object
    display: WlDisplay
    registry: WlRegistry
    manager: Manager
    counter: int
    windows*: seq[Toplevel] ## In arrival order.
    onChange*: proc (data: pointer) {.nimcall.}
      ## Called after any window is added, removed or changes.
    onChangeData*: pointer

func active*(list: Toplevels): Toplevel =
  ## The active window, or `nil`.
  for window in list.windows:
    if window.active:
      return window

func sameApp*(list: Toplevels, window: Toplevel): seq[Toplevel] =
  ## All windows with `window`'s app ID, in arrival order.
  for other in list.windows:
    if other.appId == window.appId:
      result.add other

proc changed(list: Toplevels) =
  if list.onChange != nil:
    list.onChange(list.onChangeData)

proc handleTitle(data: pointer, handle: Handle, title: cstring) {.cdecl.} =
  cast[Toplevel](data).title = $title

proc handleAppId(data: pointer, handle: Handle, appId: cstring) {.cdecl.} =
  cast[Toplevel](data).appId = $appId

proc handleOutput(data: pointer, handle: Handle, output: WlOutput) {.cdecl.} =
  discard

proc handleState(data: pointer, handle: Handle, state: ptr WlArray)
    {.cdecl.} =
  let window = cast[Toplevel](data)
  window.active = false
  window.maximized = false
  window.minimized = false
  let values = cast[ptr UncheckedArray[uint32]](state.data)
  for i in 0 ..< int(state.size div 4):
    case values[i]
    of stateActivated: window.active = true
    of stateMaximized: window.maximized = true
    of stateMinimized: window.minimized = true
    else: discard

proc handleDone(data: pointer, handle: Handle) {.cdecl.} =
  cast[Toplevel](data).owner.changed()

proc handleClosed(data: pointer, handle: Handle) {.cdecl.} =
  let
    window = cast[Toplevel](data)
    list = window.owner
  let pos = list.windows.find(window)
  if pos >= 0:
    list.windows.delete(pos)
  zwlr_foreign_toplevel_handle_v1_destroy(handle)
  # Others (the panel's name menu) may still hold this window; its actions
  # must not touch the destroyed handle.
  window.handle = nil
  GC_unref(window)
  list.changed()

proc handleParent(data: pointer, handle, parent: Handle) {.cdecl.} =
  discard

var handleListener = HandleListener(title: handleTitle, app_id: handleAppId,
    output_enter: handleOutput, output_leave: handleOutput, state: handleState,
    done: handleDone, closed: handleClosed, parent: handleParent)

proc managerToplevel(data: pointer, manager: Manager, handle: Handle)
    {.cdecl.} =
  let
    list = cast[Toplevels](data)
    window = Toplevel(owner: list, handle: handle, order: list.counter)
  inc list.counter
  GC_ref(window)
  list.windows.add window
  discard zwlr_foreign_toplevel_handle_v1_add_listener(handle,
      addr handleListener, cast[pointer](window))

proc managerFinished(data: pointer, manager: Manager) {.cdecl.} =
  discard

var managerListener = ManagerListener(toplevel: managerToplevel,
    finished: managerFinished)

proc registryGlobal(data: pointer, registry: WlRegistry, name: uint32,
    iface: cstring, version: uint32) {.cdecl.} =
  if $iface == "zwlr_foreign_toplevel_manager_v1":
    let list = cast[Toplevels](data)
    list.manager = cast[Manager](wl_registry_bind(registry, name,
        addr zwlr_foreign_toplevel_manager_v1_interface, min(version, 3)))
    discard zwlr_foreign_toplevel_manager_v1_add_listener(list.manager,
        addr managerListener, data)

proc registryGlobalRemove(data: pointer, registry: WlRegistry, name: uint32)
    {.cdecl.} =
  discard

var registryListener = RegistryListener(global: registryGlobal,
    global_remove: registryGlobalRemove)

proc track*(display: WlDisplay): Toplevels =
  ## Starts following `display`'s windows and waits until the current ones
  ## are known. Returns `nil` if the compositor has no
  ## wlr-foreign-toplevel-management. Later changes arrive through
  ## `onChange` whenever the display's events are dispatched.
  result = Toplevels(display: display)
  GC_ref(result)
  result.registry = wl_display_get_registry(display)
  discard wl_registry_add_listener(result.registry, addr registryListener,
      cast[pointer](result))
  for _ in 1 .. 3: # globals, existing toplevels, their properties
    discard wl_display_roundtrip(display)
  if result.manager == nil:
    GC_unref(result)
    result = nil

proc connectDisplay*(): WlDisplay =
  ## Connects to the Wayland display named by `WAYLAND_DISPLAY`.
  wl_display_connect(nil)

proc dispatch*(list: Toplevels): bool =
  ## Blocks for the next batch of events (standalone programs only; GTK
  ## programs dispatch through their main loop). False when disconnected.
  wl_display_dispatch(list.display) >= 0

func isClosed*(window: Toplevel): bool =
  ## The window is gone; its actions do nothing.
  window.handle == nil

proc close*(window: Toplevel) =
  ## Asks the window to close (the app may ask to save first).
  if window.isClosed:
    return
  zwlr_foreign_toplevel_handle_v1_close(window.handle)
  discard wl_display_flush(window.owner.display)

proc minimize*(window: Toplevel) =
  if window.isClosed:
    return
  zwlr_foreign_toplevel_handle_v1_set_minimized(window.handle)
  discard wl_display_flush(window.owner.display)

proc toggleMaximized*(window: Toplevel) =
  if window.isClosed:
    return
  if window.maximized:
    zwlr_foreign_toplevel_handle_v1_unset_maximized(window.handle)
  else:
    zwlr_foreign_toplevel_handle_v1_set_maximized(window.handle)
  discard wl_display_flush(window.owner.display)
