#!/usr/bin/env python3
"""Development-only deterministic UDP echo server for Phase 7 physical tests."""

import argparse
import socket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18081)
    args = parser.parse_args()

    family = socket.AF_INET6 if ":" in args.host else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as server:
        server.bind((args.host, args.port))
        print(f"UDP echo listening on {args.host}:{args.port}", flush=True)
        while True:
            payload, peer = server.recvfrom(65_535)
            print(f"received {len(payload)} bytes from {peer}", flush=True)
            server.sendto(payload, peer)


if __name__ == "__main__":
    main()
