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
    const actual = history.finalResult();
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, fixture.traces[3].aggregate);
    if (!std.mem.eql(u8, &actual, &expected)) return error.TraceMismatch;
    return actual;
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
