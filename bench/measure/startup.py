#!/usr/bin/env python3
"""Launch to first frame of the web app on studio (docs/research/web-ui/startup.md), inside one devpool lease
(startup-measure.sh stages and drives it). Every time is studio's wall clock in ms, the clock the app's markers use.

  startup.py macos <rounds> <out dir>   one warm-up launch of each web build, then <rounds> rounds of every build in
                                        turn (apps/web, apps/web-<variant>)
  startup.py ios <rounds> <out dir>     the web app on the leased simulator ($DEVPOOL_SIM_UDID): warm-up, then <rounds>
  startup.py report <out dir>…          medians and ranges of those runs, as Markdown

A macOS launch is fork + exec of the app's binary; its first frame is the app's `shell timing` line on stderr
(docs/contracts/bridge.md: processStartEpochMs plus firstFrameMs). The app then gets SIGTERM, and the next launch waits
until its processes, WebKit's included, are gone. An iOS launch is `simctl launch`; the line comes through its console.
"""

import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time


def macos_apps():
    """Kind → binary: `web` and every `web-<variant>` staged in apps/."""
    webs = sorted(name for name in os.listdir('apps') if name == 'web' or name.startswith('web-'))
    return {kind: f'apps/{kind}/ompanion.app/Contents/MacOS/ompanion' for kind in webs}


IOS_APP, IOS_BUNDLE = 'apps/ios/ompanion.app', 'com.edde746.ompanion'
# What the macOS app keeps on studio under its id, the store app's: a run refuses to start when any of it is there
# (it would be a real user's), and removes what its launches created.
MACOS_DATA = [os.path.expanduser(f'~/Library/{place}/com.edde746.ompanion')
              for place in ('Application Support', 'Caches', 'WebKit', 'HTTPStorages')]
TIMEOUT_S = 20
SETTLE_S = 2  # after the app and its processes are gone, before the next launch
# How long an app runs after its first frame, as a user's session would: the engines commit localStorage a while
# after a write (Chromium 5 s), and the web app keeps its first frame there for the next launch.
STAY_S = 7

TIMING = re.compile(r'shell timing (\{.*\})')


def now_ms():
    return time.time() * 1000


def loadavg():
    return subprocess.run(['sysctl', '-n', 'vm.loadavg'], capture_output=True, text=True).stdout.strip()


def first_frame(text):
    """(epoch ms of the first frame, the shell timing line) from an app's output, or None."""
    for line in text.splitlines():
        m = TIMING.search(line)
        if m:
            timing = json.loads(m.group(1))
            return timing['processStartEpochMs'] + timing['firstFrameMs'], timing
    return None


def wait_for(path, deadline):
    while now_ms() < deadline:
        with open(path, errors='replace') as f:
            found = first_frame(f.read())
        if found:
            return found
        time.sleep(0.005)
    return None


def running_after(pids, deadline_s=10):
    """The pids still running after waiting up to deadline_s for all to exit."""
    end = time.time() + deadline_s
    while True:
        alive = []
        for pid in pids:
            try:
                os.kill(pid, 0)
                alive.append(pid)
            except ProcessLookupError:
                pass
        if not alive or time.time() > end:
            return alive
        time.sleep(0.05)


def app_services(pid):
    """Pids of the running XPC services in launchd's domain pid/<pid>: a WKWebView's WebContent, GPU and Networking."""
    out = subprocess.run(['launchctl', 'print', f'pid/{pid}'], capture_output=True, text=True).stdout
    pids, inside = [], False
    for line in out.splitlines():
        s = line.strip()
        if s == 'services = {':
            inside = True
        elif inside and s == '}':
            break
        elif inside:
            parts = s.split()  # "<pid or 0> <last exit status or -> <label>"
            if len(parts) >= 3 and parts[0].isdigit() and int(parts[0]) > 0:
                pids.append(int(parts[0]))
    return pids


def launch_macos(kind, binary, out, label):
    stdout, stderr = (os.path.join(out, f'{label}.{name}') for name in ('stdout', 'stderr'))
    env = {k: v for k, v in os.environ.items() if not k.startswith('OMPCORE_')}
    load = loadavg()
    with open(stdout, 'wb') as so, open(stderr, 'wb') as se:
        t0 = now_ms()  # immediately before fork + exec
        proc = subprocess.Popen([os.path.abspath(binary)], env=env, stdout=so, stderr=se, stdin=subprocess.DEVNULL)
    found = wait_for(stderr, t0 + TIMEOUT_S * 1000)
    time.sleep(STAY_S)
    helpers = app_services(proc.pid)
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    left = running_after(helpers)
    for pid in left:
        os.kill(pid, signal.SIGKILL)
    result = {'app': kind, 'label': label, 'launchEpochMs': round(t0, 3), 'loadavg': load, 'helpers': helpers,
              'helpersKilled': left}
    if found:
        result['firstFrameEpochMs'] = found[0]
        result['launchToFirstFrameMs'] = round(found[0] - t0, 1)
        result['timing'] = found[1]
    return result


