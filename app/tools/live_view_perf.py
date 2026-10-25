#!/usr/bin/env python3
"""The live view's cost per step (A4 acceptance: at most 5 % slower with the view watched).

    app/tools/live_view_perf.py --with TRACE... --without TRACE...

Each TRACE is a run's trace (a .jsonl the harness writes, with its model_call lines), recorded with the live view
watched (the right column or the float on screen) or not, for the same task on the same Mac (0.4.0's A/B: alternate
the two, a few runs each). Prints the decision time per step -- the loop's model calls' latency_ms, per call -- for
each side (median, mean, n) and how much slower the watched side is. It only reads the files.
"""

import argparse
import json
import statistics
import sys


def latencies(paths):
    out = []
    for p in paths:
        with open(p, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("kind") == "model_call" and e.get("role") == "loop" and e.get("outcome") == "answered":
                    ms = e.get("latency_ms")
                    if isinstance(ms, (int, float)):
                        out.append(float(ms))
    return out


def side(name, v):
    if not v:
        return f"{name}: no model calls found"
    return f"{name}: median {statistics.median(v):.0f} ms, mean {statistics.mean(v):.0f} ms, n {len(v)}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--with", dest="watched", nargs="+", required=True, help="traces recorded with the live view watched")
    ap.add_argument("--without", dest="unwatched", nargs="+", required=True, help="traces recorded without")
    a = ap.parse_args()
    w, u = latencies(a.watched), latencies(a.unwatched)
    print(side("watched", w))
    print(side("not watched", u))
    if w and u:
        slower = statistics.median(w) / statistics.median(u) - 1
        verdict = "within" if slower <= 0.05 else "OVER"
        print(f"watched is {slower * 100:+.1f} % per step (median): {verdict} the 5 % bound")
        return 0 if slower <= 0.05 else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
