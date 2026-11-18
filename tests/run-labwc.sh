#!/bin/sh
# Stock labwc, headless, on a private D-Bus session. The bus address and
# Wayland socket are written to $XDG_RUNTIME_DIR/nim-globalmenu-test.{bus,display}.
here=$(cd "$(dirname "$0")" && pwd)
export WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1
exec dbus-run-session -- labwc -C "$here/labwc-config"
