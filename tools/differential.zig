//! Same code and checked-in typed trace execute natively and in a WASM VM.
const std = @import("std");
const bucketlist = @import("bucketlist");
const fixture = @import("reference_vectors");

const Schema = struct {
    pub const namespace = fixture.namespace;
    pub const version = fixture.version;
    pub const tables = .{
        .names = bucketlist.Table(2, bucketlist.Bytes(8), u64),
        .accounts = bucketlist.Table(1, i16, struct { balance: i64, active: bool }),
    };
};
const Db = bucketlist.Database(Schema);
var scratch: [16 * 1024 * 1024]u8 = undefined;
var result: [32]u8 = undefined;

fn calculate() ![32]u8 {
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);
    const gpa = allocator.allocator();
    var db = Db.init(gpa);
    defer db.deinit();
    var history = std.crypto.hash.sha2.Sha256.init(.{});
    history.update(&db.commitment().digest);
    for (fixture.operations[1..], 1..) |ops, sequence| {
        {
            var batch = try db.batch(gpa);
            defer batch.deinit();
            for (ops) |op| {
                switch (op.kind) {
                    .put_account => try batch.put(.accounts, op.account, .{ .balance = op.balance, .active = op.active }),
                    .delete_account => try batch.delete(.accounts, op.account),
                    .put_name => try batch.put(.names, try bucketlist.Bytes(8).init(op.name), op.owner),
                    .delete_name => try batch.delete(.names, try bucketlist.Bytes(8).init(op.name)),
                }
            }
            var prepared = try db.prepareAdvance(gpa, sequence, &batch);
            defer prepared.deinit();
            try db.commit(&prepared);
        }
        const commitment = db.commitment();
        history.update(&commitment.digest);
        if (sequence == 7 or sequence == 8 or sequence == 31 or sequence == 32 or sequence == 127) {
            const bytes = try db.checkpoint(gpa);
            defer gpa.free(bytes);
            const restored = try Db.restore(gpa, bytes, commitment.digest);
            db.deinit();
            db = restored;
        }
    }
    try verifyProofFixture();
    const actual = history.finalResult();
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, fixture.traces[3].aggregate);
    if (!std.mem.eql(u8, &actual, &expected)) return error.TraceMismatch;
    return actual;
}

/// The v2 proof verifier is pure computation; exercise it identically on
/// every target with a fixed fixture (membership verify plus a rejected
/// forged digest), no allocations.
fn verifyProofFixture() !void {
    const proofs = bucketlist.proofs;
    var block0: [42]u8 = undefined;
    var block1: [21]u8 = undefined;
    var position: usize = 0;
    for (0..3) |i| {
        const target: []u8 = if (i < 2) block0[position..] else block1[position - 42 ..];
        std.mem.writeInt(u32, target[0..4], 1, .big);
        std.mem.writeInt(u32, target[4..8], 4, .big);
        std.mem.writeInt(u32, target[8..12], @intCast(2 * i), .big);
        target[12] = 1;
        std.mem.writeInt(u32, target[13..17], 4, .big);
        std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
        position += 21;
    }
    const leaves = [2][32]u8{ proofs.blockHash(0, &block0), proofs.blockHash(1, &block1) };
    const steps = [1]proofs.BlockPath.Step{.{ .hash = leaves[1], .right = true }};
    const bucket = proofs.bucketHash(3, 2, proofs.combine(leaves[0], leaves[1]));
    var schema: [32]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 900, .big);
    std.crypto.hash.sha2.Sha256.hash(&seed, &schema, .{});
    const profile = proofs.profileHash(11, 42);
    var levels: [11]proofs.ChainLevel = undefined;
    const empty_bucket = proofs.emptyBucketHash();
    for (&levels, 0..) |*level, i| {
        var hash: [32]u8 = undefined;
        std.mem.writeInt(u32, &seed, @intCast(50 + i), .big);
        std.crypto.hash.sha2.Sha256.hash(&seed, &hash, .{});
        const young = i < 2;
        level.* = .{
            .curr = if (i == 2) bucket else if (young) empty_bucket else hash,
            .snap = if (young) empty_bucket else hash,
        };
    }
    const digest = proofs.chainCommitment(schema, profile, 9, &levels);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 2, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 1, .big);
    const proof = proofs.MembershipProof{
        .table = 1,
        .key = &key,
        .value = &value,
        .slot_level = 2,
        .slot_snapshot = false,
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 9,
        .levels = &levels,
        .bucket = .{ .block = &block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = .{ .steps = &steps } },
    };
    try proofs.verifyMembership(&proof, digest);
    var wrong = digest;
    wrong[0] ^= 0xFF;
    if (proofs.verifyMembership(&proof, wrong)) |_| return error.ForgedDigestAccepted else |_| {}
}

/// WASM returns zero only after all operations and restore transitions succeed.
pub export fn run_trace() u32 {
    result = calculate() catch return 1;
    return 0;
}

pub export fn result_pointer() usize {
    return @intFromPtr(&result);
}

pub const main = if (@import("builtin").os.tag == .freestanding) wasmMain else nativeMain;

fn wasmMain() void {}

fn nativeMain(init: std.process.Init) !void {
    result = try calculate();
    const hex = std.fmt.bytesToHex(result, .lower);
    try std.Io.File.stdout().writeStreamingAll(init.io, &hex);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}
