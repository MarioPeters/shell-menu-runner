#!/usr/bin/env python3
"""Minimal PTY driver for the Shell Menu Runner test suite.

The interactive paths (menu loop, dropdown, tag menu) need a real terminal —
"echo | run" does not cover them.  This driver runs a command in a pty and
feeds it a scripted input.

Usage: pty_driver.py <script-file> <command...>

The script file contains one directive per line:
  wait <seconds>      -> sleep
  send <literal>      -> write the literal string (\\x1b etc. are decoded)
  expect <substring>  -> read until the substring appears (or timeout)
"""
import os
import pty
import select
import sys
import time


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: pty_driver.py <script-file> <command...>\n")
        return 2

    with open(sys.argv[1], "rb") as fh:
        script = fh.read().decode("utf-8", "replace")
    cmd = sys.argv[2:]

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = os.environ.get("TERM", "xterm-256color")
        os.execvp(cmd[0], cmd)
        os._exit(127)

    out = bytearray()

    def pump(until=None, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if fd in r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                out.extend(data)
                if until and until.encode() in out:
                    return True
        return until is None

    for line in script.splitlines():
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        op, _, rest = line.partition(" ")
        if op == "wait":
            pump(None, float(rest))
        elif op == "send":
            payload = rest.encode("utf-8").decode("unicode_escape").encode("latin-1")
            try:
                os.write(fd, payload)
            except OSError:
                pass
            pump(None, 0.4)
        elif op == "expect":
            pump(rest, 10.0)

    try:
        os.close(fd)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
    except OSError:
        status = 0

    sys.stdout.write(out.decode("utf-8", "replace"))
    sys.stdout.write("\n[[exit status: %d]]\n" % (status >> 8))
    return 0


if __name__ == "__main__":
    sys.exit(main())
