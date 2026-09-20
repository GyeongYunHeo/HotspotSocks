#!/usr/bin/env python3
"""Development-only RFC 1928 UDP ASSOCIATE echo probe for Android/Termux."""

import argparse
import ipaddress
import socket
import struct


def recv_exact(connection: socket.socket, length: int) -> bytes:
    result = bytearray()
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise RuntimeError("SOCKS5 TCP control connection closed")
        result.extend(chunk)
    return bytes(result)


def encode_address(value: str, address_type: str) -> bytes:
    if address_type == "ipv4":
        return b"\x01" + ipaddress.IPv4Address(value).packed
    if address_type == "ipv6":
        return b"\x04" + ipaddress.IPv6Address(value).packed
    encoded = value.encode("utf-8")
    if not 0 < len(encoded) <= 255:
        raise ValueError("domain must contain 1...255 UTF-8 bytes")
    return b"\x03" + bytes([len(encoded)]) + encoded


def dns_query(name: str) -> bytes:
    labels = name.rstrip(".").encode("idna").split(b".")
    question = b"".join(bytes([len(label)]) + label for label in labels) + b"\x00"
    return struct.pack("!HHHHHH", 0x4853, 0x0100, 1, 0, 0, 0) + question + struct.pack("!HH", 1, 1)


def validate_dns_response(response: bytes) -> None:
    if len(response) < 12:
        raise RuntimeError("truncated DNS response")
    transaction, flags, _, answers, _, _ = struct.unpack("!HHHHHH", response[:12])
    if transaction != 0x4853 or flags & 0x8000 == 0 or flags & 0x000F != 0 or answers == 0:
        raise RuntimeError(
            f"invalid DNS response transaction={transaction:#x} flags={flags:#x} answers={answers}"
        )


def decode_stream_address(connection: socket.socket, address_type: int):
    read = lambda count: recv_exact(connection, count)
    if address_type == 1:
        return str(ipaddress.IPv4Address(read(4)))
    if address_type == 4:
        return str(ipaddress.IPv6Address(read(16)))
    if address_type == 3:
        length = read(1)[0]
        return read(length).decode("utf-8")
    raise RuntimeError(f"unsupported ATYP {address_type:#x}")


def decode_packet_address(packet: bytes, address_type: int, offset: int):
    if address_type == 1:
        end = offset + 4
        return str(ipaddress.IPv4Address(packet[offset:end])), end
    if address_type == 4:
        end = offset + 16
        return str(ipaddress.IPv6Address(packet[offset:end])), end
    if address_type == 3:
        length = packet[offset]
        end = offset + 1 + length
        return packet[offset + 1:end].decode("utf-8"), end
    raise RuntimeError(f"unsupported ATYP {address_type:#x}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proxy-host", required=True)
    parser.add_argument("--proxy-port", type=int, default=9876)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--atyp", choices=("ipv4", "domain", "ipv6"), required=True)
    parser.add_argument("--payload", default="hotspot-socks-udp-test")
    parser.add_argument("--dns-name", help="send and validate an A/IN DNS query instead of an echo payload")
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    payload = dns_query(args.dns_name) if args.dns_name else args.payload.encode("utf-8")

    proxy_info = socket.getaddrinfo(
        args.proxy_host,
        args.proxy_port,
        type=socket.SOCK_STREAM,
    )[0]
    family = proxy_info[0]
    wildcard = "::" if family == socket.AF_INET6 else "0.0.0.0"

    with socket.create_connection((args.proxy_host, args.proxy_port), args.timeout) as control, \
            socket.socket(family, socket.SOCK_DGRAM) as udp:
        control.settimeout(args.timeout)
        udp.settimeout(args.timeout)
        udp.bind((wildcard, 0))
        local_port = udp.getsockname()[1]

        control.sendall(b"\x05\x01\x00")
        if recv_exact(control, 2) != b"\x05\x00":
            raise RuntimeError("SOCKS5 NO AUTH negotiation failed")

        if family == socket.AF_INET6:
            associate = b"\x05\x03\x00\x04" + (b"\x00" * 16)
        else:
            associate = b"\x05\x03\x00\x01" + (b"\x00" * 4)
        control.sendall(associate + struct.pack("!H", local_port))

        reply_header = recv_exact(control, 4)
        if reply_header[:3] != b"\x05\x00\x00":
            raise RuntimeError(f"UDP ASSOCIATE failed: {reply_header.hex()}")
        relay_host = decode_stream_address(control, reply_header[3])
        relay_port = struct.unpack("!H", recv_exact(control, 2))[0]
        if relay_host in ("0.0.0.0", "::"):
            relay_host = args.proxy_host

        request = (
            b"\x00\x00\x00"
            + encode_address(args.target_host, args.atyp)
            + struct.pack("!H", args.target_port)
            + payload
        )
        udp.sendto(request, (relay_host, relay_port))
        response, peer = udp.recvfrom(65_535)
        if len(response) < 4 or response[:3] != b"\x00\x00\x00":
            raise RuntimeError("invalid SOCKS5 UDP response header")
        source_host, offset = decode_packet_address(response, response[3], 4)
        if offset + 2 > len(response):
            raise RuntimeError("truncated SOCKS5 UDP response port")
        source_port = struct.unpack("!H", response[offset:offset + 2])[0]
        echoed = response[offset + 2:]
        if args.dns_name:
            validate_dns_response(echoed)
        elif echoed != payload:
            raise RuntimeError(f"payload mismatch: {echoed!r}")

        print(f"PASS relay={relay_host}:{relay_port} peer={peer}")
        print(f"response-source={source_host}:{source_port}")
        if args.dns_name:
            print(f"dns={args.dns_name} response-bytes={len(echoed)}")
        else:
            print(f"payload={echoed.decode('utf-8', errors='replace')}")


if __name__ == "__main__":
    main()
