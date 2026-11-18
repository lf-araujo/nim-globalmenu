#!/bin/sh
# Starts the registrar and Firefox (throwaway profile, global-menu prefs on)
# in the isolated test session (tests/run-labwc.sh), runs a command with the
# test session's environment, then stops both. Usage:
#   tests/with-firefox.sh wayland|x11 cmd...
# x11 runs Firefox on the test session's own XWayland, never the real one.
mode="$1"; shift
here=$(cd "$(dirname "$0")" && pwd)
run=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
bus=$(cat "$run/nim-globalmenu-test.bus"); disp=$(cat "$run/nim-globalmenu-test.display")
case "$bus" in unix:path=/tmp/dbus-*) ;; *) echo "no isolated test session"; exit 1;; esac
[ "$disp" != wayland-0 ] || { echo "no isolated test session"; exit 1; }
export DBUS_SESSION_BUS_ADDRESS="$bus" WAYLAND_DISPLAY="$disp" NO_AT_BRIDGE=1
x11=$(cat "$run/nim-globalmenu-test.x11" 2>/dev/null)
case "$mode" in
  wayland) unset DISPLAY; export MOZ_ENABLE_WAYLAND=1 GDK_BACKEND=wayland ;;
  x11)
    [ -n "$x11" ] && [ "$x11" != "$DISPLAY" ] || { echo "no test XWayland"; exit 1; }
    export DISPLAY="$x11" MOZ_ENABLE_WAYLAND=0 GDK_BACKEND=x11 ;;
  *) echo "usage: $0 wayland|x11 cmd..."; exit 2 ;;
esac
t="$run/nim-globalmenu-test"; profile="$t/firefox-profile"
rm -rf "$profile"; mkdir -p "$profile"
cat >"$profile/user.js" <<'EOF'
user_pref("widget.gtk.global-menu.enabled", true);
user_pref("widget.gtk.global-menu.wayland.enabled", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("app.update.enabled", false);
user_pref("network.proxy.type", 0);
EOF
"$here/../build/nim-globalmenu-registrar" --verbose 2>"$t/registrar.log" &
reg=$!
sleep 0.5
firefox --no-remote --profile "$profile" about:blank >"$t/firefox.log" 2>&1 &
app=$!
sleep "${FF_WAIT:-10}"
"$@"
status=$?
kill $app $reg 2>/dev/null
sleep 1
exit $status
