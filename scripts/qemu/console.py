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


PROMPT = re.compile(rb"(login:|[#$] )\s*$")


def log_in(s):
    """Gets the console to a shell prompt, interrupting whatever holds it.

    Returns True when a prompt was reached.

    The interrupt is the point. A command left running in the guest owns
    this console, and a caller that sends its own command anyway is feeding
    it to that process's stdin and will then wait the full timeout for a
    marker that cannot arrive. One stuck command used to cost every later
    one its whole timeout; now it costs the seconds spent getting the
    prompt back.
    """
    for attempt in range(3):
        s.sendall(b"\x03" if attempt else b"\n")
        _, hit = read_until(s, PROMPT, 20)
        if hit is None:
            continue
        if b"login:" in hit.group(0):
            s.sendall(b"root\n")
            _, hit = read_until(s, re.compile(rb"[#$] \s*$"), 30)
            if hit is None:
                continue
        return True
    return False


def run(command):
    tag = uuid.uuid4().hex[:10]
    begin, end = f"B{tag}", f"E{tag}"
    payload = base64.b64encode(
        f"echo {begin}\n{command}\n__rc=$?\necho {end}:$__rc\n".encode()
    ).decode()

    s = connect(time.time() + 60)
    if not log_in(s):
        print("the guest console did not come back to a prompt; something"
              " is still running there", file=sys.stderr)
        return 1
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
    _, hit = read_until(s, PROMPT, 180)
    return 0 if hit else 1


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "wait":
        sys.exit(wait_for_boot())
    if len(sys.argv) >= 3 and sys.argv[1] == "exec":
        sys.exit(run(" ".join(sys.argv[2:])))
    print("usage: console.py {wait|exec <command>}", file=sys.stderr)
    sys.exit(2)


main()
