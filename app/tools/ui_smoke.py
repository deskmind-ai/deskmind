"""Drive the built DeskMind app the way a person would, through Peekaboo in the background, and check what it shows.

    <hands venv>/bin/python tools/ui_smoke.py [--app ../build/DeskMind.app] [--hands <hands checkout>]  (default: ../hands next to this repo, or $HANDS_REPO)

What it does, in order (each step prints PASS/FAIL; the exit code is the number of failures):
  1. launch (or reuse) the app, wait for its main window;
  2. the home screen: the prompt, the setup card's helper, model and permission rows (unfolded if folded), and the
     footer links, are there;
  3. language: switch to 简体中文, see the window in Chinese, switch back to English;
  4. Try examples -> the mock desktop's 6 smoke tests -> Start -> "6/6 tasks passed";
  5. Back to the main window.

Only the mock desktop runs: nothing here touches Finder, TextEdit or any file outside the app's own folder, so it
is safe to run at any time. Clicks go through hands' persistent Peekaboo MCP session (see -> element id -> click,
background). Two limits, both of SwiftUI in the background: a click is not confirmed by the platform, so each step
checks the window afterwards instead; and a text field cannot be filled (AX set-value does not reach the SwiftUI
binding), so the home screen's own instruction is not exercised here.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BUNDLE = "ai.deskmind.app"

ap = argparse.ArgumentParser()
ap.add_argument("--app", default=str(Path(__file__).resolve().parents[2] / "build" / "DeskMind.app"))
ap.add_argument("--hands", default=os.environ.get("HANDS_REPO") or str(Path(__file__).resolve().parents[3] / "hands"))
ap.add_argument("--peekaboo", default=os.path.expanduser("~/.local/bin/peekaboo"))
a = ap.parse_args()
if not Path(a.hands).is_dir():
    sys.exit(f"ui_smoke: no hands checkout at {a.hands} (pass --hands or set HANDS_REPO)")
sys.path.insert(0, a.hands)
from hands.drivers.peekaboo import _MCPSession  # noqa: E402

tmp = tempfile.mkdtemp()
session = _MCPSession(a.peekaboo, 60, env={"PEEKABOO_BRIDGE_SOCKET": os.path.join(tmp, "x.sock")})
failures = 0


def see() -> dict:
    ok, meta, _, err = session.tool("see", {"app_target": BUNDLE, "path": os.path.join(tmp, f"{time.time()}.png")})
    return meta if ok and meta else {}


def label(e: dict) -> str:
    return e.get("label") or e.get("title") or e.get("value") or ""


def texts() -> list[str]:
    return [label(e) for e in see().get("ui_elements") or []]


def wait_for(pred, timeout: float, every: float = 1.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        try:
            if pred(texts()):
                return True
        except Exception:   # noqa: BLE001 - the window may be mid-redraw
            pass
        time.sleep(every)
    return False


def click(name: str, exact: bool = True) -> bool:
    meta = see()
    hits = [e for e in meta.get("ui_elements") or []
            if (label(e) == name if exact else label(e).startswith(name))]
    if not hits:
        return False
    session.tool("click", {"on": hits[-1]["id"], "snapshot": meta.get("snapshot_id"), "background": True})
    time.sleep(1.0)
    return True


def check(step: str, ok: bool, detail: str = "") -> None:
    global failures
    failures += 0 if ok else 1
    print(f"[{'PASS' if ok else 'FAIL'}] {step}{(' -- ' + detail) if detail and not ok else ''}")


# 1. launch
running = subprocess.run(["pgrep", "-f", f"{a.app}/Contents/MacOS/DeskMind$"], capture_output=True).returncode == 0
if not running:
    subprocess.run(["open", "-g", a.app], check=True)
check("main window up", wait_for(lambda t: any(x in t for x in ("Try examples", "试试示例", "Back", "返回")), 60))
# Left on another screen by an earlier session: go back to the home screen first.
if "Back" in texts() or "返回" in texts():
    click("Back") or click("返回")
    wait_for(lambda t: "Try examples" in t or "试试示例" in t, 10)

# English to start with, whatever the last run left.
if "试试示例" in texts():
    click("简体中文")
    click("English")
    wait_for(lambda t: "Try examples" in t, 10)

# 2. home screen. The setup card folds once everything is ready: unfold it to see its rows.
if "Background helper" not in texts():
    click("Show setup")
    wait_for(lambda t: "Background helper" in t, 5)
t = texts()
for want in ("What should DeskMind do?", "Background helper", "Local model", "Vision model", "Accessibility",
             "Screen Recording", "Automation", "Developer tools", "Open-source notices"):
    check(f"home screen shows {want!r}", want in t)

# 3. language round trip
ok = click("English") and click("简体中文") and wait_for(lambda t: "试试示例" in t, 10)
check("switch to 简体中文", ok, "the window did not turn Chinese")
ok = click("简体中文") and click("English") and wait_for(lambda t: "Try examples" in t, 10)
check("switch back to English", ok, "the window did not turn English")

# 4. the mock smoke set
ok = click("Try examples") and wait_for(lambda t: any(x.startswith("6 smoke tests") for x in t), 10)
check("Try examples opens the examples screen", ok)
ok = click("6 smoke tests", exact=False) and click("Start")
check("start the mock smoke set", ok)
check("6/6 tasks passed", wait_for(lambda t: "6/6 tasks passed" in t, 120, every=2),
      next((x for x in texts() if "tasks passed" in x), "no result shown"))

# 5. back
ok = click("Back") and wait_for(lambda t: "Try examples" in t, 10)
check("Back returns to the home screen", ok)

print(f"{failures} failure(s)")
sys.exit(failures)
