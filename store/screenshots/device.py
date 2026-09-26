#!/usr/bin/env python3
"""Small helpers `capture.sh` calls, kept out of shell heredocs.

    device.py simulator-udid "<simulator name>"      the udid of that simulator, oldest runtime first
    device.py hostkeys <hostkeys dir> <ssh host>     `host|port|type|base64 blob` entries, `;`-joined
"""
import json
import os
import subprocess
import sys


def simulator_udid(name: str) -> str:
    listed = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"], capture_output=True)
    devices = json.loads(listed.stdout)["devices"]
    # Oldest runtime first: the newest runtimes put the session in a windowed mode where teardown stalls.
    for runtime in sorted(devices):
        for device in devices[runtime]:
            if device["name"] == name:
                return device["udid"]
    raise SystemExit(f"no available simulator named {name}")


def hostkeys(root: str, ssh_host: str) -> str:
    """The app trusts these before it dials, so no trust dialog interrupts a capture.

    The target container is dialed directly, the bastion as the first hop of build-server, and the target
    again by its name inside the Docker network.
    """
    entries: list[str] = []

    def add(host: str, port: int, machine: str) -> None:
        for kind in ("ed25519", "ecdsa", "rsa"):
            path = os.path.join(root, machine, f"ssh_host_{kind}_key.pub")
            if not os.path.exists(path):
                continue
            fields = open(path).read().split()
            entries.append(f"{host}|{port}|{fields[0]}|{fields[1]}")

    add(ssh_host, 22221, "target")
    add(ssh_host, 22220, "bastion")
    add("target", 22, "target")
    return ";".join(entries)


if __name__ == "__main__":
    command, *arguments = sys.argv[1:]
    if command == "simulator-udid":
        print(simulator_udid(arguments[0]))
    elif command == "hostkeys":
        print(hostkeys(arguments[0], arguments[1]))
    else:
        raise SystemExit(f"usage: device.py simulator-udid|hostkeys … (got {command})")
