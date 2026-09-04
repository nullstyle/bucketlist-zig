const std = @import("std");
const fixture = @import("reference_vectors");
const databases = @import("database.zig");
const codec = @import("codec.zig");
const schema = @import("schema.zig");
const bucket = @import("bucket.zig");
const lists = @import("list.zig");

const Schema = struct {
    pub const namespace = fixture.namespace;
    pub const version = fixture.version;
    pub const tables = .{
        .names = schema.Table(2, codec.Bytes(8), u64),
        .accounts = schema.Table(1, i16, struct { balance: i64, active: bool }),
    };
};

fn expectHash(expected: []const u8, actual: [32]u8) !void {
    var digest: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&digest, expected), &actual);
}

fn expectBucket(index: usize, actual: bucket.Bucket) !void {
    const expected = fixture.buckets[index];
    try std.testing.expectEqualSlices(u8, expected.bytes, actual.bytes());
    try expectHash(expected.hash, actual.hash());
}

test "independent schema descriptor and every checked-in canonical bucket" {
    const Def = schema.Definition(Schema);
    var descriptor: [Def.descriptor_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, fixture.schema_descriptor, try Def.encodeDescriptor(&descriptor));
    try expectHash(fixture.schema_hash, Def.hash());
    for (fixture.buckets) |expected| {
        var actual = try bucket.Bucket.decode(std.testing.allocator, expected.bytes);
        defer actual.release();
        try std.testing.expectEqualSlices(u8, expected.bytes, actual.bytes());
        try expectHash(expected.hash, actual.hash());
    }
}

test "typed database and raw engine match independently generated multi-profile traces" {
    const gpa = std.testing.allocator;
    inline for (.{ 1, 2, 3, 11 }, 0..) |depth, trace_index| {
        const trace = fixture.traces[trace_index];
        const Db = databases.DatabaseWithDepth(Schema, depth);
        var db = Db.init(gpa);
        defer db.deinit();
        var raw = lists.List(depth).init(gpa);
        defer raw.deinit();
        var aggregate = std.crypto.hash.sha2.Sha256.init(.{});
        try std.testing.expectEqual(depth, trace.depth);
        try expectHash(trace.profile, lists.List(depth).profileHash());
        for (trace.steps) |step| {
            if (step.sequence != 0) {
                var changes = try db.batch(gpa);
                defer changes.deinit();
                for (fixture.operations[@intCast(step.sequence)]) |op| {
                    switch (op.kind) {
                        .put_account => try changes.put(.accounts, op.account, .{ .balance = op.balance, .active = op.active }),
                        .delete_account => try changes.delete(.accounts, op.account),
                        .put_name => try changes.put(.names, try codec.Bytes(8).init(op.name), op.owner),
                        .delete_name => try changes.delete(.names, try codec.Bytes(8).init(op.name)),
                    }
                }
                var prepared = try db.prepareAdvance(gpa, step.sequence, &changes);
                defer prepared.deinit();
                try expectHash(step.database, prepared.commitment().digest);
                try db.commit(&prepared);
                var expected_batch = try bucket.Bucket.decode(gpa, fixture.buckets[step.batch].bytes);
                defer expected_batch.release();
                try raw.advance(step.sequence, expected_batch.records());
            }
            const commitment = db.commitment();
            try expectHash(step.root, commitment.bucket_list_root);
            try expectHash(step.continuation, commitment.continuation_hash);
            try expectHash(step.database, commitment.digest);
            aggregate.update(&commitment.digest);
            try std.testing.expectEqual(commitment.bucket_list_root, raw.root());
            try std.testing.expectEqual(commitment.continuation_hash, raw.continuationHash());
            for (step.levels, db.engine.levels) |expected, actual| {
                try expectBucket(expected.curr, actual.curr);
                try expectBucket(expected.snap, actual.snap);
                if (expected.next) |index| {
                    try std.testing.expect(actual.next != null);
                    try expectBucket(index, actual.next.?);
                } else try std.testing.expect(actual.next == null);
            }
            // Resume from independently expected commitments before or at
            // simultaneous spill boundaries, then verify the remaining trace.
            if (step.sequence == 7 or step.sequence == 8 or step.sequence == 31 or
                step.sequence == 32 or step.sequence == 127)
            {
                const bytes = try db.checkpoint(gpa);
                defer gpa.free(bytes);
                var expected: [32]u8 = undefined;
                _ = try std.fmt.hexToBytes(&expected, step.database);
                const restored = try Db.restore(gpa, bytes, expected);
                db.deinit();
                db = restored;
            }
        }
        try expectHash(trace.aggregate, aggregate.finalResult());
    }
}
