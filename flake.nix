{
  description = "One monitor layout, written for KWin, GNOME, niri and Hyprland";

  # Only the VM test and the formatter use these; the module itself needs
  # nothing but Home Manager's own arguments. Point them at your own with
  # `inputs.everyscreen.inputs.nixpkgs.follows` to avoid fetching them.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    homeModules = rec {
      everyscreen = ./module.nix;
      default = everyscreen;
    };

    checks.${system}.vm = import ./tests/vm {
      inherit pkgs home-manager;
      inherit (self.homeModules) everyscreen;
    };

    formatter.${system} = pkgs.alejandra;
  };
}
