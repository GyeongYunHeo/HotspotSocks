#!/usr/bin/env python3
"""Repeatable TCP throughput probe through a SOCKS5 CONNECT proxy."""

import argparse
import ipaddress
import socket
import struct
import threading
import time


CHUNK_SIZE = 64 * 1024


def read_exact(connection, length):
    result = bytearray()
    while len(result) < length:
        content = connection.recv(length - len(result))
        if not content:
            raise ConnectionError(f"stream ended at {len(result)}/{length} bytes")
        result.extend(content)
    return bytes(result)


def receive_exact(connection, length):
    completed = 0
    while completed < length:
        content = connection.recv(min(CHUNK_SIZE, length - completed))
        if not content:
            raise ConnectionError(f"stream ended at {completed}/{length} bytes")
        completed += len(content)


def encode_address(value, address_type):
    if address_type == "ipv4":
        return b"\x01" + ipaddress.IPv4Address(value).packed
    if address_type == "ipv6":
        return b"\x04" + ipaddress.IPv6Address(value).packed
    encoded = value.encode("utf-8")
    if not 0 < len(encoded) <= 255:
        raise ValueError("domain must contain 1...255 UTF-8 bytes")
    return b"\x03" + bytes([len(encoded)]) + encoded


def socks_connection(args):
    connection = socket.create_connection((args.proxy_host, args.proxy_port), args.timeout)
    connection.settimeout(args.timeout)
    connection.sendall(b"\x05\x01\x00")
    if read_exact(connection, 2) != b"\x05\x00":
        raise RuntimeError("SOCKS5 NO AUTH negotiation failed")
    request = (
        b"\x05\x01\x00"
        + encode_address(args.target_host, args.atyp)
        + struct.pack("!H", args.target_port)
    )
    connection.sendall(request)
    header = read_exact(connection, 4)
    if len(header) != 4 or header[:2] != b"\x05\x00":
        raise RuntimeError(f"SOCKS5 CONNECT failed: {header.hex()}")
    address_lengths = {1: 4, 4: 16}
    if header[3] == 3:
        address_length = read_exact(connection, 1)[0]
    elif header[3] in address_lengths:
        address_length = address_lengths[header[3]]
    else:
        raise RuntimeError(f"unsupported reply ATYP {header[3]:#x}")
    receive_exact(connection, address_length + 2)
    return connection


def pace(started, completed_bytes, rate_mbps):
    if rate_mbps <= 0:
        return
    target_elapsed = completed_bytes * 8 / (rate_mbps * 1_000_000)
    remaining = target_elapsed - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)


def transfer(args, barrier, results, errors):
    try:
        with socks_connection(args) as connection:
            barrier.wait()
            command = f"{args.mode.upper()} {args.bytes} {args.rate_mbps}\n".encode("ascii")
            connection.sendall(command)
            started = time.monotonic()
            if args.mode == "download":
                receive_exact(connection, args.bytes)
            else:
                chunk = bytes(CHUNK_SIZE)
                completed = 0
                while completed < args.bytes:
                    size = min(CHUNK_SIZE, args.bytes - completed)
                    connection.sendall(chunk[:size])
                    completed += size
                    pace(started, completed, args.rate_mbps)
                if read_exact(connection, 3) != b"OK\n":
                    raise RuntimeError("upload target acknowledgement failed")
            results.append(time.monotonic() - started)
    except Exception as error:  # The main thread reports worker failures together.
        errors.append(error)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy-host", required=True)
    parser.add_argument("--proxy-port", type=int, default=9876)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, default=18082)
    parser.add_argument("--atyp", choices=("ipv4", "domain", "ipv6"), default="ipv4")
    parser.add_argument("--mode", choices=("download", "upload"), default="download")
    parser.add_argument("--bytes", type=int, default=64 * 1024 * 1024)
    parser.add_argument("--rate-mbps", type=float, default=0, help="per-connection target; 0 is unlimited")
    parser.add_argument("--parallel", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if args.bytes <= 0 or args.parallel <= 0 or args.rate_mbps < 0:
        parser.error("bytes and parallel must be positive; rate must be non-negative")

    barrier = threading.Barrier(args.parallel)
    results = []
    errors = []
    threads = [
        threading.Thread(target=transfer, args=(args, barrier, results, errors), daemon=True)
        for _ in range(args.parallel)
    ]
    overall_started = time.monotonic()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    overall_elapsed = time.monotonic() - overall_started
    if errors:
        raise RuntimeError("; ".join(str(error) for error in errors))

    total_bytes = args.bytes * args.parallel
    transfer_elapsed = max(results)
    aggregate_mbps = total_bytes * 8 / transfer_elapsed / 1_000_000
    print(
        f"PASS mode={args.mode} parallel={args.parallel} bytes={total_bytes} "
        f"transfer-elapsed={transfer_elapsed:.3f}s setup-plus-transfer={overall_elapsed:.3f}s "
        f"aggregate={aggregate_mbps:.2f}Mbps"
    )
    print(f"connection-durations min={min(results):.3f}s max={max(results):.3f}s")


if __name__ == "__main__":
    main()
