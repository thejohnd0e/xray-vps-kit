#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 tests/helpers/archive-fixture.py OUTPUT traversal|symlink|regular
"""Test-only malicious ZIP producer. Never used by production acquisition."""
from enum import StrEnum
import stat
import sys
from typing import assert_never
import zipfile


class ArchiveKind(StrEnum):
    TRAVERSAL = "traversal"
    SYMLINK = "symlink"
    REGULAR = "regular"


def main() -> None:
    """Generate a selected adversarial archive inside the caller's scratch."""
    output, raw_kind = sys.argv[1:]
    kind = ArchiveKind(raw_kind)
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr("xray", b"not executable")
        archive.writestr("LICENSE", b"test license")
        match kind:
            case ArchiveKind.TRAVERSAL:
                archive.writestr("../escaped", b"must not escape")
            case ArchiveKind.SYMLINK:
                link = zipfile.ZipInfo("README.md")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, "../../outside")
            case ArchiveKind.REGULAR:
                pass
            case unreachable:
                assert_never(unreachable)


if __name__ == "__main__":
    main()
