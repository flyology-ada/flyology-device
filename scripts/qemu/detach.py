#!/usr/bin/env python3
"""Runs a command in a session of its own, and returns immediately.

setsid(1) does this on Linux and does not exist on macOS, which is a common
development host here. The call it wraps, setsid(2), is in every Unix, so
three lines of Python are more portable than the utility.

Detaching matters because the guest outlives the command that started it. A
guest in the launching shell's process group is killed by whatever kills
that shell — a timeout, a terminal closing, a CI step finishing — and the
next command then reports a guest that is not running, with nothing to say
why.
"""
import os
import sys

if len(sys.argv) < 2:
    print("usage: detach.py <command> [argument ...]", file=sys.stderr)
    sys.exit(2)

if os.fork() != 0:
    #  The parent returns at once; the guest is the caller's to stop later,
    #  through the pidfile, not this process.
    sys.exit(0)

os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
