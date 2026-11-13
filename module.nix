# everyscreen: one monitor layout for every session a machine runs. There is
# no file format the compositors share, and the wlroots output-management
# protocol that kanshi and shikane drive is not implemented by KWin or Mutter.
# So the layout is declared once, as `programs.everyscreen`, and written out in
# each compositor's own format:
#
#   Plasma    ~/.config/kwinoutputconfig.json
#   GNOME     ~/.config/monitors.xml
#   niri      ~/.config/niri/screen-layout.kdl   (config.kdl must include it)
#   Hyprland  ~/.config/hypr/screen-layout.lua   (hyprland.lua must require it)
#
# Each file is written when `programs.everyscreen.<session>.enable` is on. Those
# default to whether the system enables that session, so under NixOS nothing
# needs setting; Home Manager on its own has no system to ask and writes none
# until they are set.
#
# The user supplies the data; this module only knows the formats.
#
# Each compositor has to be at least the oldest release that reads its file as
# written here, which an assertion checks against `<session>.package`: KWin
# 6.0, Mutter 50, niri 26.04 and Hyprland 0.55.0. The reasons are in
# `sessions` below.
#
# `vmTest.enable` makes building the configuration run everyscreen's VM test
# (./tests/vm), against the sessions and compositor packages it uses.
#
# Things the formats force on the data, checked against KWin 6.6, Mutter 50,
# niri 26.04 and Hyprland 0.55 sources:
#
# - Scale has to divide the mode evenly for Mutter (n/d with d <= 4) and for
#   Hyprland (which snaps to the nearest such scale with a warning). 3840x2160
#   at 1.45 fails both; 1.5 works everywhere.
# - Positions are logical pixels in all four. Mutter rejects a whole setup if
#   two monitors overlap, none touches another, or there is not exactly one
#   primary.
# - The refresh rate is kept in mHz, as niri and KWin compare it: niri wants an
#   exact match, Mutter accepts anything within 0.001 Hz.
# - KWin and GNOME store one layout per set of connected monitors and fall back
#   to their own guess for any set they have none for, hence `setups`. niri and
#   Hyprland configure each monitor on its own, whatever else is plugged in.
#
# A layout changed in a settings app does not survive, in two different ways.
# KWin opens its file for writing through the link, which the read-only store
# refuses ("Couldn't open output config file"), so the change lasts until the
# session ends. Mutter writes a temporary file and renames it over the path
# (G_FILE_CREATE_REPLACE_DESTINATION), replacing the link with a plain file;
# `force` lets the next rebuild put the link back instead of refusing to
# activate. Either way, a change meant to stay goes into the Nix data.
{
  config,
  lib,
  modulesPath,
  osConfig,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
  cfg = config.programs.everyscreen;

  # Each session, with the oldest release of its compositor that reads the
  # file as written here, and why nothing older does. Read in each one's
  # source; only the versions in the header above ran in the VM test.
  # Plasma and GNOME have no package option in NixOS and take KWin and Mutter
  # from pkgs, which with Home Manager as a NixOS module is the same nixpkgs.
  sessions = {
    gnome = {
      name = "Mutter";
      file = "monitors.xml";
      enablePath = ["services" "desktopManager" "gnome" "enable"];
      package = pkgs.mutter;
      packageText = "pkgs.mutter";
      minimum = "50";
      why = ''
        before 50, Mutter lays monitors out physically unless the
        experimental scale-monitor-framebuffer feature is on, and leaves a
        configuration marked <layoutmode>logical</layoutmode> unused
        (meta-monitor-manager-native.c, meta-monitor-config-store.c)'';
    };
    hyprland = {
      name = "Hyprland";
      file = "hypr/screen-layout.lua";
      enablePath = ["programs" "hyprland" "enable"];
      package = osConfig.programs.hyprland.package or pkgs.hyprland;
      packageText = "osConfig.programs.hyprland.package or pkgs.hyprland";
      minimum = "0.55.0";
      why = "Hyprland reads a Lua config, and so hl.monitor(), from 0.55.0 on";
    };
    niri = {
      name = "niri";
      file = "niri/screen-layout.kdl";
      enablePath = ["programs" "niri" "enable"];
      package = osConfig.programs.niri.package or pkgs.niri;
      packageText = "osConfig.programs.niri.package or pkgs.niri";
      minimum = "26.04";
      why = ''
        the config.kdl that pulls the layout in needs `include optional=true`,
        which niri has from 26.04 on'';
    };
    plasma = {
      name = "KWin";
      file = "kwinoutputconfig.json";
      enablePath = ["services" "desktopManager" "plasma6" "enable"];
      package = pkgs.kdePackages.kwin;
      packageText = "pkgs.kdePackages.kwin";
      minimum = "6.0";
      why = "KWin reads kwinoutputconfig.json from Plasma 6.0 on; before, KScreen kept layouts in files of its own";
    };
  };

  # osConfig is null when Home Manager runs on its own
  # (modules/misc/submodule-support.nix); attrByPath and `or` both take that.
  sessionOptions = s: {
    enable = mkOption {
      default = lib.attrByPath s.enablePath false osConfig;
      defaultText = lib.literalExpression "osConfig.${lib.concatStringsSep "." s.enablePath} or false";
      description = "Whether to write the layout for ${s.name} (~/.config/${s.file}).";
      type = types.bool;
    };
    package = mkOption {
      default = s.package;
      defaultText = lib.literalExpression s.packageText;
      description = ''
        The ${s.name} that reads the layout. Only its version is used: it has
        to be ${s.minimum} or newer, the oldest that reads the file as
        everyscreen writes it. Nothing is installed. With standalone Home
        Manager the default is a guess at the ${s.name} your system runs; set
        `null` to skip the check.
      '';
      type = types.nullOr types.package;
    };
  };

  output = types.submodule {
    options = {
      connector = mkOption {
        description = "The kernel's DRM connector name; niri, Hyprland and Mutter match on it.";
        example = "DP-1";
        type = types.str;
      };
      edid = mkOption {
        description = ''
          The EDID's vendor/product block, which KWin joins into its
          `edidIdentifier` and Mutter falls back to when the EDID carries no
          product-name or serial string. `edid-decode` prints all of it.
        '';
        type = types.submodule {
          options = {
            modelYear = mkOption {
              default = 0;
              description = "Model year, 0 when the EDID gives a manufacture date instead.";
              type = types.int;
            };
            product = mkOption {
              description = "Product code.";
              type = types.int;
            };
            serial = mkOption {
              description = "Numeric serial number.";
              type = types.int;
            };
            vendor = mkOption {
              description = "Three-letter PNP manufacturer ID.";
              type = types.str;
            };
            week = mkOption {
              description = "Week of manufacture.";
              type = types.int;
            };
            year = mkOption {
              description = "Year of manufacture.";
              type = types.int;
            };
          };
        };
      };
      gnome = mkOption {
        default = null;
        description = ''
          Mutter's product and serial strings: the EDID's "Display Product
          Name" and "Display Product Serial Number", or, where the EDID has
          none, the product code as `0x%04x` and the serial as `0x%08x`.
          Mutter matches all four of connector, vendor, product and serial
          exactly, so a setup with any output left at null is not written to
          monitors.xml.
        '';
        type = types.nullOr (types.submodule {
          options = {
            product = mkOption {type = types.str;};
            serial = mkOption {type = types.str;};
          };
        });
      };
      hdr = mkOption {
        default = false;
        description = "HDR with wide colour gamut, where the compositor supports it (not niri).";
        type = types.bool;
      };
      hyprland = mkOption {
        default = {};
        description = "Extra hl.monitor() fields for this output.";
        type = types.attrsOf types.anything;
      };
      kwin = mkOption {
        default = {};
        description = "Extra kwinoutputconfig.json fields for this output, for KWin-only tuning.";
        type = types.attrsOf types.anything;
      };
      mode = {
        height = mkOption {type = types.int;};
        refresh = mkOption {
          description = "Refresh rate in mHz.";
          example = 60000;
          type = types.int;
        };
        width = mkOption {type = types.int;};
      };
      peakBrightness = mkOption {
        default = null;
        description = "Peak brightness in nits, overriding what the EDID claims (KWin, Hyprland).";
        type = types.nullOr types.int;
      };
      position = {
        x = mkOption {type = types.int;};
        y = mkOption {type = types.int;};
      };
      primary = mkOption {
        default = false;
        description = "Mutter's primary, KWin's priority 1, niri's focus-at-startup. Hyprland has no such notion.";
        type = types.bool;
      };
      scale = mkOption {
        default = 1;
        type = types.number;
      };
      transform = mkOption {
        default = "normal";
        description = "Wayland's convention: rotations are counter-clockwise.";
        type = types.enum (builtins.attrNames transforms);
      };
    };
  };

  # One row per Wayland transform: KWin's name, Mutter's rotation and flip,
  # Hyprland's wl_output_transform number. niri uses the key itself.
  transforms = {
    "180" = ["Rotated180" "upside_down" false 2];
    "270" = ["Rotated270" "right" false 3];
    "90" = ["Rotated90" "left" false 1];
    flipped = ["Flipped" "normal" true 4];
    flipped-180 = ["Flipped180" "upside_down" true 6];
    flipped-270 = ["Flipped270" "right" true 7];
    flipped-90 = ["Flipped90" "left" true 5];
    normal = ["Normal" "normal" false 0];
  };
  transformOf = o: builtins.elemAt transforms.${o.transform};

  names = builtins.attrNames cfg.outputs;
  outputsOf = setup: map (n: cfg.outputs.${n}) setup;
  # Mutter names connectors from its own table rather than the kernel's, and
  # the one that differs on a desktop is HDMI-A, which it calls plain HDMI
  # (meta-connector.c): the kernel's HDMI-A-1 is Mutter's HDMI-1.
  mutterConnector = c:
    if lib.hasPrefix "HDMI-A-" c
    then "HDMI-" + lib.removePrefix "HDMI-A-" c
    else c;
  hz = mhz: "${toString (mhz / 1000)}.${lib.fixedWidthNumber 3 (lib.mod mhz 1000)}";
  modeString = o: "${toString o.mode.width}x${toString o.mode.height}@${hz o.mode.refresh}";

  kwinJson = builtins.toJSON [
    {
      data = map (n: let
        o = cfg.outputs.${n};
        e = o.edid;
      in
        {
          inherit (o) scale;
          connectorName = o.connector;
          edidIdentifier = lib.concatMapStringsSep " " toString [e.vendor e.product e.serial e.week e.year e.modelYear];
          highDynamicRange = o.hdr;
          mode = {
            inherit (o.mode) width height;
            refreshRate = o.mode.refresh;
          };
          transform = transformOf o 0;
          wideColorGamut = o.hdr;
        }
        // lib.optionalAttrs (o.peakBrightness != null) {maxPeakBrightnessOverride = o.peakBrightness;}
        // o.kwin)
      names;
      name = "outputs";
    }
    {
      data =
        map (setup: {
          # Primary first; KWin reads a lower priority as more important.
          outputs = lib.imap1 (i: n: {
            # Required: KWin drops a setup whose outputs lack it.
            enabled = true;
            outputIndex = lib.lists.findFirstIndex (x: x == n) null names;
            position = cfg.outputs.${n}.position;
            priority = i;
          }) (lib.sort (a: b: cfg.outputs.${a}.primary && !cfg.outputs.${b}.primary) setup);
        })
        cfg.setups;
      name = "setups";
    }
  ];

  gnomeSetups = builtins.filter (setup: builtins.all (o: o.gnome != null) (outputsOf setup)) cfg.setups;
  monitorsXml = let
    x = lib.escapeXML;
    logical = o: ''
      <logicalmonitor>
        <x>${toString o.position.x}</x>
        <y>${toString o.position.y}</y>
        <scale>${toString o.scale}</scale>
        <primary>${lib.boolToYesNo o.primary}</primary>
        <transform>
          <rotation>${transformOf o 1}</rotation>
          <flipped>${lib.boolToYesNo (transformOf o 2)}</flipped>
        </transform>
        <monitor>
          <monitorspec>
            <connector>${x (mutterConnector o.connector)}</connector>
            <vendor>${x o.edid.vendor}</vendor>
            <product>${x o.gnome.product}</product>
            <serial>${x o.gnome.serial}</serial>
          </monitorspec>
          <mode>
            <width>${toString o.mode.width}</width>
            <height>${toString o.mode.height}</height>
            <rate>${hz o.mode.refresh}</rate>
          </mode>${lib.optionalString o.hdr "\n<colormode>bt2100</colormode>"}
        </monitor>
      </logicalmonitor>
    '';
  in ''
    <monitors version="2">
    ${lib.concatMapStrings (setup: ''
        <configuration>
          <layoutmode>logical</layoutmode>
          ${lib.concatMapStrings logical (outputsOf setup)}
        </configuration>
      '')
      gnomeSetups}
    </monitors>
  '';

  niriKdl = lib.concatMapStrings (o: ''
    output "${o.connector}" {
        mode "${modeString o}"
        scale ${toString o.scale}
        transform "${o.transform}"
        position x=${toString o.position.x} y=${toString o.position.y}
    ${lib.optionalString o.primary "    focus-at-startup\n"}}
  '') (builtins.attrValues cfg.outputs);

  luaValue = v:
    if builtins.isString v
    then builtins.toJSON v # a JSON string is a valid Lua string literal
    else if builtins.isBool v
    then lib.boolToString v
    else toString v;
  hyprLua = ''
    -- Generated by everyscreen from programs.everyscreen; edit that, not
    -- this.
    ${lib.concatMapStrings (o: let
      fields =
        {
          mode = modeString o;
          output = o.connector;
          position = "${toString o.position.x}x${toString o.position.y}";
          scale = toString o.scale;
          transform = transformOf o 3;
        }
        // lib.optionalAttrs o.hdr {
          bitdepth = 10;
          cm = "hdr";
        }
        // lib.optionalAttrs (o.peakBrightness != null) {max_luminance = o.peakBrightness;}
        // o.hyprland;
    in ''
      hl.monitor({ ${lib.concatStringsSep ", " (lib.mapAttrsToList (k: v: "${k} = ${luaValue v}") fields)} })
    '') (builtins.attrValues cfg.outputs)}
  '';
  enabledSessions = builtins.filter (s: cfg.${s}.enable) (builtins.attrNames sessions);
  # The test's own defaults, which it need not be told about. Comparing
  # derivations compares their output paths.
  testDefaults = {
    gnome = pkgs.mutter;
    hyprland = pkgs.hyprland;
    niri = pkgs.niri;
    plasma = pkgs.kdePackages.kwin;
  };
  vmTest = import ./tests/vm {
    inherit pkgs;
    # The NixOS module of the Home Manager evaluating this one.
    homeManagerModule = modulesPath + "/../nixos";
    everyscreen = ./module.nix;
    sessions = enabledSessions;
    packages = lib.filterAttrs (s: p: p != null && p != testDefaults.${s}) (lib.genAttrs enabledSessions (s: cfg.${s}.package));
    inherit (config.home) stateVersion;
  };
in {
  options.programs.everyscreen =
    lib.mapAttrs (_: sessionOptions) sessions
    // {
      outputs = mkOption {
        default = {};
        description = "Every monitor you have, by a name of your choosing.";
        type = types.attrsOf output;
      };
      vmTest.enable = lib.mkEnableOption ''
        running everyscreen's VM test (tests/vm in its source) as part of
        building this configuration, so that a failure stops the build before
        anything is activated. It starts each enabled session, with the
        compositor packages above, this configuration's nixpkgs and its Home
        Manager, and checks a fixed test layout, not yours: it shows that
        everyscreen works with those versions. It needs a Linux builder with
        KVM (the `kvm` and `nixos-test` system features) and runs only in
        Nix's build sandbox. A run takes minutes, and its result is cached
        until something it uses changes'';
      setups = mkOption {
        default = [];
        description = "The sets of outputs that are connected together; KWin and GNOME get one layout for each.";
        example = [["left" "center"] ["left" "center" "tv"]];
        type = types.listOf (types.listOf (types.enum names));
      };
    };

  config = lib.mkIf (cfg.outputs != {}) {
    assertions =
      map (setup: {
        assertion = lib.count (o: o.primary) (outputsOf setup) == 1;
        message = "programs.everyscreen: setup [${toString setup}] needs exactly one primary output; Mutter refuses it otherwise.";
      })
      cfg.setups
      ++ lib.mapAttrsToList (key: s: let
        c = cfg.${key};
        version = lib.getVersion c.package;
      in {
        assertion = !c.enable || c.package == null || !lib.versionOlder version s.minimum;
        message = ''
          programs.everyscreen: ${s.name} ${version} is too old for ~/.config/${s.file}; it needs ${s.minimum} or newer:
          ${s.why}.
          Update ${s.name}, or set programs.everyscreen.${key}.package = null to skip this check.'';
      })
      sessions
      ++ [
        {
          assertion = !cfg.vmTest.enable || pkgs.stdenv.hostPlatform.isLinux;
          message = "programs.everyscreen.vmTest needs Linux: it boots a NixOS VM.";
        }
        {
          assertion = !cfg.vmTest.enable || enabledSessions != [];
          message = "programs.everyscreen.vmTest is on, but no session is enabled to test.";
        }
      ];

    home.checks = lib.mkIf cfg.vmTest.enable [vmTest];

    warnings = lib.optional (cfg.gnome.enable && gnomeSetups != cfg.setups) ''
      programs.everyscreen: outputs ${toString (builtins.filter (n: cfg.outputs.${n}.gnome == null) names)} have no
      `gnome` product/serial strings, so setups using them are left out of monitors.xml.
    '';

    xdg.configFile = lib.mkMerge [
      (lib.mkIf cfg.plasma.enable {
        "kwinoutputconfig.json" = {
          force = true;
          text = kwinJson;
        };
      })
      (lib.mkIf (cfg.gnome.enable && gnomeSetups != []) {
        "monitors.xml" = {
          force = true;
          text = monitorsXml;
        };
      })
      (lib.mkIf cfg.niri.enable {
        "niri/screen-layout.kdl".text = niriKdl;
      })
      (lib.mkIf cfg.hyprland.enable {
        "hypr/screen-layout.lua".text = hyprLua;
      })
    ];
  };
}
