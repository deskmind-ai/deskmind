#!/usr/bin/env python3
"""Sums up DeskMind's UI event log (app/Shared/UIEvents.swift, plan section 5) for an acceptance run.

    app/tools/ui_events_summary.py [--since TIME] [--dir DIR | FILE ...]

TIME is an ISO date or time ("2026-10-25", "2026-10-25T14:00") in local time, or milliseconds since 1970; only
events at or after it count. Without files it reads ui-events.jsonl and ui-events-helper.jsonl (and their .1) in
DIR, by default ~/Library/Application Support/DeskMind. It only reads; nothing leaves this Mac.

Prints, per task: cards shown by kind and where they were answered, take-backs, expiries, re-asks and undo
outcomes; then the time from a card shown to the pick that was sent (median and 90th percentile) by the main
window's state when it came; then activations by cause, pauses, and l10n misses.

An answer is a card_sent: its pick is the last one before it (a pick taken back is no answer; one held and dropped --
the card closed, cloud models went off -- has no card_sent). An activation is explained by DeskMind's own funnel (its
`by`), by the user's own event AppKit was handling then (a mouse-down, a key-down: `input`), or by a reopen the app
was asked for or a live-card open the helper logged within a second of it; any other is "unexplained" (acceptance
wants 0). Nothing is guessed from timing of the user's input.
"""

import argparse
import datetime
import json
import os
import sys
from collections import Counter, defaultdict

FILES = ["ui-events.jsonl", "ui-events-helper.jsonl"]
NEAR_MS = 1000
# the event AppKit was handling as the app became active, when it is the user's own: a click, a key (⌘Tab)
USER_INPUT = {"mouse_down_in_window", "mouse_down", "key_down"}


def parse_since(s):
    if s is None:
        return 0
    if s.isdigit():
        return int(s)
    t = datetime.datetime.fromisoformat(s)
    return int(t.timestamp() * 1000)


def read(paths, since):
    events, bad = [], 0
    for p in paths:
        if not os.path.exists(p):
            continue
        with open(p, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    bad += 1
                    continue
                if isinstance(e, dict) and isinstance(e.get("t"), int) and e["t"] >= since:
                    events.append(e)
    events.sort(key=lambda e: e["t"])
    return events, bad


def pct(values, q):
    """The q-quantile (0..1) by the nearest rank."""
    if not values:
        return None
    v = sorted(values)
    k = max(0, min(len(v) - 1, int(-(-q * len(v) // 1)) - 1))
    return v[k]


def ms(v):
    return "-" if v is None else f"{v / 1000:.1f}s"


def counts(c):
    return ", ".join(f"{k} {n}" for k, n in sorted(c.items())) or "-"


def summary(events):
    out = []
    tasks = defaultdict(lambda: {"shown": Counter(), "answered_in": Counter(), "take_backs": 0, "expired": 0,
                                 "reasks": 0, "undo": Counter()})
    window_of = {}  # (run, ask) -> the window when the card came
    last_pick = {}  # (run, ask) -> its pick held now (taken back: none)
    answers = []    # (card, the pick that was sent)
    activations_raw, reopens, live_opens = [], [], []
    activations = Counter()
    pauses, paused_ms = 0, 0
    l10n = Counter()

    for e in events:
        name, run = e.get("e"), e.get("run_id", "-")
        card = (run, e.get("ask_id"))
        t = tasks[run]
        if name == "card_shown":
            t["shown"][e.get("kind", "?")] += 1
            window_of[card] = e.get("window", "?")
        elif name == "card_pick":
            last_pick[card] = e
        elif name == "card_take_back":
            t["take_backs"] += 1
            last_pick.pop(card, None)
        elif name == "card_sent":
            p = last_pick.pop(card, None)
            if p is not None:
                answers.append((card, p))
        elif name == "card_ended" and e.get("why") == "expired":
            t["expired"] += 1
        elif name == "card_reask":
            t["reasks"] += 1
        elif name == "undo":
            t["undo"][e.get("outcome", "?")] += 1
        elif name == "activation":
            activations_raw.append(e)
        elif name == "reopen_asked":
            reopens.append(e["t"])
        elif name == "live_card_open":
            live_opens.append(e["t"])
        elif name == "paused":
            pauses += 1
            paused_ms += e.get("ms", 0)
        elif name == "l10n_miss":
            l10n[e.get("key", "?")] += 1

    picks_by_window = defaultdict(list)
    for card, e in answers:
        tasks[card[0]]["answered_in"][e.get("place", "?")] += 1
        picks_by_window[window_of.get(card, "?")].append(e.get("ms", 0))

    def near(times, t):
        return any(abs(x - t) <= NEAR_MS for x in times)

    for e in activations_raw:
        by = e.get("by", "none")
        if by != "none":
            activations[by] += 1
        elif e.get("input") in USER_INPUT:
            activations["user_" + e["input"]] += 1
        elif near(live_opens, e["t"]):
            activations["live_card"] += 1
        elif near(reopens, e["t"]):
            activations["reopen_asked"] += 1
        else:
            activations["unexplained"] += 1

    out.append("Tasks")
    out.append("| task | cards shown | answered in | take-backs | expired | re-asks | undo |")
    out.append("|---|---|---|---|---|---|---|")
    for run in sorted(r for r in tasks if r != "-"):
        t = tasks[run]
        out.append(f"| {run} | {counts(t['shown'])} | {counts(t['answered_in'])} | {t['take_backs']} | {t['expired']} "
                   f"| {t['reasks']} | {counts(t['undo'])} |")
    out.append("")
    out.append("Time to answer, by the main window when the card came")
    out.append("| window | picks | median | p90 |")
    out.append("|---|---|---|---|")
    for w in sorted(picks_by_window):
        v = picks_by_window[w]
        out.append(f"| {w} | {len(v)} | {ms(pct(v, 0.5))} | {ms(pct(v, 0.9))} |")
    out.append("")
    out.append(f"Activations: {counts(activations)}; unexplained (must be 0): {activations.get('unexplained', 0)}")
    out.append(f"Pauses: {pauses}, {ms(paused_ms) if pauses else '0.0s'} in all")
    out.append(f"l10n misses: {counts(l10n)}")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="ISO date/time (local) or ms since 1970")
    ap.add_argument("--dir", default=os.path.expanduser("~/Library/Application Support/DeskMind"))
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    paths = a.files or [os.path.join(a.dir, f + s) for f in FILES for s in (".1", "")]
    events, bad = read(paths, parse_since(a.since))
    sys.stdout.write(summary(events))
    if bad:
        sys.stderr.write(f"{bad} unreadable lines skipped\n")


if __name__ == "__main__":
    main()
