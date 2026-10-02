#!/usr/bin/env python3
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()

    handler = partial(QuietHandler, directory=args.directory)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        Path(args.port_file).write_text(str(server.server_port), encoding="ascii")
        server.serve_forever()


if __name__ == "__main__":
    main()
