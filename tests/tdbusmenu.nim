import std/unittest
import ../src/globalmenu/[dbusmenu, gio]

proc layoutOf(text: string): Layout =
  let reply = g_variant_new_parsed(cstring(text))
  result = parseLayout(reply)
  g_variant_unref(reply)

const sample = """(uint32 7, (0, @a{sv} {'children-display': <'submenu'>}, [
  <(1, {'label': <'_File'>, 'children-display': <'submenu'>}, [
    <(2, {'label': <'_Open…'>, 'shortcut': <[['Control', 'O']]>},
      @av [])>,
    <(3, {'type': <'separator'>}, @av [])>,
    <(4, {'label': <'Show _Toolbar'>, 'toggle-type': <'checkmark'>,
      'toggle-state': <1>}, @av [])>,
    <(5, {'label': <'Hidden'>, 'visible': <false>, 'enabled': <false>},
      @av [])>])>,
  <(6, {'label': <'_View'>, 'children-display': <'submenu'>}, @av [])>]))"""

suite "dbusmenu":
  test "layout tree and properties":
    let layout = layoutOf(sample)
    check layout.revision == 7
    check layout.root.id == 0
    check layout.root.children.len == 2
    let file = layout.root.children[0]
    check file.label == "_File"
    check file.hasSubmenu
    check file.children.len == 4
    check file.children[0].shortcuts == @[@["Control", "O"]]
    check file.children[1].separator
    check file.children[2].toggle == tkCheck
    check file.children[2].toggled
    check not file.children[3].visible
    check not file.children[3].enabled
    check file.children[0].enabled and file.children[0].visible

  test "a declared submenu without items yet still counts as one":
    let view = layoutOf(sample).root.children[1]
    check view.children.len == 0
    check view.hasSubmenu

  test "removed properties go back to the defaults":
    var item = layoutOf(sample).root.children[0].children[3]
    item.applyProperty("visible", nil)
    item.applyProperty("enabled", nil)
    check item.visible and item.enabled

  test "equality compares whole subtrees":
    let (a, b) = (layoutOf(sample).root, layoutOf(sample).root)
    check a == b
    var c = b
    c.children[0].children[2].toggled = false
    check a != c
