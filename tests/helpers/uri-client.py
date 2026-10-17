#!/usr/bin/env python3
# Run: python3 tests/helpers/uri-client.py URI SOCKS_PORT [--uuid X] [--short-id X] [--public-key X]
"""Test adapter: turn an exported vless:// URI into an Xray client config.

Written independently of lib/render.sh so the export is consumed the way a real
client application would, not through the kit's own state. The overrides exist
only to build deliberately broken profiles for negative tests.
"""
import argparse
import json
import sys
from urllib.parse import parse_qs, unquote, urlsplit


def build(uri: str, socks_port: int, uuid: str | None, short_id: str | None, public_key: str | None) -> dict:
    parts = urlsplit(uri)
    if parts.scheme != "vless" or not parts.username or not parts.hostname or not parts.port:
        raise SystemExit("not a vless URI with user, host and port")
    query = {key: values[0] for key, values in parse_qs(parts.query, strict_parsing=True).items()}
    expected = {"encryption": "none", "type": "tcp", "security": "reality", "flow": "xtls-rprx-vision"}
    for key, value in expected.items():
        if query.get(key) != value:
            raise SystemExit(f"unexpected URI parameter {key}")
    for key in ("sni", "pbk", "sid", "fp"):
        if not query.get(key):
            raise SystemExit(f"missing URI parameter {key}")
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": False},
        }],
        "outbounds": [{
            "protocol": "vless",
            "tag": unquote(parts.fragment) or "proxy",
            "settings": {"vnext": [{
                "address": parts.hostname,
                "port": parts.port,
                "users": [{
                    "id": uuid or unquote(parts.username),
                    "encryption": "none",
                    "flow": query["flow"],
                }],
            }]},
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "serverName": query["sni"],
                    "fingerprint": query["fp"],
                    "publicKey": public_key or query["pbk"],
                    "shortId": short_id or query["sid"],
                    "spiderX": "",
                },
            },
        }],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("uri")
    parser.add_argument("socks_port", type=int)
    parser.add_argument("--uuid")
    parser.add_argument("--short-id")
    parser.add_argument("--public-key")
    arguments = parser.parse_args()
    json.dump(build(arguments.uri.strip(), arguments.socks_port, arguments.uuid, arguments.short_id,
                    arguments.public_key), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
