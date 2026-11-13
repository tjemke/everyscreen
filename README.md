# everyscreen

One monitor layout, declared once in Home Manager and written out for every
Wayland session you use:

| Session  | File                               | Notes                              |
|----------|------------------------------------|------------------------------------|
| Plasma   | `~/.config/kwinoutputconfig.json`  | one layout per set of monitors     |
| GNOME    | `~/.config/monitors.xml`           | one layout per set of monitors     |
| niri     | `~/.config/niri/screen-layout.kdl` | your `config.kdl` must include it  |
| Hyprland | `~/.config/hypr/screen-layout.lua` | your `hyprland.lua` must require it |

There is no format the compositors share, and the wlroots output-management
protocol that kanshi and shikane use is not implemented by KWin or Mutter, so
everyscreen writes each compositor's own file instead.

Checked against KWin 6.6, Mutter 50, niri 26.04 and Hyprland 0.55 (the Lua
config; the older `hyprland.conf` syntax is not written).

Needs at least KWin 6.0, Mutter 50, niri 26.04 and Hyprland 0.55.0, the oldest
releases that read the files as written. An assertion checks this against
`programs.everyscreen.<session>.package`. That option is only read for its
version and installs nothing. By default it is the system's niri or Hyprland
package, and KWin or Mutter from `pkgs`. With standalone Home Manager, point it
at what your system runs, or set it to `null` to skip the check.

## Use

```nix
# flake.nix
inputs.everyscreen = {
  url = "github:tjemke/everyscreen";
  # Only the VM test uses these; this avoids fetching them.
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
```

Import `inputs.everyscreen.homeModules.default` into your Home Manager
configuration, then describe your monitors:

```nix
programs.everyscreen = {
  outputs = {
    left = {
      connector = "DP-2";
      edid = { vendor = "EXA"; product = 4097; serial = 16843009; week = 10; year = 2019; };
      gnome = { product = "Example 22"; serial = "EX22A0000001"; };
      mode = { width = 1920; height = 1080; refresh = 60000; };   # refresh in mHz
      transform = "90";                                           # counter-clockwise
      position = { x = 0; y = 0; };                               # logical pixels
    };
    center = {
      connector = "DP-1";
      edid = { vendor = "EXA"; product = 4098; serial = 16843009; week = 20; year = 2019; };
      gnome = { product = "Example 24"; serial = "EX24A0000002"; };
      mode = { width = 1920; height = 1080; refresh = 60000; };
      position = { x = 1080; y = 412; };
      primary = true;
    };
  };
  # The sets of monitors that are connected together. Plasma and GNOME get
  # one layout for each; niri and Hyprland place each monitor on its own.
  setups = [ [ "left" "center" ] ];
};
```

[`tests/vm/layout.nix`](tests/vm/layout.nix) is a complete example with a TV
that is not always on, HDR and Plasma-only tuning.

### Which sessions get a file

`programs.everyscreen.{plasma,gnome,niri,hyprland}.enable` default to whether
your NixOS (or nix-darwin) configuration enables that session, so with Home
Manager as a NixOS module there is nothing to set. With standalone Home Manager
there is no system to ask: set the ones you want.

### niri and Hyprland

Both read the layout only if your own config pulls it in:

```kdl
// ~/.config/niri/config.kdl
include optional=true "screen-layout.kdl"
```

```lua
-- ~/.config/hypr/hyprland.lua
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
pcall(require, "screen-layout")
```

## Where the values come from

The easiest source is what your desktops already saved: arrange the monitors
once in Plasma's and GNOME's display settings, then copy from

- `~/.config/kwinoutputconfig.json`: `connectorName`, `mode`, and
  `edidIdentifier`, which is `vendor product serial week year modelYear`.
- `~/.config/monitors.xml`: each monitor's `<product>` and `<serial>`, which
  go into `gnome`. Mutter takes them from the EDID's product-name and serial
  strings, or prints the numbers as `0x%04x` and `0x%08x` where there are none.

`edid-decode /sys/class/drm/card*-DP-1/edid` shows the same fields from the
monitor itself.

The formats limit the data in a few ways, and the module enforces what it can:

- The scale has to divide the mode evenly for Mutter (n/d with d ≤ 4) and
  Hyprland: 3840×2160 at 1.45 fails both, 1.5 works everywhere.
- Mutter rejects a whole setup if two monitors overlap, none touches another,
  or there is not exactly one `primary` (the last one is an assertion here).
- niri wants the refresh rate to match exactly, in mHz.
- A setup with a monitor that has no `gnome` strings is left out of
  `monitors.xml`, with a warning.

## Things to know

- **Changes made in a settings app do not stick.** KWin cannot write through
  the store link, so a change lasts until you log out. Mutter replaces the
  link with its own file, which the next Home Manager switch puts back
  (`force = true`). Put changes you want to keep into the Nix data.
- **HDR** (`hdr`, `peakBrightness`) is written for KWin, Mutter and Hyprland
  but not tested: the VM's virtual GPU has no HDR.

## Test

```
nix build .#checks.x86_64-linux.eval -L   # seconds, no VM
nix build .#checks.x86_64-linux.vm -L     # the VM test
```

The first compares the four generated files with
[`tests/eval/golden`](tests/eval/golden), and checks what the assertions and
warnings report for a set of configurations.

The second boots a VM with three virtual monitors carrying real EDIDs (a
patched vkms). It starts Plasma, GNOME, Hyprland and niri in turn, and checks
that each lays them out as [`tests/vm/layout.nix`](tests/vm/layout.nix) says.
It also checks each one with the TV unplugged and plugged back, and without
everyscreen's file, to show the layout really comes from it. It needs Nix's
build sandbox (`sandbox = true`, the default on Linux) and refuses to run
without it. With KVM the test script should take about 2 minutes. Without KVM,
QEMU emulates the CPU: about 5½ minutes on a fast desktop CPU, and close to an
hour on a slower machine. Compiling the patched niri the test uses adds a few
minutes the first time.

One known failure is tolerated: Hyprland 0.55 on vkms never brings the TV back
after a replug. The kernel shows it connected again and the other three
sessions take it back, so it looks like Hyprland's hotplug handling on vkms,
but that is not confirmed on real hardware.

### From your own configuration

```nix
programs.everyscreen.vmTest.enable = true;
```

This runs the VM test whenever your configuration is built, so that a failure
stops the build before anything is activated. It starts only the sessions you
enable, with your nixpkgs, your Home Manager and the compositor packages
everyscreen checks (`programs.everyscreen.<session>.package`). It still lays
out the test's monitors, not yours: it shows that everyscreen works with the
versions you run.

It needs a Linux builder with KVM (the `kvm` and `nixos-test` system features)
and Nix's sandbox. Your `linuxPackages_latest` has to be recent enough for
vkms's configfs. The result is cached until something it uses changes.
