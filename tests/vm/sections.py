TWO = {k: v for k, v in EXPECT.items() if k != "HDMI-A-1"}


def section(fn):
    try:
        fn()
    except Exception as e:  # keep going: one compositor must not hide the others
        check(f"{fn.__name__} ran to the end", False, repr(e)[:300])
        machine.execute("systemctl stop 'sess-*'; loginctl terminate-user alice")
        machine.sleep(5)
    plug(True)


def smoke():
    for conn, model in [("DP-1", "Example 24"), ("DP-2", "Example 22"), ("HDMI-A-1", "Example-TV")]:
        st = machine.succeed(f"cat /sys/class/drm/card*-{conn}/status").strip()
        name = machine.succeed(f"edid-decode /sys/class/drm/card*-{conn}/edid | grep 'Display Product Name'").strip()
        check(f"vkms: {conn} connected with the {model} EDID", st == "connected" and model in name, f"{st}; {name}")
    for f in ["kwinoutputconfig.json", "monitors.xml", "niri/screen-layout.kdl", "niri/config.kdl", "hypr/screen-layout.lua", "hypr/hyprland.lua"]:
        rc, _ = machine.execute(f"test -e /home/alice/.config/{f}")
        check(f"home-manager wrote ~/.config/{f}", rc == 0)


def kde():
    cfg = "/home/alice/.config/kwinoutputconfig.json"
    start_session("kwin", "kwin_wayland --drm --no-lockscreen")
    machine.wait_until_succeeds("test -S /run/user/1000/wayland-0", timeout=900)
    machine.sleep(20)
    check_geometry("KDE, TV on", EXPECT)

    raw = as_user("WAYLAND_DISPLAY=wayland-0 kscreen-doctor -j")
    print(raw)
    outs = {o["name"]: o for o in json.loads(raw)["outputs"]}
    want = {"DP-1": (1.0, 1, 1), "DP-2": (1.0, 2, 2), "HDMI-A-1": (1.5, 1, 3)}
    for name, (scale, rot, prio) in want.items():
        o = outs.get(name, {})
        mode = next((m for m in o.get("modes", []) if m.get("id") == o.get("currentModeId")), {})
        check(f"KDE: {name} scale {scale}", abs(o.get("scale", 0) - scale) < 1e-6, str(o.get("scale")))
        check(f"KDE: {name} rotation {rot}", o.get("rotation") == rot, str(o.get("rotation")))
        check(f"KDE: {name} priority {prio}", o.get("priority") == prio, str(o.get("priority")))
        check(f"KDE: {name} mode @60", abs(mode.get("refreshRate", 0) - 60) < 0.01, str(mode))

    plug(False)
    machine.sleep(20)
    check_geometry("KDE, TV unplugged (setup 1)", TWO)
    plug(True)
    machine.sleep(20)
    check_geometry("KDE, TV plugged back (setup 2)", EXPECT)

    print(machine.execute(f"ls -l {cfg}; journalctl -u sess-kwin --no-pager | grep -i -E 'output|config|kwinoutput' | tail -30")[1])
    stop_session("kwin")
    rc, _ = machine.execute(f"test -L {cfg}")
    check("KDE: kwinoutputconfig.json is still the store link after the session", rc == 0)

    # Control: without the file, KWin must lay the outputs out differently.
    machine.succeed(f"mv {cfg} {cfg}.off")
    start_session("kwin", "kwin_wayland --drm --no-lockscreen")
    machine.wait_until_succeeds("test -S /run/user/1000/wayland-0", timeout=900)
    machine.sleep(20)
    got = logical_outputs()
    check("KDE control: without the file the layout differs", got != EXPECT, str(got))
    stop_session("kwin")
    machine.succeed(f"rm -f {cfg}; mv {cfg}.off {cfg}")


