#!/bin/sh
# Cross-build the Frunk quick-setting plugin for BengalOS FP5 (arm64, phosh 0.59.0+nb20261116).
# Needs: phosh source at the matching commit (PHOSH_SRC, e.g. e4949f0 = main 2026-11-16) for
#        src/quick-setting.h + status-icon.h + status-page.h; arm64 GTK3/GLib dev headers
#        extracted from Debian trixie debs into SYSROOT (libgtk-3-dev libgio-2.0-dev
#        libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev libatk1.0-dev
#        libharfbuzz-dev); zig (pip ziglang) as the cross compiler.
# Plugins resolve phosh_* symbols from the phosh executable at load time (like upstream plugins).
set -eu
PHOSH_SRC=${PHOSH_SRC:?}; SYSROOT=${SYSROOT:?}
R=$SYSROOT/usr; P=$PHOSH_SRC/src
python3 -m ziglang cc -target aarch64-linux-gnu.2.36 -shared -fPIC -O2 -Wall -Wextra -Wno-unused-parameter \
  -I"$P" -I"$R/include/gtk-3.0" -I"$R/include/glib-2.0" -I"$R/lib/aarch64-linux-gnu/glib-2.0/include" \
  -I"$R/include/gio-unix-2.0" -I"$R/include/pango-1.0" -I"$R/include/harfbuzz" -I"$R/include/cairo" \
  -I"$R/include/gdk-pixbuf-2.0" -I"$R/include/atk-1.0" \
  -o libphosh-plugin-frunk-quick-setting.so "$(dirname "$0")/frunk-quick-setting.c"
