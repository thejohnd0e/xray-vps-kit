#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 tests/helpers/test-port-preflight.py PROJECT
"""Exercise real TCP-vs-UDP visibility without privileged ports or host rules."""
import errno
import socket
import subprocess
import sys


def main() -> None:
    """UDP alone is allowed; a real TCP listener on that port is a conflict."""
    project = sys.argv[1]
    script = 'source "$1/lib/common.sh"; source "$1/lib/preflight.sh"; xvk_port_free "$2"'
    for _ in range(8):
        with socket.socket() as tcp, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            tcp.bind(("127.0.0.1", 0))
            port = tcp.getsockname()[1]
            try:
                udp.bind(("127.0.0.1", port))
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    raise
                continue
            command = ["bash", "-c", script, "bash", project, str(port)]
            assert subprocess.run(command, check=False, timeout=5).returncode == 0, "UDP incorrectly blocks TCP installation"
            tcp.listen()
            assert subprocess.run(command, check=False, timeout=5).returncode != 0, "TCP conflict was missed"
            return
    raise SystemExit("Unable to reserve an isolated TCP/UDP test port pair")


if __name__ == "__main__":
    main()
