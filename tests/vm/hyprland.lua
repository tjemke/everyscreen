-- The least Hyprland config that uses everyscreen: a catch-all for any output
-- the layout does not name, then the generated layout. pcall, so Hyprland
-- still starts where the file is missing (the test's control case).
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
pcall(require, "screen-layout")
