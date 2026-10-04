#!/usr/bin/env python3
"""Jev Cleaner: sort a messy folder (e.g. ~/Desktop) into category folders using Jev.

Unambiguous files are sorted by rules (macOS screenshot names, extensions).
Everything else is sent to Jev as a typed Choice question; low-confidence answers
are left in place for you to review.

    python3 jev_cleaner.py ~/Desktop            # dry run: show the plan
    python3 jev_cleaner.py ~/Desktop --apply    # move files
    python3 jev_cleaner.py ~/Desktop --undo     # put everything back

Requires TYPESAFE_API_KEY in the environment. Standard library only.
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

API_URL = "https://api.typesafe.ai/v1/systemone"
MODEL = "jev-latest"
MANIFEST = ".jev-cleaner-manifest.json"

CATEGORIES = {
    "Screenshots": "A screen capture of a computer or phone display, e.g. macOS 'Screenshot 2025-…' or 'CleanShot' files.",
    "Recordings": "A screen recording or captured screen video, e.g. 'Screen Recording 2025-…'.",
    "Videos": "A video that is not a screen recording: movies, clips, exported edits, demo videos.",
    "Audio": "Music, podcasts, voice memos, or other sound files.",
    "Images": "Photos, logos, graphics, designs, or other pictures that are not screen captures.",
    "Docs": "Documents meant to be read: PDFs, notes, papers, slides, spreadsheets, Markdown, text.",
    "Code": "Source code, scripts, config files, notebooks, or developer data files.",
    "Archives": "Compressed archives and installers: zip, tar, dmg, pkg.",
    "Other": "Anything that does not clearly fit the other folders.",
}

EXT_CATEGORY = {
    **dict.fromkeys(["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "opus"], "Audio"),
    **dict.fromkeys(["pdf", "doc", "docx", "pages", "ppt", "pptx", "key", "xls", "xlsx",
                     "numbers", "csv", "rtf", "epub", "odt"], "Docs"),
    **dict.fromkeys(["py", "js", "ts", "tsx", "jsx", "sh", "zsh", "rb", "go", "rs", "java",
                     "kt", "swift", "c", "cc", "cpp", "h", "hpp", "cs", "php", "sql",
                     "ipynb", "yaml", "yml", "toml", "css", "scss"], "Code"),
    **dict.fromkeys(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso"],
                    "Archives"),
}
SCREENSHOT_RE = re.compile(r"^(Screenshot|Screen Shot|CleanShot)\b", re.I)
RECORDING_RE = re.compile(r"^(Screen Recording|CleanShot)\b", re.I)
IMAGE_EXTS = {"png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"}
VIDEO_EXTS = {"mp4", "mov", "m4v", "avi", "mkv", "webm"}
TEXT_EXTS = {"txt", "md", "json", "html", "xml", "log", "ini", "env", ""}


def rule_category(path):
    """Return a category when the answer is certain from the name alone, else None."""
    ext = path.suffix.lower().lstrip(".")
    if ext in IMAGE_EXTS and SCREENSHOT_RE.match(path.name):
        return "Screenshots"
    if ext in VIDEO_EXTS and RECORDING_RE.match(path.name):
        return "Recordings"
    return EXT_CATEGORY.get(ext)


def file_state(path):
    """Context Jev needs to judge a file: name, type, size, and a peek at text content."""
    stat = path.stat()
    ext = path.suffix.lower().lstrip(".")
    state = {
        "filename": path.name,
        "extension": ext or None,
        "size_kb": round(stat.st_size / 1024, 1),
        "modified": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d"),
    }
    if ext in TEXT_EXTS and stat.st_size < 2_000_000:
        try:
            with open(path, "r", encoding="utf-8") as f:
                state["text_preview"] = f.read(600)
        except (UnicodeDecodeError, OSError):
            pass
    return state


def ask_jev(state, api_key, retries=4):
    body = json.dumps({
        "model": MODEL,
        "state": state,
        "questions": {
            "folder": {
                "type": "choice",
                "instructions": "This file is sitting on a cluttered desktop. Which folder should it be "
                                "moved into? Judge from `filename`, `extension`, and `text_preview` if present.",
                "criteria": CATEGORIES,
            }
        },
    }).encode()
    req = urllib.request.Request(API_URL, data=body, headers={
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    })
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                answer = json.load(resp)["answers"]["folder"]
                return answer["choice"], answer["confidence"]
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == retries:
                raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}")
        except urllib.error.URLError as e:
            if attempt == retries:
                raise RuntimeError(str(e.reason))
        time.sleep(2 ** attempt)


def unique_dest(dest):
    if not dest.exists():
        return dest
    for i in range(1, 10_000):
        candidate = dest.with_name(f"{dest.stem} ({i}){dest.suffix}")
        if not candidate.exists():
            return candidate
    raise RuntimeError(f"Too many name collisions for {dest}")


def collect_files(root):
    return sorted(
        p for p in root.iterdir()
        if p.is_file() and not p.is_symlink() and not p.name.startswith(".")
    )


def short(name, width=34):
    return name if len(name) <= width else name[: width - 3] + "..."


def classify(files, api_key, workers, threshold, all_jev):
    plan, review, errors = [], [], []
    to_ask = []
    for f in files:
        cat = None if all_jev else rule_category(f)
        if cat:
            plan.append((f, cat, None))
            print(f"  {short(f.name):<34} → {cat.lower():<12} rule")
        else:
            to_ask.append(f)

    if to_ask:
        print(f"\nAsking Jev about {len(to_ask)} file(s)...")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(ask_jev, file_state(f), api_key): f for f in to_ask}
        for fut in as_completed(futures):
            f = futures[fut]
            try:
                cat, conf = fut.result()
            except Exception as e:
                errors.append((f, str(e)))
                print(f"  {short(f.name):<34} ✗ {e}")
                continue
            if conf < threshold:
                review.append((f, cat, conf))
                print(f"  {short(f.name):<34} ? {cat.lower():<12} {conf:.0%}  (left in place)")
            else:
                plan.append((f, cat, conf))
                print(f"  {short(f.name):<34} → {cat.lower():<12} {conf:.0%}")
    return plan, review, errors


def apply_plan(root, plan):
    moves = []
    for src, cat, _ in plan:
        dest = unique_dest(root / cat / src.name)
        dest.parent.mkdir(exist_ok=True)
        shutil.move(str(src), str(dest))
        moves.append({"from": str(src), "to": str(dest)})
    manifest = root / MANIFEST
    history = json.loads(manifest.read_text()) if manifest.exists() else []
    history.append({"at": datetime.now().isoformat(timespec="seconds"), "moves": moves})
    manifest.write_text(json.dumps(history, indent=2))
    return len(moves)


def undo(root):
    manifest = root / MANIFEST
    if not manifest.exists():
        sys.exit("Nothing to undo: no manifest found.")
    history = json.loads(manifest.read_text())
    if not history:
        sys.exit("Nothing to undo.")
    run = history.pop()
    restored = 0
    for m in reversed(run["moves"]):
        src, dest = Path(m["to"]), Path(m["from"])
        if src.exists():
            shutil.move(str(src), str(unique_dest(dest)))
            restored += 1
    for cat in CATEGORIES:
        d = root / cat
        if d.is_dir() and not any(d.iterdir()):
            d.rmdir()
    if history:
        manifest.write_text(json.dumps(history, indent=2))
    else:
        manifest.unlink()
    print(f"Restored {restored} file(s) from the run at {run['at']}.")


def print_summary(plan):
    counts = {c: 0 for c in CATEGORIES}
    for _, cat, _ in plan:
        counts[cat] += 1
    print(f"\nSorted — {len(plan)} files")
    for cat, n in counts.items():
        if n:
            print(f"  📁 {cat:<12} {n:>5}")


def main():
    parser = argparse.ArgumentParser(description="Sort a cluttered folder into categories with Jev.")
    parser.add_argument("folder", nargs="?", default="~/Desktop", help="folder to clean (default: ~/Desktop)")
    parser.add_argument("--apply", action="store_true", help="actually move files (default is a dry run)")
    parser.add_argument("--undo", action="store_true", help="revert the most recent --apply run")
    parser.add_argument("--threshold", type=float, default=0.5,
                        help="minimum Jev confidence to move a file (default: 0.5)")
    parser.add_argument("--workers", type=int, default=8, help="parallel Jev requests (default: 8)")
    parser.add_argument("--all-jev", action="store_true", help="skip the rules and ask Jev about every file")
    args = parser.parse_args()

    root = Path(args.folder).expanduser().resolve()
    if not root.is_dir():
        sys.exit(f"Not a folder: {root}")
    if args.undo:
        return undo(root)

    api_key = os.environ.get("TYPESAFE_API_KEY")
    if not api_key:
        sys.exit("Set TYPESAFE_API_KEY first (https://console.typesafe.ai/).")

    files = collect_files(root)
    if not files:
        print("Nothing to clean.")
        return
    print(f"Cleaning {root} — {len(files)} files\n")
    plan, review, errors = classify(files, api_key, args.workers, args.threshold, args.all_jev)
    print_summary(plan)
    if review:
        print(f"\n{len(review)} file(s) below {args.threshold:.0%} confidence were left in place.")
    if errors:
        print(f"{len(errors)} file(s) failed to classify and were left in place.")

    if args.apply:
        moved = apply_plan(root, plan)
        print(f"\n✨ Moved {moved} file(s). Run with --undo to put them back.")
    else:
        print("\nDry run — nothing moved. Re-run with --apply to sort.")


if __name__ == "__main__":
    main()
