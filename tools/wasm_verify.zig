//! Standalone wasm32-freestanding proof verifier (the release artifact).
//!
//! Exports a C ABI over static buffers: the caller writes a flat-encoded
//! proof at bkl_input()[0..proof_len] and its 32-byte trusted digest at
//! bkl_input()[digest_off..digest_off+32], then calls one of the verify
//! entry points. Return codes: 0 verified, 1 invalid proof, 2 undecodable
//! input, 3 unknown record, 4 present record. Verification allocates only
//! from a fixed buffer over static memory, so the module needs no wasm
//! imports; nothing here touches a filesystem, clock, or network.
const std = @import("std");
const lib = @import("bucketlist");

var input: [4 * 1024 * 1024]u8 align(16) = undefined;
var heap: [4 * 1024 * 1024]u8 align(16) = undefined;

export fn bkl_input() u32 {
    return @intCast(@intFromPtr(&input));
}

export fn bkl_verify_visible(proof_len: u32, digest_off: u32) u32 {
    if (@as(usize, digest_off) + 32 > input.len or proof_len > digest_off) return 2;
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const proof = lib.proof_flat.decodeVisible(fba.allocator(), input[0..proof_len]) catch return 2;
    const digest = input[digest_off..][0..32].*;
    lib.proofs.verifyVisible(&proof, digest) catch |err| return switch (err) {
        error.InvalidProof => 1,
        error.UnknownRecord => 3,
        error.PresentRecord => 4,
    };
    return 0;
}

export fn bkl_verify_range(proof_len: u32, digest_off: u32) u32 {
    if (@as(usize, digest_off) + 32 > input.len or proof_len > digest_off) return 2;
    var fba = std.heap.FixedBufferAllocator.init(&heap);
    const proof = lib.proof_flat.decodeRange(fba.allocator(), input[0..proof_len]) catch return 2;
    const digest = input[digest_off..][0..32].*;
    lib.proofs.verifyRange(&proof, digest) catch return 1;
    return 0;
}
