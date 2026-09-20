import socket
import threading
import time

HOST = "0.0.0.0"
PORT = 18080

def handle_client(conn, addr):
    print(f"[+] connected: {addr}")

    try:
        # 아무 데이터도 보내지 않고,
        # 클라이언트가 끊을 때까지 연결만 유지
        while True:
            data = conn.recv(4096)

            if not data:
                print(f"[-] disconnected: {addr}")
                break

            print(f"[>] received {len(data)} bytes from {addr}")

    except Exception as e:
        print(f"[!] {addr}: {e}")

    finally:
        try:
            conn.close()
        except:
            pass


with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((HOST, PORT))
    s.listen()

    print(f"TCP idle test server listening on {HOST}:{PORT}")

    while True:
        conn, addr = s.accept()

        threading.Thread(
            target=handle_client,
            args=(conn, addr),
            daemon=True
        ).start()
