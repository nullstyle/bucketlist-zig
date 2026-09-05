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

test "disk: point reads agree with and without the local read index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const reference = blk: {
        var db = try Disk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        for (1..35) |seq| try advance(db, seq);
        break :blk db.reference();
    };
    // Default options enable the read index; the null opt-out keeps
    // whole-bucket verification on every lookup. Both must agree. The
    // exclusive store lock means the two opens are sequential.
    var results: [40]?u64 = undefined;
    var flags: [40]?bool = undefined;
    {
        var indexed = try Disk.open(gpa, io, path, .{ .expected = reference, .merge_workers = 1 });
        defer indexed.deinit();
        for (0..40) |key| {
            const k: u64 = @intCast(key * 13 % 43);
            results[key] = try indexed.get(.accounts, k);
            // A second get of the same key exercises the warm path.
            try std.testing.expectEqual(results[key], try indexed.get(.accounts, k));
        }
        for (0..40) |key| flags[key] = try indexed.get(.flags, @intCast(key % 5));
    }
    {
        var verified = try Disk.open(gpa, io, path, .{ .expected = reference, .merge_workers = 1, .read_index = null });
        defer verified.deinit();
        for (0..40) |key| {
            const k: u64 = @intCast(key * 13 % 43);
            try std.testing.expectEqual(results[key], try verified.get(.accounts, k));
        }
        for (0..40) |key| try std.testing.expectEqual(flags[key], try verified.get(.flags, @intCast(key % 5)));
    }
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

test "disk: batch normalization reads each bucket independently of changed-key count" {
    const S = struct {
        pub const namespace = "disk.normalization.io";
        pub const version = 1;
        pub const tables = .{ .rows = lib.Table(1, u64, [128]u8) };
    };
    const Db = native.Database(S);
    const Reads = struct {
        var bytes: std.atomic.Value(u64) = .init(0);
        fn read(ctx: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const n = try io.vtable.fileReadPositional(ctx, file, buffers, offset);
            _ = bytes.fetchAdd(n, .monotonic);
            return n;
        }
    };
    var vtable = io.vtable.*;
    vtable.fileReadPositional = Reads.read;
    const measured: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try Db.open(gpa, measured, try pathOf(&tmp, &buf), .{ .merge_workers = 1 });
    defer db.deinit();
    var batch = Db.Batch.init(gpa);
    defer batch.deinit();
    for (0..128) |k| try batch.put(.rows, k, @splat(@intCast(k)));
    var first = try db.prepare(1, &batch, "first");
    defer first.deinit();
    try first.commit();
    Reads.bytes.store(0, .release);
    var second = try db.prepare(2, &batch, "unchanged batch");
    defer second.deinit();
    // Includes authentication, spill merges, and deduplication of their files.
    // The byte allowance scales with the file, not with 128 point lookups.
    const bucket_bytes = "bucketlist.bucket.v1\x00".len + 8 + 128 * (4 + 4 + 8 + 1 + 4 + 128);
    const read_bytes = Reads.bytes.load(.acquire);
    try std.testing.expect(read_bytes < bucket_bytes * 8 + 128 * 1024);
    try std.testing.expectEqual(@as(u64, 1), db.commitment().advance);
    try second.commit();
    try std.testing.expectEqual(@as(?[128]u8, @splat(127)), try db.get(.rows, 127));
}

test "disk: dense multi-table normalization matches portable history across spills" {
    const S = struct {
        pub const namespace = "disk.normalization.tables";
        pub const version = 1;
        pub const tables = .{
            .rows = lib.Table(7, u16, lib.Bytes(16)),
            .empty = lib.Table(3, u8, [0]u8),
            .flags = lib.Table(1, u16, bool),
        };
    };
    const Stage = struct {
        fn run(batch: anytype, seq: usize) !void {
            // Reverse order and repeated changes exercise sorting independently
            // of table declaration order, canonical key order, and call order.
            for (0..24) |i| {
                const key: u16 = @intCast(23 - i);
                if ((seq + i) % 5 == 0) continue;
                if ((seq + i) % 4 == 0) {
                    try batch.delete(.rows, key);
                    try batch.delete(.empty, @intCast(key));
                    try batch.delete(.flags, key);
                } else {
                    const bytes: []const u8 = if ((seq / 3 + i) % 3 == 0) "" else "unchanged";
                    try batch.put(.rows, key, try lib.Bytes(16).init("replaced"));
                    try batch.put(.rows, key, try lib.Bytes(16).init(bytes));
                    try batch.put(.empty, @intCast(key), .{});
                    try batch.put(.flags, key, (seq / 4 + i) % 2 == 0);
                }
            }
            try batch.delete(.rows, 65535);
        }
    };
    const Db = native.Database(S);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try Db.open(gpa, io, try pathOf(&tmp, &buf), .{ .merge_workers = 2 });
    defer db.deinit();
    var memory = lib.Database(S).init(gpa);
    defer memory.deinit();
    for (1..67) |seq| {
        var batch = Db.Batch.init(gpa);
        defer batch.deinit();
        var reference = try memory.batch(gpa);
        defer reference.deinit();
        try Stage.run(&batch, seq);
        try Stage.run(&reference, seq);
        var candidate = try db.prepare(seq, &batch, "");
        defer candidate.deinit();
        var expected = try memory.prepareAdvance(gpa, seq, &reference);
        defer expected.deinit();
        try memory.commit(&expected);
        try std.testing.expectEqualDeep(memory.commitment(), candidate.commitment());
        try candidate.commit();
        if (seq % 8 == 0 or seq == 66) {
            for (0..24) |key| {
                try std.testing.expectEqualDeep(memory.get(.rows, @intCast(key)), try db.get(.rows, @intCast(key)));
                try std.testing.expectEqualDeep(memory.get(.empty, @intCast(key)), try db.get(.empty, @intCast(key)));
                try std.testing.expectEqual(memory.get(.flags, @intCast(key)), try db.get(.flags, @intCast(key)));
            }
        }
    }
}

