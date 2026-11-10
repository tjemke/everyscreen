# The test's desk: a portrait monitor on the left, the main one in the middle,
# and a 4K TV on the right, which is not always on. ./edid.py gives the
# virtual monitors these identities, which are made up.
#
# Shaped like what Plasma saves in ~/.config/kwinoutputconfig.json, plus the
# `gnome` strings GNOME saves in ~/.config/monitors.xml. The TV is at 1.5, not
# 1.45, which neither Mutter nor Hyprland can do at 3840x2160. The middle
# monitor sits where it would with the TV on (y = 412); niri and Hyprland have
# one position per monitor, not one per set.
{
  programs.everyscreen = {
    outputs = {
      left = {
        connector = "DP-2";
        edid = {
          vendor = "EXA";
          product = 4097;
          serial = 16843009;
          week = 10;
          year = 2019;
        };
        gnome = {
          product = "Example 22";
          serial = "EX22A0000001";
        };
        mode = {
          width = 1920;
          height = 1080;
          refresh = 60000;
        };
        transform = "90";
        position = {
          x = 0;
          y = 0;
        };
      };

      center = {
        connector = "DP-1";
        edid = {
          vendor = "EXA";
          product = 4098;
          serial = 16843009;
          week = 20;
          year = 2019;
        };
        gnome = {
          product = "Example 24";
          serial = "EX24A0000002";
        };
        mode = {
          width = 1920;
          height = 1080;
          refresh = 60000;
        };
        position = {
          x = 1080;
          y = 412;
        };
        primary = true;
      };

      tv = {
        connector = "HDMI-A-1";
        edid = {
          vendor = "EXT";
          product = 8193;
          serial = 16843009;
          week = 0;
          year = 2020;
        };
        # No serial string in the TV's EDID, so Mutter prints the number.
        gnome = {
          product = "Example-TV";
          serial = "0x01010101";
        };
        mode = {
          width = 3840;
          height = 2160;
          refresh = 60000;
        };
        scale = 1.5;
        position = {
          x = 3000;
          y = 300;
        };
        hdr = true;
        peakBrightness = 550;
        # Plasma's tuning, which has no counterpart in the other sessions.
        kwin = {
          sdrBrightness = 250;
          colorPowerTradeoff = "PreferAccuracy";
        };
      };
    };

    setups = [
      ["left" "center"]
      ["left" "center" "tv"]
    ];
  };
}
