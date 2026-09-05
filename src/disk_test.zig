const std = @import("std");
const lib = @import("bucketlist");
const native = @import("disk.zig");
const store = @import("bucketlist-store");
const gpa = std.testing.allocator;
const io = std.testing.io;
const Schema = struct {
    pub const namespace = "disk.tests";
    pub const version: u32 = 1;
    pub const tables = .{ .accounts = lib.Table(1, u64, u64), .flags = lib.Table(2, u8, bool) };
};
const Disk = native.Database(Schema);
fn pathOf(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buf);
    return buf[0..n];
}
fn stage(batch: anytype, seq: u64) !void {
    try batch.put(.accounts, seq % 7, seq * 3);
    try batch.put(.accounts, seq % 7, seq * 17);
    if (seq % 3 == 0) try batch.delete(.flags, @intCast(seq % 5)) else try batch.put(.flags, @intCast(seq % 5), seq % 2 == 0);
    try batch.delete(.accounts, 999); // absent deletion is normalized away
}
fn advance(db: *Disk, seq: u64) !void {
    var batch = Disk.Batch.init(gpa);
    defer batch.deinit();
    try stage(&batch, seq);
    var p = try db.prepare(seq, &batch, &.{@intCast(seq % 256)});
    defer p.deinit();
    try p.commit();
}

test "disk: typed file execution matches portable commitments and durable reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    var db = try Disk.open(gpa, io, path, .{ .merge_workers = 3 });
    defer db.deinit();
    var memory = lib.Database(Schema).init(gpa);
    defer memory.deinit();
    for (1..67) |seq| {
        try advance(db, seq);
        var batch = try memory.batch(gpa);
        defer batch.deinit();
        try stage(&batch, seq);
        var p = try memory.prepareAdvance(gpa, seq, &batch);
        defer p.deinit();
        try memory.commit(&p);
        try std.testing.expectEqualDeep(memory.commitment(), db.commitment());
        try std.testing.expectEqual(memory.get(.accounts, seq % 7), try db.get(.accounts, seq % 7));
        if (seq == 7 or seq == 8 or seq == 32 or seq == 65) {
            const ref = db.reference();
            db.deinit();
            db = try Disk.open(gpa, io, path, .{ .expected = ref, .merge_workers = 2 });
            try std.testing.expectEqualDeep(memory.commitment(), db.commitment());
            try std.testing.expectEqualSlices(u8, &.{@intCast(seq)}, db.metadata());
        }
    }
}

test "disk: bounded batches, abort, ownership, pinned reads and collection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    var db = try Disk.open(gpa, io, path, .{ .max_read_views = 1 });
    defer db.deinit();
    var batch = Disk.Batch.initBounded(gpa, 29, 1);
    defer batch.deinit();
    try batch.put(.accounts, 1, 2);
    try std.testing.expectError(error.BatchTooLarge, batch.put(.accounts, 2, 3));
    try batch.put(.accounts, 1, 4);
    try std.testing.expectEqual(@as(usize, 1), batch.changes.items.len);
    const before = db.commitment();
    var p = try db.prepare(1, &batch, "first");
    try std.testing.expectError(error.PreparedActive, db.prepare(1, &batch, ""));
    try std.testing.expectError(error.PreparedActive, db.collect(&.{}));
    p.deinit();
    try std.testing.expectEqual(before, db.commitment());
    p = try db.prepare(1, &batch, "first");
    defer p.deinit();
    try p.commit();
    const view = try db.readView();
    try std.testing.expectError(error.TooManyViews, db.readView());
    const retained = view.reference();
    for (2..18) |seq| try advance(db, seq);
    _ = try db.collect(&.{});
    try std.testing.expectEqual(@as(?u64, 4), try view.get(.accounts, 1));
    try std.testing.expectEqual(@as(u64, 1), view.commitment().advance);
    view.deinit();
    _ = try db.collect(&.{retained});
    const removed = try db.collect(&.{});
    try std.testing.expect(removed > 0);
    try std.testing.expectError(error.NotFound, db.collect(&.{retained}));
}

test "disk: publication failure poisons writer and reopen resolves frontier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    var db = try Disk.open(gpa, io, path, .{});
    var closed = false;
    defer if (!closed) db.deinit();
    var batch = Disk.Batch.init(gpa);
    defer batch.deinit();
    try batch.put(.accounts, 1, 2);
    var p = try db.prepare(1, &batch, "published");
    try tmp.dir.rename("manifest", tmp.dir, "previous-manifest", io);
    try tmp.dir.createDir(io, "manifest", .default_dir);
    try std.testing.expectError(error.IoFailed, p.commit());
    try std.testing.expectEqual(@as(u64, 0), db.commitment().advance);
    try std.testing.expectError(error.Poisoned, db.prepare(1, &batch, ""));
    p.deinit();
    db.deinit();
    closed = true;
    try tmp.dir.deleteDir(io, "manifest");
    try tmp.dir.rename("previous-manifest", tmp.dir, "manifest", io);
    db = try Disk.open(gpa, io, path, .{});
    closed = false;
    try std.testing.expectEqual(@as(u64, 0), db.commitment().advance);
    var retry = try db.prepare(1, &batch, "recovered");
    defer retry.deinit();
    try retry.commit();
    try std.testing.expectEqual(@as(?u64, 2), try db.get(.accounts, 1));
}

test "disk: reduced profiles retain deletion precedence through terminal compaction" {
    inline for (.{ 1, 2, 3 }) |depth| {
        const Reduced = native.DatabaseWithDepth(Schema, depth);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try pathOf(&tmp, &buf);
        var db = try Reduced.open(gpa, io, path, .{ .merge_workers = 2 });
        defer db.deinit();
        var expected: [9]?u64 = @splat(null);
        for (1..67) |seq| {
            var batch = Reduced.Batch.init(gpa);
            defer batch.deinit();
            const key = seq % expected.len;
            if (seq % 7 != 0) { // empty advances still rotate
                if (seq % 3 == 0) {
                    try batch.delete(.accounts, key);
                    expected[key] = null;
                } else {
                    try batch.put(.accounts, key, seq);
                    expected[key] = seq;
                }
            }
            var p = try db.prepare(seq, &batch, "");
            defer p.deinit();
            try p.commit();
            if (seq % 8 == 0 or seq == 66) {
                for (expected, 0..) |value, k| try std.testing.expectEqual(value, try db.get(.accounts, k));
                const ref = db.reference();
                db.deinit();
                db = try Reduced.open(gpa, io, path, .{ .expected = ref });
            }
        }
    }
}

test "host: include bounded publisher tests" {
    _ = @import("host.zig");
}

test "disk: include adversarial recovery and memory-bound tests" {
    _ = @import("disk_adversarial_test.zig");
}
