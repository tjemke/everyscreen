# Starts each session in a VM on three virtual monitors and checks that it
# lays them out as ./layout.nix says, then unplugs and replugs the TV, and
# finally checks each again without everyscreen's file, to see the layout
# really comes from it.
#
# vkms (./vkms.nix) stands in for the GPU: three outputs named DP-1, DP-2 and
# HDMI-A-1, each given one of the layout's monitors' EDIDs (./edid.py) through
# the kernel's EDID override. Every compositor renders with llvmpipe, which
# stock niri refuses (./niri-sw.nix).
#
# The flake's check runs it with its own nixpkgs and every session. It can
# also run with another nixpkgs and Home Manager, only some of the sessions,
# and other compositor packages. The layout is always ./layout.nix.
#
# It refuses to run outside Nix's build sandbox (./lib.py). Without KVM, QEMU
# emulates the CPU: about 8 minutes on a fast desktop, an hour on a slow one.
{
  pkgs,
  # Home Manager's NixOS module.
  homeManagerModule,
  # The module under test.
  everyscreen,
  # Which sessions to start; any of plasma, gnome, niri and hyprland.
  sessions ? ["plasma" "gnome" "hyprland" "niri"],
  # Compositors to test instead of the ones in pkgs, by session name.
  packages ? {},
  # Must be a release the Home Manager above knows.
  stateVersion ? "26.05",
}: let
  inherit (pkgs) lib;
  on = s: builtins.elem s sessions;

  # NixOS has no package option for Plasma or GNOME: their modules take KWin
  # and Mutter from pkgs, so a different one goes in through an overlay.
  testPkgs =
    if packages ? plasma || packages ? gnome
    then
      pkgs.extend (final: prev:
        lib.optionalAttrs (packages ? gnome) {mutter = packages.gnome;}
        // lib.optionalAttrs (packages ? plasma) {
          kdePackages = prev.kdePackages.overrideScope (_: _: {kwin = packages.plasma;});
        })
    else pkgs;

  kernelPackages = testPkgs.linuxPackages_latest;
  vkms = kernelPackages.callPackage ./vkms.nix {};
  edids = testPkgs.runCommand "everyscreen-test-edids" {nativeBuildInputs = [testPkgs.python3];} ''
    python3 -I ${./edid.py} $out/lib/firmware/edid
  '';

  # configfs: one vkms device, three pipelines. Connectors are created in
  # this order, which connector_types=10,10,11 turns into DP-1, DP-2, HDMI-A-1.
  vkmsSetup = testPkgs.writeShellScript "vkms-setup" ''
    set -eu
    d=/sys/kernel/config/vkms/desk
    mkdir $d
    for i in 0 1 2; do
      mkdir $d/crtcs/crtc$i $d/planes/plane$i $d/encoders/encoder$i $d/connectors/connector$i
      echo 1 > $d/planes/plane$i/type
      ln -s $d/crtcs/crtc$i $d/planes/plane$i/possible_crtcs
      ln -s $d/crtcs/crtc$i $d/encoders/encoder$i/possible_crtcs
      ln -s $d/encoders/encoder$i $d/connectors/connector$i/possible_encoders
    done
    echo 1 > $d/enabled
  '';

  # The order the sections run in.
  order = builtins.filter on ["plasma" "hyprland" "niri" "gnome"];
in
  testPkgs.testers.runNixOSTest {
    name = "everyscreen";
    globalTimeout = 4 * 3600;
    nodes.machine = {
      imports = [homeManagerModule];

      virtualisation = {
        memorySize = 6144;
        cores = 4;
        diskSize = 4096;
        graphics = false;
        # No emulated graphics card: vkms has to be the only DRM device.
        qemu.options = ["-vga none"];
      };

      boot.kernelPackages = kernelPackages;
      boot.extraModulePackages = [vkms];
      boot.blacklistedKernelModules = ["vkms" "bochs" "virtio_gpu" "simpledrm"];
      boot.extraModprobeConfig = ''
        options vkmsdesk create_default_dev=0 connector_types=10,10,11
      '';
      boot.kernelParams = [
        "drm.edid_firmware=DP-1:edid/center.bin,DP-2:edid/left.bin,HDMI-A-1:edid/tv.bin"
      ];
      hardware.firmware = [edids];
      hardware.graphics.enable = true;

      systemd.services.vkms = {
        wantedBy = ["multi-user.target"];
        after = ["sys-kernel-config.mount"];
        path = [testPkgs.kmod];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          modprobe vkmsdesk
          ${vkmsSetup}
        '';
      };

      # The sessions under test. The module's switches default to these,
      # which the test relies on.
      services.desktopManager.plasma6.enable = on "plasma";
      services.desktopManager.gnome.enable = on "gnome";
      programs.hyprland = lib.mkIf (on "hyprland") {
        enable = true;
        package = lib.mkIf (packages ? hyprland) packages.hyprland;
      };
      programs.niri = lib.mkIf (on "niri") {
        enable = true;
        package = testPkgs.callPackage ./niri-sw.nix {niri = packages.niri or testPkgs.niri;};
      };

      environment.systemPackages = with testPkgs;
        [
          jq
          libdrm # modetest
          edid-decode
          wayland-utils
          grim
        ]
        ++ lib.optional (on "gnome") mutter; # gdctl

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = ["video" "input"];
      };

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.alice = {
        imports = [everyscreen ./layout.nix];
        xdg.configFile."hypr/hyprland.lua" = lib.mkIf (on "hyprland") {source = ./hyprland.lua;};
        xdg.configFile."niri/config.kdl" = lib.mkIf (on "niri") {source = ./niri.kdl;};
        home.stateVersion = stateVersion;
      };
    };

    skipLint = true;
    testScript = lib.concatStringsSep "\n" [
      (builtins.readFile ./lib.py)
      "SESSIONS = ${builtins.toJSON order}"
      (builtins.readFile ./sections.py)
      ''
        machine.wait_for_unit("vkms.service")
        machine.wait_for_unit("home-manager-alice.service")
        for c in ["DP-1", "DP-2", "HDMI-A-1"]:
            machine.succeed(f"echo detect > /sys/class/drm/card0-{c}/status")
        section(smoke)
        for s in SESSIONS:
            section(SECTIONS[s])
        summary()
      ''
    ];
  }
