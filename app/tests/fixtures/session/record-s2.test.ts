/**
 * Records real session event streams (what `harness.mjs session` writes to stdout) for the app's reducer tests
 * (app/tests/SessionTests.swift reads the *.jsonl next to this file). Same rig as harness test/session-tasks.test.ts: a
 * scripted session model, the executor in process on the simulated computer with a scripted runtime and scripted judges.
 *
 * To record again: copy this file into a harness checkout's test/ (recorded on harness 74e8b80, the one app/deps.lock
 * pins), then
 *   OUT=<dir> npx vitest run test/record-s2.test.ts
 * and copy <dir>/*.jsonl here, replacing the temporary task folders (`"scope":"/var/folders/…"`) with "/tmp/scope".
 */
import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { PassThrough } from "node:stream";
import type { Message } from "@earendil-works/pi-ai";
import { SessionHost } from "../src/session/host.js";
import type { ExecutorHandle, Launcher } from "../src/session/task.js";
import { appRun, LineReader } from "../src/cli/app.js";
import { SimComputer } from "../src/executor/sim.js";
import { OUTGOING_QUESTION } from "../src/executor/judge.js";
import { Gateway } from "../src/gateway/index.js";
import { scriptedStream, type Step } from "../src/runtime/scripted.js";

const OUT = process.env.OUT ?? fs.mkdtempSync(path.join(os.tmpdir(), "s2-fixtures-"));
const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), "s2-rec-"));
const MODEL = { id: "scripted", name: "scripted", api: "openai-completions", provider: "test", baseUrl: "", input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, reasoning: false, contextWindow: 128_000, maxTokens: 8_000 } as never;
const roles = ["goal", "plan", "bind", "intent", "choice", "skill", "verify", "transform"];
type Verify = () => Record<string, unknown>;
const gateway = (verify: Verify = () => ({ choice: "pass", reason: "做完了" })) => {
  const gw = new Gateway(Object.fromEntries(roles.map((r) => [r, { backend: "scripted", model: "scripted" }])) as never);
  gw.script = Array(80).fill((role: string, _s: string, u: string) => (role === "verify" ? verify() : u.includes(OUTGOING_QUESTION.slice(0, 12)) ? { choice: "stays" } : { choice: "matches" }));
  return gw;
};
const lastJson = (ms: any[]) => { const m = [...ms].reverse().find((x) => x.role === "toolResult"); try { return JSON.parse(m.content[0].text.split("\n")[0]); } catch { return {}; } };
const waitFor = async (cond: () => unknown, ms = 15_000) => { const t0 = Date.now(); while (!cond()) { if (Date.now() - t0 > ms) throw new Error("timed out waiting"); await new Promise((r) => setTimeout(r, 5)); } };

function inproc(scripts: Step[][], sim: (scope?: string) => SimComputer, verify?: Verify) {
  let i = 0;
  const launch: Launcher = (req, o) => {
    const steps = scripts[i++] ?? [];
    const input = new PassThrough();
    let ended = false, cb: ((l: string) => void) | null = null;
    const early: string[] = [];
    const out = (e: unknown) => { const l = JSON.stringify(e); if (cb) cb(l); else early.push(l); };
    const exited = appRun(req as never, { runs: o.runs, out, input: new LineReader(input), linger: o.linger,
      inject: { driver: sim(req.scope as string | undefined), gateway: gateway(verify), model: { model: MODEL, streamFn: scriptedStream(steps, []) } } }).then(() => ({ code: 0, signal: null }));
    return { write: (l) => { if (!ended) input.write(l + "\n"); }, close: () => { if (!ended) { ended = true; input.end(); } }, onLine: (f) => { cb = f; for (const l of early.splice(0)) f(l); }, exited } as ExecutorHandle;
  };
  return { launch };
}

const hosts: SessionHost[] = [];
afterEach(async () => { for (const h of hosts.splice(0)) h.end(); await new Promise((r) => setTimeout(r, 50)); });

