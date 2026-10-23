// Generates normalize-config.json: the harness's own normalizeConfig (deskmind-ai/harness src/gateway/index.ts) run on
// the inputs below, so the app's port (SessionClient.normalizeConfig) and the tests' fake helpers are checked against
// the harness, not against themselves (#107 review at 32c458b).
//
//   node app/tests/fixtures/normalize-config.gen.js <harness checkout at the deps.lock pin> > app/tests/fixtures/normalize-config.json
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(process.argv[2], "src/gateway/index.ts"), "utf8");
const fn = /export function normalizeConfig\(spec: string\): string \{[\s\S]*?\n\}/.exec(src)[0]
  .replace("export function normalizeConfig(spec: string): string {", "function normalizeConfig(spec) {").replace("m[2]!", "m[2]");
const normalizeConfig = new Function(`${fn}; return normalizeConfig;`)();
const models = ["gpt-4o"];
const ws = ["", " ", "\t", "\n", "\r\n", "\u000b", "\u000c", " ", " ", " ", " ", " ", " ", " ",
            " ", " ", "　", "﻿", "​", "\u0085", "᠎", "﻿ ", " ﻿ "];
const inputs = [];
for (const w of ws) for (const m of models) {
  inputs.push(`openai:custom|${w}${m}${w}`);
  inputs.push(`openai:deepseek|${m}${w}`);
}
inputs.push("ds-flash", " ds-flash ", "openai:Custom| gpt-4o ", "openai:|gpt-4o ", "openai:cus tom| x ", "openai:custom|", "openai:custom|  ",
            "openai:custom|a b ", "openai:custom|x|y ", "OPENAI:custom| x", "ark-evolving﻿");
const table = inputs.map((input) => ({ input, output: normalizeConfig(input) }));
process.stdout.write(JSON.stringify({ source: "deskmind-ai/harness 0bbabd4 src/gateway/index.ts normalizeConfig", cases: table }, null, 1) + "\n");
