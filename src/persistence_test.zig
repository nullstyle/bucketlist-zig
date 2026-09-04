const std = @import("std");
const dbs = @import("database.zig");
const schema = @import("schema.zig");
const bucket = @import("bucket.zig");
const native = @import("bucketlist-store");
const gpa = std.testing.allocator;
const io = std.testing.io;

test "persistence: streaming native merges exactly match in-memory merges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var store = try native.Store.open(gpa, io, path[0..n]);
    defer store.deinit();
    var old = try bucket.Bucket.fromSorted(gpa, &.{
        .{ .table = 1, .key = "a", .value = "old" },
        .{ .table = 1, .key = "b", .value = "old" },
        .{ .table = 2, .key = "a", .value = "other" },
    });
    defer old.release();
    var new = try bucket.Bucket.fromSorted(gpa, &.{
        .{ .table = 1, .key = "a", .value = null },
        .{ .table = 1, .key = "b", .value = "new" },
        .{ .table = 1, .key = "c", .value = "" },
    });
    defer new.release();
    const oh = try store.putBlob(old.bytes());
    const nh = try store.putBlob(new.bytes());
    try std.testing.expectEqual(old.hash(), oh);
    try std.testing.expectEqual(new.hash(), nh);
    for ([_]bool{ false, true }) |terminal| {
        var memory = try bucket.merge(gpa, old, new, terminal);
        defer memory.release();
        const disk_hash = try store.mergeBuckets(oh, nh, terminal, .{});
        try std.testing.expectEqual(memory.hash(), disk_hash);
        const disk = try store.getBlob(gpa, disk_hash, 4096);
        defer gpa.free(disk);
        try std.testing.expectEqualSlices(u8, memory.bytes(), disk);
    }
}

test "persistence: database checkpoint survives store reopen and exact continuation" {
    const S = struct {
        pub const namespace = "persistent.database";
        pub const version: u32 = 1;
        pub const tables = .{ .rows = schema.Table(1, u64, u64) };
    };
    const Db = dbs.Database(S);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path);
    var db = Db.init(gpa);
    defer db.deinit();
    for (1..10) |seq| {
        var batch = try db.batch(gpa);
        defer batch.deinit();
        try batch.put(.rows, seq, seq * 7);
        var p = try db.prepareAdvance(gpa, seq, &batch);
        defer p.deinit();
        try db.commit(&p);
    }
    const trusted = db.commitment().digest;
    {
        var store = try native.Store.open(gpa, io, path[0..n]);
        defer store.deinit();
        const checkpoint = try db.checkpoint(gpa);
        defer gpa.free(checkpoint);
        const blob = try store.putBlob(checkpoint);
        // This local manifest is a blob reference, not a remote certificate.
        try store.publish(&blob);
    }
    var reopened = try native.Store.open(gpa, io, path[0..n]);
    defer reopened.deinit();
    const manifest = (try reopened.readManifest(gpa, 32)).?;
    defer gpa.free(manifest);
    try std.testing.expectEqual(@as(usize, 32), manifest.len);
    const checkpoint = try reopened.getBlob(gpa, manifest[0..32].*, 1024 * 1024);
    defer gpa.free(checkpoint);
    var restored = try Db.restore(gpa, checkpoint, trusted);
    defer restored.deinit();
    var a = try db.batch(gpa);
    defer a.deinit();
    var b = try restored.batch(gpa);
    defer b.deinit();
    try a.delete(.rows, 3);
    try b.delete(.rows, 3);
    var pa = try db.prepareAdvance(gpa, 10, &a);
    defer pa.deinit();
    var pb = try restored.prepareAdvance(gpa, 10, &b);
    defer pb.deinit();
    try std.testing.expectEqual(pa.commitment(), pb.commitment());
}
