#!/usr/bin/env python3
"""Test-only core archive: version/config adapter, never a traffic fixture."""
import sys
import zipfile

output, version = sys.argv[1:3]
config_status = 1 if len(sys.argv) > 3 and sys.argv[3] == "reject" else 0
script = f'''#!/usr/bin/env bash
if [[ ${{1:-}} == version ]]; then printf 'Xray {version} (test fixture)\\n'; exit 0; fi
if [[ ${{1:-}} == uuid ]]; then cat /proc/sys/kernel/random/uuid; exit; fi
if [[ ${{1:-}} == run && ${{2:-}} == -test ]]; then exit {config_status}; fi
exit 1
'''
with zipfile.ZipFile(output, "w") as archive:
    for name, content in (("xray", script), ("LICENSE", "test fixture license\n")):
        entry = zipfile.ZipInfo(name)
        entry.create_system = 3
        entry.external_attr = 0o100755 << 16
        archive.writestr(entry, content)
