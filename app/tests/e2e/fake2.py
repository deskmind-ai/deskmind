"""fake_model.py with a mode for the op-run e2e (tests/e2e/OpRunE2E.swift, run by session.sh): no network, no key.
`python3 fake2.py <port file> undo`: a computer task's loop model makes a.txt in the folder, then finishes done (and a
judge passes it), so its result card offers undo; otherwise as fake_model.py.

It answers by who is asking, read from the tools the request offers:
- the session's model (it is offered `computer_task`): a greeting to 你好, a long reply to 讲个长故事, and a line after
  a computer task's result;
- a computer task's loop model (offered `ask_user`): first a question card (ask_user with two options), then, once
  answered, finish as `cannot` (nothing on the simulated computer is touched);
- anything else (a judge): an empty answer, which the executor reads as no conclusion.

    python3 fake_model.py <port file>      (listens on 127.0.0.1, a free port, written to the file)

GET /calls answers {"calls": n}: how many model requests it has had (any caller), so a test can tell that none went out.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QUESTION = "要用哪个颜色？"
OPTIONS = ["红", "蓝"]
LONG = [f"第{i}段。" for i in range(40)]
CALLS = [0]
MODE = sys.argv[2] if len(sys.argv) > 2 else ""
LOG = []
COUNT = threading.Lock()


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        with COUNT:
            n = CALLS[0]
        data = json.dumps({"calls": n}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        with COUNT:
            CALLS[0] += 1
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))) or b"{}")
        tools = [t.get("function", {}).get("name") for t in body.get("tools") or []]
        msgs = body.get("messages") or []
        stream = body.get("stream", False)
        if "computer_task" in tools:
            last = msgs[-1] if msgs else {}
            if last.get("role") == "tool":
                self.reply(stream, chunks=["任务", "结束了。"])
            elif "讲个长故事" in text_of(last.get("content")):
                self.reply(stream, chunks=LONG, delay=0.05)
            elif "你好" in text_of(last.get("content")):
                self.reply(stream, chunks=["你好，", "我是", "测试模型。"])
            else:
                self.reply(stream, chunks=["收到。"])
        elif "ask_user" in tools and MODE == "undo":
            calls = sum(1 for m in msgs if m.get("role") == "assistant" and m.get("tool_calls"))
            create = next((t for t in tools if t and "create_text" in t), None)
            LOG.append(tools)
            if calls == 0 and create:
                self.reply(stream, tool=(create, {"parent": ".", "name": "a.txt", "text": "hi"}))
            else:
                self.reply(stream, tool=("finish", {"outcome": "done", "summary": "created a.txt in the folder"}))
        elif "ask_user" in tools:
            calls = sum(1 for m in msgs if m.get("role") == "assistant" and m.get("tool_calls"))
            if calls == 0:
                self.reply(stream, tool=("ask_user", {"question": QUESTION, "options": OPTIONS}))
            elif calls == 1:
                self.reply(stream, tool=("finish", {"outcome": "cannot", "summary": "测试任务：只问了一个问题，没有动电脑。"}))
            else:
                self.reply(stream, chunks=["好了。"])
        elif MODE == "undo":
            self.reply(stream, chunks=['{"choice":"pass","reason":"the file is there","claims_contradicted":[]}'])
        else:
            self.reply(stream, chunks=[""])

    def reply(self, stream, chunks=(), tool=None, delay=0.0):
        if not stream:
            msg = {"role": "assistant", "content": "".join(chunks)}
            finish = "stop"
            if tool:
                msg = {"role": "assistant", "content": None, "tool_calls": [
                    {"id": "call_1", "type": "function", "function": {"name": tool[0], "arguments": json.dumps(tool[1], ensure_ascii=False)}}]}
                finish = "tool_calls"
            data = json.dumps({"id": "c1", "object": "chat.completion", "created": 0, "model": "fake",
                               "choices": [{"index": 0, "message": msg, "finish_reason": finish}],
                               "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()

        def chunk(delta, finish=None):
            c = {"id": "c1", "object": "chat.completion.chunk", "created": 0, "model": "fake",
                 "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(c, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant", "content": ""})
        if tool:
            chunk({"tool_calls": [{"index": 0, "id": "call_1", "type": "function",
                                   "function": {"name": tool[0], "arguments": json.dumps(tool[1], ensure_ascii=False)}}]})
            chunk({}, "tool_calls")
        else:
            for c in chunks:
                if delay:
                    time.sleep(delay)
                chunk({"content": c})
            chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as f:
        f.write(str(server.server_address[1]))
    server.serve_forever()
