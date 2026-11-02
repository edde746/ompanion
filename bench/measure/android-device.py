#!/usr/bin/env python3
"""Device side of startup-measure.sh android. Runs on studio.local under a devpool lease of the Pixel 7 on air.local
($ANDROID_SERIAL), in the stage directory, next to apk/. adb runs on air.local over one shared ssh connection. Every
time stamp it records is the phone's wall clock (CLOCK_REALTIME), as the app's epochMs are.

  android-device.py startup <rounds> <out> launch to first frame (docs/research/web-ui/startup.md): the first launch
                                           of the web app after install, then <rounds> cold starts

The package must not be on the phone before: a pre-existing install is never touched (exit 1). Everything this
installs is uninstalled, and the stay-awake setting is restored, on every exit path.
"""
import json
import os
import queue
import re
import shlex
import subprocess
import sys
import threading
import time

AIR = "air.local"
ADB = "~/Library/Android/sdk/platform-tools/adb"
SERIAL = os.environ["ANDROID_SERIAL"]
CTL = f"/tmp/ompanion-measure-{os.getpid()}.ssh"
SSH = ["ssh", "-o", "ControlMaster=auto", "-o", f"ControlPath={CTL}", "-o", "ControlPersist=600", AIR]
SETTLE_S = 3  # after force-stop, before a launch
# A startup run keeps the app this long after its first frame, as a user's session would: Chromium commits
# localStorage 5 s after a write, and the web app keeps its first frame there for the next launch.
STAY_S = 7

APPS = {
    # Its first frame is in the shell's `shell timing` line (docs/contracts/bridge.md), logged on every launch.
    "web": {"pkg": "com.edde746.ompanion", "apk": "apk/web.apk", "tag": "OmpanionShell", "extra": ""},
}
PACKAGES = sorted({a["pkg"] for a in APPS.values()})


def adb_argv(*args):
    return SSH + [f"{ADB} -s {SERIAL} " + " ".join(shlex.quote(a) for a in args)]


def adb(*args, input=None, check=True, timeout=180):
    r = subprocess.run(adb_argv(*args), input=input, capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"adb {' '.join(args)}: exit {r.returncode}: {r.stderr.strip()}")
    return r.stdout


def sh(cmd, **kw):
    return adb("shell", cmd, **kw)


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=1)


# --- the phone's state -------------------------------------------------------------------------------------------

def device_state():
    """Battery, thermal state, display mode and load: recorded at the start and the end of a session."""
    text = sh(
        "echo '## date'; date +%s%3N; echo '## loadavg'; cat /proc/loadavg; echo '## uptime'; cat /proc/uptime; "
        "echo '## battery'; dumpsys battery; "
        "echo '## thermal'; dumpsys thermalservice | sed -n '1,/^HAL Ready/p' | head -40; "
        "echo '## display'; dumpsys display | grep -E 'mActiveSfDisplayMode|mActiveRenderFrameRate|mUserPreferredModeId' | head -6; "
        "echo '## refresh settings'; settings get system peak_refresh_rate; settings get system min_refresh_rate; "
        "echo '## surfaceflinger'; dumpsys SurfaceFlinger | grep -E 'refresh-rate|^Display .* modes|activeMode' | head -6; "
        "echo '## stay_on_while_plugged_in'; settings get global stay_on_while_plugged_in; "
        "echo '## power'; dumpsys power | grep -E 'mWakefulness=|mStayOn=' | head -2"
    )
    studio = subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()
    battery = dict(re.findall(r"^\s+(level|temperature|status|plugged|AC powered|USB powered): (\S+)", text, re.M))
    thermal = re.search(r"Thermal Status: (\d+)", text)
    return {
        "deviceEpochMs": int(text.split("## date\n")[1].split()[0]),
        "batteryLevel": int(battery.get("level", -1)),
        "batteryTempC": int(battery.get("temperature", 0)) / 10,
        "batteryStatus": battery.get("status"),
        "usbPowered": battery.get("USB powered"),
        "thermalStatus": int(thermal.group(1)) if thermal else None,
        "studioLoadavg": studio,
        "raw": text,
    }


def device_info():
    text = sh(
        "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.id; uname -r; "
        "perfetto --version 2>&1 | head -1; "
        "dumpsys webviewupdate | sed -n 's/.*Current WebView package (name, version): (\\(.*\\))/\\1/p'"
    ).splitlines()
    return dict(zip(["model", "android", "build", "kernel", "perfetto", "webview"], text))


# --- launch ---------------------------------------------------------------------------------------------------------

def am_start(pkg, extra):
    """Starts the app cold; returns the phone's clock just before `am start` (ms) and am's report."""
    out = sh(f"date +%s%3N; am start -W -n {pkg}/.MainActivity {extra}")
    lines = out.splitlines()
    report = dict(re.findall(r"^(\w+): (.*)$", out, re.M))
    return int(lines[0]), {
        "totalTimeMs": int(report["TotalTime"]) if "TotalTime" in report else None,
        "waitTimeMs": int(report["WaitTime"]) if "WaitTime" in report else None,
        "launchState": report.get("LaunchState"),
        "status": report.get("Status"),
        "raw": out,
    }


def force_stop(pkg):
    sh(f"am force-stop {pkg}")


