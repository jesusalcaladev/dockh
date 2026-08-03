<div align="center">

# 🧊 dockh

**A dock for Hyprland written in Zig — GTK4 + GSK, liquid glass, zero polling.**

A modern rewrite of [nwg-dock-hyprland](https://github.com/nwg-piotr/nwg-dock-hyprland)
(Go/GTK3) with no Go dependencies, no garbage collector and no generated
bindings: the C ABI is hand-declared in `src/c.zig`.

</div>

---

## ✨ Features

| | |
|---|---|
| 🪟 **GTK4 + GSK** | Hardware rendering (Vulkan/OpenGL) and modern CSS with `transform: scale() / translateY() / rotate()` and `transition` with `cubic-bezier` curves — without disturbing the container's fixed layout. |
| 🧊 **Liquid glass** | Translucent CSS theme + real compositor blur (`layerrule = blur on, match:namespace dockh`). See [Theming](#theming). |
| 📌 **Pinned apps** | Keep your favorite apps in the dock and launch them with one click; pin/unpin from the context menu. Separated from running apps by a divider, with *ghost* (not running) and *running* states visible in CSS. |
| 🖱️ **Autohide with hotspot** | Per-monitor invisible windows with configurable delay (detector + strip), no polling. |
| 🧠 **Workspace intellihide** | With `hide_on_activity = true` the dock hides while the active workspace has windows and reappears when it empties. |
| ⚡ **Hyprland IPC over UNIX socket** | Integrated into the GLib main loop (`g_unix_fd_add`): reacts to `activewindowv2`, `openwindow`, `closewindow`, `workspacev2`, `fullscreen`, `movewindow`… **zero polling**. |
| 🎨 **CSS engine with dynamic states** | Per-state classes (`active`, `running`, `idle`) and per-app classes (`.dockh-app-alacritty`, …) to style every app without touching the TOML. |
| 🔍 **Proximity magnify (macOS)** | As you move the cursor, icons scale by distance: the closest hits the max, neighbors fall off smoothly, and distant ones stay at 1.0 — like the macOS dock. |
| 📍 **Per-workspace dots (macOS)** | Under every running app, one small dot per workspace with a window — the current workspace glows, and the dots spread apart as the icon magnifies. |
| ▶️ **Media progress (macOS)** | Thin progress bar under the icon while the app plays (playerctl/MPRIS), updated every second without rebuilding the dock. |
| 🔔 **Notification counter** | Badge with the number of notifications per app (mako/makoctl), on the corner of the icon. |
| ♻️ **Theme hot reload** | Edit `style.css` and changes apply instantly (GFileMonitor + debounce) — no dock restart needed. CSS errors are shown in the log. |
| 🖼️ **Icons and .desktop** | Resolves icon/name/exec from `.desktop` entries (XDG + Flatpak) and launches apps with `posix_spawnp` (no `fork()`). |
| 📝 **Flexible configuration** | `config.toml` with CLI overrides (CLI wins). |
| 🔔 **Signals** | `SIGRTMIN+1/+2/+3` for toggle/show/hide and single-instance with `flock`. |

---

## 📦 Requirements (Arch / CachyOS / Omarchy)

```bash
sudo pacman -S gtk4 gtk4-layer-shell zig
```

> `gtk4-layer-shell` is in `extra`. On other distros install the equivalents
> of `gtk4`, `gtk4-layer-shell` and `zig` (0.16+).

---

## 🚀 Installing

### Option A — `install.sh` script (recommended, any distro)

```bash
./install.sh                 # build + install to /usr/local (needs sudo/root)
sudo ./install.sh            # explicit
./install.sh --user          # installs to ~/.local/bin — no root ✨
./install.sh --user --prefix=/opt   # custom rootless prefix
./install.sh --check         # only verify dependencies
./install.sh --uninstall     # uninstall (system or --user, depending on mode)
./install.sh -h              # help
```

The script checks `gtk4`, `gtk4-layer-shell` and `zig`, compiles in
`ReleaseFast` and installs:

```
<prefix>/bin/dockh
<prefix>/share/dockh/style.css
<prefix>/share/dockh/config.toml
```

> 💡 For personal rootless use, `./install.sh --user` is enough
> (installs to `~/.local/bin`, which is usually on `PATH`).

### Option B — Make (classic alternative)

```bash
make build                 # zig build -Doptimize=ReleaseFast
sudo make install          # bin + theme in /usr/local
sudo make uninstall
```

### Option C — AUR (Arch / CachyOS / Omarchy — pacman, yay, paru)

The repo includes a `PKGBUILD` (git source; `pkgver()` follows the tags). Once
published to the AUR:

```bash
yay -S dockh          # or: paru -S dockh / pacman -S dockh
```

To try it locally before publishing:

```bash
makepkg -si
```

### First run

The first run creates `~/.config/dockh/` with default `config.toml` and
`style.css`, ready to customize.

---

## ▶️ Usage

```bash
dockh                       # bottom bar, centered, bottom layer (behind windows)
dockh -p top -f             # top bar, full width
dockh -d -i 32              # autohide with hotspot, 32px icons
dockh -o DP-1 -p left       # left dock on the DP-1 monitor
dockh -r                    # resident without hotspot (toggle via signal)
dockh -ha -d                # intellihide + hotspot (very comfortable)
```

### Flags

```
-a <start|center|end>    alignment on full width/height (center)
-d                       autohide: show on hotspot, hide on leave
-ha                      intellihide: hide if the active workspace has windows
-r                       resident mode (no hotspot)
-p <bottom|top|left|right>  position (bottom)
-f                       take the full width/height
-l <overlay|top|bottom>  layer (bottom — behind windows)
-x                       exclusive zone (reserves space, forces top)
-i <px>                  icon size (32)
-o <output>              target monitor, e.g. DP-1
-c <cmd>                 launcher button command (nwg-drawer)
-ico <icon>              launcher icon (name or path)
-nolauncher              hide the launcher button
-lp <start|end>          launcher position (end)
-s <file>                CSS name in the config dir (style.css)
-hd <ms>                 hotspot delay (20)
-hl <overlay|top>        hotspot layer
-mb/-ml/-mr/-mt <px>     margins
-w <n>                   number of workspaces (10)
-g <classes>             classes to ignore (space separated)
-iw <list>               ignore apps on these workspaces, e.g. special,10
-cfg <path>              configuration file
-m                       allow multiple instances
-debug                   verbose logging
-v / -h                  version / help
```

---

## 🖥️ Autostart — launch with your session

### Hyprland (recommended)

Add an `exec-once` line to `~/.config/hypr/autostart.conf`:

```ini
exec-once = uwsm-app -- dockh        # Omarchy (UWU sm) — uwsm manages the app
exec-once = dockh                    # vanilla Hyprland
```

> If `dockh` isn't on your `PATH` (e.g. you installed with `--prefix=/opt`),
> use the full path: `exec-once = /opt/bin/dockh` or
> `exec-once = uwsm-app -- /opt/bin/dockh`.

**On Omarchy**: `~/.config/hypr/autostart.conf` is already sourced from
`hyprland.conf` (line `source = ~/.config/hypr/autostart.conf`), so you only
need to add the line. Hyprland reloads the config automatically on save; if
not, `hyprctl reload`.

**On vanilla Hyprland**: the same line goes in `hyprland.conf`:

```ini
exec-once = dockh
```

### Systemd (generic alternative)

If you prefer to manage it as a user service:

```ini
# ~/.config/systemd/user/dockh.service
[Unit]
Description=dockh — GTK4 layer-shell dock for Hyprland
After=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.local/bin/dockh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=graphical-session.target
```

```bash
systemctl --user enable --now dockh.service
```

> ⚠️ Systemd mode requires `HYPRLAND_INSTANCE_SIGNATURE` to be in the service
> environment (Hyprland exports it to session apps, not to services). With
> Hyprland's `exec-once` you don't need to worry about this.

### Verify it's running

```bash
pgrep -x dockh && echo "dockh is running"
hyprctl layers          # you should see dockh and dockh-hotspot (if using autohide)
```

---

## ⚙️ Configuration

`~/.config/dockh/config.toml` — sections `[dock]`, `[margins]`,
`[launcher]`, `[hotspot]`, `[animation]`, `[magnify]`, `[progress]`,
`[badge]`, `[glow]`, `[apps]`:

```toml
[dock]
position = "bottom"        # bottom | top | left | right
alignment = "center"       # start | center | end
full = false               # take the whole monitor edge
layer = "bottom"          # overlay | top | bottom (bottom = behind windows)
exclusive = false          # reserve space (forces layer = top)
autohide = false           # hide with hotspot
hide_on_activity = false   # intellihide: hide if the active workspace has windows
resident = false           # always visible, toggle via signal
icon_size = 32           # 32px macOS-style icons (magnify on hover)
num_workspaces = 10
target_output = ""         # "DP-1" — empty = focused monitor

[margins]
top = 0
bottom = 0
left = 0
right = 0

[launcher]
show = false
command = "nwg-drawer"     # or nwggrid -p, or any command
icon = ""                  # icon name or absolute path
position = "end"           # start | end

[hotspot]
delay_ms = 20              # "flick" window at the edge; 0 = always show
layer = "overlay"          # overlay | top
size = 0                   # detector depth in px; 0 = auto (1/3 of the edge)

[animation]
scale = 1.5               # max magnify / hover zoom (dramatic macOS)
duration_ms = 200          # transition duration (simple hover)
curve = "cubic-bezier(0.34, 1.56, 0.64, 1)"   # playful overshoot

[magnify]
enabled = true             # macOS-style proximity magnify
spread = 3                 # effect radius in icon slots from the cursor
steps = 256                # bucket ladder size: 256 = sub-pixel steps (~0.06 px)
duration_ms = 40           # exponential ease constant in ms (higher = smoother follow)
spring = true              # macOS settle bounce when the pointer stops over the dock
spring_strength = 0.06     # bounce amplitude, fraction of each icon's scale (0-0.25)

[progress]
enabled = true             # media progress bar under the icon (playerctl)

[badge]
enabled = true             # per-app notification counter (makoctl)
threshold = 5             # badge turns red (.dockh-badge.high) at >= N; 0 = never

[glow]
enabled = true             # in-dock blur halo behind the active app's icon
radius = 8                # gaussian radius in px (0 disables)

[apps]
css_file = "style.css"
pinned = ["firefox", "kitty"]   # also from the dock's right-click menu
ignore_classes = []
ignore_workspaces = []          # e.g. ["special", "10"]
```

> 📌 **Persistent pinned**: what you pin from the context menu is saved in
> `~/.cache/dockh/pinned` (one class per line). The TOML `pinned = [...]` is
> only used on first run.
>
> 🔄 `style.css` hot-reloads (see [Hot reload](#hot-reload)), but `config.toml`
> values — including `[magnify]` and `[animation]` — apply on the **next
> start** (the dock parses the config at launch). After editing them, restart
> dockh: `pkill -x dockh && dockh`.

---

## 🎨 Theming (liquid glass)

The glass look comes from CSS (`~/.config/dockh/style.css`) + compositor
blur. Add to your `hyprland.conf` (**Hyprland 0.55+ syntax**, with
`match:namespace` and the underscore in `ignore_alpha`):

```ini
layerrule = blur on, match:namespace dockh
layerrule = ignore_alpha 0.5, match:namespace dockh
layerrule = blur on, match:namespace dockh-hotspot
```

> 🔍 **Verified against Hyprland 0.55.4**: the effect is called `ignore_alpha`
> (not `ignorealpha`) — the exact name lives in the `eLayerRuleEffect` enum in
> `src/desktop/rule/layerRule/`. `blur` takes `on|off`, `ignore_alpha` a float
> 0–1. On older versions (< 0.45) the form was
> `layerrule = blur, dockh` / `layerrule = ignorealpha 0.5, dockh`.
>
> On Omarchy you can put them at the end of `~/.config/hypr/hyprland.conf`
> (the "Add any other personal Hyprland configuration below" zone).

### In-dock blur (active app halo) ✨

On top of the compositor blur (layerrule), dockh **blurs the active app's own
icon** and draws it behind as a soft halo — without depending on Hyprland. The
backend is chosen automatically at runtime:

| Backend | When | How |
|---|---|---|
| **`GskGLShaderNode`** | GTK < 4.16 (classic GL renderer) | Custom 5×5 gaussian GLSL shader (`mainImage` + `GskTexture()`) |
| **`GskBlurNode`** | GTK ≥ 4.16 — your case (4.22) | Native GSK node, GPU-accelerated in `ngl` |
| **none** | No realizable renderer | The dock draws the normal icon, no crash or warnings |

> 🔍 **The truth about 4.16+**: `GskGLShaderNode` is deprecated since GTK 4.16
> because the `ngl` renderer (the default) silently ignores it — verified in
> the GTK 4.22.4 source. That's why dockh uses its own shader on GTK < 4.16 and
> automatically falls back to `GskBlurNode` (supported by every renderer) on
> 4.16+. The startup log with `-debug` tells you the backend:
> `blur backend: blur_node`.

Control the effect from `config.toml`:

```toml
[glow]
enabled = true    # turn it off if you prefer just the compositor glass
radius = 8       # higher radius = bigger and softer halo
```

And style it with the `.dockh-glow` class in your `style.css` (opacity,
extra blur, etc.):

```css
.dockh-glow {
    opacity: 0.85;
}
```

### Media progress (macOS style) ▶️

While an app plays audio/video via **MPRIS** (Spotify, Firefox, mpv, …),
dockh shows a **thin progress bar** pinned to the bottom edge of the icon —
like the macOS dock. The source is `playerctl`, queried every second with
`GSubprocess` (posix_spawn, without blocking the main loop):

```toml
[progress]
enabled = true
```

The bar is associated with the app by `mpris:desktopEntry` (e.g. `firefox`);
if it doesn't match any app in the dock, it shows on the focused app. The bar
**only appears with real progress** (≥ 0.5%) and hugs the bottom edge of the
icon — the trough is invisible, so an idle or just-started track never shows
a white line "doing nothing". Style the accent fill with `.dockh-progress`:

```css
.dockh-progress trough progress {
    background-color: @accent;
    border-radius: 3px;
    min-height: 3px;
}
```

### Notification counter 🔔

With **mako** (or another daemon compatible with `makoctl list`), dockh shows
a badge with the number of notifications on the corner of each app's icon,
updated every 2 s. The badge is **neutral** by default; once an app reaches
`badge.threshold` notifications (default **5**) the dock adds the `.high`
class and the badge turns **red**:

```toml
[badge]
enabled = true
threshold = 5    # >= 5 notifications -> .dockh-badge.high (red); 0 = never
```

```css
/* base: neutral pill */
.dockh-badge {
    background-color: rgba(232, 234, 240, 0.85);
    color: #10131c;
    border-radius: 999px;
    padding: 1px 5px;
}

/* high priority: red pill once the threshold is reached */
.dockh-badge.high {
    background-color: #e5484d;
    color: #ffffff;
}
```

> 🎨 **Per-app status classes**: the progress bar and badge also carry a
> per-app class derived from the window class — `.dockh-progress-<app>` and
> `.dockh-badge-<app>` (e.g. `.dockh-progress-firefox`, `.dockh-badge-firefox`)
> — so you can restyle a single app's bar or badge without touching the TOML:
>
> ```css
> .dockh-badge-firefox { background-color: #ff9500; color: #10131c; }
> .dockh-progress-firefox trough progress { background-color: #ff9500; }
> ```

> 💡 Badges and the progress bar live inside each button (GtkOverlay) and
> update **without rebuilding the dock** — zero flicker.

### Hot reload ♻️

`style.css` **hot-reloads**: save from your editor and the dock applies it
instantly, no restart. Syntax errors are logged as `CSS parse: …` and GTK
keeps showing the last valid theme. Metadata-only events (chmod/touch) are
ignored.

### Available CSS classes

- `.dockh-item` with `.active` (focused app), `.running` (has windows),
  `.idle` (pinned, not running) states and per-type `.dockh-task`,
  `.dockh-pinned`, `.dockh-launcher`.
- `.dockh-app-<class>` — one class per app, e.g. `.dockh-app-alacritty`:

  ```css
  .dockh-app-firefox .dockh-btn {
      background-color: rgba(255, 138, 101, 0.18);
  }
  ```

- `.dockh-btn`, `.dockh-indicator` (the workspace-dot row; `.empty` is
  added when the app has no windows — ghost pins / launcher), `.dockh-wsdot`
  (one dot per workspace — 5px, centered under the icon, with `.active` for
  the current workspace and `.inactive` otherwise), `.dockh-glow` (blur halo
  of the active icon),
  `.dockh-progress` (media progress bar), `.dockh-badge` (notification
  counter), `.dockh-separator`, `.dockh-menu*`, and the ids
  `#dockh-window`, `#dockh-box`, `#dockh-hotspot-window`.

  > 🔍 **CSS breaking change (0.2.0)**: the old single-dot indicator classes
  > `.dockh-indicator.single/.multiple` and the app-level `.dockh-indicator.active`
  > capsule are gone — the indicator is now a per-workspace dot row. Style the
  > current-workspace dot with `.dockh-wsdot.active` instead.

### Proximity magnify (macOS style) 🔍

With `[magnify] enabled = true`, the dock scales icons **by distance to the
cursor** with a **gaussian** curve identical to the macOS dock: the icon under
the mouse reaches `animation.scale` (1.5×), immediate neighbors fall off fast
(σ ≈ 0.4·spread) and distant ones stay at 1.0.

The scale is driven by a ladder of `.dockh-mag-N` CSS buckets (N = 0…steps-1,
generated at startup and on config reload), but the fluidity comes from how
the buckets are *driven*: a `GtkEventControllerMotion` only records the
pointer position, and a `GtkTickCallback` synced to the compositor's frame
clock **eases each icon's scale in code** — exponential smoothing with the
real frame delta (`gdk_frame_clock_get_frame_time`) — then applies the
rounded bucket instantly.

> 🔍 **Why no CSS `transition: transform`?** A CSS transition restarts on
> *every* bucket class swap, and while the cursor moves the bucket changes
> every frame — GTK renders that constant restart as micro-cuts (the
> "choppy" animation). Easing in code avoids transitions entirely: each
> frame moves the continuous scale toward its target, and the rounded bucket
> lands instantly. With `steps = 256` each step is ~0.06 px (sub-pixel), so
> instant swaps are invisible and the motion is perfectly continuous — this
> is how the real macOS dock works.

> 🔍 **Why not a continuous transform?** GTK4 has no `gtk_widget_set_transform`,
> and `gtk_widget_allocate`'s transform is only honored on top-level widgets —
> children of a `GtkBox` wipe it on relayout (verified empirically). CSS
> buckets render reliably, so dockh combines them with code-driven easing.

The scale is anchored to the dock's screen edge via `transform-origin`, so
icons **grow outward from their base** (like macOS) instead of from their
center. When the pointer leaves, the same easing shrinks the icons back to
1.0 smoothly (no snap).

```toml
[magnify]
enabled = true             # false returns to simple hover
spread = 3                 # higher = more neighbor icons affected
steps = 256                # bucket ladder size: 256 = sub-pixel steps, continuous look
duration_ms = 40           # exponential ease constant in ms (higher = smoother)
spring = true              # macOS settle bounce: tiny damped overshoot when the pointer stops
spring_strength = 0.06     # bounce amplitude, fraction of each icon's scale (0-0.25)
```

> 🔍 **Why `steps = 256`?** The classic mistake is a coarse ladder (e.g. 32
> buckets = ~0.5 px jumps on 32 px icons) plus an overshooting CSS curve —
> every bucket change bounces the icon past its target and back. 256 buckets
> make each step ~0.06 px (invisible), and with no CSS transition there is
> nothing to overshoot: the easing happens in code.

### The macOS settle spring 🍎

Just like the real dock, when you *stop* moving the pointer the icons don't
freeze mid-motion — they complete their magnification with one tiny **damped
bounce** (a controlled overshoot) and settle. It's a second-order spring
integrated in the same per-frame tick, in code: while the pointer is idle
(> 120 ms without motion) the scale *target* of every icon gets a decaying
sine perturbation `e^(-ζωt)·sin(ω_d·t)` — `ζ = 0.6`, `ω = 30 rad/s` —
proportional to that icon's own magnification, so the icon under the cursor
bounces most and distant icons stay put. `spring_strength` is the peak
overshoot as a fraction of the icon's scale (0.06 = ~6% of the 1.5× max, a
couple of pixels on a 32 px icon); `spring = false` removes the bounce
entirely and the icons simply stop.

> 🔍 The *rendered* overshoot is slightly smaller than `spring_strength`:
> the per-frame exponential ease (τ = `magnify.duration_ms`) attenuates and
> phase-shifts the target oscillation, so the perceived bounce is a little
> softer than the raw knob. Raise `spring_strength` (e.g. 0.08–0.10) if you
> want the settle to read more clearly.

The `duration_ms` is the exponential ease constant: 25–50 ms feels like macOS
(fast, responsive), higher values float. The `[animation]` values are injected
at startup as `transition: transform` + `transform: scale()` for the
non-magnify hover mode, so buttons animate on top of the box without shifting
the layout.

---

## 🔔 Signals

`SIGRTMIN+1` toggles visibility, `SIGRTMIN+2` shows, `SIGRTMIN+3` hides
(only in `-r`/`-d` modes):

```ini
bind = SUPER, D, exec, pkill -RTMIN+1 dockh
```

---

## 🛠️ Troubleshooting

### dockh doesn't start at login

1. **Test manually first**: `dockh` (or with `-debug`). If it fails, you'll
   see the error in the terminal.
2. **`HYPRLAND_INSTANCE_SIGNATURE not set`**: dockh wasn't launched from a
   Hyprland session (e.g. you set it up as a systemd service without the
   environment). Use Hyprland's `exec-once` instead, or export the variable.
3. **Not on PATH**: with `--user` use `~/.local/bin/dockh`; with
   `--prefix=/opt` use the full path in `exec-once`.
4. **Check the autostart**: `hyprctl configerrors` (should be empty) and
   `grep dockh ~/.config/hypr/autostart.conf`.

### The dock is not visible

- **Autohide mode**: the dock starts hidden by design. Move the mouse to the
  screen edge (hotspot) to reveal it.
- **Intellihide**: with `hide_on_activity = true` it hides when the workspace
  has windows. Switch to an empty workspace.
- **Layer**: `layer = "bottom"` (default) means the dock stays *behind*
  windows: if an app covers it, that's expected behavior. If you want the dock
  to float above apps, use `overlay` or `top`.
- **Layer level**: `hyprctl layers` shows the level (1 = bottom, 2 = top,
  3 = overlay). The dock should be at `Layer level 1 (bottom)`.

### No blur / glass not visible

- Add the blur and `ignore_alpha` layerrules (see [Theming](#theming)).
  **On Hyprland 0.55+** use the `match:namespace` syntax with the underscore:

  ```ini
  layerrule = blur on, match:namespace dockh
  layerrule = ignore_alpha 0.5, match:namespace dockh
  ```

- If `hyprctl configerrors` reports `invalid field type`, the effect name is
  wrong: on 0.55+ it's `ignore_alpha`, not `ignorealpha`.
- On Hyprland, blur needs to be enabled globally
  (`decoration:blur`), not just the layerrule.
- The 50% `ignore_alpha` keeps GTK from painting an opaque background over the
  blur.

### Icons come out generic (broken image)

- dockh resolves the icon from `.desktop` entries (XDG + Flatpak) and by name
  in the system icon theme. If a class has no `.desktop` of its own, the class
  name is used as a fallback.
- Try a complete icon theme (e.g. `papirus-icon-theme`).
- You can force an app's icon in CSS or by pinning the app from the
  right-click menu.

### Hot reload doesn't apply changes

- The watcher follows the CSS path from your config (`css_file` in `[apps]`).
- Check the log: `CSS parse: …` means a syntax error — GTK keeps the last
  valid theme until the CSS is correct.
- If the file is on a FS without inotify (network/NFS), the monitor may not
  fire; run with `-debug` to see `watching … for changes`.

### dockh keeps quitting

- Check the logs with `dockh -debug` and look for `CRITICAL` or `error`.
- The Hyprland events socket: if Hyprland restarts, dockh reconnects
  automatically within 3 s. If not, check `HYPRLAND_INSTANCE_SIGNATURE`.

### dockh uses too much RAM

- Build in `ReleaseFast` (already the default of `install.sh` and `make
  build`): a `Debug` build (plain `zig build` without flags) retains much
  more. Verify with `file $(which dockh)` → it should say `stripped`.
- dockh calls `malloc_trim(0)` periodically (5 s, then every 30 s) to return
  to the OS the pages GTK4 frees when rebuilding the dock — without it the
  RSS stays at the peak (~200 MB instead of ~75 MB).
- The `bottom` layer (default) doesn't reserve an exclusive zone, so apps
  cover it and you don't waste screen space; the base GTK4+GSK footprint is
  inherent (~70-80 MB in `ReleaseFast`).

### I have multiple monitors and the dock is on the wrong one

```bash
hyprctl monitors                 # list of monitors and names
dockh -o eDP-1                   # force the dock to that monitor
```

### Uninstall

```bash
./install.sh --uninstall        # system (sudo)
./install.sh --user --uninstall # just your user
```

---

## 🏗️ Architecture

```
src/
├── main.zig            # entry point, CLI, single-instance, event socket
├── c.zig               # hand-written C ABI declarations (GTK4, layer-shell, libc)
├── core/
│   ├── config.zig      # TOML-lite parser + defaults + overrides
│   ├── state.zig       # process-global state
│   ├── log.zig         # logging to stderr
│   └── fs.zig          # file I/O via libc
├── hypr/
│   ├── ipc.zig         # Hyprland UNIX sockets (hyprctl + events)
│   └── desktop.zig     # .desktop entries, icons, posix_spawnp
├── ui/
│   ├── widgets.zig     # buttons, indicators, GTK4 popovers, progress + badges
│   ├── blur.zig        # in-dock blur in the scene graph (GskBlurNode/GLShader)
│   ├── status.zig      # playerctl/makoctl polling (GSubprocess)
│   └── theme.zig       # GtkCssProvider + injected animations + hot reload
└── defaults/           # embedded config.toml and style.css (first run)
```

No `@cImport` and no generated bindings: the ~120 GTK4/GLib/libc functions
are hand-declared in `c.zig` (direct C ABI, no GC).

### Hyprland IPC

- `.socket.sock` (hyprctl): synchronous request/response — clients, monitors,
  activewindow and dispatchers (focus/close/float/fullscreen/movetoworkspace,
  with fallback to the modern syntax).
- `.socket2.sock` (events): `activewindowv2`, `openwindow`, `closewindow`,
  `workspacev2`, `fullscreen`, `movewindow` → dock refresh via the GLib main
  loop. Zero polling.

---

## 🗺️ Roadmap

- [x] GTK4 + gtk4-layer-shell + global CSS provider
- [x] Configurable transform/transition animations
- [x] Event-driven Hyprland event socket
- [x] Pinned apps + context menus (GTK4 popovers)
- [x] Single-instance with flock and signal toggle
- [x] Workspace intellihide (`hide_on_activity`)
- [x] Dynamic CSS classes per app and state
- [x] `style.css` hot reload (GFileMonitor + debounce)
- [x] Packaging: `install.sh`, `Makefile`, AUR `PKGBUILD`
- [x] In-dock blur with `GskGLShaderNode` + automatic `GskBlurNode` fallback
- [x] Media progress bar (playerctl) + notification counter (makoctl)
- [x] Per-workspace indicators (macOS style) — dots spread with the magnify
- [ ] Publish to the AUR

---

## 🤝 Contributing

Want to help? Check out [CONTRIBUTING.md](CONTRIBUTING.md) — it covers
building in **Debug** mode, running tests, the `src/` layout, code
conventions (`zig fmt`, keeping `config/` in sync with `src/defaults/`,
class-driven styling) and the PR workflow.

---

## 📄 License

MIT — see [LICENSE](LICENSE). dockh is a rewrite of
[nwg-dock-hyprland](https://github.com/nwg-piotr/nwg-dock-hyprland) (MIT, ©
Piotr Miller).
