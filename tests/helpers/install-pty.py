#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 tests/helpers/install-pty.py PROJECT SCRATCH ARCHIVE CASE
"""Drive real terminal input, never pretend piped stdin is a TTY."""
import errno
from enum import StrEnum
import json
import os
from pathlib import Path
import pty
import select
import signal
import sys
import tempfile
import time
from typing import assert_never


class Scenario(StrEnum):
    ALL = "all"
    HAPPY = "interactive-defaults-and-overrides"
    CANCEL = "cancellation-and-noninteractive-errors"


def dialogue(arguments: list[str], replies: list[tuple[bytes, bytes]]) -> tuple[int, bytes]:
    """Drive a bounded PTY and always reap its child, including assertion failures."""
    pid, descriptor = pty.fork()
    if pid == 0:
        os.execvpe("bash", ["bash", *arguments], os.environ)
    output = bytearray()
    position = 0
    deadline = time.monotonic() + 90
    reaped = False
    try:
        for token, response in replies:
            while output.find(token, position) < 0:
                assert time.monotonic() < deadline, "PTY prompt deadline exceeded"
                ready, _, _ = select.select([descriptor], [], [], 1)
                if ready:
                    output.extend(os.read(descriptor, 65536))
            position = output.index(token, position) + len(token)
            os.write(descriptor, response)
        while True:
            assert time.monotonic() < deadline, "PTY completion deadline exceeded"
            ready, _, _ = select.select([descriptor], [], [], 1)
            if ready:
                try:
                    chunk = os.read(descriptor, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output.extend(chunk)
        _, status = os.waitpid(pid, 0)
        reaped = True
        return os.waitstatus_to_exitcode(status), bytes(output)
    finally:
        if not reaped:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(descriptor)


def main() -> None:
    """Exercise user-visible outcomes, retaining no raw credentials in output."""
    project, scratch, archive, raw_scenario = sys.argv[1:]
    scenario = Scenario(raw_scenario)
    match scenario:
        case Scenario.ALL:
            run_happy, run_negative = True, True
        case Scenario.HAPPY:
            run_happy, run_negative = True, False
        case Scenario.CANCEL:
            run_happy, run_negative = False, True
        case unreachable:
            assert_never(unreachable)

    def command() -> tuple[Path, list[str]]:
        root = Path(tempfile.mkdtemp(prefix="pty-root.", dir=scratch))
        return root, [f"{project}/install.sh", "--no-service", "--root", str(root),
                      "--endpoint", "203.0.113.7", "--archive", archive]

    if run_happy:
        root, arguments = command()
        code, _ = dialogue(arguments, [(b"Xray TCP port", b"\n"), (b"REALITY SNI", b"\n"),
                                      (b"First client name", b"\n")])
        assert code == 0, "interactive defaults failed"
        state = json.loads((root / "etc/xray-vps-kit/state.json").read_text())
        assert state["port"] == 443 and state["target"] == "github.com:443"
        assert [client["name"] for client in state["clients"]] == ["main-user"]
        root, arguments = command()
        arguments += ["--port", "8443", "--server-name", "github.com", "--first-client", "tablet"]
        code, output = dialogue(arguments, [])
        assert code == 0 and b"Xray TCP port [" not in output and b"First client name [" not in output
        state = json.loads((root / "etc/xray-vps-kit/state.json").read_text())
        assert state["port"] == 8443 and state["target"] == "github.com:443"
        assert [client["name"] for client in state["clients"]] == ["tablet"]
        root, arguments = command()
        code, output = dialogue(arguments + ["--port", "8443"], [(b"REALITY SNI", b"\n"),
                                (b"First client name", b"reader\n")])
        assert code == 0 and b"Xray TCP port [" not in output
        state = json.loads((root / "etc/xray-vps-kit/state.json").read_text())
        assert state["port"] == 8443 and state["clients"][0]["name"] == "reader"
        root, arguments = command()
        code, output = dialogue(arguments + ["--no-first-client"], [(b"Xray TCP port", b"\n"),
                               (b"REALITY SNI", b"\n")])
        assert code == 0 and b"First client name [" not in output
        state = json.loads((root / "etc/xray-vps-kit/state.json").read_text())
        assert state["clients"] == []
    if run_negative:
        root, arguments = command()
        code, _ = dialogue(arguments, [(b"Xray TCP port", b"\n"), (b"REALITY SNI", b"\n"),
                                      (b"First client name", b"\x03")])
        assert code != 0 and not list(root.iterdir()), "interrupt at the last prompt mutated the root"
        root, arguments = command()
        code, _ = dialogue(arguments, [(b"Xray TCP port", b"\x04")])
        assert code != 0 and not list(root.iterdir()), "EOF mutated the root"
        root, arguments = command()
        code, _ = dialogue(arguments, [(b"Xray TCP port", b"\x03")])
        assert code != 0 and not list(root.iterdir()), "interrupt mutated the root"
        root, arguments = command()
        code, _ = dialogue(arguments, [(b"Xray TCP port", b"0\n"), (b"Xray TCP port", b"8443\n"),
                                      (b"REALITY SNI", b"bad/host\n"), (b"REALITY SNI", b"github.com\n"),
                                      (b"First client name", b"../bad\n"), (b"First client name", b"reader\n")])
        assert code == 0, "invalid/retry flow failed"
        state = json.loads((root / "etc/xray-vps-kit/state.json").read_text())
        assert state["port"] == 8443 and state["clients"][0]["name"] == "reader"


if __name__ == "__main__":
    main()
