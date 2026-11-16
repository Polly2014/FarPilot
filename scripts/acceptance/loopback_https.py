#!/usr/bin/env python3
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import ssl


def checked_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        raise SystemExit(f"{label} must not be a symbolic link")
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"{label} does not exist") from error
    if not resolved.is_file():
        raise SystemExit(f"{label} must be a regular file")
    return resolved


def checked_root(path: Path) -> Path:
    if path.is_symlink():
        raise SystemExit("root must not be a symbolic link")
    resolved = path.resolve(strict=True)
    if not resolved.is_dir():
        raise SystemExit("root must be a directory")
    return resolved


class QuietStaticHandler(SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        return

    def list_directory(self, path: str):
        self.send_error(403, "directory listing disabled")
        return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cert", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("port must be between 1024 and 65535")
    root = checked_root(args.root)
    cert = checked_file(args.cert, "certificate")
    key = checked_file(args.key, "private key")
    handler = partial(QuietStaticHandler, directory=str(root))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"READY https://127.0.0.1:{args.port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
