PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share/dockh

.PHONY: all build install uninstall run clean

all: build

build:
	zig build -Doptimize=ReleaseFast

install: build
	install -Dm755 zig-out/bin/dockh $(DESTDIR)$(BINDIR)/dockh
	# Keep config/ in sync with src/defaults/ (the embedded first-run copies).
	install -Dm644 config/style.css $(DESTDIR)$(DATADIR)/style.css
	install -Dm644 config/config.toml $(DESTDIR)$(DATADIR)/config.toml

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/dockh
	rm -rf $(DESTDIR)$(DATADIR)

run: build
	./zig-out/bin/dockh

clean:
	rm -rf zig-out .zig-cache
