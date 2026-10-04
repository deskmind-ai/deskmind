"""Acceptance runs for the live view, through the installed app's helper (DeskMind Hands): real tasks with the real
models, the card on and off, and what each run left behind checked.

It sends the helper the same "run" request the app sends (one JSON line on the helper's Unix socket), answers a
question the way the app does ("answer"), and reads the events back. Nothing is typed and nothing is clicked by this
script; the run itself acts as it always does (in the background, or with a short foreground flash for an app read
from the screen, which the app's confirmation allows).

    python3 app/tests/e2e/live_view_runs.py <case> [--off] [--out DIR]

Cases: ledger (TextEdit, asks which order; answered "09-27"), safari (Safari + TextEdit, copy a table), music
(NetEase Cloud Music, read from the screen -- it plays a song). Per run it prints and writes to DIR/<case>-<on|off>.json:
- steps, their latency (hands' latency_s) and the run's result;
- helper CPU % and RSS (MB), sampled every second during the run;
- whether any of hands' step screenshots shows the card (its dark chrome, in the part of the screenshot the card
  covered on screen);
- that the card and its capture are gone 4 s after the run ends (no helper windows on screen).
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import threading
import time
from pathlib import Path

SOCK = Path.home() / "Library/Application Support/DeskMind/hands.sock"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

CASES = {
    "ledger": {
        "goal": "Find Lisa Wong's order in records.txt and add it to ledger.csv as Date,Customer,Order,Amount, then save "
                "ledger.csv. Both files are in the attached folder; open them in TextEdit.",
        "apps": [{"name": "TextEdit", "bundle": "com.apple.TextEdit"}],
        "folder": "ledger", "answer": "09-27",
    },
    "safari": {
        "goal": "Open parts.html in Safari and copy its table into parts.csv in TextEdit, highest Qty first, then save "
                "and close parts.csv.",
        "apps": [{"name": "Safari", "bundle": "com.apple.Safari"}, {"name": "TextEdit", "bundle": "com.apple.TextEdit"}],
        "folder": "parts", "answer": None,
    },
    "music": {
        "goal": "Open NetEase Cloud Music, search Billie Eilish's BIRDS OF A FEATHER and play the live version.",
        "apps": [{"name": "NetEase Cloud Music", "bundle": "com.netease.163music"}],
        "folder": None, "answer": None,
    },
}


def request(body: dict, on_line=None, timeout: float = 20) -> dict | None:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout if on_line is None else None)
    s.connect(str(SOCK))
    s.sendall((json.dumps({**body, "lang": "en"}) + "\n").encode())
    buf = b""
    last = None
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line) if line.strip() else None
            if on_line is None:
                s.close()
                return obj
            last = obj
            on_line(obj)
    s.close()
    return last


def helper_pid() -> int | None:
    out = subprocess.run(["pgrep", "-f", "DeskMind Hands.app/Contents/MacOS/DeskMindHands"], capture_output=True, text=True).stdout
    pids = [int(p) for p in out.split()]
    return pids[0] if pids else None


def helper_windows(pid: int) -> list[dict]:
    import Quartz
    wins = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
    return [dict(w) for w in wins if w.get("kCGWindowOwnerPID") == pid and w.get("kCGWindowLayer", 0) > 0]


def card_in_shot(png: Path, card: dict | None) -> bool:
    """Whether a step screenshot (a window capture) shows the card's dark chrome where the card was on screen."""
    if not card:
        return False
    from PIL import Image
    with Image.open(png) as im:
        im = im.convert("RGB")
        px = im.load()
        w, h = im.size
        dark = total = 0
        for y in range(0, h, 4):
            for x in range(0, w, 4):
                r, g, b = px[x, y]
                total += 1
                if abs(r - 38) < 8 and abs(g - 43) < 8 and abs(b - 40) < 8:
                    dark += 1
        # The card is 360 x 300 points at least: a capture showing it has far more than 1 % of its pixels in that colour.
        return total > 0 and dark / total > 0.01


def stage(case: dict, out: Path) -> str | None:
    if not case["folder"]:
        return None
    dst = out / f"work-{case['folder']}-{int(time.time())}"
    subprocess.run(["cp", "-R", str(FIXTURES / case["folder"]), str(dst)], check=True)
    return str(dst)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("case", choices=sorted(CASES))
    ap.add_argument("--off", action="store_true", help="the card off (the baseline)")
    ap.add_argument("--out", default="/tmp/deskmind-liveview-runs")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    case = CASES[a.case]
    pid = helper_pid()
    if not pid or not SOCK.exists():
        print("the DeskMind helper is not running (open the app once)")
        return 2
    folder = stage(case, out)
    body = {"op": "run", "goal": case["goal"], "foreground_ok": True, "apps": case["apps"], "live_view": not a.off}
    if folder:
        body["folder"] = folder

    samples: list[tuple[float, float]] = []
    seen_card: list[dict] = []
    done = threading.Event()

    def sample():
        while not done.is_set():
            r = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
            if len(r) == 2:
                samples.append((float(r[0]), int(r[1]) / 1024))
            for w in helper_windows(pid):
                b = w.get("kCGWindowBounds") or {}
                seen_card.append({"x": b.get("X"), "y": b.get("Y"), "w": b.get("Width"), "h": b.get("Height")})
            time.sleep(1)

    threading.Thread(target=sample, daemon=True).start()
    events: list[dict] = []
    t0 = time.time()

    def on_line(e: dict):
        events.append(e)
        kind = e.get("event")
        if kind == "step":
            print(f"  step {e.get('n')}: {e.get('human')}  ({e.get('latency')} s)")
        elif kind == "ask":
            print(f"  ask: {e.get('question')}")
            if case["answer"]:
                time.sleep(2)
                request({"op": "answer", "reply": case["answer"], "approve": True})
                print(f"  answered: {case['answer']}")
        elif kind in ("done", "error", "task_done"):
            print(f"  {kind}: {json.dumps({k: e.get(k) for k in ('state', 'exit', 'reason', 'error', 'strict') if k in e})}")

    request(body, on_line)
    wall = time.time() - t0
    time.sleep(4)   # the card says how the run ended (2.5 s), then fades
    left = helper_windows(pid)
    done.set()

    steps = [e for e in events if e.get("event") == "step"]
    shots = [Path(e["shot"]) for e in steps if e.get("shot") and Path(e["shot"]).exists()]
    card = seen_card[-1] if seen_card else None
    with_card = [str(p) for p in shots if card_in_shot(p, card)]
    lat = [float(e.get("latency") or 0) for e in steps if e.get("latency")]
    cpu = [c for c, _ in samples]
    rss = [m for _, m in samples]
    report = {
        "case": a.case, "live_view": not a.off, "wall_s": round(wall, 1),
        "result": next((e for e in reversed(events) if e.get("event") in ("done", "error")), {}),
        "steps": len(steps),
        "latency_s": {"mean": round(sum(lat) / len(lat), 2) if lat else None, "max": max(lat) if lat else None},
        "helper_cpu_pct": {"mean": round(sum(cpu) / len(cpu), 1) if cpu else None, "max": max(cpu) if cpu else None},
        "helper_rss_mb": {"max": round(max(rss), 0) if rss else None},
        "card_seen_on_screen": bool(seen_card) if not a.off else None,
        "screenshots": len(shots), "screenshots_with_card": with_card,
        "helper_windows_after_end": len(left),
    }
    (out / f"{a.case}-{'off' if a.off else 'on'}.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print(json.dumps(report, indent=2, ensure_ascii=False))
    ok = not with_card and not left and (a.off or bool(seen_card))
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