def launch_ios(udid, out, label):
    console = os.path.join(out, f'{label}.console')
    load = loadavg()
    with open(console, 'wb') as f:
        t0 = now_ms()
        proc = subprocess.Popen(['xcrun', 'simctl', 'launch', '--console-pty', '--terminate-running-process', udid,
                                 IOS_BUNDLE], stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    found = wait_for(console, t0 + TIMEOUT_S * 1000)
    time.sleep(STAY_S)
    subprocess.run(['xcrun', 'simctl', 'terminate', udid, IOS_BUNDLE], capture_output=True)
    try:
        proc.wait(10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    result = {'app': 'web-ios', 'label': label, 'launchEpochMs': round(t0, 3), 'loadavg': load}
    if found:
        result['firstFrameEpochMs'] = found[0]
        result['launchToFirstFrameMs'] = round(found[0] - t0, 1)
        result['timing'] = found[1]
    return result


def record(out, result):
    with open(os.path.join(out, f"{result['label']}.json"), 'w') as f:
        json.dump(result, f, indent=1)
    timing = result.get('timing') or {}
    print(result['label'], result.get('launchToFirstFrameMs', 'no first frame'),
          'process start → first frame', timing.get('firstFrameMs', '—'), result['loadavg'], flush=True)


def macos(rounds, out):
    apps = macos_apps()
    present = [path for path in MACOS_DATA if os.path.exists(path)]
    if present or subprocess.run(['defaults', 'read', 'com.edde746.ompanion'], capture_output=True).returncode == 0:
        sys.exit(f'com.edde746.ompanion data is on this Mac ({present or "its defaults"}): not touching it')
    try:
        # The first launch of each creates its data (a returning user's state for the measured ones).
        for kind, binary in apps.items():
            record(out, launch_macos(kind, binary, out, f'warmup-{kind}'))
            time.sleep(SETTLE_S)
        for r in range(1, rounds + 1):
            for kind, binary in apps.items():
                record(out, launch_macos(kind, binary, out, f'{kind}-{r}'))
                time.sleep(SETTLE_S)
    finally:
        for path in MACOS_DATA:
            shutil.rmtree(path, ignore_errors=True)
        subprocess.run(['defaults', 'delete', 'com.edde746.ompanion'], capture_output=True)


def ios(rounds, out):
    udid = os.environ['DEVPOOL_SIM_UDID']
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, capture_output=True)
    subprocess.run(['xcrun', 'simctl', 'install', udid, IOS_APP], check=True)
    try:
        record(out, launch_ios(udid, out, 'warmup-web-ios'))
        time.sleep(SETTLE_S)
        for r in range(1, rounds + 1):
            record(out, launch_ios(udid, out, f'web-ios-{r}'))
            time.sleep(SETTLE_S)
    finally:
        subprocess.run(['xcrun', 'simctl', 'uninstall', udid, IOS_BUNDLE], check=True)


def summary(values):
    if not values:
        return '—'
    return f'{statistics.median(values):.0f} ({min(values):.0f}–{max(values):.0f})'


def load(path):
    """One run; an android-device.py cold start in this script's shape, its launch being `am start`."""
    with open(path) as f:
        run = json.load(f)
    if 'amStartEpochMs' not in run:
        return run
    first = run.get('firstFrame') or {}
    shaped = {'app': run['app'], 'totalTimeMs': run['am']['totalTimeMs'], 'timing': first.get('timing')}
    if first:
        shaped['launchToFirstFrameMs'] = first['epochMs'] - run['amStartEpochMs']
    return shaped


def report(dirs):
    for out in dirs:
        # Not the warm-up launches here, nor android-device.py's first launch after install.
        runs = [load(os.path.join(out, name)) for name in sorted(os.listdir(out))
                if name.endswith('.json') and name.startswith(('web', 'cold-'))]
        print(f'## {out}\n')
        print('|App|Runs|launch → first frame, ms|every run|`am start -W` TotalTime, ms|')
        print('|---|--:|--:|---|--:|')
        for app in sorted({r['app'] for r in runs}):
            mine = [r for r in runs if r['app'] == app]
            values = [r['launchToFirstFrameMs'] for r in mine if 'launchToFirstFrameMs' in r]
            total = [r['totalTimeMs'] for r in mine if r.get('totalTimeMs') is not None]
            print(f"|{app}|{len(mine)}|{summary(values)}|{', '.join(f'{v:.0f}' for v in values)}|{summary(total)}|")
        stages = {}
        for r in runs:
            for name, value in (r.get('timing') or {}).items():
                if name != 'processStartEpochMs':
                    stages.setdefault(r['app'], {}).setdefault(name, []).append(value)
        for app, by_stage in stages.items():
            print(f'\n{app}: ms since the process started, median (range)\n')
            print('|Stage|ms|')
            print('|---|--:|')
            for name, values in sorted(by_stage.items(), key=lambda item: statistics.median(item[1])):
                print(f'|{name}|{summary(values)}|')
        print()


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] in ('macos', 'ios'):
        os.makedirs(sys.argv[3], exist_ok=True)
        (macos if sys.argv[1] == 'macos' else ios)(int(sys.argv[2]), sys.argv[3])
    elif len(sys.argv) >= 3 and sys.argv[1] == 'report':
        report(sys.argv[2:])
    else:
        sys.exit(__doc__)
