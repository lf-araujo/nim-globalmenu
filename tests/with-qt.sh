#!/bin/sh
# Starts the registrar and a Qt app (VLC by default) in the isolated test
# session (tests/run-labwc.sh), runs a command with the test session's
# environment, then stops both. Usage: tests/with-qt.sh cmd...
#   QT_APP="vlc --no-qt-privacy-ask"  the app to start
#   QT_QPA_PLATFORM=wayland|xcb       passed through (default: wayland)
here=$(cd "$(dirname "$0")" && pwd)
run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
bus=$(cat "$run/nim-globalmenu-test.bus"); disp=$(cat "$run/nim-globalmenu-test.display")
case "$bus" in unix:path=/tmp/dbus-*) ;; *) echo "no isolated test session"; exit 1;; esac
[ "$disp" != wayland-0 ] || { echo "no isolated test session"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS="$bus" WAYLAND_DISPLAY="$disp" NO_AT_BRIDGE=1
# Only the test session's own XWayland (labwc-config/autostart), never the
# real session's.
x11=$(cat "$run/nim-globalmenu-test.x11" 2>/dev/null)
if [ -n "$x11" ] && [ "$x11" != "$DISPLAY" ]; then export DISPLAY="$x11"; else unset DISPLAY; fi
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
t="$run/nim-globalmenu-test"; mkdir -p "$t/config" "$t/data"
"$here/../build/nim-globalmenu-registrar" --verbose 2>"$t/registrar.log" &
reg=$!
sleep 0.5                    # Qt only looks for the registrar at startup.
XDG_CONFIG_HOME="$t/config" XDG_DATA_HOME="$t/data" \
  sh -c "exec ${QT_APP:-vlc --no-qt-privacy-ask}" >"$t/qt-app.log" 2>&1 &
app=$!
sleep "${QT_WAIT:-5}"
"$@"
status=$?
kill $app $reg 2>/dev/null
exit $status
