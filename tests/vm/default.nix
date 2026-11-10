# Starts Plasma, GNOME, Hyprland and niri in a VM on three virtual monitors and
# checks that each lays them out as ./layout.nix says, then unplugs and replugs
# the TV, and finally checks each again without everyscreen's file, to see the
# layout really comes from it.
#
# vkms (./vkms.nix) stands in for the GPU: three outputs named DP-1, DP-2 and
# HDMI-A-1, each given one of the layout's monitors' EDIDs (./edid.py) through
# the kernel's EDID override. Every compositor renders with llvmpipe, which
# stock niri refuses (./niri-sw.nix).
#
# Slow without KVM: under plain emulation a full run is closer to an hour.
{
  pkgs,
  home-manager,
  everyscreen,
}: let
  inherit (pkgs) lib;
  kernelPackages = pkgs.linuxPackages_latest;
  vkms = kernelPackages.callPackage ./vkms.nix {};
  edids = pkgs.runCommand "everyscreen-test-edids" {nativeBuildInputs = [pkgs.python3];} ''
    python3 -I ${./edid.py} $out/lib/firmware/edid
  '';

  # configfs: one vkms device, three pipelines. Connectors are created in
  # this order, which connector_types=10,10,11 turns into DP-1, DP-2, HDMI-A-1.
  vkmsSetup = pkgs.writeShellScript "vkms-setup" ''
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
in
  pkgs.testers.runNixOSTest {
    name = "everyscreen";
    globalTimeout = 4 * 3600;
    nodes.machine = {
      imports = [home-manager.nixosModules.home-manager];

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
        path = [pkgs.kmod];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          modprobe vkmsdesk
          ${vkmsSetup}
        '';
      };

      # Every session everyscreen writes a file for. The module's switches
      # default to these, which the test relies on.
      services.desktopManager.plasma6.enable = true;
      services.desktopManager.gnome.enable = true;
      programs.hyprland.enable = true;
      programs.niri.enable = true;
      programs.niri.package = pkgs.callPackage ./niri-sw.nix {};

      environment.systemPackages = with pkgs; [
        jq
        libdrm # modetest
        edid-decode
        wayland-utils
        grim
        mutter # gdctl
      ];

      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = ["video" "input"];
      };

      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.users.alice = {
        imports = [everyscreen ./layout.nix];
        xdg.configFile."hypr/hyprland.lua".source = ./hyprland.lua;
        xdg.configFile."niri/config.kdl".source = ./niri.kdl;
        home.stateVersion = "26.05";
      };
    };

    skipLint = true;
    testScript = lib.concatStringsSep "\n" [
      (builtins.readFile ./lib.py)
      (builtins.readFile ./sections.py)
      ''
        machine.wait_for_unit("vkms.service")
        machine.wait_for_unit("home-manager-alice.service")
        for c in ["DP-1", "DP-2", "HDMI-A-1"]:
            machine.succeed(f"echo detect > /sys/class/drm/card0-{c}/status")
        for s in [smoke, kde, hyprland, niri, gnome]:
            section(s)
        summary()
      ''
    ];
  }
