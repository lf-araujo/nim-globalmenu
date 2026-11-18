# Package

version = "0.1.0"
author = "Luis De Araujo"
description = "Global menu for Xfce on labwc: the active window's menu in the panel"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.0.0"

# Tasks

const
  pluginLib = "build/libglobalmenu-nim.so"
  libFlags = "--app:lib -d:release -d:noSignalHandler --hints:off"

task test, "Run the unit tests":
  exec "nim c -r --hints:off -o:build/tfinder tests/tfinder.nim"
  exec "nim c -r --hints:off -o:build/tdbusmenu tests/tdbusmenu.nim"
  exec "nim c -r --hints:off -o:build/tappmenuproxy tests/tappmenuproxy.nim"

task cli, "Build the command-line tool (build/nim-globalmenu)":
  exec "nim c -d:release --hints:off -o:build/nim-globalmenu " &
    "src/nim_globalmenu.nim"

task registrar, "Build the AppMenu registrar daemon (build/nim-globalmenu-registrar)":
  exec "nim c -d:release --hints:off -o:build/nim-globalmenu-registrar " &
    "src/nim_globalmenu_registrar.nim"

task proxy, "Build the Wayland appmenu proxy for Chromium browsers (build/nim-globalmenu-appmenu-proxy)":
  exec "nim c -d:release --hints:off -o:build/nim-globalmenu-appmenu-proxy " &
    "src/nim_globalmenu_appmenu_proxy.nim"

task plugin, "Build the panel plugin (build/libglobalmenu-nim.so)":
  exec "nim c " & libFlags & " -o:" & pluginLib &
    " src/nim_globalmenu_plugin.nim"

task module, "Build the GTK module that hides menubars (build/libglobalmenu-hide.so)":
  exec "gcc -shared -fPIC -Wall -O2 -o build/libglobalmenu-hide.so " &
    "src/hide-module/globalmenu-hide.c $(pkg-config --cflags --libs gtk+-3.0 gio-2.0)"

task installUser, "Install the plugin, the menubar-hiding module and the registrar for the user (~/.local)":
  # xfce4-panel pairs ~/.local/share with the library directory name it was
  # built with, which is lib64 on some distributions (Solus among them).
  let
    libName =
      if dirExists("/usr/lib64/xfce4/panel/plugins"): "lib64" else: "lib"
    prefix = getEnv("HOME") & "/.local/"
    libDir = prefix & libName & "/xfce4/panel/plugins"
    dataDir = prefix & "share/xfce4/panel/plugins"
  exec "nimble plugin"
  exec "nimble module"
  mkDir libDir
  mkDir dataDir
  # Copy then rename: overwriting a library the running panel has loaded
  # would crash the panel.
  cpFile pluginLib, libDir & "/libglobalmenu-nim.so.new"
  mvFile libDir & "/libglobalmenu-nim.so.new", libDir & "/libglobalmenu-nim.so"
  cpFile "data/globalmenu-nim.desktop", dataDir & "/globalmenu-nim.desktop"
  # The module is loaded by GTK apps through GTK_MODULES (absolute path).
  let moduleDir = prefix & libName & "/nim-globalmenu"
  mkDir moduleDir
  cpFile "build/libglobalmenu-hide.so", moduleDir & "/libglobalmenu-hide.so.new"
  mvFile moduleDir & "/libglobalmenu-hide.so.new",
    moduleDir & "/libglobalmenu-hide.so"
  # The AppMenu registrar (Qt and other dbusmenu apps), started by D-Bus
  # activation when the plugin starts. A service file in ~/.local/share
  # takes precedence over vala-panel-appmenu's in /usr/share.
  exec "nimble registrar"
  let
    binDir = prefix & "bin"
    servicesDir = prefix & "share/dbus-1/services"
    registrarBin = binDir & "/nim-globalmenu-registrar"
  mkDir binDir
  mkDir servicesDir
  cpFile "build/nim-globalmenu-registrar", registrarBin & ".new"
  mvFile registrarBin & ".new", registrarBin
  exec "chmod 755 " & registrarBin
  exec "nimble proxy"
  let proxyBin = binDir & "/nim-globalmenu-appmenu-proxy"
  cpFile "build/nim-globalmenu-appmenu-proxy", proxyBin & ".new"
  mvFile proxyBin & ".new", proxyBin
  exec "chmod 755 " & proxyBin
  writeFile servicesDir & "/com.canonical.AppMenu.Registrar.service",
    "[D-BUS Service]\nName=com.canonical.AppMenu.Registrar\nExec=" &
    registrarBin & "\n"
  # dbus-broker reads service files only at startup or on ReloadConfig;
  # without this, vala-panel-appmenu's registrar keeps being activated.
  let (output, code) = gorgeEx("gdbus call --session --dest " &
    "org.freedesktop.DBus --object-path /org/freedesktop/DBus " &
    "--method org.freedesktop.DBus.ReloadConfig")
  if code != 0:
    echo "Could not reload the session bus configuration: " & output
  echo "Installed to " & libDir & ", " & moduleDir & " and " & registrarBin
