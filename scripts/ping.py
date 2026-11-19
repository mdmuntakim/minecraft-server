#!/usr/bin/env python3
"""Minecraft Server List Ping (protocol 1.7+), used by the test suite.

    python3 scripts/ping.py 127.0.0.1 25565
    python3 scripts/ping.py bore.pub 41234 --json

Exit status 0 means the server answered a status request with valid JSON.
"""

from __future__ import annotations

import argparse
import json
import socket
import struct
import sys
import time


def write_varint(value: int) -> bytes:
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        out.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(out)


def read_varint(sock: socket.socket) -> int:
    value = 0
    shift = 0
    while True:
        raw = sock.recv(1)
        if not raw:
            raise ConnectionError("connection closed while reading a VarInt")
        byte = raw[0]
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value
        shift += 7
        if shift > 35:
            raise ValueError("VarInt is too large")


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def varint(self) -> int:
        value = 0
        shift = 0
        while True:
            if self.pos >= len(self.data):
                raise ValueError("truncated VarInt")
            byte = self.data[self.pos]
            self.pos += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value
            shift += 7
            if shift > 35:
                raise ValueError("VarInt is too large")

    def string(self) -> str:
        length = self.varint()
        text = self.data[self.pos:self.pos + length]
        self.pos += length
        return text.decode("utf-8")


def send_packet(sock: socket.socket, payload: bytes) -> None:
    sock.sendall(write_varint(len(payload)) + payload)


def read_packet(sock: socket.socket) -> bytes:
    length = read_varint(sock)
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise ConnectionError("connection closed in the middle of a packet")
        data += chunk
    return data


def status(host: str, port: int, timeout: float) -> tuple[dict, float]:
    started = time.monotonic()
    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        host_bytes = host.encode("utf-8")
        handshake = (
            write_varint(0)                       # packet id: handshake
            + write_varint(769)                   # protocol version (status ignores it)
            + write_varint(len(host_bytes)) + host_bytes
            + struct.pack(">H", port)             # server port, unsigned short
            + write_varint(1)                     # next state: status
        )
        send_packet(sock, handshake)
        send_packet(sock, write_varint(0))        # status request
        data = read_packet(sock)
        latency = (time.monotonic() - started) * 1000.0
        reader = Reader(data)
        packet_id = reader.varint()
        if packet_id != 0:
            raise ValueError(f"unexpected packet id {packet_id}")
        payload = json.loads(reader.string())
        return payload, latency


def motd_text(payload: dict) -> str:
    description = payload.get("description", "")
    if isinstance(description, str):
        return description
    if isinstance(description, dict):
        return "".join(part.get("text", "") for part in description.get("extra", [])) \
            or description.get("text", "")
    return str(description)


def main() -> int:
    parser = argparse.ArgumentParser(description="Ping a Minecraft server")
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--json", action="store_true", help="print the raw status JSON")
    args = parser.parse_args()

    try:
        payload, latency = status(args.host, args.port, args.timeout)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print(f"ping {args.host}:{args.port} failed: {error}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0

    version = payload.get("version", {})
    players = payload.get("players", {})
    print(f"Minecraft server {args.host}:{args.port}")
    print(f"  version: {version.get('name', '?')} (protocol {version.get('protocol', '?')})")
    print(f"  players: {players.get('online', 0)}/{players.get('max', 0)}")
    print(f"  MOTD:    {motd_text(payload)}")
    print(f"  latency: {latency:.0f} ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
