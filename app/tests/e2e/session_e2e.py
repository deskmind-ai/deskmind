"""The helper's chat sessions, end to end through its socket (run by tests/e2e/session.sh).

Starts the fake model service (fake_model.py) and SessionE2E (Helper/SessionHost.swift behind a socket of its own),
then drives the socket as the main app would. Each check prints PASS or FAIL; the exit status is the number of
failures.

    python3 -I session_e2e.py <SessionE2E> <node> <harness.mjs> <out dir> [<SessionClientE2E> [<ShellE2E>]]
"""
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
BIN, NODE, BUNDLE, OUT = sys.argv[1:5]
CLIENT = sys.argv[5] if len(sys.argv) > 5 else None     # SessionClientE2E: the app's client, on a helper of its own
SHELL = sys.argv[6] if len(sys.argv) > 6 else None      # ShellE2E: the 0.5 window's model, on a helper (and a folder) of its own
DIR = os.path.join(OUT, "support")
SHELL_DIR = os.path.join(OUT, "shell-support")
# a Unix socket's path is at most 103 bytes: beside the output when that is short enough, else in a folder of its own
SOCK = os.path.join(OUT, "s.sock")
if len(SOCK.encode()) > 100:
    SOCK = os.path.join(tempfile.mkdtemp(prefix="dms", dir=tempfile.gettempdir() if len(tempfile.gettempdir()) < 80 else "/tmp"), "s.sock")
IDLE = 4
CONFIG = "openai:local|fake"
LONG = "".join(f"第{i}段。" for i in range(40))
failures = 0


def check(ok, what):
    global failures
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures += 1


def until(f, timeout=30.0, step=0.05):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = f()
        if v:
            return v
        time.sleep(step)
    return None


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    return s


def request(body, timeout=60):
    s = connect()
    s.settimeout(timeout)
    s.sendall((json.dumps(body, ensure_ascii=False) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data or b"{}")


class Watch:
    """One sessions.watch connection: every line it gets, in order."""

    def __init__(self, after=None, runs=None):
        self.lines = []
        self.sock = connect()
        body = {"op": "sessions.watch", "after": after or {}}
        if runs:
            body["runs"] = runs
        self.sock.sendall((json.dumps(body) + "\n").encode())
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        while True:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self.lines.append(json.loads(line))

    def close(self):
        self.sock.close()

    def kinds(self, kind, sid=None):
        return [e for e in list(self.lines) if e.get("kind") == kind and (sid is None or e.get("session_id") == sid)]

    def stored(self, sid):
        return [e["seq"] for e in list(self.lines) if e.get("session_id") == sid and str(e.get("kind", "")).startswith("session.") and "seq" in e]

    def last_seq(self, sid):
        s = self.stored(sid)
        return s[-1] if s else 0


def send(sid, line):
    return request({"op": "session.send", "session_id": sid, "line": line})


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def start_helper(env, folder=DIR):
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    p = subprocess.Popen([BIN, "serve", SOCK, folder, NODE, BUNDLE, str(IDLE)], env=env, stdout=subprocess.PIPE,
                         stderr=open(os.path.join(OUT, "helper.log"), "a"), text=True)
    assert p.stdout.readline().strip() == "listening"
    return p


def ui(run=None):
    """What the live card and the recording were driven with (SessionE2E's recorder), for one run or all."""
    items = request({"op": "e2e.ui"}).get("ui", [])
    return [i for i in items if run is None or i.get("run_id") == run]


def task_running():
    return request({"op": "e2e.state"}).get("task_running")


def run_seqs(w, run):
    return [e["seq"] for e in list(w.lines) if e.get("run_id") == run and "seq" in e and not str(e.get("kind", "")).startswith("session.")]


def session_lines(sid):
    with open(os.path.join(DIR, "sessions", sid, "session.jsonl")) as f:
        return [json.loads(l) for l in f if l.strip()]


def main():
    os.makedirs(DIR, exist_ok=True)
    port_file = os.path.join(OUT, "port")
    fake = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "fake_model.py"), port_file])
    until(lambda: os.path.exists(port_file) and open(port_file).read().strip())
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ["HOME"], "LOCAL_API_KEY": "test-key",
           "LOCAL_URL": f"http://127.0.0.1:{open(port_file).read().strip()}"}
    helper = start_helper(env)
    helpers = [helper]
    try:
        run(env, helper)
        if CLIENT:
            for p in helpers:
                if p.poll() is None:
                    p.kill(); p.wait()
            helpers.append(start_helper(env))
            r = subprocess.run([CLIENT, SOCK, CONFIG], capture_output=True, text=True, timeout=240)
            print(r.stdout, end="")
            check(r.returncode == 0, f"the app's session client against the helper ({r.returncode} failures){r.stderr[-400:]}")
        if SHELL:
            # the 0.5 window's model: a conversation, then the app quits and the helper restarts (the sessions' processes
            # go with it), then the app again; defaults in a suite of their own (removed at the end), a folder of its own
            os.makedirs(SHELL_DIR, exist_ok=True)
            suite = f"ai.deskmind.e2e.shell.{os.getpid()}"
            state = os.path.join(OUT, "shell-state")
            for phase in ["a", "b"]:
                for p in helpers:
                    if p.poll() is None:
                        p.kill(); p.wait()
                helpers.append(start_helper(env, SHELL_DIR))
                r = subprocess.run([SHELL, phase, SOCK, CONFIG, suite, SHELL_DIR, state], capture_output=True, text=True, timeout=300,
                                   env={**os.environ, "FAKE_MODEL_PORT": open(port_file).read().strip()})
                print(r.stdout, end="")
                check(r.returncode == 0, f"the 0.5 window's model against the helper, phase {phase} ({r.returncode} failures){r.stderr[-400:]}")
            subprocess.run(["defaults", "delete", suite], capture_output=True)
    finally:
        for p in helpers + [fake]:
            if p.poll() is None:
                p.kill()
        # the session processes go when their helper does (stdin's end); any left are reported, then stopped
        pattern = f"harness.mjs session --dir {OUT}/"
        left = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
        check(until(lambda: not subprocess.run(["pgrep", "-f", pattern], capture_output=True).stdout, 20) is not None,
              f"no session process outlives the test ({left})")
        for pid in subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split():
            os.kill(int(pid), signal.SIGKILL)