class Markers:
    """Follows logcat for an app's BENCH lines from before its launch. The phone-side logcat is killed by its pid: a
    remote command without a tty outlives its ssh session."""

    def __init__(self, tag):
        self.events = queue.Queue()
        self.device_pid = None
        attached = threading.Event()
        self.proc = subprocess.Popen(
            adb_argv("shell", f"echo PID $$; exec logcat -v raw -T 1 -s {tag}:I"),
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        threading.Thread(target=self._read, args=(attached,), daemon=True).start()
        attached.wait(15)
        time.sleep(0.5)  # logcat itself attached

    def _read(self, attached):
        for line in self.proc.stdout:
            if self.device_pid is None and line.startswith("PID "):
                self.device_pid = int(line.split()[1])
                attached.set()
                continue
            m = re.search(r"BENCH (\{.*\})\s*$", line)
            timing = re.search(r"shell timing (\{.*\})\s*$", line)
            try:
                if m:
                    event = json.loads(m.group(1))
                elif timing:
                    stages = json.loads(timing.group(1))
                    event = {"event": "first-frame", "epochMs": stages["processStartEpochMs"] + stages["firstFrameMs"],
                             "timing": stages}
                else:
                    continue
            except json.JSONDecodeError:
                continue
            event["receivedAt"] = time.time()
            self.events.put(event)

    def stop(self):
        if self.device_pid:
            sh(f"kill {self.device_pid}", check=False)
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()


# --- sessions --------------------------------------------------------------------------------------------------------

class Session:
    """Owns the phone for one devpool lease: refuses pre-existing installs, keeps the screen on, cleans up."""

    def __init__(self, out):
        self.out = out
        self.installed = []
        os.makedirs(out, exist_ok=True)

    def __enter__(self):
        present = [p for p in PACKAGES if "package:" in sh(f"pm path {p}", check=False)]
        if present:
            log(f"already installed on {SERIAL}, not touching the phone: {' '.join(present)}")
            sys.exit(1)
        self.stay_on = sh("settings get global stay_on_while_plugged_in").strip()
        self.info = device_info()
        log("device", json.dumps(self.info))
        self.state_start = device_state()
        log("state at start", json.dumps({k: v for k, v in self.state_start.items() if k != "raw"}))
        sh("settings put global stay_on_while_plugged_in 7; input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard")
        return self

    def install(self, name):
        app = APPS[name]
        remote = f"/tmp/ompanion-measure-{SERIAL}-{name}.apk"
        subprocess.run(["scp", "-q", app["apk"], f"{AIR}:{remote}"], check=True)
        if app["pkg"] not in self.installed:
            self.installed.append(app["pkg"])
        adb("install", remote)
        subprocess.run(SSH + [f"rm -f {remote}"], check=True)
        log("installed", name, app["pkg"])

    def uninstall(self, pkg):
        if "package:" in sh(f"pm path {pkg}", check=False):
            adb("uninstall", pkg, check=False)
        if pkg in self.installed:
            self.installed.remove(pkg)

    def __exit__(self, *exc):
        for pkg in list(self.installed):
            self.uninstall(pkg)
        self.state_end = device_state()
        sh(f"settings put global stay_on_while_plugged_in {self.stay_on}")
        left = [p for p in PACKAGES if "package:" in sh(f"pm path {p}", check=False)]
        restored = sh("settings get global stay_on_while_plugged_in").strip()
        log("state at end", json.dumps({k: v for k, v in self.state_end.items() if k != "raw"}))
        log(f"cleanup: packages left {left or 'none'}; stay_on_while_plugged_in {restored} (was {self.stay_on})")
        write_json(f"{self.out}/session.json", {
            "info": self.info, "stateStart": self.state_start, "stateEnd": self.state_end,
            "stayOnBefore": self.stay_on, "stayOnAfter": restored, "packagesLeft": left,
        })
        subprocess.run(SSH[:-1] + ["-O", "exit", AIR], capture_output=True)


def cold_start(name, label, out, stay_s=0):
    """A cold `am start -W` after force-stop; the app runs until its first-frame line, then `stay_s`."""
    app = APPS[name]
    pkg = app["pkg"]
    force_stop(pkg)
    time.sleep(SETTLE_S)
    markers = Markers(app["tag"])
    started_ms, am = am_start(pkg, app["extra"])
    first = None
    deadline = time.time() + 30
    while first is None and time.time() < deadline:
        try:
            event = markers.events.get(timeout=1)
        except queue.Empty:
            continue
        if event["event"] == "first-frame" and event["epochMs"] >= started_ms:
            first = event
    markers.stop()
    time.sleep(stay_s)
    force_stop(pkg)
    result = {"app": name, "label": label, "amStartEpochMs": started_ms, "am": am, "firstFrame": first}
    write_json(f"{out}/{label}.json", result)
    log(label, f"TotalTime {am['totalTimeMs']} ms, {am['launchState']}",
        f"first-frame +{first['epochMs'] - started_ms} ms" if first else "")


def startup(rounds, out):
    with Session(out) as s:
        s.install("web")
        cold_start("web", "first-web", out, STAY_S)  # the first launch after install, reported apart
        for r in range(1, rounds + 1):
            cold_start("web", f"cold-web-{r}", out, STAY_S)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "startup":
        startup(int(sys.argv[2]), sys.argv[3])
    else:
        sys.exit(__doc__)
