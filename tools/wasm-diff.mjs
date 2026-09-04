#!/usr/bin/env node
// Execute both compiled targets and compare with the independent Python corpus.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const [wasmPath, nativePath, fixturePath = "vectors/reference.json"] = process.argv.slice(2);
if (!wasmPath || !nativePath) {
  throw new Error("Usage: node tools/wasm-diff.mjs <runner.wasm> <native-runner> [reference.json]");
}
const corpus = JSON.parse(readFileSync(fixturePath, "utf8"));
const expected = corpus.traces.find((trace) => trace.depth === 11).aggregate;
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
if (instance.exports.run_trace() !== 0) throw new Error("WASM trace or recovery failed");
const wasm = Buffer.from(instance.exports.memory.buffer, instance.exports.result_pointer() >>> 0, 32).toString("hex");
const native = execFileSync(resolve(nativePath), { encoding: "utf8" }).trim();
if (wasm !== expected || native !== expected) {
  throw new Error(`Cross-target mismatch: expected=${expected} native=${native} wasm=${wasm}`);
}
console.log(`Native and wasm32-freestanding match the independent 128-advance trace: ${expected}`);
