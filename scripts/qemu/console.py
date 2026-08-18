#!/usr/bin/env python3
"""Drives the test guest over its serial console.

The guest is a Debian nocloud image, which logs root in on the console with
no password. Commands are sent base64-encoded and evaluated, so the line the
shell echoes back contains neither the command text nor the framing markers,
and the output between them is exactly what the command produced.

A serial console is a coarse instrument, but it needs nothing installed in
the guest and no network, which makes the harness work on a fresh image with
no provisioning step at all.
"""
import base64
import os
import re
import socket
import sys
import time
import uuid

SOCKET = os.environ.get("FLYOLOGY_DEVICE_VM_CONSOLE",
                        "/tmp/flyology-device-vm/console.sock")
#  A command that hangs should say so in a minute or two, not in a quarter
#  of an hour. QEMU's console socket accepts one client at a time, so a
#  process still waiting on it blocks every later command; a short default
#  keeps one stuck command from wedging the whole harness.
TIMEOUT = float(os.environ.get("FLYOLOGY_DEVICE_VM_TIMEOUT", "120"))
ANSI = re.compile(rb"\x1b\[[0-9;?]*[a-zA-Z]")


def connect(deadline):
    """Waits for QEMU to create the console socket, then connects."""
    while time.time() < deadline:
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(SOCKET)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.5)
    raise SystemExit(f"no console at {SOCKET} after waiting")


def read_until(s, pattern, timeout):
    buf, end = b"", time.time() + timeout
    s.settimeout(1.0)
    while time.time() < end:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf += chunk
        match = pattern.search(ANSI.sub(b"", buf))
        if match:
            return ANSI.sub(b"", buf), match
    return ANSI.sub(b"", buf), None


def log_in(s):
    """Gets the console to a shell prompt, logging in if it is at login."""
    s.sendall(b"\n")
    _, hit = read_until(s, re.compile(rb"(login:|[#$] )\s*$"), 20)
    if hit and b"login:" in hit.group(0):
        s.sendall(b"root\n")
        read_until(s, re.compile(rb"[#$] \s*$"), 30)


def run(command):
    tag = uuid.uuid4().hex[:10]
    begin, end = f"B{tag}", f"E{tag}"
    payload = base64.b64encode(
        f"echo {begin}\n{command}\n__rc=$?\necho {end}:$__rc\n".encode()
    ).decode()

    s = connect(time.time() + 60)
    log_in(s)
    s.sendall(f'eval "$(echo {payload} | base64 -d)"\n'.encode())

    buf, hit = read_until(s, re.compile(end.encode() + rb":(\d+)"), TIMEOUT)
    text = buf.decode("utf-8", "replace").replace("\r", "")
    if begin in text:
        text = text.split(begin, 1)[1].lstrip("\n")
    print(text.split(end + ":")[0].rstrip("\n"))

    if not hit:
        print("the guest did not finish within the timeout", file=sys.stderr)
        return 1
    return int(hit.group(1))


def wait_for_boot():
    s = connect(time.time() + 180)
    _, hit = read_until(s, re.compile(rb"(login:|[#$] )\s*$"), 180)
    return 0 if hit else 1


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "wait":
        sys.exit(wait_for_boot())
    if len(sys.argv) >= 3 and sys.argv[1] == "exec":
        sys.exit(run(" ".join(sys.argv[2:])))
    print("usage: console.py {wait|exec <command>}", file=sys.stderr)
    sys.exit(2)


main()
