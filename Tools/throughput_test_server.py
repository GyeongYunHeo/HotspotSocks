#!/usr/bin/env python3
"""Deterministic streaming target for HotspotSocks performance tests."""

import argparse
import socketserver
import time


CHUNK_SIZE = 64 * 1024
MAX_TRANSFER_BYTES = 2 * 1024 * 1024 * 1024


def read_line(connection, limit=128):
    result = bytearray()
    while len(result) < limit:
        byte = connection.recv(1)
        if not byte:
            raise ConnectionError("connection closed before command")
        if byte == b"\n":
            return result.decode("ascii")
        result.extend(byte)
    raise ValueError("command is too long")


def pace(started, completed_bytes, rate_mbps):
    if rate_mbps <= 0:
        return
    target_elapsed = completed_bytes * 8 / (rate_mbps * 1_000_000)
    remaining = target_elapsed - (time.monotonic() - started)
    if remaining > 0:
        time.sleep(remaining)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        operation, byte_text, rate_text = read_line(self.request).split()
        byte_count = int(byte_text)
        rate_mbps = float(rate_text)
        if not 0 <= byte_count <= MAX_TRANSFER_BYTES or rate_mbps < 0:
            raise ValueError("invalid transfer parameters")

        started = time.monotonic()
        completed = 0
        if operation == "DOWNLOAD":
            chunk = bytes(CHUNK_SIZE)
            while completed < byte_count:
                size = min(CHUNK_SIZE, byte_count - completed)
                self.request.sendall(chunk[:size])
                completed += size
                pace(started, completed, rate_mbps)
        elif operation == "UPLOAD":
            while completed < byte_count:
                content = self.request.recv(min(CHUNK_SIZE, byte_count - completed))
                if not content:
                    raise ConnectionError("upload ended early")
                completed += len(content)
            self.request.sendall(b"OK\n")
        else:
            raise ValueError(f"unsupported operation {operation}")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18082)
    args = parser.parse_args()

    with Server((args.host, args.port), Handler) as server:
        print(f"throughput target listening on {args.host}:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
