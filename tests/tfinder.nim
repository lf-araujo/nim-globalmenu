import std/unittest
import ../src/globalmenu/finder

suite "finder":
  test "wanted names for a plain app id":
    check "thunar" in wantedNames("thunar", @[])
    let names = wantedNames("org.gnome.Calculator", @["gnome-calculator"])
    check "gnome-calculator" in names
    check "calculator" in names

  test "libreoffice windows match soffice processes":
    check "soffice.bin" in wantedNames("libreoffice-writer", @[])

  test "program matching, including 15-character comm":
    check matches(@["thunar"], @["thunar"])
    check not matches(@["thunar"], @["firefox"])
    check matches(@["gnome-calculator"], @["gnome-calculat"]) == false
    check matches(@["gnome-calculator"], @["gnome-calculato"])

  test "a program matches an app ID that adds a suffix to its name":
    check matches(wantedNames("brave-browser", @["brave-browser-stable"]),
        @["brave"])
    check not matches(@["brave-browser"], @["bra"]) # too short to trust
    check not matches(@["bravery"], @["brave"])

  test "menu choice lines windows up from the newest end":
    let sources = @[MenuSource(busName: ":1.1", path: "/m/0"),
      MenuSource(busName: ":1.1", path: "/m/1"),
      MenuSource(busName: ":1.1", path: "/m/2")]
    check pickMenu(sources, 0, 3) == 0
    check pickMenu(sources, 2, 3) == 2
    check pickMenu(sources, 1, 2) == 2 # two windows, three menus
    check pickMenu(sources, 0, 1) == 2
    check pickMenu(sources, 0, 5) == 0 # more windows than menus: clamp
    check pickMenu(@[], 0, 1) == -1

  test "app path is the menubar path minus /menus/...":
    check MenuSource(path: "/org/xfce/Thunar/menus/menubar/0").appPath ==
      "/org/xfce/Thunar"
