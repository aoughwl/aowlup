// Minimal smoke test: the manager resolves a config payload and a doctor table.
"use strict";
const cp = require("child_process"), path = require("path"), assert = require("assert");
const BIN = path.join(__dirname, "..", "bin", "aowlup");
const run = (args) => cp.spawnSync(process.execPath, [BIN, ...args],
  { encoding: "utf8", env: Object.assign({}, process.env, { NO_COLOR: "1" }) });

let pass = 0;
function ok(name, cond) { console.log((cond ? "  ok   " : "  FAIL ") + name); if (cond) pass++; }

const cfg = run(["config"]);
ok("config exits 0", cfg.status === 0);
let j = null; try { j = JSON.parse(cfg.stdout); } catch (_) {}
ok("config emits JSON", j !== null);
ok("config has a profile", j && typeof j.profile === "string");
ok("config has resolved slots", j && j.slots && j.slots.parser && "exe" in j.slots.parser);

const doc = run(["doctor"]);
ok("doctor exits 0", doc.status === 0);
ok("doctor lists parser + backends", /parser/.test(doc.stdout) && /native/.test(doc.stdout));

const prof = run(["+nimony", "config"]);
let pj = null; try { pj = JSON.parse(prof.stdout); } catch (_) {}
ok("+nimony ephemeral profile applies", pj && pj.profile === "nimony");

console.log("\n" + pass + "/7 passed");
process.exit(pass === 7 ? 0 : 1);