function session(o: { model: Step[]; tasks?: Step[][]; scope?: string; sim?: (scope?: string) => SimComputer; verify?: Verify; config?: string; noModel?: boolean }) {
  const evs: any[] = [];
  const ex = inproc(o.tasks ?? [], o.sim ?? ((s) => new SimComputer(s)), o.verify);
  let onEvent: ((e: any) => void) | null = null;
  const h = new SessionHost({ dir: tmp(), sessionId: "ses_t", out: (e) => { evs.push(e); onEvent?.(e); }, coalesceMs: 5,
    ...(o.noModel ? {} : { model: { model: MODEL, streamFn: scriptedStream(o.model, []) } }), ...(o.config ? { config: o.config } : {}),
    launch: ex.launch, watchMs: 20, ...(o.scope ? { scope: o.scope } : {}) });
  hosts.push(h);
  h.start();
  const send = (c: Record<string, unknown>) => h.handle(JSON.stringify(c));
  const kinds = (k: string) => evs.filter((e) => e.kind === k);
  const save = (name: string) => fs.writeFileSync(path.join(OUT, name), evs.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return { h, evs, send, kinds, save, on: (f: (e: any) => void) => { onEvent = f; } };
}

const CREATE = (name = "a.txt", text = "hi"): Step[] => [
  { calls: [{ name: "fs_create_text", args: { parent: ".", name, text } }] },
  { calls: [{ name: "finish", args: { outcome: "done", summary: `写了 ${name}` } }] },
];
const EDIT = (w: string, finish: Step[] = [{ calls: [{ name: "finish", args: { outcome: "done", summary: "正文改成了「新的」" } }] }]): Step[] => [
  { calls: [{ name: "computer_snapshot", args: {} }] },
  { calls: [{ name: "computer_observe", args: { window: w } }] },
  { calls: [{ name: "plan", args: { steps: [{ purpose: "把正文改成「新的」", objects: [`window:${w}`], consequence: "modify_user" }] } }] },
  { calls: [{ name: "computer_observe", args: { window: w } }] },
  (m) => ({ calls: [{ name: "computer_act", args: { action: { kind: "set_value", window: w, target: `${w}:0:textarea`, value: "新的" }, epoch: lastJson(m).epoch, consequence: "modify_user", purpose: "改正文", plan_step: 1 } }] }),
  ...finish,
];
const editor = (hook?: (s: SimComputer) => void) => (scope?: string) => { const s = new SimComputer(scope); s.addEditor("编辑器", { title: "笔记.txt", text: "旧的正文", path: null }); hook?.(s); return s; };
const CALL = (goal: string): Step => ({ calls: [{ name: "computer_task", args: { goal } }] });
const approveOf = (e: any) => e.card.options.findIndex((x: any) => x.kind === "approve");

describe("record session fixtures", () => {
  it("chat: streaming, a replaced final, a stopped reply, busy, then attach replays the stored events", async () => {
    const chunks = ["你好，", "我是 ", "DeskMind。", "有什么", "可以帮你？"];
    const long = Array.from({ length: 40 }, (_, i) => `第${i}句。`);
    const s = session({ model: [{ text: chunks.join(""), chunks, delayMs: 15 }, { text: "abc", chunks: ["ab", "c"], final: "xyz" }, { text: long.join(""), chunks: long, delayMs: 25 }] });
    s.send({ type: "say", text: "你好" });
    s.send({ type: "say", text: "插一句" });            // busy: a reply is coming
    await s.h.idle();
    s.send({ type: "say", text: "hi" });
    await s.h.idle();
    s.send({ type: "say", text: "讲个长故事" });
    const before = s.kinds("session.delta").length;
    await waitFor(() => s.kinds("session.delta").slice(before).filter((d) => d.text).length > 4);
    s.send({ type: "stop" });
    await s.h.idle();
    expect(s.kinds("session.message").at(-1)).toMatchObject({ stopped: true });
    expect(s.kinds("session.message").at(-1).text.length).toBeGreaterThan(0);
    s.send({ type: "attach", after_seq: 0 });
    s.save("chat.jsonl");
  });

  it("chat error: no key", async () => {
    const saved = { url: process.env.CUSTOM_URL, key: process.env.CUSTOM_API_KEY };
    process.env.CUSTOM_URL = "http://127.0.0.1:9"; delete process.env.CUSTOM_API_KEY;
    try {
      const s = session({ model: [], config: "openai:custom|some-model", noModel: true });
      s.send({ type: "say", text: "在吗" });
      await s.h.idle();
      expect(s.kinds("session.error")[0]).toMatchObject({ code: "no_key" });
      s.save("chat-error.jsonl");
    } finally {
      if (saved.url === undefined) delete process.env.CUSTOM_URL; else process.env.CUSTOM_URL = saved.url;
      if (saved.key !== undefined) process.env.CUSTOM_API_KEY = saved.key;
    }
  });

  it("task with a plan card: say refused while it is open (card_open), answered by index, steps, result card", async () => {
    const s = session({ sim: editor(), model: [CALL("把笔记正文改成「新的」"), { text: "改好了" }], tasks: [EDIT("editor-1")] });
    s.on((e) => { if (e.kind === "ask") setTimeout(() => { s.send({ type: "say", text: "顺便说一句" }); s.send({ type: "answer", run_id: e.run_id, ask_id: e.ask_id, option: approveOf(e) }); }, 20); });
    s.send({ type: "say", text: "把笔记的正文改成「新的」" });
    await s.h.idle();
    expect(s.kinds("session.error").map((e) => e.code)).toEqual(["card_open"]);
    expect(s.kinds("session.task_end")[0]).toMatchObject({ status: "succeeded" });
    s.save("task-card.jsonl");
  });

  it("/cua, then undo from the result card", async () => {
    const scope = tmp();
    const s = session({ scope, model: [{ text: "建好了 a.txt" }], tasks: [CREATE()] });
    s.send({ type: "cua", text: "新建 a.txt 写 hi" });
    await s.h.idle();
    const done = s.kinds("task_done")[0];
    s.send({ type: "respond", run_id: done.run_id, option: done.result_card.options.findIndex((x: any) => x.kind === "undo") });
    await waitFor(() => s.kinds("session.task_closed").length);
    expect(s.kinds("session.task_undo")[0]).toMatchObject({ undone: 1, total: 1 });
    s.save("task-undo.jsonl");
  });

  it("stop with a card open: typing before the card is queued; the card is voided; the queue is held; send now", async () => {
    const s = session({ sim: editor(), model: [CALL("改笔记"), { text: "停下了" }, { text: "好的，三" }], tasks: [[{ text: "想想", delayMs: 300 }, ...EDIT("editor-1")]] });
    s.on((e) => { if (e.kind === "ask") setTimeout(() => s.send({ type: "stop" }), 20); });
    s.send({ type: "say", text: "把笔记的正文改成「新的」" });
    await waitFor(() => s.kinds("start").length);
    s.send({ type: "say", text: "三" });
    await s.h.idle();
    expect(s.kinds("ask_void")[0]).toMatchObject({ why: "stop" });
    const q = s.kinds("session.queue").at(-1).items;
    expect(q[0]).toMatchObject({ held: true });
    s.send({ type: "queue_send_now", id: q[0].id });
    await s.h.idle();
    s.save("task-stop.jsonl");
  });

  it("steer and queue: a steer reaches the task (steered); queued words go to the model after it", async () => {
    const scope = tmp();
    const s = session({ scope, model: [CALL("新建 a.txt"), { text: "建好了" }, { text: "收到一和二" }], tasks: [[{ text: "想想", delayMs: 300 }, ...CREATE()]] });
    s.send({ type: "say", text: "新建 a.txt 写 hi" });
    await waitFor(() => s.kinds("start").length);
    s.send({ type: "say", text: "一" });
    s.send({ type: "say", text: "二" });
    s.send({ type: "queue_edit", id: s.kinds("session.queue").at(-1).items[1].id, text: "二改" });
    s.send({ type: "steer", text: "内容就写 hi 吧" });
    await s.h.idle();
    expect(s.kinds("steered")[0]).toMatchObject({ text: "内容就写 hi 吧" });
    s.save("task-steer.jsonl");
  });

  it("a question card answered with the user's own words", async () => {
    const scope = tmp();
    const s = session({ scope, model: [CALL("新建一个文件"), { text: "建好了" }], tasks: [[
      { calls: [{ name: "ask_user", args: { question: "文件叫什么名字？", options: ["a.txt", "b.txt"] } }] },
      ...CREATE("c.txt")]] });
    s.on((e) => { if (e.kind === "ask") setTimeout(() => s.send({ type: "answer", run_id: e.run_id, ask_id: e.ask_id, text: "叫 c.txt" }), 20); });
    s.send({ type: "say", text: "新建一个文件" });
    await s.h.idle();
    s.save("task-question.jsonl");
  });

  it("the user at the keyboard pauses a step; the verdict wants evidence (look only); the task ends unconfirmed", async () => {
    let sim: SimComputer | null = null;
    let verifies = 0;
    const s = session({ sim: editor((x) => { sim = x; }), model: [CALL("改笔记"), { text: "改了，没能确认" }],
      verify: () => (verifies++ === 0 ? { choice: "unknown", reason: "看不到正文", missing_kind: "evidence" } : { choice: "unknown", reason: "还是看不到", missing_kind: "evidence" }),
      tasks: [EDIT("editor-1", [
        { calls: [{ name: "finish", args: { outcome: "done", summary: "正文改成了「新的」" } }] },
        { calls: [{ name: "computer_snapshot", args: {} }] },
        { calls: [{ name: "finish", args: { outcome: "unconfirmed", summary: "改了，看不到证据" } }] },
      ])] });
    s.on((e) => {
      if (e.kind === "ask") setTimeout(() => { sim!.user_active = true; setTimeout(() => { sim!.user_active = false; }, 300); s.send({ type: "answer", run_id: e.run_id, ask_id: e.ask_id, option: approveOf(e) }); }, 20);
    });
    s.send({ type: "say", text: "把笔记的正文改成「新的」" });
    await s.h.idle();
    expect(s.kinds("waiting").some((e) => !e.ask_id)).toBe(true);
    expect(s.kinds("verify")[0]).toMatchObject({ verdict: "unknown", missing_kind: "evidence" });
    s.save("task-paused-unconfirmed.jsonl");
  }, 20_000);

  it("the screen is locked: the task ends environment", async () => {
    const s = session({ sim: editor((x) => x.lock()), model: [CALL("改笔记"), { text: "屏幕锁着" }], tasks: [EDIT("editor-1")] });
    s.send({ type: "say", text: "把笔记的正文改成「新的」" });
    await s.h.idle();
    expect(s.kinds("task_done")[0]).toMatchObject({ status: "environment" });
    s.save("task-locked.jsonl");
  });
});
