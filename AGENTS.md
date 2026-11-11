# Working on everyscreen

A Home Manager module (`module.nix`) that takes one monitor layout,
`programs.everyscreen`, and writes it in the native format of Plasma, GNOME,
niri and Hyprland. `tests/vm` checks the result against the real compositors.

Everything below was checked during development. Each fact is tagged with how:
**[src]** read in the pinned source, **[vm]** observed in the VM test, or
**[src+vm]** both. A fact with no tag is a design decision. Re-verify a fact
when you bump a compositor; don't rely on memory, either yours or a model's.

Versions it was verified against: KWin 6.6.6, Mutter / gnome-shell 50.5, niri
26.04, Hyprland 0.55.4, Home Manager release-26.05 (`24f21905`), nixpkgs
nixos-26.05 (`7dcdd873`), and Linux 7.3.1 for the test.

## Why the project exists

- No shared format exists. The wlroots output-management protocol that kanshi
  and shikane drive is not implemented by KWin or Mutter, so shikane covers
  niri and Hyprland only. [src]
- So the module writes each compositor's own file instead:

| Session  | File                               | How it is picked up                           |
|----------|------------------------------------|-----------------------------------------------|
| Plasma   | `~/.config/kwinoutputconfig.json`  | KWin reads it directly                        |
| GNOME    | `~/.config/monitors.xml`           | Mutter reads it directly                      |
| niri     | `~/.config/niri/screen-layout.kdl` | user's `config.kdl`: `include optional=true`  |
| Hyprland | `~/.config/hypr/screen-layout.lua` | user's `hyprland.lua`: `pcall(require, …)`    |

## Compositor facts

### KWin (`kwinoutputconfig.json`)

- The file holds two lists: `outputs` (per-monitor settings) and `setups` (one
  arrangement per set of connected monitors). For a set that has no setup,
  KWin falls back to its own guess. [src+vm]
- Each output in a setup needs `"enabled": true`, or KWin drops the whole
  setup. [src]
- Outputs are matched by `edidIdentifier`, which is
  `"vendor product serial week year modelYear"`, when that is unique, so no
  `edidHash` is needed. [src+vm]
- `priority`: lower means more important, and 1 is the primary. [src+vm]
- **A settings change can't be saved through the store link.** KWin opens the
  file write-only through the symlink, which fails with "Couldn't open output
  config file" (`outputconfigurationstore.cpp:1511-1514`). The change lasts
  until the session ends, and the link stays in place. [src+vm]

### Mutter / GNOME (`monitors.xml`, version 2)

- A monitor matches only if all four of connector, vendor, product and serial
  are exactly equal. [src]
