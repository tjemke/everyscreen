# Shared helpers, prepended to every script.
import json
import os
import re
import shlex
import time

# The driver runs this script on the build host, next to QEMU. In Nix's build
# sandbox it sees only its inputs from the store, never /nix/var/nix; outside
# the sandbox it, QEMU and the VM's disk image would have the host's whole
# filesystem and network. Refuse rather than run there.
if os.path.exists("/nix/var/nix"):
    raise Exception(
        "everyscreen's VM test runs only inside Nix's build sandbox, and this build can see the host "
        "(/nix/var/nix exists). Enable `sandbox = true` in nix.conf."
    )

USER_ENV = "XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
CONN = "/sys/kernel/config/vkms/desk/connectors"
POLL = 2  # seconds between looks at the layout

# What ./layout.nix prescribes, in logical pixels:
# left is 1920x1080 rotated, the TV 3840x2160 at scale 1.5.
EXPECT = {
    "DP-2": (0, 0, 1080, 1920),
    "DP-1": (1080, 412, 1920, 1080),
    "HDMI-A-1": (3000, 300, 2560, 1440),
}
TWO = {k: v for k, v in EXPECT.items() if k != "HDMI-A-1"}
results = []


def check(label, ok, detail=""):
    results.append((label, ok, detail))
    print(("PASS " if ok else "FAIL ") + label + (f"  [{detail}]" if detail else ""))


def as_user(cmd, check_rc=True):
    full = f"su - alice -c {shlex.quote('export ' + USER_ENV + '; ' + cmd)}"
    if check_rc:
        return machine.succeed(full)
    return machine.execute(full)[1]


def start_session(name, cmd):
    machine.succeed("chvt 7")
    machine.succeed(
        f"systemd-run --unit=sess-{name} -p PAMName=login -p User=alice "
        "-p TTYPath=/dev/tty7 -p StandardInput=tty -p StandardOutput=journal "
        "-p StandardError=journal -p TTYReset=yes -p TTYVHangup=yes "
        f"/run/current-system/sw/bin/bash -lc {shlex.quote('exec ' + cmd)}"
    )


def logged_out():
    """End alice's sessions and wait until nothing of hers is left running.
    The next session must not find the last one's sockets."""
    machine.execute("loginctl terminate-user alice")
    machine.wait_until_succeeds("! pgrep -u alice && ! test -e /run/user/1000", timeout=120)


def stop_session(name):
    machine.execute(f"systemctl stop sess-{name}")
    machine.wait_until_succeeds(f"! systemctl is-active sess-{name}", timeout=120)
    machine.execute(f"systemctl reset-failed sess-{name}")
    logged_out()


def plug(tv):
    machine.succeed(f"echo {1 if tv else 2} > {CONN}/connector2/status")


def logical_outputs():
    """name -> (x, y, w, h) from xdg-output, as any Wayland client sees it;
    empty while no compositor answers."""
    rc, out = machine.execute(
        "su - alice -c "
        + shlex.quote(
            f"export {USER_ENV}; WAYLAND_DISPLAY=wayland-1 wayland-info 2>/dev/null || WAYLAND_DISPLAY=wayland-0 wayland-info"
        )
    )
    res = {}
    for m in re.finditer(
        r"name: '([^']+)'.*?logical_x: (-?\d+), logical_y: (-?\d+).*?logical_width: (\d+), logical_height: (\d+)",
        out,
        re.S,
    ):
        res[m.group(1)] = tuple(int(m.group(i)) for i in range(2, 6))
    return res


def poll(done, timeout):
    """Look at the layout every POLL seconds until done(layout), or give up
    after timeout seconds; either way return the last layout seen. Waiting on
    the layout itself, not a fixed time, keeps a fast run fast and a slow one
    (no KVM: QEMU emulates the CPU) from reading a layout before it is
    applied."""
    end = time.monotonic() + timeout
    while True:
        got = logical_outputs()
        if done(got) or time.monotonic() > end:
            return got
        time.sleep(POLL)


def check_geometry(session, expect, timeout=180):
    """Wait for exactly this layout, then record a check per output."""
    got = poll(lambda g: g == expect, timeout)
    for name, want in expect.items():
        check(f"{session}: {name} logical geometry", got.get(name) == want, f"want {want}, got {got.get(name)}")
    extra = set(got) - set(expect)
    check(f"{session}: no unexpected outputs", not extra, f"extra {sorted(extra)}")
    return got


def check_control(label, expect, timeout=180):
    """The control for a check_geometry: with everyscreen's file out of the
    way, the same outputs have to come up and settle on a different layout.
    Without the first condition a compositor that showed nothing yet would
    pass."""
    seen = []

    def settled(g):
        seen.append(g)
        # The same layout three looks in a row, with every output there.
        return set(g) == set(expect) and len(seen) >= 3 and seen[-1] == seen[-2] == seen[-3]

    got = poll(settled, timeout)
    check(f"{label}: the same outputs are up", set(got) == set(expect), f"want {sorted(expect)}, got {sorted(got)}")
    check(f"{label}: without the file the layout differs", set(got) == set(expect) and got != expect, str(got))


# Failures tolerated because they look like the compositor's, not everyscreen's.
KNOWN = {
    # Hyprland 0.55 on vkms never brings an output back after a replug, though
    # the kernel shows it connected again and KWin, Mutter and niri all take it
    # back. Not confirmed on real hardware.
    "Hyprland, TV plugged back: HDMI-A-1 logical geometry",
}


def summary():
    """Print every check, then fail the test on any failure not in KNOWN."""
    print("\n===== SUMMARY =====")
    for label, ok, detail in results:
        tag = "PASS " if ok else ("XFAIL " if label in KNOWN else "FAIL ")
        print(tag + label + (f"  [{detail}]" if detail else ""))
    fails = [r for r in results if not r[1] and r[0] not in KNOWN]
    xfails = [r for r in results if not r[1] and r[0] in KNOWN]
    for label in KNOWN & {r[0] for r in results if r[1]}:
        print(f"note: known failure now passes, drop it from KNOWN: {label}")
    print(f"{len(results) - len(fails) - len(xfails)} passed, {len(xfails)} known failures, {len(fails)} failed")
    if fails:
        raise Exception(f"{len(fails)} checks failed")


def wait_up(name, probe, timeout=900):
    """Wait for the compositor's socket; give up at once if its unit died."""
    machine.wait_until_succeeds(f"{probe} || ! systemctl is-active -q sess-{name}", timeout=timeout)
    rc, _ = machine.execute(probe)
    if rc != 0:
        print(machine.execute(f"journalctl -u sess-{name} --no-pager | tail -40")[1])
        raise Exception(f"sess-{name} exited before it came up")
