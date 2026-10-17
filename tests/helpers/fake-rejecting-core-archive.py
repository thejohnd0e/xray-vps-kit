#!/usr/bin/env python3
"""Build a test-only archive whose version matches but config test fails."""
import stat
import sys
import zipfile

if len(sys.argv) != 2:
    raise SystemExit("usage: fake-rejecting-core-archive.py OUTPUT.zip")

archive = sys.argv[1]
entries = {
    "xray": b"#!/usr/bin/env bash\nif [[ ${1:-} == version ]]; then printf 'Xray 26.3.27 test\\n'; exit 0; fi\nexit 2\n",
    "LICENSE": b"test-only fake core license\n",
}
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
    for name, contents in entries.items():
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        mode = 0o755 if name == "xray" else 0o644
        info.external_attr = (stat.S_IFREG | mode) << 16
        bundle.writestr(info, contents)
