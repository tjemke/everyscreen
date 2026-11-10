{
  description = "One monitor layout, written for KWin, GNOME, niri and Hyprland";

  outputs = _: {
    homeModules = rec {
      everyscreen = ./module.nix;
      default = everyscreen;
    };
  };
}
