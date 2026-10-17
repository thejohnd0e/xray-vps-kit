#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
# Run: python3 tests/helpers/uri-check.py STATE_FILE URI_FILE
"""Independent stdlib parser; never prints the URI or credential values."""
import json
from pathlib import Path
import sys
from urllib.parse import parse_qs, unquote, urlsplit


def main() -> None:
    """Check the public export against its ephemeral source state."""
    state_path, uri_path = map(Path, sys.argv[1:])
    state = json.loads(state_path.read_text(encoding="utf-8"))
    raw = uri_path.read_text(encoding="utf-8")
    assert raw.endswith("\n") and raw.count("\n") == 1, "one URI line required"
    uri = urlsplit(raw.rstrip("\n"))
    query = parse_qs(uri.query, strict_parsing=True)
    client = state["clients"][0]
    expected = {
        "encryption": ["none"], "type": ["tcp"], "security": ["reality"],
        "flow": ["xtls-rprx-vision"], "sni": [state["serverName"]],
        "fp": ["chrome"], "pbk": [state["publicKey"]], "sid": [client["shortId"]],
    }
    assert uri.scheme == "vless", "wrong scheme"
    assert uri.hostname == state["endpoint"], "wrong endpoint"
    assert uri.port == state["port"], "wrong port"
    assert uri.username == client["uuid"], "wrong identity"
    assert unquote(uri.fragment) == client["name"], "wrong fragment"
    assert query == expected, "wrong query fields or duplicate parameters"
    assert state["privateKey"] not in raw, "private key leak"


if __name__ == "__main__":
    main()
