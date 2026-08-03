# Maintainer: Jesus Alcala <jesusalcaladev@gmail.com>
#
# dockh — a GTK4 layer-shell dock for Hyprland, written in Zig.
# Rewrite of nwg-dock-hyprland (Go/GTK3) with no Go/GC/bindings layers.
#
# Build with:  makepkg -si    (or via an AUR helper: yay -S dockh / paru -S dockh)
#
# NOTE: built from the git HEAD (no release tag published yet). Once v0.1.0
# is tagged, switch `source` to the tarball and fill in the real sha256sums:
#   source=("$pkgname-$pkgver.tar.gz::https://github.com/jesusalcaladev/dockh/archive/refs/tags/v$pkgver.tar.gz")

pkgname=dockh
pkgver=0.1.0
pkgrel=1
pkgdesc="A GTK4 layer-shell dock for Hyprland, written in Zig (rewrite of nwg-dock-hyprland)"
arch=('x86_64' 'aarch64')
url="https://github.com/jesusalcaladev/dockh"
license=('MIT')
depends=('gtk4' 'gtk4-layer-shell')
makedepends=('zig' 'pkg-config')
source=("$pkgname::git+https://github.com/jesusalcaladev/dockh.git")
sha256sums=('SKIP') # SKIP is valid for git sources; swap for a real checksum with tarball sources

pkgver() {
    cd "$srcdir/$pkgname"
    # Bump with `git tag vX.Y.Z` — pkgver follows the newest tag.
    git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0"
}

build() {
    cd "$srcdir/$pkgname"
    zig build -Doptimize=ReleaseFast
}

package() {
    cd "$srcdir/$pkgname"

    install -Dm755 zig-out/bin/dockh "$pkgdir/usr/bin/dockh"
    install -Dm644 config/style.css   "$pkgdir/usr/share/dockh/style.css"
    install -Dm644 config/config.toml "$pkgdir/usr/share/dockh/config.toml"
    install -Dm644 LICENSE            "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