def run(env, helper):
    r = request({"op": "sessions.list"})
    check(r.get("ok") is True and r.get("sessions") == [], f"sessions.list, none yet: {r}")

    w1 = Watch()
    check(until(lambda: w1.kinds("helper.watching")) is not None, "the watch says it is watching")

    o = request({"op": "session.open", "config": CONFIG, "lang": "zh", "driver": "sim"})
    sid = o.get("session_id", "")
    check(o.get("ok") is True and sid.startswith("ses_") and o.get("resumed") is False and o.get("last_seq") == 0, f"session.open, new: {o}")
    again = request({"op": "session.open", "session_id": sid})
    check(again.get("ok") is True and again.get("already_open") is True and again.get("pid") == o.get("pid") and again.get("last_seq") == 0,
          f"session.open, already open (with its last_seq): {again}")
    bad = request({"op": "session.open", "session_id": "../x"})
    check(bad.get("ok") is False and bad.get("code") == "bad_request", f"a session id that is no folder name: {bad}")

    # a chat reply
    check(send(sid, {"type": "say", "text": "你好"}).get("ok") is True, "say")
    reply = until(lambda: [m for m in w1.kinds("session.message", sid) if m.get("role") == "assistant"])
    check(bool(reply) and reply[0]["text"] == "你好，我是测试模型。", f"session.message from the model: {reply}")
    check(w1.stored(sid) == [1, 2], f"stored lines 1, 2: {w1.stored(sid)}")
    check(any(d.get("text") == "" and d.get("offset") == 0 for d in w1.kinds("session.delta", sid)), "the reply's start (an empty delta)")
    check(all(e.get("session_id") == sid for e in w1.lines if e.get("kind") != "helper.watching"), "every line names its session")

    # lines the helper refuses, with the reason
    for line, what in [({"type": "dance"}, "an unknown type"), ("not json", "not JSON"), ({"type": "say"}, "say without text"),
                       ({"type": "answer", "option": 0}, "an answer that names no card"), (["say"], "an array")]:
        r = send(sid, line)
        check(r.get("ok") is False and r.get("code") == "bad_line" and r.get("error"), f"refused: {what}: {r}")
    r = send("ses_nope", {"type": "say", "text": "x"})
    check(r.get("ok") is False and r.get("code") == "not_open", f"a session that is not open: {r}")
    r = send(sid, json.dumps({"type": "say", "text": "你好"}))
    check(r.get("ok") is True, "a line as JSON text")
    until(lambda: len([m for m in w1.kinds("session.message", sid) if m.get("role") == "assistant"]) == 2)

    # cloud models off (harness#64 set_config, the app's switch): no model call at all — a running task stopped, no turn
    # after it, the words refused (no_model) — and back on, the next say answered, in place by the same process
    import urllib.request

    def model_calls():
        with urllib.request.urlopen(env["LOCAL_URL"] + "/calls", timeout=5) as f:
            return json.loads(f.read())["calls"]

    so = request({"op": "session.open", "config": CONFIG, "lang": "zh", "driver": "sim"})
    off = so.get("session_id", "")
    check(send(off, {"type": "cua", "text": "给笔记换个颜色"}).get("ok") is True, "model off: a task first")
    check(until(lambda: w1.kinds("ask", off), 30) is not None, "model off: its card waits")
    calls = model_calls()
    r = send(off, {"type": "set_config", "config": None, "client_id": "c_off"})
    cfg = until(lambda: [e for e in w1.kinds("session.config", off) if e.get("client_id") == "c_off"], 10)
    check(r.get("ok") is True and bool(cfg) and cfg[0].get("config") is None, f"set_config null: sent, stored ({r})")
    send(off, {"type": "stop"})       # the user's Stop as well
    ended = until(lambda: w1.kinds("session.task_end", off), 20)
    check(ended is not None, f"model off: the running task stopped ({ended and ended[0].get('status')})")
    until(lambda: w1.kinds("session.task_closed", off), 20)
    time.sleep(2)
    check(model_calls() == calls, f"model off: no model call after the switch and Stop (no turn after the task): {model_calls() - calls}")
    send(off, {"type": "say", "text": "你好", "client_id": "c_say_off"})
    no = until(lambda: [e for e in w1.kinds("session.error", off) if e.get("code") == "no_model" and e.get("client_id") == "c_say_off"], 10)
    check(no is not None and model_calls() == calls, "model off: a say is refused (no_model), nothing reaches the model")
    r = send(off, {"type": "set_config", "config": CONFIG, "lang": "zh", "client_id": "c_on"})
    check(until(lambda: [e for e in w1.kinds("session.config", off) if e.get("client_id") == "c_on"], 10) is not None, "model back on: stored")
    send(off, {"type": "say", "text": "你好"})
    back = until(lambda: [m for m in w1.kinds("session.message", off) if m.get("role") == "assistant" and m.get("text") == "你好，我是测试模型。"], 30)
    check(back is not None and alive(so.get("pid")), "model back on: answered, by the same process (no restart)")
    r = request({"op": "session.end", "session_id": off})
    check(r.get("ok") is True and until(lambda: not alive(so.get("pid")), 15) is not None, f"its session ends, idle ({r})")

    # a computer task on the simulated computer: its question card, answered over the socket
    check(send(sid, {"type": "cua", "text": "给笔记换个颜色"}).get("ok") is True, "cua")
    # the app ends the session right after the /cua, before its session.task can have come back (#107 review): the
    # helper asks the session itself, after the /cua, and refuses — the task is not stopped
    r = request({"op": "session.end", "session_id": sid})
    check(r.get("ok") is False and r.get("code") == "not_idle" and "busy" in (r.get("why") or []),
          f"session.end right after a /cua: refused, not idle, and why — the session's own answer to end_if_idle ({r})")
    ask = until(lambda: w1.kinds("ask", sid))
    task = w1.kinds("session.task", sid)
    check(bool(ask) and bool(task) and ask[0].get("run_id") == task[0].get("run_id"), f"the task's card comes through, with its session: {ask and ask[0].get('card', {}).get('text')}")
    run_id = task[0]["run_id"] if task else ""
    check(task_running() is True, "a task runs: the helper does not restart under it")
    if ask:
        check(ask[0]["card"]["text"] == "要用哪个颜色？", "the card's question")
        r = send(sid, {"type": "say", "text": "插一句"})
        refusal = until(lambda: [e for e in w1.kinds("session.error", sid) if e.get("code") == "card_open"], 10)
        check(r.get("ok") is True and bool(refusal), "say while a card waits: the session refuses it (card_open)")
        r = send(sid, {"type": "answer", "run_id": run_id, "ask_id": ask[0]["ask_id"], "option": 0})
        check(r.get("ok") is True, "answer")
    done = until(lambda: w1.kinds("task_done", sid))
    check(bool(done) and done[0].get("run_id") == run_id, f"task_done: {done and done[0].get('status')}")
    check(until(lambda: w1.kinds("session.task_closed", sid)) is not None, "session.task_closed")
    after_task = until(lambda: [m for m in w1.kinds("session.message", sid) if m.get("text") == "任务结束了。"])
    check(after_task is not None, "the model's line after the task")
    answered = [e for e in w1.kinds("resumed", sid) if e.get("ask_id") == (ask[0]["ask_id"] if ask else None)]
    check(bool(answered), "the card closed (resumed)")
    runs = [e for e in w1.lines if e.get("run_id") == run_id and not str(e.get("kind", "")).startswith("session.")]
    seqs = [e["seq"] for e in runs]
    check(seqs == list(range(1, len(seqs) + 1)), f"the task's lines once each, in order: {seqs}")
    # the live card, on by default (as for op run), follows the task: one start, its events, one finish
    drove = ui(run_id)
    whats = [d["what"] for d in drove]
    check(whats[:1] == ["start"] and whats.count("start") == 1 and "show" in whats and whats[-1:] == ["finish"] and whats.count("finish") == 1,
          f"the live card is shown without live_view (default on): {whats}")
    check(until(lambda: task_running() is False, 5) is not None, "the task over, no undo offered: nothing holds a restart")

    # disconnect; the chat goes on; reconnect with the cursor: no duplicate, no gap, the reply in progress caught up
    n = w1.last_seq(sid)
    check(w1.stored(sid) == list(range(1, n + 1)), f"the first watch: 1..{n}")
    w1.close()
    time.sleep(0.3)
    check(send(sid, {"type": "say", "text": "你好"}).get("ok") is True, "say while nobody watches")
    check(until(lambda: session_lines(sid)[-1]["seq"] == n + 2, 10) is not None, "its reply is stored")
    check(send(sid, {"type": "say", "text": "讲个长故事"}).get("ok") is True, "a long reply starts")
    r = request({"op": "session.end", "session_id": sid})
    check(r.get("ok") is False and r.get("code") == "not_idle" and "busy" in (r.get("why") or []),
          f"session.end while a reply streams: refused, busy ({r})")
    time.sleep(0.6)   # some of it streamed while nobody watched
    w2 = Watch(after={sid: n})
    w3 = Watch()       # from the beginning, at the same time
    final = until(lambda: [m for m in w2.kinds("session.message", sid) if m.get("text") == LONG], 30)
    check(final is not None, "the long reply reaches the reconnected watch")
    last = session_lines(sid)[-1]["seq"]
    until(lambda: w3.last_seq(sid) == last, 10)
    check(w2.stored(sid) == list(range(n + 1, last + 1)), f"reconnected at {n}: {n + 1}..{last} once each, in order: {w2.stored(sid)}")
    check(w3.stored(sid) == list(range(1, last + 1)), f"from the beginning: 1..{last} once each: {w3.stored(sid)}")
    if final:
        mid = final[0]["msg_id"]
        # as the app reads them: a delta past what it has is a gap (it joined mid-reply), skipped until the replay's
        # delta from offset 0 brings the whole text so far
        text, caught_up = "", False
        for d in w2.kinds("session.delta", sid):
            if d.get("msg_id") != mid or d["offset"] > len(text):
                continue
            caught_up = caught_up or (d["offset"] == 0 and len(d["text"]) > 0)
            text = text[:d["offset"]] + d["text"]
        check(caught_up and text == LONG, f"the reply in progress, caught up: its deltas by offset make the final text ({len(text)}/{len(LONG)})")
    check(not any(e.get("run_id") == run_id for e in w2.lines), "a closed task is not replayed to a cursor past it")
    # a task the app has up to seq 3: the rest of it, once, and nothing of the session it already has
    w7 = Watch(after={sid: last}, runs={run_id: 3})
    total = len(seqs)
    until(lambda: len([e for e in w7.lines if e.get("run_id") == run_id]) >= total - 3, 10)
    time.sleep(0.5)
    got = [e["seq"] for e in w7.lines if e.get("run_id") == run_id and not str(e.get("kind", "")).startswith("session.")]
    check(got == list(range(4, total + 1)) and w7.stored(sid) == [], f"a task's cursor: its lines after 3, once ({got})")
    # a replay the app asks for itself reaches every watch, and none takes a line twice
    send(sid, {"type": "attach", "after_seq": 0})
    send(sid, {"type": "attach", "after_seq": 0, "run_id": run_id})
    time.sleep(1)
    got = [e["seq"] for e in w7.lines if e.get("run_id") == run_id and not str(e.get("kind", "")).startswith("session.")]
    check(got == list(range(4, total + 1)) and w7.stored(sid) == [] and w3.stored(sid) == list(range(1, last + 1)), "an extra replay: nothing twice")
    w7.close()
    check(len(ui(run_id)) == len(drove), f"replays of a finished task drive neither the card nor the recording ({len(ui(run_id))} vs {len(drove)})")

    # watches that join while a task's lines flow, with only a session cursor: each gets the task's lines replay first,
    # then live, contiguous from 1 (a live line that comes before the replay below it waits for it)
    check(send(sid, {"type": "cua", "text": "给笔记换个颜色"}).get("ok") is True, "another task")
    ask = until(lambda: [a for a in w2.kinds("ask", sid) if a.get("run_id") != run_id], 30)
    run1 = ask[0]["run_id"] if ask else ""
    joined = []
    if ask:
        send(sid, {"type": "answer", "run_id": run1, "ask_id": ask[0]["ask_id"], "option": 0})
        t0 = time.time()
        while time.time() - t0 < 0.4:
            joined.append(Watch(after={sid: 10 ** 6}))
            time.sleep(0.003)
    until(lambda: [e for e in w2.kinds("session.task_closed", sid) if e.get("run_id") == run1], 30)
    total1 = len(run_seqs(w2, run1))
    time.sleep(1.0)
    # a watch that joined once the task was closed gets none of it (a closed task is not replayed past the cursor)
    full = [w for w in joined if run_seqs(w, run1) == list(range(1, total1 + 1))]
    bad = [run_seqs(w, run1) for w in joined if run_seqs(w, run1) and w not in full]
    check(total1 > 0 and len(full) > 0 and not bad, f"{len(full)} of {len(joined)} watches joined mid-task, each got 1..{total1} in order, once ({bad[:2]})")
    for w in joined:
        w.close()
    whats = [d["what"] for d in ui(run1)]
    check(whats.count("start") == 1 and whats.count("finish") == 1, f"those replays drove the card once: {whats.count('start')} start, {whats.count('finish')} finish")
    until(lambda: [m for m in w2.kinds("session.message", sid) if m.get("text") == "任务结束了。" and m.get("seq", 0) > last], 20)
    last = session_lines(sid)[-1]["seq"]
    until(lambda: w2.last_seq(sid) == last and w3.last_seq(sid) == last, 10)
    again = request({"op": "session.open", "session_id": sid})
    check(again.get("already_open") is True and again.get("last_seq") == last, f"open again: last_seq is the last stored ({again.get('last_seq')} vs {last})")

    # the helper's side of the same lock file (ComputerLock): an op run takes the Mac between two session tasks
    check(request({"op": "e2e.acquire", "run_id": "run_oprun1"}).get("ok") is True, "an op run takes the Mac when no task acts")

    # a task whose executor dies before its task_done: its card ends with the session's task_end, and the next task of
    # the session still gets one
    send(sid, {"type": "cua", "text": "给笔记换个颜色"})
    ask = until(lambda: [a for a in w2.kinds("ask", sid) if a.get("run_id") not in (run_id, run1)], 30)
    runk = ask[0]["run_id"] if ask else ""
    ex = subprocess.run(["pgrep", "-f", f"executor --linger .* --runs {DIR}/sessions/{sid}/runs"], capture_output=True, text=True).stdout.split()
    for pid in ex:
        os.kill(int(pid), signal.SIGKILL)
    ended = until(lambda: [e for e in w2.kinds("session.task_end", sid) if e.get("run_id") == runk], 15)
    check(bool(ex) and ended is not None and ended[0].get("status") == "failed", f"the executor killed: the session ends the task ({ex}, {ended and ended[0].get('status')})")
    whats = [d["what"] for d in ui(runk)]
    check(whats[:1] == ["start"] and whats[-1:] == ["finish"], f"its card ends without a task_done: {whats}")
    until(lambda: [e for e in w2.kinds("session.task_closed", sid) if e.get("run_id") == runk], 10)
    until(lambda: [m for m in w2.kinds("session.message", sid) if m.get("role") == "assistant" and m.get("seq", 0) > ended[0].get("seq", 0)] if ended else True, 20)
    send(sid, {"type": "cua", "text": "给笔记换个颜色"})
    ask = until(lambda: [a for a in w2.kinds("ask", sid) if a.get("run_id") not in (run_id, run1, runk)], 30)
    runn = ask[0]["run_id"] if ask else ""
    check(bool(runn) and [d["what"] for d in ui(runn)][:1] == ["start"], "the next task of the session gets its card")
    if ask:
        send(sid, {"type": "answer", "run_id": runn, "ask_id": ask[0]["ask_id"], "option": 0})
    until(lambda: [e for e in w2.kinds("session.task_closed", sid) if e.get("run_id") == runn], 30)
    # (w2 joined after the first task: it has the model's line after each of the other three; waiting for a fourth
    # sat 20 s idle, long enough for the helper to close the session — #107: it closes idle sessions watched or not)
    until(lambda: len([m for m in w2.kinds("session.message", sid) if m.get("text") == "任务结束了。"]) >= 3, 20)
    time.sleep(0.5)
    last = session_lines(sid)[-1]["seq"]
    until(lambda: w2.last_seq(sid) == last and w3.last_seq(sid) == last, 10)

    r = request({"op": "sessions.list"})
    item = [s for s in r.get("sessions", []) if s.get("session_id") == sid]
    check(r.get("ok") is True and bool(item) and item[0].get("open") is True and item[0].get("title") == "你好", f"sessions.list: {item}")

    # the machine lock: held by a live process the way the helper's own run holds it, a session's task is refused
    lock = os.path.join(DIR, "sessions", "computer.lock")
    held = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)   # an executor's group (its owner gone)
    with open(lock + ".tmp", "w") as f:
        json.dump({"v": 2, "state": "acting", "pgid": held.pid, "pid": held.pid, "start": 0, "run_id": "run_helper",
                   "session_id": "", "by": "helper", "owner": 999999, "t": 0}, f)
    os.rename(lock + ".tmp", lock)
    send(sid, {"type": "cua", "text": "再换一次"})
    busy = until(lambda: [e for e in w2.kinds("session.error", sid) if e.get("code") == "computer_busy"], 15)
    check(busy is not None, "the helper's lock (its run's group, acting) keeps a session's task from starting (computer_busy)")
    held.kill()
    held.wait()
    os.unlink(lock)

    # end, then reopen: resumed, and the watches get nothing twice
    pid = o.get("pid")
    check(request({"op": "session.end", "session_id": sid}).get("ok") is True, "session.end")
    check(until(lambda: w2.kinds("helper.session_exit", sid), 20) is not None, "the watch hears the process end")
    ex = w2.kinds("helper.session_exit", sid)[-1] if w2.kinds("helper.session_exit", sid) else {}
    check(ex.get("pid") == pid and ex.get("start_seq") == 0 and ex.get("last_seq") == session_lines(sid)[-1]["seq"],
          f"session_exit names the process: pid, start_seq, last_seq ({ex})")
    check(until(lambda: not alive(pid), 5) is not None, "the process is gone")
    r = request({"op": "sessions.list"})
    check([s.get("open") for s in r.get("sessions", []) if s.get("session_id") == sid] == [False], "listed, not open")
    o2 = request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim"})
    check(o2.get("ok") is True and o2.get("resumed") is True and o2.get("last_seq") == last, f"reopened: {o2}")
    send(sid, {"type": "say", "text": "你好"})
    until(lambda: w2.last_seq(sid) == last + 2, 15)
    check(w2.stored(sid) == list(range(n + 1, last + 3)), f"after the reopen, the watch goes on without a repeat: {w2.stored(sid)[-4:]}")
    check(w3.stored(sid) == list(range(1, last + 3)), "the other watch too")
    last += 2

    # its history from the stored log, while it runs and with no process (#107 review: reading needs none)
    h = request({"op": "session.history", "session_id": sid, "after_seq": last - 2})
    check(h.get("ok") is True and h.get("open") is True and [e.get("seq") for e in h.get("lines", []) if str(e.get("kind")).startswith("session.")] == [last - 1, last]
          and all(e.get("session_id") == sid for e in h.get("lines", [])), f"session.history after a cursor, open: {[e.get('seq') for e in h.get('lines', [])]}")

    # idle and watched (#107 review: each process is ~80 MB): the helper closes it all the same, says it was idle (no
    # run cut), and the watch goes on; reading it needs no process
    pid2 = o2["pid"]
    check(until(lambda: not alive(pid2), IDLE + 20) is not None, f"an idle session closes after {IDLE} s, watched")
    exits = until(lambda: [e for e in w2.kinds("helper.session_exit", sid) if e.get("pid") == pid2], 10) or []
    check(bool(exits) and exits[-1].get("idle") is True, f"its exit says idle: {exits[-1:]}")
    h = request({"op": "session.history", "session_id": sid, "runs": {run_id: 0}})
    whole = [e["seq"] for e in session_lines(sid)]
    check(h.get("ok") is True and h.get("open") is False and h.get("last_seq") == whole[-1]
          and [e.get("seq") for e in h.get("lines", []) if str(e.get("kind")).startswith("session.")] == whole
          and [e["seq"] for e in h.get("lines", []) if e.get("run_id") == run_id and not str(e.get("kind")).startswith("session.")] == seqs,
          f"session.history with no process: the whole story and the task's lines ({h.get('open')}, {h.get('last_seq')})")
    w = request({"op": "sessions.list"})
    check([x.get("open") for x in w.get("sessions", []) if x.get("session_id") == sid] == [False], "listed, not open")
    w9 = Watch(after={sid: last})
    hw = until(lambda: w9.kinds("helper.watching"), 5)
    check(bool(hw) and sid in hw[0].get("idle", []), f"a watch that comes later hears it was closed idle: {hw and hw[0]}")
    w9.close()
    # a restart the app asks for while a task waits on its card: deferred, the task goes on; done once it is idle
    o2 = request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim"})
    pid2 = o2.get("pid")
    send(sid, {"type": "cua", "text": "给笔记换个颜色"})
    askd = until(lambda: [a for a in w2.kinds("ask", sid) if a.get("run_id") not in (run_id, run1, runk, runn)], 30)
    rund = askd[0]["run_id"] if askd else ""
    r = request({"op": "session.end", "session_id": sid, "when_idle": True})
    check(r.get("ok") is True and r.get("deferred") is True, f"a restart while a task waits on its card: deferred ({r})")
    time.sleep(1)
    check(alive(pid2), "the task's session stays up meanwhile")
    if askd:
        send(sid, {"type": "answer", "run_id": rund, "ask_id": askd[0]["ask_id"], "option": 0})
    check(until(lambda: not alive(pid2), 40) is not None, "the task over and its reply done: the restart happens")
    ends = [e for e in w2.kinds("session.task_end", sid) if e.get("run_id") == rund]
    exits = until(lambda: [e for e in w2.kinds("helper.session_exit", sid) if e.get("pid") == pid2], 10) or []
    check(bool(ends) and ends[-1].get("status") != "stopped" and bool(exits) and exits[-1].get("idle") is True,
          f"the task was not stopped by it ({ends and ends[-1].get('status')}), the exit says idle")
    until(lambda: w2.last_seq(sid) == session_lines(sid)[-1]["seq"], 10)
    last = session_lines(sid)[-1]["seq"]

    # idle and unwatched: the session closes; with a task waiting on its card, it stays (the app closed, the card waits)
    o2 = request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim"})
    w2.close(); w3.close()
    pid2 = o2["pid"]
    check(until(lambda: not alive(pid2), IDLE + 20) is not None, f"an idle session nobody watches closes after {IDLE} s")
    o3 = request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim", "live_view": False})
    w4 = Watch(after={sid: last})
    sent2 = send(sid, {"type": "cua", "text": "给笔记换个颜色"})
    ask2 = until(lambda: w4.kinds("ask", sid), 30)
    check(ask2 is not None, f"a second task waits on its card ({sent2}, {[(e.get('code'), e.get('why'), e.get('text')) for e in w4.kinds('session.error', sid)]})")
    run2 = ask2[0]["run_id"] if ask2 else ""
    whats = [d["what"] for d in ui(run2)]
    check("start" not in whats and "show" not in whats, f"live_view false: no card, the recording only ({whats})")
    r = request({"op": "e2e.acquire", "run_id": "run_oprun2"})
    check(r.get("code") == "computer_busy", f"op run while a session's task holds the Mac: computer_busy ({r.get('code')})")
    w4.close()
    time.sleep(IDLE + 6)
    check(alive(o3["pid"]), "the app gone, the task's session stays up (its card waits)")
    # the app comes back: the waiting card is replayed with its task, from the task's start
    w5 = Watch(after={sid: last})
    back = until(lambda: [e for e in w5.kinds("ask", sid) if e.get("run_id") == run2], 15)
    check(back is not None, "back again: the open task is replayed, its card with it")
    seqs = [e["seq"] for e in w5.lines if e.get("run_id") == run2 and not str(e.get("kind", "")).startswith("session.")]
    check(seqs == sorted(set(seqs)) and seqs[:1] == [1], f"the task's lines once each: {seqs}")
    w5.close()

    # the helper goes: the session's stdin ends, it stops the task itself and exits
    helper.kill()
    helper.wait()
    check(until(lambda: not alive(o3["pid"]), 25) is not None, "the helper gone: the session process exits")
    events = os.path.join(DIR, "sessions", sid, "runs", run2, "events.jsonl")
    td = [json.loads(l) for l in open(events) if '"task_done"' in l] if os.path.exists(events) else []
    check(bool(td) and td[-1].get("status") == "stopped", f"its task stopped itself: {td and td[-1].get('status')}")
    ends = [l for l in session_lines(sid) if l.get("kind") == "session.task_end" and l.get("run_id") == run2]
    check(bool(ends) and ends[-1].get("status") == "stopped", "and the session recorded it")

    # a new helper: the session reopens and its story is whole
    helper2 = start_helper(env)
    try:
        o4 = request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim"})
        check(o4.get("ok") is True and o4.get("resumed") is True, "reopened under a new helper")
        w6 = Watch(runs={run_id: 0, run1: 0, run2: 0})
        stored = session_lines(sid)[-1]["seq"]
        until(lambda: w6.last_seq(sid) == stored, 15)
        check(w6.stored(sid) == list(range(1, stored + 1)), f"its whole history, once: 1..{stored}")
        until(lambda: run_seqs(w6, run_id) and run_seqs(w6, run2), 10)
        time.sleep(0.5)
        check(bool(run_seqs(w6, run_id)) and ui() == [], f"its old tasks replayed under the new helper drive neither the card nor the recording ({ui()[:3]})")
        w6.close()

        # a helper killed outright (SIGKILL) while its run's executor and a child of it still act: the lock names their
        # group, not the helper, so a new helper's run and a session's task are refused until all of it is gone
        hold = subprocess.Popen([BIN, "holdrun", DIR], stdout=subprocess.PIPE, text=True)
        pgid = int(hold.stdout.readline().strip() or 0)
        hold.kill()
        hold.wait()
        members = subprocess.run(["pgrep", "-g", str(pgid)], capture_output=True, text=True).stdout.split()
        check(pgid > 0 and len(members) >= 2, f"the helper gone, its run's group still up ({members})")
        r = subprocess.run([BIN, "tryacquire", DIR], capture_output=True, text=True).stdout.strip()
        check(r == "busy run_held", f"a new helper's op run is refused (computer_busy): {r}")
        w8 = Watch(after={sid: 10 ** 6})
        send(sid, {"type": "cua", "text": "再换一次"})
        refused = until(lambda: [e for e in w8.kinds("session.error", sid) if e.get("code") == "computer_busy"], 15)
        check(refused is not None, "a session's task is refused (computer_busy)")
        os.killpg(pgid, signal.SIGKILL)
        until(lambda: not subprocess.run(["pgrep", "-g", str(pgid)], capture_output=True).stdout, 10)
        r = subprocess.run([BIN, "tryacquire", DIR], capture_output=True, text=True).stdout.strip()
        check(r == "ok", f"the group gone: the next run takes the Mac ({r})")
        w8.close()

        # the helper holds "cloud models off" (models.off: the app's engine setting, written from either window): for
        # every session it runs, whichever client — a running one nulled at once, what needs a model refused, a new
        # one started with null — and it survives a helper restart
        def cfgs(s):
            try:
                return [l for l in session_lines(s) if l.get("kind") == "session.config"]
            except OSError:
                return []
        request({"op": "session.open", "session_id": sid, "config": CONFIG, "driver": "sim"})
        r = request({"op": "models.off", "off": True})
        check(r.get("ok") is True and r.get("off") is True, f"models.off: {r}")
        check(until(lambda: cfgs(sid) and cfgs(sid)[-1].get("config") is None, 10) is not None, "models off: a running session nulled at once (stored)")
        calls = model_calls()
        r = send(sid, {"type": "say", "text": "你好", "client_id": "c_hoff"})
        check(r.get("ok") is False and r.get("code") == "no_model" and r.get("client_id") == "c_hoff", f"models off: a say refused by the helper, no_model ({r})")
        r = send(sid, {"type": "set_config", "config": CONFIG, "lang": "zh"})
        check(r.get("ok") is False and r.get("code") == "no_model", f"models off: a client that still has cloud on cannot set a model back ({r})")
        check(send(sid, {"type": "set_config", "config": None}).get("ok") is True, "models off: a null passes")
        helper2.kill()
        helper2.wait()
        helper2 = start_helper(env)
        o5 = request({"op": "session.open", "config": CONFIG, "lang": "zh", "driver": "sim"})
        s5 = o5.get("session_id", "")
        first = until(lambda: cfgs(s5), 10)
        check(bool(first) and first[0].get("config") is None, f"after a helper restart (the bit kept): a new session's first settings are null ({first and first[0]}; {o5})")
        r = send(s5, {"type": "say", "text": "你好"})
        check(r.get("code") == "no_model" and model_calls() == calls, f"and what needs a model is refused there, no model call ({r})")
        check(request({"op": "models.off", "off": False}).get("ok") is True, "models on again")
        check(send(s5, {"type": "set_config", "config": CONFIG, "lang": "zh"}).get("ok") is True, "models on: a configuration passes")
        check(send(s5, {"type": "say", "text": "你好"}).get("ok") is True, "models on: a say passes")
        check(until(lambda: [m for m in session_lines(s5) if m.get("role") == "assistant"], 30) is not None, "and is answered")
    finally:
        helper2.kill()
        helper2.wait()

    print("session e2e: all passed" if failures == 0 else f"session e2e: {failures} failed", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # a crash is a failure, with its cause
        import traceback
        traceback.print_exc()
        failures += 1
    sys.exit(min(failures, 100))
