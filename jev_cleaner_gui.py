#!/usr/bin/env python3
"""Jev Cleaner GUI: a local web app that visualises Jev sorting a folder.

    python3 jev_cleaner_gui.py              # opens the app on ~/Desktop
    python3 jev_cleaner_gui.py ~/Downloads  # start on another folder

Nothing is moved until you press "Move files". Classifications from the
animation are the ones that get applied, so what you see is what happens.
"""

import argparse
import json
import mimetypes
import os
import random
import secrets
import shutil
import subprocess
import sys
import threading
import webbrowser
from concurrent.futures import ThreadPoolExecutor, as_completed
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from jev_cleaner import CATEGORIES, apply_plan, ask_jev, collect_files, file_state, rule_category, undo

HERE = Path(__file__).resolve().parent
TOKEN = secrets.token_urlsafe(16)
START_FOLDER = "~/Desktop"
THUMB_EXTS = {"png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"}
MAX_THUMB_BYTES = 15_000_000

session = {"root": None, "files": {}, "results": {}}
lock = threading.Lock()


def scan(folder):
    root = Path(folder).expanduser().resolve()
    if not root.is_dir():
        raise ValueError(f"Not a folder: {root}")
    files = collect_files(root)
    with lock:
        session["root"] = root
        session["files"] = {str(i): f for i, f in enumerate(files)}
        session["results"] = {}
    return {
        "root": str(root),
        "categories": list(CATEGORIES),
        "files": [
            {
                "id": str(i),
                "name": f.name,
                "ext": f.suffix.lower().lstrip("."),
                "thumb": f.suffix.lower().lstrip(".") in THUMB_EXTS and f.stat().st_size < MAX_THUMB_BYTES,
            }
            for i, f in enumerate(files)
        ],
    }


def classify_events(threshold, all_jev, workers):
    """Yield one result dict per file: rule hits first (shuffled), then Jev answers as they land."""
    api_key = os.environ.get("TYPESAFE_API_KEY")
    with lock:
        files = dict(session["files"])
        session["results"] = {}
    to_ask = []
    rule_hits = []
    for fid, f in files.items():
        cat = None if all_jev else rule_category(f)
        if cat:
            rule_hits.append({"id": fid, "category": cat, "confidence": None, "source": "rule", "status": "ok"})
        else:
            to_ask.append(fid)
    if to_ask and not api_key:
        yield {"type": "fatal", "error": "TYPESAFE_API_KEY is not set in the environment."}
        return
    yield {"type": "start", "rules": len(rule_hits), "jev": len(to_ask)}
    random.shuffle(rule_hits)
    for r in rule_hits:
        session["results"][r["id"]] = r
        yield r

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(ask_jev, file_state(files[fid]), api_key): fid for fid in to_ask}
        for fut in as_completed(futures):
            fid = futures[fut]
            try:
                cat, conf = fut.result()
                status = "ok" if conf >= threshold else "review"
                r = {"id": fid, "category": cat, "confidence": conf, "source": "jev", "status": status}
            except Exception as e:
                r = {"id": fid, "category": None, "confidence": None, "source": "jev", "status": "error",
                     "error": str(e)[:160]}
            session["results"][fid] = r
            yield r
    yield {"type": "done"}


def move_files():
    with lock:
        root = session["root"]
        plan = [
            (session["files"][fid], r["category"], r["confidence"])
            for fid, r in session["results"].items()
            if r["status"] == "ok" and session["files"][fid].exists()
        ]
    if not plan:
        return {"moved": 0}
    return {"moved": apply_plan(root, plan)}


def undo_last():
    root = session["root"]
    if root is None:
        raise ValueError("Scan a folder first.")
    try:
        undo(root)
    except SystemExit as e:
        raise ValueError(str(e))
    return {"ok": True}


def pick_folder():
    script = 'POSIX path of (choose folder with prompt "Choose a folder for Jev to clean")'
    out = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    return {"folder": out.stdout.strip() or None}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self, query):
        if query.get("token", [""])[0] != TOKEN:
            self.send_json({"error": "bad token"}, 403)
            return False
        return True

    def do_GET(self):
        url = urlparse(self.path)
        q = parse_qs(url.query)
        if url.path == "/":
            html = (HERE / "gui.html").read_text().replace("__TOKEN__", TOKEN).replace("__FOLDER__", json.dumps(START_FOLDER)[1:-1])
            body = html.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not url.path.startswith("/api/") or not self.authorized(q):
            if not url.path.startswith("/api/"):
                self.send_error(404)
            return
        try:
            if url.path == "/api/scan":
                self.send_json(scan(q.get("folder", ["~/Desktop"])[0]))
            elif url.path == "/api/pick":
                self.send_json(pick_folder())
            elif url.path == "/api/thumb":
                self.serve_thumb(q.get("id", [""])[0])
            elif url.path == "/api/classify":
                self.stream_classify(
                    float(q.get("threshold", ["0.5"])[0]),
                    q.get("all_jev", ["0"])[0] == "1",
                    int(q.get("workers", ["8"])[0]),
                )
            else:
                self.send_error(404)
        except ValueError as e:
            self.send_json({"error": str(e)}, 400)

    def do_POST(self):
        url = urlparse(self.path)
        if not self.authorized(parse_qs(url.query)):
            return
        try:
            if url.path == "/api/move":
                self.send_json(move_files())
            elif url.path == "/api/undo":
                self.send_json(undo_last())
            else:
                self.send_error(404)
        except (ValueError, OSError) as e:
            self.send_json({"error": str(e)}, 400)

    def serve_thumb(self, fid):
        f = session["files"].get(fid)
        if not f or f.suffix.lower().lstrip(".") not in THUMB_EXTS or not f.exists():
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(f.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(f.stat().st_size))
        self.send_header("Cache-Control", "max-age=300")
        self.end_headers()
        with open(f, "rb") as fh:
            shutil.copyfileobj(fh, self.wfile)

    def stream_classify(self, threshold, all_jev, workers):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            for event in classify_events(threshold, all_jev, workers):
                self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def open_window(url):
    chrome = "/Applications/Google Chrome.app"
    if sys.platform == "darwin" and Path(chrome).exists():
        subprocess.Popen(["open", "-na", chrome, "--args", f"--app={url}", "--window-size=1440,900"])
    else:
        webbrowser.open(url)


def main():
    parser = argparse.ArgumentParser(description="Visual Jev Cleaner.")
    parser.add_argument("folder", nargs="?", default="~/Desktop", help="folder to open (default: ~/Desktop)")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-open", action="store_true", help="don't open a window")
    args = parser.parse_args()
    global START_FOLDER
    START_FOLDER = args.folder

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"Jev Cleaner running at {url}  (Ctrl+C to quit)")
    if not args.no_open:
        threading.Timer(0.4, open_window, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
