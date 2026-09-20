#!/usr/bin/env python3
"""Deterministic TCP peer for HotspotSocks half-close verification."""

import argparse
import socket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--once", action="store_true")
    arguments = parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((arguments.host, arguments.port))
        listener.listen()
        print(f"half-close test server listening on {arguments.host}:{arguments.port}", flush=True)

        while True:
            connection, address = listener.accept()
            with connection:
                request = bytearray()
                while True:
                    chunk = connection.recv(65_536)
                    if not chunk:
                        break
                    request.extend(chunk)

                body = f"received={len(request)}\n".encode()
                response = (
                    b"HTTP/1.1 200 OK\r\n"
                    + f"Content-Length: {len(body)}\r\n".encode()
                    + b"Connection: close\r\n\r\n"
                    + body
                )
                connection.sendall(response)
                connection.shutdown(socket.SHUT_WR)
                print(
                    f"served {address[0]}:{address[1]} after EOF; "
                    f"request={len(request)} response={len(response)}",
                    flush=True,
                )

            if arguments.once:
                return


if __name__ == "__main__":
    main()