test "disk: normalization authenticates tail even after every changed key matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const db = try Disk.open(gpa, io, try pathOf(&tmp, &buf), .{ .merge_workers = 1 });
    defer db.deinit();
    var initial = Disk.Batch.init(gpa);
    defer initial.deinit();
    try initial.put(.accounts, 0, 42);
    try initial.put(.flags, 255, true);
    var first = try db.prepare(1, &initial, "baseline");
    defer first.deinit();
    try first.commit();
    const before = db.reference();
    const manifest = try db.store.getBlob(gpa, before.manifest_hash, 4096);
    defer gpa.free(manifest);
    const header = "bucketlist.disk-frontier.v1\x00".len + 32 + 32 + 8;
    const hash = manifest[header..][0..32].*;
    const bytes = try db.store.getBlob(gpa, hash, 4096);
    defer gpa.free(bytes);
    const name = std.fmt.bytesToHex(hash, .lower);
    const file = try db.store.blobs.openFile(io, &name, .{ .mode = .read_write });
    defer file.close(io);
    // A canonical bool edit at the tail keeps framing valid but breaks SHA-256.
    try file.writePositionalAll(io, "\x00", bytes.len - 1);
    var batch = Disk.Batch.init(gpa);
    defer batch.deinit();
    try batch.put(.accounts, 0, 42);
    try std.testing.expectError(error.CorruptBlob, db.prepare(2, &batch, "candidate"));
    try std.testing.expectEqual(before, db.reference());
    try std.testing.expectEqualStrings("baseline", db.metadata());
    try file.writePositionalAll(io, bytes[bytes.len - 1 ..], bytes.len - 1);
    var retry = try db.prepare(2, &batch, "retry");
    defer retry.deinit();
    try retry.commit();
    try std.testing.expectEqual(@as(?u64, 42), try db.get(.accounts, 0));
}

test "disk: every prepare allocation failure allows retry on the same owner and batch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    var batch = Disk.Batch.init(gpa);
    defer batch.deinit();
    try batch.put(.accounts, 0, 0);
    try batch.put(.accounts, 1, 10);
    try batch.delete(.accounts, 2);
    try batch.delete(.accounts, 999);
    try batch.put(.flags, 1, false);
    const before, const expected = blk: {
        const db = try Disk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        for (1..8) |seq| try advance(db, seq);
        var p = try db.prepare(8, &batch, "next");
        defer p.deinit(); // Seed immutable outputs; no attempt publishes them.
        break :blk .{ db.reference(), p.commitment() };
    };
    var failures: usize = 0;
    while (failures < 1000) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{});
        const db = try Disk.open(failing.allocator(), io, path, .{ .merge_workers = 1, .expected = before });
        defer db.deinit();
        failing.fail_index = failing.alloc_index + failures;
        var p = db.prepare(8, &batch, "next") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(before, db.reference());
            try std.testing.expectEqual(@as(usize, 5), batch.changes.items.len);
            failing.fail_index = std.math.maxInt(usize);
            var retry = try db.prepare(8, &batch, "next");
            defer retry.deinit();
            try std.testing.expectEqualDeep(expected, retry.commitment());
            continue;
        };
        defer p.deinit();
        try std.testing.expectEqualDeep(expected, p.commitment());
        if (!failing.has_induced_failure) break;
    }
    try std.testing.expect(failures > 10 and failures < 1000);
    const reopened = try Disk.open(gpa, io, path, .{ .expected = before });
    defer reopened.deinit();
    try std.testing.expectEqual(before, reopened.reference());
}
