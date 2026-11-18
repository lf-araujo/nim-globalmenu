#!/bin/sh
# Starts Thunar in the isolated test session (tests/run-labwc.sh) with the
# given GTK_MODULES value, runs a command with the test session's
# environment, then stops Thunar. Usage: tests/with-thunar.sh MODULES cmd...
mods="$1"; shift
run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
bus=$(cat "$run/nim-globalmenu-test.bus"); disp=$(cat "$run/nim-globalmenu-test.display")
case "$bus" in unix:path=/tmp/dbus-*) ;; *) echo "no isolated test session"; exit 1;; esac
[ "$disp" != wayland-0 ] || { echo "no isolated test session"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS="$bus" WAYLAND_DISPLAY="$disp"
t="$run/nim-globalmenu-test"; mkdir -p "$t/config" "$t/data"
timeout 5 thunar -q 2>/dev/null; sleep 1.5   # Thunar is single-instance
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" GTK_MODULES="$mods" \
  thunar "$t" >"$t/thunar.log" 2>&1 &
pid=$!
sleep 4
"$@"
status=$?
kill $pid 2>/dev/null
exit $status
