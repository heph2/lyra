#!/usr/bin/env python3
"""Minimal WebDAV server for exercising Lyra's remote library end to end.

Speaks just enough of RFC 4918 for Lyra: Basic auth, PROPFIND Depth:1
multistatus, and ranged GET. Every request is logged with the bytes actually
served so partial indexing versus a full download is measurable.
"""
import base64
import json
import time
import os
import sys
import threading
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])
LOG = sys.argv[3]
USER, PASSWORD = "lyra", "s3cr3t-webdav-pw"
# Slows every response so the in-app scan progress card stays on screen long
# enough to photograph.
DELAY = float(os.environ.get("LYRA_DAV_DELAY", "0"))

lock = threading.Lock()


def record(entry):
    with lock:
        with open(LOG, "a") as handle:
            handle.write(json.dumps(entry) + "\n")


def local_path(url_path):
    rel = unquote(url_path).lstrip("/")
    target = os.path.abspath(os.path.join(ROOT, rel))
    if target != ROOT and not target.startswith(ROOT + os.sep):
        return None
    return target


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def stall(self):
        if DELAY:
            time.sleep(DELAY)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            user, _, pw = base64.b64decode(header[6:]).decode().partition(":")
        except Exception:
            return False
        return user == USER and pw == PASSWORD

    def deny(self):
        record({"method": self.command, "path": self.path, "status": 401, "bytes_sent": 0})
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="lyra"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PROPFIND(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if not self.authorized():
            return self.deny()
        self.stall()
        target = local_path(self.path)
        if target is None or not os.path.isdir(target):
            record({"method": "PROPFIND", "path": self.path, "status": 404, "bytes_sent": 0})
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        base = self.path if self.path.endswith("/") else self.path + "/"
        entries = [(base, True, 0, os.path.getmtime(target))]
        for name in sorted(os.listdir(target)):
            if name.startswith("."):
                continue
            child = os.path.join(target, name)
            is_dir = os.path.isdir(child)
            href = base + quote(name) + ("/" if is_dir else "")
            entries.append((href, is_dir, 0 if is_dir else os.path.getsize(child),
                            os.path.getmtime(child)))

        parts = ['<?xml version="1.0" encoding="utf-8"?>', '<D:multistatus xmlns:D="DAV:">']
        for href, is_dir, size, mtime in entries:
            rtype = "<D:collection/>" if is_dir else ""
            parts.append(
                f"<D:response><D:href>{href}</D:href><D:propstat><D:prop>"
                f"<D:resourcetype>{rtype}</D:resourcetype>"
                f"<D:getcontentlength>{size}</D:getcontentlength>"
                f"<D:getlastmodified>{formatdate(mtime, usegmt=True)}</D:getlastmodified>"
                f"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
            )
        parts.append("</D:multistatus>")
        body = "".join(parts).encode()
        record({"method": "PROPFIND", "path": unquote(self.path), "status": 207,
                "bytes_sent": len(body), "entries": len(entries) - 1})
        self.send_response(207)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("DAV", "1,2")
        self.send_header("Allow", "OPTIONS, GET, HEAD, PROPFIND")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.serve(body=False)

    def do_GET(self):
        self.serve(body=True)

    def serve(self, body):
        if not self.authorized():
            return self.deny()
        self.stall()
        target = local_path(self.path)
        if target is None or not os.path.isfile(target):
            record({"method": self.command, "path": unquote(self.path), "status": 404, "bytes_sent": 0})
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        total = os.path.getsize(target)
        rng = self.headers.get("Range")
        start, end, status = 0, total - 1, 200
        if rng and rng.startswith("bytes="):
            spec = rng[6:].split("-")
            start = int(spec[0] or 0)
            if len(spec) > 1 and spec[1]:
                end = min(int(spec[1]), total - 1)
            status = 206
        count = max(0, end - start + 1)

        with open(target, "rb") as handle:
            handle.seek(start)
            chunk = handle.read(count) if body else b""

        record({"method": self.command, "path": unquote(self.path), "status": status,
                "range": rng, "file_size": total, "bytes_sent": count if body else 0,
                "fraction_of_file": round(count / total, 4) if total else 0})
        self.send_response(status)
        self.send_header("Content-Type", "audio/flac")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(count))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        if body:
            self.wfile.write(chunk)


class Server(ThreadingHTTPServer):
    # Lyra reads six tracks' headers at once and keeps the connections alive.
    # The stdlib default backlog of 5 fills up under that, and the connections
    # that do not get accepted surface in the app as NSURLErrorTimedOut.
    request_queue_size = 128
    daemon_threads = True
    allow_reuse_address = True

    def finish_request(self, request, client_address):
        # A connection the client opens and never uses would otherwise hold a
        # worker thread until the process exits.
        request.settimeout(30)
        super().finish_request(request, client_address)


if __name__ == "__main__":
    open(LOG, "w").close()
    Server(("127.0.0.1", PORT), Handler).serve_forever()
