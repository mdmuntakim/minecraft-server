#!/usr/bin/env python3
"""Minimal RCON client for the test suite (Source RCON protocol).

    python3 scripts/rcon.py 127.0.0.1 25575 secret "mobhead selftest"
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys

SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


def packet(request_id: int, kind: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, kind) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def receive(sock: socket.socket) -> tuple[int, int, str]:
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("RCON connection closed")
        header += chunk
    length = struct.unpack("<i", header)[0]
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise ConnectionError("RCON connection closed mid packet")
        data += chunk
    request_id, kind = struct.unpack("<ii", data[:8])
    return request_id, kind, data[8:-2].decode("utf-8", "replace")


def run(host: str, port: int, password: str, command: str, timeout: float) -> str:
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        sock.sendall(packet(1, SERVERDATA_AUTH, password))
        request_id, kind, _ = receive(sock)
        if kind == SERVERDATA_AUTH_RESPONSE and request_id == -1:
            raise PermissionError("RCON authentication failed")
        sock.sendall(packet(2, SERVERDATA_EXECCOMMAND, command))
        _, kind, body = receive(sock)
        if kind != SERVERDATA_RESPONSE_VALUE:
            raise ValueError(f"unexpected RCON packet type {kind}")
        return body


def main() -> int:
    parser = argparse.ArgumentParser(description="Run one RCON command")
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("password")
    parser.add_argument("command")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    try:
        print(run(args.host, args.port, args.password, args.command, args.timeout))
    except (OSError, ValueError, PermissionError) as error:
        print(f"rcon failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
