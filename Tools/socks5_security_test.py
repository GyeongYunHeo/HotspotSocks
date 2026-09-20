#!/usr/bin/env python3
"""Development-only SOCKS5 malformed-input, policy, and timeout probe."""

import argparse
import socket
import struct
import time


def receive_exact(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        try:
            chunk = connection.recv(length - len(result))
        except ConnectionResetError:
            break
        if not chunk:
            break
        result.extend(chunk)
    return bytes(result)


def connect(proxy_host: str, proxy_port: int, timeout: float) -> socket.socket:
    connection = socket.create_connection((proxy_host, proxy_port), timeout)
    connection.settimeout(timeout)
    return connection


def negotiate(connection: socket.socket) -> None:
    connection.sendall(b"\x05\x01\x00")
    response = receive_exact(connection, 2)
    if response != b"\x05\x00":
        raise RuntimeError(f"NO AUTH negotiation failed: {response.hex()}")


def expect_reply(args, request: bytes, expected: int, label: str) -> None:
    with connect(args.proxy_host, args.proxy_port, args.timeout) as connection:
        negotiate(connection)
        connection.sendall(request)
        response = receive_exact(connection, 10)
        if len(response) < 2 or response[0] != 5 or response[1] != expected:
            raise RuntimeError(f"{label}: expected reply 05{expected:02x}, got {response.hex()}")
    print(f"PASS {label}: reply=05{expected:02x}")


def policy_requests(args) -> None:
    expect_reply(
        args,
        b"\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x50",
        2,
        "IPv4 loopback blocked",
    )
    numeric = b"127.0.0.1"
    expect_reply(
        args,
        b"\x05\x01\x00\x03" + bytes([len(numeric)]) + numeric + struct.pack("!H", 80),
        2,
        "numeric-domain loopback blocked",
    )
    localhost = b"localhost"
    expect_reply(
        args,
        b"\x05\x01\x00\x03" + bytes([len(localhost)]) + localhost + struct.pack("!H", 80),
        2,
        "localhost blocked",
    )
    if args.private_target:
        octets = socket.inet_aton(args.private_target)
        expect_reply(
            args,
            b"\x05\x01\x00\x01" + octets + struct.pack("!H", args.private_port),
            2,
            "private destination blocked",
        )


def malformed_requests(args) -> None:
    with connect(args.proxy_host, args.proxy_port, args.timeout) as connection:
        connection.sendall(b"\x05\x01\x02")
        response = receive_exact(connection, 2)
        if response != b"\x05\xff":
            raise RuntimeError(f"unsupported authentication: got {response.hex()}")
    print("PASS unsupported authentication: reply=05ff")

    expect_reply(args, b"\x05\x02\x00\x01", 7, "BIND unsupported")
    expect_reply(args, b"\x05\x01\x00\x02", 8, "ATYP unsupported")

    with connect(args.proxy_host, args.proxy_port, args.timeout) as connection:
        connection.sendall(b"\x04\x01\x00")
        if receive_exact(connection, 1):
            raise RuntimeError("unsupported SOCKS version was not closed")
    print("PASS unsupported version: connection closed")


def handshake_deadline(args) -> None:
    with connect(args.proxy_host, args.proxy_port, 25) as connection:
        connection.settimeout(25)
        started = time.monotonic()
        connection.sendall(b"\x05")
        time.sleep(8)
        connection.sendall(b"\x01")
        response = receive_exact(connection, 1)
        elapsed = time.monotonic() - started
        if response:
            raise RuntimeError(f"handshake deadline did not close the connection: {response.hex()}")
        if not 13 <= elapsed <= 22:
            raise RuntimeError(f"unexpected handshake deadline: {elapsed:.1f}s")
    print(f"PASS absolute handshake deadline: closed after {elapsed:.1f}s")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy-host", required=True)
    parser.add_argument("--proxy-port", type=int, default=9876)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--private-target", help="private IPv4 expected to be blocked while the setting is off")
    parser.add_argument("--private-port", type=int, default=18081)
    parser.add_argument("--test-handshake-timeout", action="store_true")
    args = parser.parse_args()

    malformed_requests(args)
    policy_requests(args)
    if args.test_handshake_timeout:
        handshake_deadline(args)
    print("PASS security probe")


if __name__ == "__main__":
    main()
