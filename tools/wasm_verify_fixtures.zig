//! Emit flat-encoded proofs from a real v2 disk database as JSON lines for
//! the wasm verifier gate: one visible-state proof and one range proof,
//! each with its trusted digest. The native suite verifies the same proofs
//! before they are emitted, so the gate exercises a real artifact on real
//! evidence, not hand-written bytes.
const std = @import("std");
const lib = @import("bucketlist");
const native = @import("bucketlist-disk");
const storage = @import("bucketlist-store");
const Schema = struct {
    pub const namespace = "benchmark.wasm-verify.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .accounts = lib.Table(1, u64, u64) };
};
const Db = native.Database(Schema);

fn hexAlloc(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, bytes.len * 2);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 15];
    }
    return out;
}

fn json(writer: *std.Io.Writer, gpa: std.mem.Allocator, kind: []const u8, proof: []const u8, digest: [32]u8) !void {
    const proof_hex = try hexAlloc(gpa, proof);
    defer gpa.free(proof_hex);
    const digest_hex = try hexAlloc(gpa, &digest);
    defer gpa.free(digest_hex);
    try std.json.Stringify.value(.{ .kind = kind, .proof = proof_hex, .digest = digest_hex }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;
    const io = init.io;
    var stamp: [64]u8 = undefined;
    const now = std.Io.Clock.awake.now(io);
    const root = try std.fmt.bufPrint(&stamp, ".zig-cache/wasm-verify-{d}", .{now.nanoseconds});
    _ = try std.Io.Dir.cwd().createDirPathOpen(io, root, .{});
    const format: storage.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try Db.open(gpa, io, root, .{ .merge_workers = 1, .format = format });
    defer db.deinit();
    var seq: u64 = 0;
    while (seq < 12) : (seq += 1) {
        var batch = Db.Batch.init(gpa);
        defer batch.deinit();
        for (0..6) |i| {
            const key = seq * 6 + i;
            if (key % 9 == 8) try batch.delete(.accounts, key - 3) else try batch.put(.accounts, key, key * 31 + 7);
        }
        var prepared = try db.prepare(seq + 1, &batch, "fixture");
        defer prepared.deinit();
        try prepared.commit();
    }
    const digest = db.commitment().digest;
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(io, &output_buffer);
    {
        var bundle = try db.prove(.accounts, 4, gpa);
        defer bundle.deinit();
        // The emitted proof must verify natively first.
        try lib.proofs.verifyVisible(&bundle.proof, digest);
        const flat = try lib.proof_flat.encodeVisible(gpa, &bundle.proof);
        defer gpa.free(flat);
        try json(&output.interface, gpa, "visible", flat, digest);
    }
    {
        var bundle = try db.proveRange(.accounts, 3, 30, gpa);
        defer bundle.deinit();
        try lib.proofs.verifyRange(&bundle.proof, digest);
        const flat = try lib.proof_flat.encodeRange(gpa, &bundle.proof);
        defer gpa.free(flat);
        try json(&output.interface, gpa, "range", flat, digest);
    }
}