- Product and serial come from the EDID's product-name and serial strings. If
  the EDID has none, Mutter writes the numbers as `0x%04x` and `0x%08x` (for
  example, the TV's serial is `0x01010101`). [src+vm]
- **Connector names differ from the kernel's:** Mutter calls HDMI-A plain
  HDMI, so the kernel's `HDMI-A-1` is Mutter's `HDMI-1` (`meta-connector.c`).
  This applies in `monitors.xml` and also in the xdg-output names Wayland
  clients see. [src+vm]
- Mutter 50 always uses the logical layout mode, so the experimental
  `scale-monitor-framebuffer` feature makes no difference. [src]
- The scale has to be n/d with d ≤ 4, dividing the mode evenly. 3840×2160 at
  1.45 fails; 1.5 works. [src]
- Mutter rejects a whole configuration if two monitors overlap, if one
  doesn't touch any other, or if there isn't exactly one primary. The module
  asserts the primary rule. [src]
- The refresh rate is accepted within 0.001 Hz. [src]
- **A settings change replaces the link.** Mutter saves with
  `g_file_replace_contents(…, G_FILE_CREATE_REPLACE_DESTINATION)`
  (`meta-monitor-config-store.c:2527`, `:2582`). With that flag GLib writes a
  temporary file and renames it over the path (`glocalfileoutputstream.c:1033`),
  so the symlink becomes a plain file. `force = true` lets the next Home
  Manager switch put the link back. [src only: not exercised in the VM]
- `gnome-shell` is the binary that runs the session; there is no `mutter`
  binary on PATH. `gdctl` comes with the `mutter` package. [vm]

### niri (KDL)

- The layout is `output "<connector>" { mode …; scale …; transform …;
  position …; }`, and `focus-at-startup` marks the primary. [src+vm]
- `include optional=true "file.kdl"` lets niri start when the file is
  missing. [vm]
- The mode's refresh rate has to match exactly, which is why the module keeps
  it in mHz (`60000`, written as `60.000`). [src+vm]
- `niri msg -j outputs` reports the transform as `"90"`, not `"_90"`. [vm]
- niri refuses software EGL renderers such as llvmpipe
  (`src/backend/tty.rs:784-789`). The test patches that check out
  (`tests/vm/niri-sw.nix`). [src+vm]
- niri positions each monitor on its own; there are no per-set setups. Hotplug
  works on vkms: the TV comes back after a replug. [vm]

### Hyprland 0.55 (Lua)

- The config is Lua, and monitors are set with `hl.monitor({ output = …,
  mode = …, position = "XxY", scale = …, transform = <n> })`. The older
  `hyprland.conf` syntax is not written. [src+vm]
- `require("screen-layout")` resolves relative to the config directory. A
  catch-all `hl.monitor({ output = "", … })` before it covers anything the
  layout doesn't name. [vm]
- The scale has to give whole logical pixels: Hyprland snaps 1.45 to 1.5 and
  logs a warning. [src]
- The transform is the `wl_output_transform` number: 0 = normal, 1 = 90,
  2 = 180, 3 = 270, and 4–7 are the flipped variants. [src+vm]
- HDR is set with `cm = "hdr"`, `bitdepth = 10` and `max_luminance`. On vkms,
  Hyprland reports that the output doesn't support HDR. [vm]
- **Known failure:** on vkms, Hyprland never brings an output back after it is
  unplugged and replugged. The kernel shows the output connected again, and
  KWin, Mutter and niri all take it back. The cause is not confirmed and real
  hardware is untested; the test lists it in `KNOWN` in `tests/vm/lib.py`.
  [vm]

### Shared across all four

- Positions are in logical pixels (after scaling) everywhere. [src+vm]
- Rotations follow the Wayland convention: counter-clockwise. A portrait
  monitor at `transform = "90"` comes out 1080×1920 in all four. [vm]

## Home Manager facts

- Run as a NixOS (or nix-darwin) module, Home Manager passes `osConfig` as a
  `specialArg` (`nixos/common.nix:30`). Standalone, it sets
  `_module.args.osConfig = lib.mkDefault null`
  (`modules/misc/submodule-support.nix:40`). Naming `osConfig` as a module
  argument is therefore safe in both cases; it is just `null` when
  standalone. [src+vm: evaluated both ways]
- The module system looks up every named argument even if it has a default:
  `lib/modules.nix:724-729` falls back to `_module.args.<name>`. So writing
  `osConfig ? null` would not help if Home Manager didn't provide it. [src]
- `lib.attrByPath path false null` and `null.a.b or false` both return the
  default, which is what makes the per-session switch defaults work. [vm:
  evaluated]
- The per-session switches `programs.everyscreen.<session>.enable` default to
  the matching system setting:
  `services.desktopManager.{plasma6,gnome}.enable` and
  `programs.{niri,hyprland}.enable`. Standalone, all default to off.
- The Plasma and GNOME files use `force = true`, because Mutter can turn the
  link into a plain file (see above).

## The VM test (`nix build .#checks.x86_64-linux.vm -L`)

How it works, and why each piece is there:

- **vkms stands in for the GPU,** with configfs: one device, three pipelines.
  It is built out of tree as `vkmsdesk` with two patches:
  - A `connector_types` module parameter. Upstream names every connector
    Virtual-N; with `10,10,11` they become DP-1, DP-2, HDMI-A-1.
  - A call to `drm_edid_override_connector_update()` in `get_modes`. The DRM
    probe helper only falls back to `drm.edid_firmware` when `get_modes`
    returns 0 modes, and vkms always returns its built-in list. [src+vm]
- **Hotplug** is done through configfs: `echo 2 > …/connector2/status`
  unplugs the TV and `echo 1` plugs it back. [vm]
- **The EDIDs** come from `tests/vm/edid.py`, and pass `edid-decode`'s
  conformance check apart from the expected dummy-serial warning. They carry
  the identity fields KWin and Mutter match on. [vm]
- **Sessions** run as
  `systemd-run --unit=sess-<name> -p PAMName=login -p User=… -p TTYPath=/dev/tty7`,
  without a display manager. Before a session is restarted, its unit needs
  `systemctl reset-failed`, or the failed unit stays loaded and blocks the
  restart. [vm]
- **The neutral check** is `wayland-info`'s xdg-output logical geometry,
  which works the same in all four compositors. Per-compositor tools add
  detail: `kscreen-doctor -j`, `gdctl show`, `niri msg -j outputs`, and
  `hyprctl -j monitors all`. [vm]
- **Each section has a control:** it moves everyscreen's file away and checks
  that the layout then differs, which proves the layout came from the file.
- **Speed:** without KVM, QEMU emulates the CPU in software and every
  compositor renders with llvmpipe on top of that. A full run is then close
  to an hour. The test's timeouts are wall-clock, so if the host sleeps
  mid-run, a check can fail that would otherwise pass. [vm]
- **HDR is untestable here:** vkms exposes no HDR properties. [vm]
- `skipLint = true`: the test-script linter rejects an import that the
  section files use. [vm]

Results at the versions above: Plasma, GNOME and niri pass every check;
Hyprland passes everything except the known replug failure.

## Pitfalls hit while building it

- `nix eval -f file.nix` does not call a file that is a function. Use
  `--expr 'import ./file.nix { … }'`.
- A wait loop like `while pgrep -f "pattern"` finds itself, because its own
  command line contains the pattern, so it never ends. Wait on a PID or on a
  file instead.
- `su - user -c 'A=1 B=2 cmd1 || cmd2'` sets the variables for `cmd1` only.
  `export` them first.

## Conventions

- `alejandra` formats the Nix code.
- Comments explain *why*: the upstream behaviour or the format constraint the
  code works around. Point to source files and lines where possible, as
  above.
- When a fact about a compositor changes, update this file and the module's
  header comment together.
- Keep the generated file names (`screen-layout.kdl` and `.lua`): users'
  configs include them by name.