def hyprland():
    start_session("hypr", "Hyprland")
    machine.wait_until_succeeds("ls /run/user/1000/hypr/*/.socket.sock", timeout=900)
    machine.sleep(15)
    hc = "hyprctl --instance 0"
    check_geometry("Hyprland, TV on", EXPECT)
    raw = as_user(f"{hc} -j monitors all")
    print(raw)
    mons = {m["name"]: m for m in json.loads(raw)}
    want = {"DP-1": (1.0, 0), "DP-2": (1.0, 1), "HDMI-A-1": (1.5, 0)}
    for name, (scale, tf) in want.items():
        m = mons.get(name, {})
        check(f"Hyprland: {name} scale {scale}", abs(m.get("scale", 0) - scale) < 1e-6, str(m.get("scale")))
        check(f"Hyprland: {name} transform {tf}", m.get("transform") == tf, str(m.get("transform")))
        check(f"Hyprland: {name} 60 Hz", abs(m.get("refreshRate", 0) - 60) < 0.01, str(m.get("refreshRate")))
    errs = as_user(f"{hc} -j configerrors")
    check("Hyprland: no config errors", json.loads(errs) in ([], [""]), errs.strip())
    log = as_user("cat /run/user/1000/hypr/*/hyprland.log", check_rc=False)
    bad = [l for l in log.splitlines() if re.search(r"Invalid scale|failed to find a clean divisor|hl\.monitor", l)]
    check("Hyprland: no scale or monitor-rule complaints in the log", not bad, " | ".join(bad)[:300])
    print("\n".join(l for l in log.splitlines() if re.search(r"(?i)hdr|cm |colou?r|10.?bit", l))[:3000])

    plug(False)
    machine.sleep(15)
    check_geometry("Hyprland, TV unplugged", TWO)
    plug(True)
    machine.sleep(15)
    check_geometry("Hyprland, TV plugged back", EXPECT)

    # Control: move the generated file away and reload.
    lua = "/home/alice/.config/hypr/screen-layout.lua"
    machine.succeed(f"mv {lua} {lua}.off")
    as_user(f"{hc} reload")
    machine.sleep(15)
    got = logical_outputs()
    check("Hyprland control: without the file the layout differs", got != EXPECT, str(got))
    machine.succeed(f"mv {lua}.off {lua}")
    stop_session("hypr")


def niri():
    start_session("niri", "niri")
    wait_up("niri", "ls /run/user/1000/niri.*.sock")
    machine.sleep(10)
    msg = "NIRI_SOCKET=$(ls /run/user/1000/niri.*.sock | head -1) niri msg"
    check_geometry("niri, TV on", EXPECT)
    raw = as_user(f"{msg} -j outputs")
    print(raw)
    outs = json.loads(raw)
    want = {"DP-1": (1.0, "Normal"), "DP-2": (1.0, "90"), "HDMI-A-1": (1.5, "Normal")}
    for name, (scale, tf) in want.items():
        o = outs.get(name, {})
        lg = o.get("logical") or {}
        cur = o.get("current_mode")
        mode = o.get("modes", [])[cur] if cur is not None else {}
        check(f"niri: {name} scale {scale}", abs(lg.get("scale", 0) - scale) < 1e-6, str(lg.get("scale")))
        check(f"niri: {name} transform {tf}", lg.get("transform") == tf, str(lg.get("transform")))
        check(f"niri: {name} 60.000 Hz", mode.get("refresh_rate") == 60000, str(mode))
    focused = json.loads(as_user(f"{msg} -j focused-output"))
    check("niri: focus starts on the primary (DP-1)", focused.get("name") == "DP-1", str(focused.get("name")))
    log = machine.execute("journalctl -u sess-niri --no-pager")[1]
    bad = [l for l in log.splitlines() if re.search(r"(?i)error.*(config|output)|couldn't find mode", l)]
    check("niri: no config or mode errors in the log", not bad, " | ".join(bad)[:300])

    plug(False)
    machine.sleep(10)
    check_geometry("niri, TV unplugged", TWO)
    plug(True)
    machine.sleep(10)
    check_geometry("niri, TV plugged back", EXPECT)
    stop_session("niri")


def gnome():
    xml = "/home/alice/.config/monitors.xml"
    M3 = {("HDMI-1" if k == "HDMI-A-1" else k): v for k, v in EXPECT.items()}
    start_session("mutter", "gnome-shell --wayland --display-server --no-x11")
    wait_up("mutter", "test -S /run/user/1000/wayland-0")
    machine.sleep(20)
    check_geometry("GNOME, TV on", M3)
    raw = as_user("gdctl show --verbose", check_rc=False)
    print(raw)
    check("GNOME: DP-1 is primary", bool(re.search(r"(?s)Primary: yes.*?DP-1|DP-1.*?Primary: yes", raw)), "see gdctl output")
    log = machine.execute("journalctl -u sess-mutter --no-pager")[1]
    bad = [l for l in log.splitlines() if re.search(r"Failed to (use|read).*monitor|monitors\.xml|Scale not supported", l)]
    check("GNOME: Mutter accepted the stored configuration", not bad, " | ".join(bad)[:300])

    plug(False)
    machine.sleep(20)
    check_geometry("GNOME, TV unplugged (setup 1)", TWO)
    plug(True)
    machine.sleep(20)
    check_geometry("GNOME, TV plugged back (setup 2)", M3)
    stop_session("mutter")

    machine.succeed(f"mv {xml} {xml}.off")
    start_session("mutter", "gnome-shell --wayland --display-server --no-x11")
    wait_up("mutter", "test -S /run/user/1000/wayland-0")
    machine.sleep(20)
    got = logical_outputs()
    check("GNOME control: without the file the layout differs", got != M3, str(got))
    stop_session("mutter")
    machine.succeed(f"rm -f {xml}; mv {xml}.off {xml}")
