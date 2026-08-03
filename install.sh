#!/usr/bin/env sh
# dockh installer — builds from source and installs the dock.
#
#   ./install.sh                 build + system install (/usr/local, needs root)
#   sudo ./install.sh            same, explicit
#   ./install.sh --user          install to ~/.local (no root needed)
#   ./install.sh --prefix=/opt   install to a custom prefix
#   ./install.sh --uninstall     remove the previously installed files
#   ./install.sh --check         only verify dependencies and exit
#   ./install.sh -h              this help
#
# Installs:
#   <prefix>/bin/dockh
#   <prefix>/share/dockh/style.css
#   <prefix>/share/dockh/config.toml

set -e

PREFIX="" # empty = resolved below (default /usr/local, or ~/.local with --user)
USER_MODE=0
DO_UNINSTALL=0
DO_CHECK=0
BUILD_FLAGS="-Doptimize=ReleaseFast"

usage() {
    cat <<'EOF'
dockh installer

Usage:
  ./install.sh                 build + system install (/usr/local, needs root)
  sudo ./install.sh            same, explicit
  ./install.sh --user          install to ~/.local (no root needed)
  ./install.sh --prefix=/opt   install to a custom prefix
  ./install.sh --uninstall     remove the previously installed files
  ./install.sh --check         only verify dependencies and exit
  ./install.sh -h              this help

Installs:
  <prefix>/bin/dockh
  <prefix>/share/dockh/style.css
  <prefix>/share/dockh/config.toml
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        -h|--help) usage ;;
        --user) USER_MODE=1 ;;
        --uninstall) DO_UNINSTALL=1 ;;
        --check) DO_CHECK=1 ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        -D*) BUILD_FLAGS="$BUILD_FLAGS $arg" ;;
        *)
            echo "dockh: unknown option '$arg' (see ./install.sh -h)" >&2
            exit 1
            ;;
    esac
done

# Resolve the prefix: explicit --prefix wins; --user defaults to ~/.local;
# otherwise the system default /usr/local. (:- is safe because PREFIX is empty.)
if [ "$USER_MODE" = "1" ]; then
    PREFIX="${PREFIX:-$HOME/.local}"
else
    PREFIX="${PREFIX:-/usr/local}"
fi

BINDIR="$PREFIX/bin"
DATADIR="$PREFIX/share/dockh"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
    missing=""
    if ! command -v zig >/dev/null 2>&1; then missing="$missing zig"; fi
    if ! command -v pkg-config >/dev/null 2>&1; then missing="$missing pkg-config"; fi
    if ! pkg-config --exists gtk4 2>/dev/null; then missing="$missing gtk4"; fi
    if ! pkg-config --exists gtk4-layer-shell-0 2>/dev/null; then missing="$missing gtk4-layer-shell"; fi
    if [ -n "$missing" ]; then
        echo "dockh: missing dependencies:$missing" >&2
        echo "On Arch / CachyOS:" >&2
        echo "  sudo pacman -S gtk4 gtk4-layer-shell zig" >&2
        echo "Other distros: install the equivalents of gtk4, gtk4-layer-shell and zig (0.16+)." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall() {
    echo "dockh: removing $BINDIR/dockh and $DATADIR"
    rm -f "$BINDIR/dockh"
    rm -rf "$DATADIR"
    echo "dockh: uninstalled."
    exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$DO_CHECK" = "1" ]; then
    check_deps
    echo "dockh: all dependencies present. zig: $(zig version)"
    exit 0
fi

if [ "$DO_UNINSTALL" = "1" ]; then
    if [ "$USER_MODE" != "1" ] && [ "$(id -u)" -ne 0 ]; then
        echo "dockh: system uninstall needs root — re-run with sudo, or use --user." >&2
        exit 1
    fi
    uninstall
fi

check_deps

# Build
echo "dockh: building with 'zig build $BUILD_FLAGS' ..."
if [ ! -f build.zig ]; then
    echo "dockh: build.zig not found — run this script from the repo root." >&2
    exit 1
fi
zig build $BUILD_FLAGS

# System installs (no --user) need root. For a custom prefix without root,
# combine: ./install.sh --user --prefix=/opt.
if [ "$USER_MODE" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "dockh: system install needs root. Re-run with sudo, or use ./install.sh --user" >&2
    exit 1
fi

echo "dockh: installing to $PREFIX"
install -Dm755 zig-out/bin/dockh "$BINDIR/dockh"
install -Dm644 config/style.css   "$DATADIR/style.css"
install -Dm644 config/config.toml "$DATADIR/config.toml"

echo
echo "dockh: installed. Start it with:"
echo "  $BINDIR/dockh"
echo
echo "First run creates ~/.config/dockh/{config.toml,style.css} for customization."
echo "For the liquid-glass blur, add to hyprland.conf:"
echo "  layerrule = blur, dockh"
echo "  layerrule = ignorealpha 0.5, dockh"
