#!/bin/sh
# Starts Thunar inside the isolated test session (tests/run-labwc.sh) with the
# given GTK_MODULES value, and reports whether it exports a menu over D-Bus
# and whether its menubar is visible. Usage: tests/probe-thunar.sh MODULES [shot.png]
# Never touches the real session: refuses to run unless the test bus is in use.
mods="$1"; shot="$2"
run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
bus=$(cat "$run/nim-globalmenu-test.bus") ; disp=$(cat "$run/nim-globalmenu-test.display")
# The test bus lives in /tmp/dbus-*; the real one is /run/user/N/bus.
case "$bus" in unix:path=/tmp/dbus-*) ;; *) echo "no isolated test session"; exit 1;; esac
[ "$disp" != wayland-0 ] || { echo "no isolated test session"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS="$bus" WAYLAND_DISPLAY="$disp"
t="$run/nim-globalmenu-test"; mkdir -p "$t/config" "$t/data"
# Thunar is single-instance: a copy already running on the test bus (even one
# started by D-Bus activation, without the module) would swallow our launch.
timeout 5 thunar -q 2>/dev/null; sleep 1.5
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" GTK_MODULES="$mods" \
  thunar "$t" >"$t/thunar.log" 2>&1 &
pid=$!
sleep 4
[ -n "$shot" ] && grim "$shot"
found=0
for n in $(timeout 5 gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.ListNames | tr ',' '\n' | tr -d "[]()' " | grep '^:'); do
  p=$(timeout 5 gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
      --method org.freedesktop.DBus.GetConnectionUnixProcessID "$n" 2>/dev/null | grep -o '[0-9]\+' | tail -1)
  [ "$p" = "$pid" ] || continue
  for path in /org/xfce/Thunar/menus/menubar/0 /org/appmenu/gtk/window/0; do
    out=$(timeout 5 gdbus call --session --dest "$n" --object-path "$path" --method org.gtk.Menus.Start '[0,1,2,3]' 2>/dev/null)
    [ -n "$out" ] && { echo "$n $path: $(echo "$out" | grep -o "'label': <'[^']*'>" | wc -l) labels"; found=1; }
  done
done
[ $found = 0 ] && echo "no menu exported"
grep -E 'globalmenu|appmenu|CRITICAL' "$t/thunar.log" | head -3
kill $pid 2>/dev/null
