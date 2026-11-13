# Checks that need no VM, in seconds: the four generated files against the
# copies in ./golden, and what the assertions and warnings say for a set of
# configurations. Everything is evaluated with standalone Home Manager; the VM
# test evaluates the module under NixOS.
#
# A change to the generated files is meant to show up as a diff here. When it
# is intended, update the copies:
#
#   nix build .#checks.x86_64-linux.eval.generated -o generated
#   cp generated/* tests/eval/golden/ && rm generated
{
  pkgs,
  home-manager,
  everyscreen,
}: let
  inherit (pkgs) lib;

  # A derivation that is never built: the version check reads only its name.
  fake = name: pkgs.runCommand name {} "exit 1";

  # Home Manager's own evaluation (modules/default.nix), minus the step that
  # throws on a failed assertion, since some cases are meant to fail.
  hmLib = import "${home-manager}/modules/lib/stdlib-extended.nix" lib;
  hm = modules:
    (hmLib.evalModules {
      class = "homeManager";
      specialArgs.modulesPath = "${home-manager}/modules";
      modules =
        import "${home-manager}/modules/modules.nix" {
          inherit pkgs;
          lib = hmLib;
          check = true;
        }
        ++ [
          everyscreen
          {
            home = {
              username = "alice";
              homeDirectory = "/home/alice";
              stateVersion = "26.05";
            };
          }
        ]
        ++ modules;
    }).config;

  all = {
    programs.everyscreen = lib.genAttrs ["plasma" "gnome" "niri" "hyprland"] (_: {enable = true;});
  };
  fixture = [../vm/layout.nix all];
  failed = c: map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);

  # Each case: the configuration, and the substrings that each failed
  # assertion (or warning) has to contain, one per failure, in order.
  cases = {
    "the test layout passes" = {
      config = hm fixture;
      assertions = [];
    };
    "standalone, nothing enabled: no assertion and no file" = {
      config = hm [../vm/layout.nix];
      assertions = [];
      check = c:
        lib.optional (builtins.any (n: c.xdg.configFile ? ${n}) ["kwinoutputconfig.json" "monitors.xml" "niri/screen-layout.kdl" "hypr/screen-layout.lua"])
        "a file was written with every session off";
    };
    "versions just below each minimum fail" = {
      config = hm (fixture
        ++ [
          {
            programs.everyscreen = {
              gnome.package = fake "mutter-49.2";
              hyprland.package = fake "hyprland-0.54.3";
              niri.package = fake "niri-25.11";
              plasma.package = fake "kwin-5.27.11";
            };
          }
        ]);
      assertions = ["Mutter 49.2 is too old" "Hyprland 0.54.3 is too old" "niri 25.11 is too old" "KWin 5.27.11 is too old"];
    };
    "the minimums themselves pass" = {
      config = hm (fixture
        ++ [
          {
            programs.everyscreen = {
              gnome.package = fake "mutter-50.0";
              hyprland.package = fake "hyprland-0.55.0";
              niri.package = fake "niri-26.04";
              plasma.package = fake "kwin-6.0";
            };
          }
        ]);
      assertions = [];
    };
    "package = null skips the check" = {
      config = hm (fixture
        ++ [
          {
            programs.everyscreen = lib.genAttrs ["plasma" "gnome" "niri" "hyprland"] (_: {package = null;});
          }
        ]);
      assertions = [];
    };
    "a session that is off is not checked" = {
      config = hm [
        ../vm/layout.nix
        {
          programs.everyscreen.niri = {
            enable = false;
            package = fake "niri-25.11";
          };
        }
      ];
      assertions = [];
    };
    "a setup with two primaries fails" = {
      config = hm (fixture ++ [{programs.everyscreen.outputs.left.primary = true;}]);
      assertions = ["setup [left center] needs exactly one primary" "setup [left center tv] needs exactly one primary"];
    };
    "a setup with no primary fails" = {
      config = hm (fixture ++ [{programs.everyscreen.outputs.center.primary = lib.mkForce false;}]);
      assertions = ["setup [left center] needs exactly one primary" "setup [left center tv] needs exactly one primary"];
    };
    "an output without gnome strings warns and drops its setups" = {
      config = hm (fixture ++ [{programs.everyscreen.outputs.tv.gnome = lib.mkForce null;}]);
      assertions = [];
      warnings = ["outputs tv have no"];
      check = c: let
        xml = c.xdg.configFile."monitors.xml".text;
      in
        lib.optional (lib.hasInfix "HDMI-1" xml) "monitors.xml still has the TV's setup"
        ++ lib.optional (!lib.hasInfix "<connector>DP-1</connector>" xml) "monitors.xml lost the setup without the TV";
    };
  };

  # Each case's problems, as strings; none means it passed.
  matches = what: want: got:
    if builtins.length want != builtins.length got
    then ["want ${toString (builtins.length want)} ${what}, got ${toString (builtins.length got)}: ${builtins.toJSON got}"]
    else lib.concatLists (lib.zipListsWith (w: g: lib.optional (!lib.hasInfix w g) "${what}: want \"${w}\" in: ${g}") want got);
  problems = c:
    matches "failed assertions" c.assertions (failed c.config)
    ++ matches "warnings" (c.warnings or []) c.config.warnings
    ++ (c.check or (_: [])) c.config;
  report = lib.concatStrings (lib.mapAttrsToList (name: c: let
    p = problems c;
  in
    (
      if p == []
      then "PASS "
      else "FAIL "
    )
    + name
    + "\n"
    + lib.concatMapStrings (x: "    ${x}\n") p)
  cases);
  allPass = builtins.all (c: problems c == []) (builtins.attrValues cases);

  # The generated files, KWin's JSON pretty-printed so a diff is readable.
  files = (hm fixture).xdg.configFile;
  generated = pkgs.runCommand "everyscreen-generated" {nativeBuildInputs = [pkgs.jq];} ''
    mkdir $out
    jq . ${pkgs.writeText "kwin" files."kwinoutputconfig.json".text} > $out/kwinoutputconfig.json
    cp ${pkgs.writeText "monitors" files."monitors.xml".text} $out/monitors.xml
    cp ${pkgs.writeText "kdl" files."niri/screen-layout.kdl".text} $out/screen-layout.kdl
    cp ${pkgs.writeText "lua" files."hypr/screen-layout.lua".text} $out/screen-layout.lua
  '';
in
  pkgs.runCommand "everyscreen-eval" {
    passthru = {inherit generated;};
    inherit report;
    passAsFile = ["report"];
  } ''
    cat "$reportPath"
    ok=${lib.boolToString allPass}
    for f in kwinoutputconfig.json monitors.xml screen-layout.kdl screen-layout.lua; do
      if diff -u ${./golden}/$f ${generated}/$f; then
        echo "PASS generated $f matches tests/eval/golden/$f"
      else
        echo "FAIL generated $f differs from tests/eval/golden/$f (diff above)"
        ok=false
      fi
    done
    $ok || { echo "See tests/eval/default.nix for how to update the golden copies."; exit 1; }
    touch $out
  ''
