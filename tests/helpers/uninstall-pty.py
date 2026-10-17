#!/usr/bin/env python3
# Run: python3 tests/helpers/uninstall-pty.py PROJECT ROOT REPLY
"""Answer the real uninstall confirmation on a PTY; print the child's exit status."""
import errno
import os
import pty
import select
import signal
import sys
import time

PROMPT = b"Proceed with uninstall? [y/N]: "


def main(project: str, root: str, reply: str) -> int:
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", f"{project}/uninstall.sh", "--root", root])
    output = bytearray()
    deadline = time.monotonic() + 60
    answered = False
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([descriptor], [], [], 1)
            if not ready:
                continue
            try:
                chunk = os.read(descriptor, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                break
            if not chunk:
                break
            output.extend(chunk)
            if not answered and PROMPT in output:
                os.write(descriptor, reply.encode() + b"\n")
                answered = True
        else:
            os.kill(pid, signal.SIGKILL)
            raise TimeoutError("uninstall PTY deadline exceeded")
    finally:
        _, status = os.waitpid(pid, 0)
    if not answered:
        return 99
    print(os.waitstatus_to_exitcode(status))
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
