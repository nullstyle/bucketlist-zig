#!/usr/bin/env node
// Gate the standalone wasm verifier artifact on real generated evidence:
// accept the true proofs, reject a tampered digest, a tampered proof body,
// and truncated input.
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const [wasmPath, fixturePath] = process.argv.slice(2);
if (!wasmPath || !fixturePath) {
  throw new Error("Usage: node tools/wasm-verify.mjs <bucketlist-verifier.wasm> <fixtures-exe>");
}
const fixtures = execFileSync(fixturePath, { encoding: "utf8" })
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});
const scratch = instance.exports.bkl_input() >>> 0;
const memory = new Uint8Array(instance.exports.memory.buffer);

function run(exportName, proof, digest) {
  memory.set(proof, scratch);
  memory.set(digest, scratch + proof.length);
  return instance.exports[exportName](proof.length, proof.length);
}

for (const fixture of fixtures) {
  const exportName = fixture.kind === "visible" ? "bkl_verify_visible" : "bkl_verify_range";
  const proof = Buffer.from(fixture.proof, "hex");
  const digest = Buffer.from(fixture.digest, "hex");
  if (proof.length + 32 >= 4 * 1024 * 1024) throw new Error("fixture exceeds the wasm input buffer");
  const ok = run(exportName, proof, digest);
  if (ok !== 0) throw new Error(`${fixture.kind}: true proof rejected with ${ok}`);

  const badDigest = Buffer.from(digest);
  badDigest[9] ^= 0xff;
  if (run(exportName, proof, badDigest) === 0) throw new Error(`${fixture.kind}: tampered digest accepted`);

  const badProof = Buffer.from(proof);
  badProof[badProof.length >> 1] ^= 0xff;
  if (run(exportName, badProof, digest) === 0) throw new Error(`${fixture.kind}: tampered proof accepted`);

  if (run(exportName, proof.subarray(0, proof.length - 1), digest) === 0) {
    throw new Error(`${fixture.kind}: truncated proof accepted`);
  }
  console.log(`${fixture.kind}: wasm verifier accepted the true proof and rejected tampering (${proof.length} bytes)`);
}
