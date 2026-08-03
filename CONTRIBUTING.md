# Contributing to dockh

First off — thank you for taking the time to contribute! 🎉

dockh is a GTK4 layer-shell dock for Hyprland, written in Zig. This guide
covers everything you need to get started: building in debug mode, running
tests, understanding the code layout, and the conventions we follow.

---

## 📋 Table of contents

- [Development environment](#-development-environment)
- [Building in Debug mode](#-building-in-debug-mode)
- [Release builds](#-release-builds)
- [Running the dock during development](#-running-the-dock-during-development)
- [Running tests](#-running-tests)
- [Project structure](#-project-structure)
- [Code conventions](#-code-conventions)
- [Testing your changes manually](#-testing-your-changes-manually)
- [Commit messages & branching](#-commit-messages--branching)
- [Submitting a pull request](#-submitting-a-pull-request)
- [Troubleshooting](#-troubleshooting)

---

## 🧰 Development environment

### Required toolchain

| Tool | Version | Notes |
|------|---------|-------|
| Zig | **0.16.0+** | `minimum_zig_version` in `build.zig.zon` |
| GTK4 | **4.16+** | 4.16 required for the in-dock blur (`GskBlurNode`); developed against 4.22 |
| gtk4-layer-shell | latest | provides the `gtk4-layer-shell-0` pkg-config module |
| pkg-config | any | used by `build.zig` to discover link flags |
| Hyprland | any recent | for live testing (IPC sockets) |

### Arch / CachyOS

```sh
sudo pacman -S gtk4 gtk4-layer-shell zig
```

Other distros: install the equivalents of `gtk4`, `gtk4-layer-shell` and
`zig` (0.16+). No header files are needed — the C bindings in `src/c.zig`
are hand-written `extern` declarations, so the build only needs the shared
libraries at link time.

### Verify your environment

```sh
./install.sh --check
# or manually:
zig version        # 0.16.0+
pkg-config --modversion gtk4
pkg-config --modversion gtk4-layer-shell-0
```

---

## 🔨 Building in Debug mode

Debug builds give you full stack traces, assertions, and un-stripped
symbols — this is what you want while developing:

```sh
zig build -Doptimize=Debug
```

This produces `./zig-out/bin/dockh`. The Debug binary is deliberately
**not** stripped (see the `strip = true` guard in `build.zig`), so you can
debug with `gdb`, `rr`, or `zig build`'s own stack traces.

> 💡 `zig build` with no flags defaults to `Debug`. Run `zig build -h` to
> see all available optimization levels.

Other useful build invocations:

```sh
zig build -Doptimize=ReleaseSafe   # fast, with safety checks still on
zig build -Doptimize=ReleaseFast   # release build (production speed)
zig build version                  # print the dockh version
```

### Using the Makefile

```sh
make build       # zig build -Doptimize=ReleaseFast
make run         # build + run ./zig-out/bin/dockh
make clean       # remove zig-out/ and .zig-cache/
```

---

## 🚀 Release builds

For install-size and RAM-conscious release binaries:

```sh
zig build -Doptimize=ReleaseFast
```

Release builds are stripped automatically (`exe.root_module.strip = true`
when `optimize != .Debug`), which keeps the resident memory footprint low.

### Installing from source

```sh
./install.sh --user     # installs to ~/.local (no root needed)
sudo ./install.sh       # system install to /usr/local
./install.sh --prefix=/opt
```

First run creates `~/.config/dockh/{config.toml,style.css}` for
customization.

---

## 🖥️ Running the dock during development

You can run the binary directly from the build tree — no install needed:

```sh
zig build -Doptimize=Debug
./zig-out/bin/dockh -debug        # -debug = verbose logging to stderr
```

Run with `-debug` to get detailed logs (magnify engine, IPC events, blur
backend selection). Logs go to stderr, so redirect them while iterating:

```sh
./zig-out/bin/dockh -debug 2> /tmp/dockh.log
tail -f /tmp/dockh.log
```

To restart cleanly between iterations:

```sh
pkill -x dockh; ./zig-out/bin/dockh -debug 2> /tmp/dockh.log &
```

**Hot-reload for styling**: CSS is live — edit
`~/.config/dockh/style.css` and it applies immediately, no restart. Config
changes in `~/.config/dockh/config.toml` need a restart (they're parsed at
startup).

---

## 🧪 Running tests

dockh is a GTK4 app, so most behavior is integration-level and hard to unit
test, but the codebase is structured so pure logic lives in testable
places.

### Test blocks

Zig test blocks (`test "name" { ... }`) live next to the code they cover.
There are currently none in the tree — that's an open area to contribute!
To add one, e.g. in `src/core/config.zig`:

```zig
test "config clamps icon_size" {
    // ...
}
```

### Running the suite

```sh
zig build test     # runs every test block in the project
```

Or run a single file's tests:

```sh
zig test src/core/config.zig -- -I.  # adjust import paths as needed
```

> If the suite is empty, `zig build test` reports success with no tests —
> that's expected today.

When adding features, prefer extracting pure logic (parsing, math, state
transitions) into functions you can test without a display server.

---

## 🗂️ Project structure

```
.
├── build.zig            # build system: pkg-config discovery, strip logic
├── build.zig.zon        # package manifest (name, version, min Zig, paths)
├── install.sh           # from-source installer (--user/--prefix/--uninstall)
├── Makefile             # convenience wrappers (build/install/run/clean)
├── PKGBUILD / .SRCINFO  # AUR packaging metadata
├── config/              # shipped defaults — KEEP IN SYNC with src/defaults/
│   ├── config.toml
│   └── style.css
└── src/
    ├── main.zig         # entry point: GTK app, window, motion controllers,
    │                    #   hotspot/autohide, IPC setup, signal wiring
    ├── c.zig            # hand-written extern C bindings for GTK4/GLib/GSK
    ├── core/
    │   ├── config.zig   # TOML parsing, defaults, clamping, config keys
    │   ├── state.zig    # global app state (clients, config, scratch arena)
    │   ├── log.zig      # leveled logging (used by -debug)
    │   └── fs.zig       # paths, first-run file copy, cache handling
    ├── hypr/
    │   ├── ipc.zig      # Hyprland UNIX-socket IPC (events + commands)
    │   └── desktop.zig  # .desktop entry parsing (icons, exec, names)
    ├── ui/
    │   ├── widgets.zig  # dock buttons, magnify engine, workspace dots,
    │   │                #   spring physics, popovers
    │   ├── theme.zig    # runtime CSS generation (magnify ladder, ...)
    │   ├── blur.zig     # in-dock blur (GskBlurNode) w/ backend fallback
    │   └── status.zig   # notification/progress badge state
    └── defaults/        # embedded first-run defaults — KEEP IN SYNC
        ├── config.toml  #   with config/
        └── style.css
```

### Data flow at a glance

1. `main.zig` connects to the Hyprland event socket (`socket2.sock`).
2. `hypr/ipc.zig` parses events (active window, workspace, open/close) and
   updates `core/state.zig`.
3. `ui/widgets.zig` rebuilds the dock box and animates the magnify ladder
   with classes generated by `ui/theme.zig`.
4. `ui/blur.zig` wraps the dock surface in a `GskBlurNode` when the
   renderer supports it, falling back gracefully otherwise.

---

## ✍️ Code conventions

- **Formatting**: always run `zig fmt` (or `zig fmt --check`) on changed
  files before committing.
  ```sh
  zig fmt src/
  ```
- **Zig idioms**: use `std.ArrayList`, `std.mem`, `std.fs` from the
  standard library; no third-party Zig deps. Allocators are explicit —
  prefer `state.scratch` (an arena reset on each refresh) for transient
  data.
- **C bindings**: never add `@cImport` — extend `src/c.zig` with the exact
  `extern fn` you need, matching the GTK4 header signature.
- **CSS classes**: new visual states should be class-driven
  (`.dockh-*`) so users can style them from `style.css` without code
  changes. Document new classes in `README.md`.
- **Keep defaults in sync**: `config/config.toml` + `config/style.css`
  must stay identical to `src/defaults/`. A PR that edits one should edit
  all three copies (including updating the user's live copy if you're
  testing locally).
- **Config keys**: every new option needs (1) a field + clamp in
  `src/core/config.zig`, (2) the key in all three TOML files, (3) a README
  mention. Defaults must be conservative.
- **Error handling**: be graceful. The dock must never hard-crash if
  Hyprland IPC is unavailable or a CSS class is missing — fall back, log
  via `log.zig`, and keep running.

---

## 🧑‍🔬 Testing your changes manually

dockh targets Hyprland, so a live session is the real test bed:

1. **Build debug** and run with `-debug`:
   ```sh
   zig build -Doptimize=Debug && ./zig-out/bin/dockh -debug
   ```
2. **Exercise the feature**, e.g. for magnify:
   - hover a pinned icon → icon + workspace dots scale with distance
   - stop the cursor → spring settle bounce fires exactly once
   - leave and re-enter → state fully resets (no stale transforms)
3. **Check the log** for errors: `grep -iE 'error|critical' /tmp/dockh.log`
4. **Screenshot-based verification** (optional, used in CI-style checks):
   ```sh
   grim -g "$(hyprctl layers | grep 'namespace: dockh' | ...)" /tmp/dock.png
   ```

Regression checklist: empty workspace, single app across 2+ workspaces,
pinned-but-not-running app, launcher entry, left/right dock orientation.

---

## 🧑‍💻 Commit messages & branching

- **Style**: short, imperative, lowercase — e.g. `add workspace dot
  indicator` or `fix magnify reset on leave`. Scope-prefix when useful
  (`ui:`, `hypr:`, `build:`).
- **One logical change per commit.** Format before you commit:
  ```sh
  zig fmt src/ && git add -p
  ```
- **Branching**: for anything non-trivial, work on a feature branch:
  ```sh
  git checkout -b feat/workspace-dots
  ```
- Do **not** commit build artifacts (`zig-out/`, `.zig-cache/`,
  `.freebuff/` are gitignored).

---

## 🚦 Submitting a pull request

1. Fork the repo and create a feature branch (see above).
2. Make your change; add tests where the logic is testable.
3. Run `zig fmt --check` and `zig build -Doptimize=Debug` — both must pass.
4. Also confirm `zig build -Doptimize=ReleaseFast` compiles clean.
5. Update `README.md` (features table, CSS class list, config keys) and
   keep `config/` in sync with `src/defaults/`.
6. Open the PR with a clear title and a description of *what* and *why*,
   plus any screenshots for visual changes.

---

## 🩹 Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: gtk4 or gtk4-layer-shell not found` | Install the deps: `sudo pacman -S gtk4 gtk4-layer-shell` |
| Link errors with missing GLib/GObject symbols | The build links direct **and** transitive deps from pkg-config; ensure you're on the same Zig as `build.zig.zon` (0.16+) |
| Dock doesn't show / no blur | Check `layerrule = blur, dockh` in `hyprland.conf`; confirm the layer namespace with `hyprctl layers` |
| No IPC events | Verify `$HYPRLAND_INSTANCE_SIGNATURE` is set and the socket exists at `/tmp/hypr/$HYPRLAND_INSTANCE_SIGNATURE/` |
| Tests do nothing | There are no test blocks yet — perfect first contribution 🙂 |

---

Happy hacking! If you're unsure where to start, look for the simplest
improvement in the roadmap in `README.md` or add your first `test "..."`
block to `src/core/config.zig`. 💜
