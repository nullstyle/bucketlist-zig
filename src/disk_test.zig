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

test "disk: generated visible proofs verify against the live commitment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    const reference = blk: {
        var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
        defer db.deinit();
        for (1..40) |seq| {
            var batch = V2Disk.Batch.init(gpa);
            defer batch.deinit();
            try batch.put(.accounts, seq % 7, seq * 3);
            if (seq % 3 == 0) try batch.delete(.flags, @intCast(seq % 5)) else try batch.put(.flags, @intCast(seq % 5), seq % 2 == 0);
            var prepared = try db.prepare(seq, &batch, &.{@intCast(seq % 256)});
            defer prepared.deinit();
            try prepared.commit();
        }
        const digest = db.commitment().digest;
        // Membership: a live key, proven and verified against the digest.
        {
            var bundle = try db.prove(.accounts, 0, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyVisible(&bundle.proof, digest);
            try std.testing.expect(!bundle.proof.absent);
            try std.testing.expectEqual(@as(?u64, 35 * 3), try db.get(.accounts, 0));
        }
        // Absence: a key that never existed.
        {
            var bundle = try db.prove(.accounts, 12345, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyVisible(&bundle.proof, digest);
            try std.testing.expect(bundle.proof.absent);
        }
        // A deleted key proves as absent: flags table at a tombstoned slot.
        {
            var bundle = try db.prove(.flags, 0, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyVisible(&bundle.proof, digest);
        }
        // Forged digest rejection.
        {
            var bundle = try db.prove(.accounts, 3, gpa);
            defer bundle.deinit();
            var wrong = digest;
            wrong[0] ^= 0xff;
            try std.testing.expectError(error.InvalidProof, lib.proofs.verifyVisible(&bundle.proof, wrong));
        }
        break :blk db.reference();
    };
    // The same proof verifies after reopen against the reopened digest.
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format, .expected = reference });
    defer db.deinit();
    var bundle = try db.prove(.accounts, 6, gpa);
    defer bundle.deinit();
    try lib.proofs.verifyVisible(&bundle.proof, db.commitment().digest);
}

test "disk: v2 profiles execute, reopen identically, and bind distinct digests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    const reference = blk: {
        var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
        defer db.deinit();
        for (1..40) |seq| {
            var batch = V2Disk.Batch.init(gpa);
            defer batch.deinit();
            try batch.put(.accounts, seq % 7, seq * 3);
            if (seq % 3 == 0) try batch.delete(.flags, @intCast(seq % 5)) else try batch.put(.flags, @intCast(seq % 5), seq % 2 == 0);
            var prepared = try db.prepare(seq, &batch, &.{@intCast(seq % 256)});
            defer prepared.deinit();
            try prepared.commit();
        }
        try std.testing.expectEqual(@as(?u64, 35 * 3), try db.get(.accounts, 0));
        try std.testing.expectEqual(@as(?u64, 34 * 3), try db.get(.accounts, 6));
        break :blk db.reference();
    };
    {
        var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format, .expected = reference });
        defer db.deinit();
        try std.testing.expectEqual(@as(?u64, 35 * 3), try db.get(.accounts, 0));
        try std.testing.expectEqual(@as(?u64, 34 * 3), try db.get(.accounts, 6));
        try std.testing.expectEqual(@as(?u64, null), try db.get(.accounts, 999));
    }
    // The same operations under v1 commit to different digests, and a v1
    // open of a v2 store is rejected by the manifest profile bytes.
    var v1_tmp = std.testing.tmpDir(.{});
    defer v1_tmp.cleanup();
    var v1_buf: [std.fs.max_path_bytes]u8 = undefined;
    const V1Disk = native.DatabaseWithDepth(Schema, 4);
    const v1_digest = blk: {
        var db = try V1Disk.open(gpa, io, try pathOf(&v1_tmp, &v1_buf), .{ .merge_workers = 1 });
        defer db.deinit();
        for (1..40) |seq| {
            var batch = V1Disk.Batch.init(gpa);
            defer batch.deinit();
            try batch.put(.accounts, seq % 7, seq * 3);
            if (seq % 3 == 0) try batch.delete(.flags, @intCast(seq % 5)) else try batch.put(.flags, @intCast(seq % 5), seq % 2 == 0);
            var prepared = try db.prepare(seq, &batch, &.{@intCast(seq % 256)});
            defer prepared.deinit();
            try prepared.commit();
        }
        break :blk db.commitment().digest;
    };
    var v2_digest: [32]u8 = undefined;
    {
        var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format, .expected = reference });
        defer db.deinit();
        v2_digest = db.commitment().digest;
    }
    try std.testing.expect(!std.mem.eql(u8, &v1_digest, &v2_digest));
    try std.testing.expectError(error.ProfileMismatch, V1Disk.open(gpa, io, path, .{ .merge_workers = 1 }));
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

test "disk: pre_publish commits batch blob syncs per publication and reopens identically" {
    const Guard = struct {
        var syncs: usize = 0;
        fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            syncs += 1;
            return io.vtable.fileSync(ctx, file);
        }
    };
    var counted = io;
    {
        var vtable = io.vtable.*;
        vtable.fileSync = Guard.sync;
        counted = .{ .userdata = io.userdata, .vtable = &vtable };
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    var expected: [7]?u64 = undefined;
    const reference = blk: {
        var db = try Disk.open(gpa, counted, path, .{ .merge_workers = 1, .durability = .pre_publish });
        defer db.deinit();
        Guard.syncs = 0;
        for (1..35) |seq| try advance(db, seq);
        const relaxed_syncs = Guard.syncs;
        for (0..7) |key| expected[key] = try db.get(.accounts, key);
        const ref = db.reference();
        // The same operations under the default policy: every blob costs
        // three sync calls (file, blobs dir, installed file), while the
        // publication barrier syncs each distinct blob once.
        var plain_tmp = std.testing.tmpDir(.{});
        defer plain_tmp.cleanup();
        var plain_buf: [std.fs.max_path_bytes]u8 = undefined;
        var steady = try Disk.open(gpa, counted, try pathOf(&plain_tmp, &plain_buf), .{ .merge_workers = 1 });
        defer steady.deinit();
        Guard.syncs = 0;
        for (1..35) |seq| try advance(steady, seq);
        try std.testing.expect(relaxed_syncs * 2 < Guard.syncs);
        break :blk ref;
    };
    // A reopen under the default policy validates every barrier-synced blob.
    var db = try Disk.open(gpa, io, path, .{ .expected = reference, .merge_workers = 1 });
    defer db.deinit();
    for (0..7) |key| try std.testing.expectEqual(expected[key], try db.get(.accounts, key));
    try std.testing.expectEqual(reference, db.reference());
}

test "disk: proofs pin retained references and read views across later advances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
    defer db.deinit();
    {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        try batch.put(.accounts, 0, 7);
        try batch.put(.accounts, 5, 9);
        var prepared = try db.prepare(1, &batch, "historical");
        defer prepared.deinit();
        try prepared.commit();
    }
    const historical = db.reference();
    var view = try db.readView();
    // The pinned state and the live frontier diverge after the next advance.
    {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        try batch.delete(.accounts, 0);
        try batch.put(.accounts, 6, 11);
        var prepared = try db.prepare(2, &batch, "live");
        defer prepared.deinit();
        try prepared.commit();
    }
    try std.testing.expectEqual(@as(?u64, null), try db.get(.accounts, 0));
    try std.testing.expectEqual(@as(?u64, 7), try view.get(.accounts, 0));

    // Live proof: the tombstone decides; the pinned states disagree.
    {
        var bundle = try db.prove(.accounts, 0, gpa);
        defer bundle.deinit();
        try lib.proofs.verifyVisible(&bundle.proof, db.commitment().digest);
        try std.testing.expect(!bundle.proof.absent);
        try std.testing.expect(bundle.proof.value == null);
    }
    // Pinned-view proof: value 7 against the view's own digest.
    {
        var bundle = try view.prove(.accounts, 0, gpa);
        defer bundle.deinit();
        const digest = view.commitment().digest;
        try lib.proofs.verifyVisible(&bundle.proof, digest);
        try std.testing.expect(!bundle.proof.absent);
        try std.testing.expectEqual(@as(u64, 7), try lib.Codec(u64).decode(bundle.proof.value.?));
        // A historical proof does not verify against the live digest.
        var wrong = digest;
        wrong[0] ^= 0xff;
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyVisible(&bundle.proof, wrong));
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyVisible(&bundle.proof, db.commitment().digest));
    }
    // Retained-reference proof survives collection that explicitly retains it
    // (the first collect also drops a superseded pending output).
    _ = try db.collect(&.{historical});
    {
        var bundle = try db.proveReference(historical, .accounts, 0, gpa);
        defer bundle.deinit();
        try lib.proofs.verifyVisible(&bundle.proof, historical.database_digest);
        try std.testing.expect(!bundle.proof.absent);
        try std.testing.expectEqual(@as(u64, 7), try lib.Codec(u64).decode(bundle.proof.value.?));
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyVisible(&bundle.proof, db.commitment().digest));
    }
    view.deinit();
    // Dropping the view releases its pin; the retained reference still holds
    // its history and collection remains a no-op for it.
    try std.testing.expectEqual(@as(usize, 0), try db.collect(&.{historical}));
}

test "disk: range proofs cover boundary cases and match point reads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
    defer db.deinit();
    for (1..41) |seq| {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        try batch.put(.accounts, seq - 1, seq * 100);
        if (seq % 4 == 0) try batch.delete(.accounts, seq - 2); // tombstones inside the space
        if (seq % 5 == 0) try batch.put(.flags, @intCast(seq % 8), seq % 2 == 0); // second table interleaved
        var prepared = try db.prepare(seq, &batch, "range-build");
        defer prepared.deinit();
        try prepared.commit();
    }
    const digest = db.commitment().digest;
    const Case = struct { start: u64, end: u64 };
    const cases = [_]Case{
        .{ .start = 0, .end = 40 }, // the whole key space
        .{ .start = 0, .end = 1 }, // first key
        .{ .start = 39, .end = 40 }, // last key
        .{ .start = 3, .end = 4 }, // single present key
        .{ .start = 2, .end = 3 }, // single tombstoned key
        .{ .start = 0, .end = 20 }, // half space
        .{ .start = 19, .end = 21 }, // straddles deletes
        .{ .start = 100, .end = 200 }, // entirely beyond every key
        .{ .start = 1 << 60, .end = (1 << 60) + 5 },
        .{ .start = 5, .end = 6 }, // deleted early, rewritten later
    };
    for (cases) |case| {
        var bundle = try db.proveRange(.accounts, case.start, case.end, gpa);
        defer bundle.deinit();
        try lib.proofs.verifyRange(&bundle.proof, digest);
        var expected: usize = 0;
        var cursor: u64 = case.start;
        while (cursor < case.end) : (cursor += 1) {
            const value = try db.get(.accounts, cursor);
            if (value == null) continue;
            try std.testing.expect(expected < bundle.proof.entries.len);
            const entry = bundle.proof.entries[expected];
            try std.testing.expectEqual(cursor, try lib.Codec(u64).decode(entry.key));
            try std.testing.expectEqual(value.?, try lib.Codec(u64).decode(entry.value));
            expected += 1;
        }
        try std.testing.expectEqual(expected, bundle.proof.entries.len);
        var wrong = digest;
        wrong[1] ^= 0xff;
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyRange(&bundle.proof, wrong));
    }
    // Dropping one claimed entry breaks verification, as does editing one.
    {
        var bundle = try db.proveRange(.accounts, 0, 40, gpa);
        defer bundle.deinit();
        var shortened = bundle.proof;
        shortened.entries = shortened.entries[0 .. shortened.entries.len - 1];
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyRange(&shortened, digest));
        var edited = bundle.proof;
        var entries = try gpa.dupe(lib.proofs.RangeEntry, edited.entries);
        defer gpa.free(entries);
        entries[0].value = entries[0].value[0..0];
        edited.entries = entries;
        try std.testing.expectError(error.InvalidProof, lib.proofs.verifyRange(&edited, digest));
    }
    // Degenerate and inverted intervals are rejected up front.
    try std.testing.expectError(error.InvalidRange, db.proveRange(.accounts, 7, 7, gpa));
    try std.testing.expectError(error.InvalidRange, db.proveRange(.accounts, 9, 2, gpa));
    // A v1 profile cannot range-prove.
    {
        var v1_tmp = std.testing.tmpDir(.{});
        defer v1_tmp.cleanup();
        var v1_buf: [std.fs.max_path_bytes]u8 = undefined;
        var plain = try V2Disk.open(gpa, io, try pathOf(&v1_tmp, &v1_buf), .{ .merge_workers = 1 });
        defer plain.deinit();
        try std.testing.expectError(error.ProfileMismatch, plain.proveRange(.accounts, 0, 10, gpa));
    }
}

test "disk: range proofs match an independent model across a random workload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
    defer db.deinit();
    var model = std.AutoHashMap(u64, u64).init(gpa);
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed_1234);
    const random = prng.random();
    var seq: u64 = 0;
    var checked: usize = 0;
    var stale_checks: usize = 0;
    while (seq < 90) : (seq += 1) {
        {
            var batch = V2Disk.Batch.init(gpa);
            defer batch.deinit();
            for (0..8) |_| {
                const key = random.uintAtMost(u64, 63);
                if (random.uintLessThan(u32, 100) < 25) {
                    try batch.delete(.accounts, key);
                    _ = model.remove(key);
                } else {
                    const value = random.int(u64);
                    try batch.put(.accounts, key, value);
                    try model.put(key, value);
                }
                if (random.uintLessThan(u32, 100) < 20) {
                    const flag = random.uintAtMost(u8, 7);
                    try batch.put(.flags, flag, random.boolean());
                }
            }
            var prepared = try db.prepare(seq + 1, &batch, "range-random");
            defer prepared.deinit();
            try prepared.commit();
        }
        if (seq % 7 != 3) continue;
        // A stale digest from an earlier round stays valid for proofs made
        // against it and invalid for the live frontier.
        const digest = db.commitment().digest;
        for (0..3) |_| {
            const a = random.uintAtMost(u64, 68);
            const b = a + 1 + random.uintAtMost(u64, 6);
            var bundle = try db.proveRange(.accounts, a, b, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyRange(&bundle.proof, digest);
            var expected: usize = 0;
            var cursor: u64 = a;
            while (cursor < b) : (cursor += 1) {
                const value = model.get(cursor) orelse continue;
                try std.testing.expect(expected < bundle.proof.entries.len);
                try std.testing.expectEqual(cursor, try lib.Codec(u64).decode(bundle.proof.entries[expected].key));
                try std.testing.expectEqual(value, try lib.Codec(u64).decode(bundle.proof.entries[expected].value));
                expected += 1;
            }
            try std.testing.expectEqual(expected, bundle.proof.entries.len);
            checked += 1;
        }
        // Advance once more, then the round's proofs fail the new digest.
        {
            var batch = V2Disk.Batch.init(gpa);
            defer batch.deinit();
            try batch.put(.accounts, 64, 1);
            try model.put(64, 1);
            var prepared = try db.prepare(seq + 2, &batch, "range-stale");
            defer prepared.deinit();
            try prepared.commit();
            var bundle = try db.proveRange(.accounts, 0, 60, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyRange(&bundle.proof, db.commitment().digest);
            try std.testing.expectError(error.InvalidProof, lib.proofs.verifyRange(&bundle.proof, digest));
            stale_checks += 1;
            seq += 1;
        }
    }
    try std.testing.expect(checked > 24 and stale_checks > 8);
}

test "disk: proof generation survives struct-literal reordering across depths" {
    // Regression: scanForProof's return literal once mixed computed fields
    // with `try` expressions, and the pinned compiler evaluated
    // `.block_count` against stale state, producing internally inconsistent
    // placements (this exact history made a one-block bucket claim two).
    // The same shape is exercised at the default depth and a shallow one.
    const Repro = struct {
        fn run(comptime depth: usize) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try pathOf(&tmp, &buf);
            const Db = native.DatabaseWithDepth(Schema, depth);
            const format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
            var db = try Db.open(gpa, io, path, .{ .merge_workers = 1, .format = format });
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
            var bundle = try db.prove(.accounts, 4, gpa);
            defer bundle.deinit();
            try lib.proofs.verifyVisible(&bundle.proof, digest);
            var range = try db.proveRange(.accounts, 0, 72, gpa);
            defer range.deinit();
            try lib.proofs.verifyRange(&range.proof, digest);
        }
    };
    try Repro.run(4);
    try Repro.run(11);
}

test "disk: range scans match the model, point reads, and range proofs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
    defer db.deinit();
    var model = std.AutoHashMap(u64, u64).init(gpa);
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(0xb5c4_1111);
    const random = prng.random();
    var checked: usize = 0;
    var seq: u64 = 0;
    while (seq < 80) : (seq += 1) {
        {
            var batch = V2Disk.Batch.init(gpa);
            defer batch.deinit();
            for (0..7) |_| {
                const key = random.uintAtMost(u64, 47);
                if (random.uintLessThan(u32, 100) < 30) {
                    try batch.delete(.accounts, key);
                    _ = model.remove(key);
                } else {
                    const value = random.int(u64);
                    try batch.put(.accounts, key, value);
                    try model.put(key, value);
                }
                if (random.uintLessThan(u32, 100) < 15) {
                    try batch.put(.flags, random.uintAtMost(u8, 3), random.boolean());
                }
            }
            var prepared = try db.prepare(seq + 1, &batch, "scan-random");
            defer prepared.deinit();
            try prepared.commit();
        }
        if (seq % 9 != 4) continue;
        const a = random.uintAtMost(u64, 44);
        const b = a + 1 + random.uintAtMost(u64, 40);
        var scan = try db.scan(.accounts, a, b, gpa);
        defer scan.deinit();
        var expected: usize = 0;
        var cursor_key: u64 = a;
        while (cursor_key < b) : (cursor_key += 1) {
            const value = model.get(cursor_key) orelse continue;
            const entry = try scan.next();
            try std.testing.expect(entry != null);
            try std.testing.expectEqual(cursor_key, entry.?.key);
            try std.testing.expectEqual(value, entry.?.value);
            try std.testing.expectEqual(value, (try db.get(.accounts, cursor_key)).?);
            expected += 1;
        }
        try std.testing.expect(try scan.next() == null);
        try scan.finish();
        try std.testing.expect(try scan.next() == null);
        // The authenticated range proof claims exactly the same records.
        var bundle = try db.proveRange(.accounts, a, b, gpa);
        defer bundle.deinit();
        try lib.proofs.verifyRange(&bundle.proof, db.commitment().digest);
        try std.testing.expectEqual(expected, bundle.proof.entries.len);
        var index: usize = 0;
        cursor_key = a;
        while (cursor_key < b and index < bundle.proof.entries.len) : (cursor_key += 1) {
            const value = model.get(cursor_key) orelse continue;
            try std.testing.expectEqual(cursor_key, try lib.Codec(u64).decode(bundle.proof.entries[index].key));
            try std.testing.expectEqual(value, try lib.Codec(u64).decode(bundle.proof.entries[index].value));
            index += 1;
        }
        checked += 1;
    }
    try std.testing.expect(checked > 4);
    // Degenerate intervals and a v1 profile are rejected up front.
    try std.testing.expectError(error.InvalidRange, db.scan(.accounts, 7, 7, gpa));
    try std.testing.expectError(error.InvalidRange, db.scan(.accounts, 9, 2, gpa));
}

test "disk: scans pin read views across advances and survive bounded failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buf);
    const V2Disk = native.DatabaseWithDepth(Schema, 4);
    const v2_format: store.BucketFormat = .{ .v2 = .{ .target_block_bytes = 96 } };
    var db = try V2Disk.open(gpa, io, path, .{ .merge_workers = 1, .format = v2_format });
    defer db.deinit();
    {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        for (0..30) |key| try batch.put(.accounts, key, key * 5);
        var prepared = try db.prepare(1, &batch, "scan-build");
        defer prepared.deinit();
        try prepared.commit();
    }
    // Spread data across levels so several slots participate in a scan.
    for (2..6) |seq| {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        try batch.put(.accounts, seq * 40, seq);
        try batch.delete(.accounts, seq - 1);
        var prepared = try db.prepare(seq, &batch, "scan-spread");
        defer prepared.deinit();
        try prepared.commit();
    }
    var view = try db.readView();
    {
        var batch = V2Disk.Batch.init(gpa);
        defer batch.deinit();
        for (0..30) |key| try batch.delete(.accounts, key);
        try batch.put(.accounts, 30, 300);
        try batch.put(.accounts, 5, 55);
        var prepared = try db.prepare(6, &batch, "scan-live");
        defer prepared.deinit();
        try prepared.commit();
    }
    // The pinned view sees keys 0 and 5..29 (at five-fold values; the
    // spread advances deleted 1..4) plus the four spread keys.
    {
        var scan = try view.scan(.accounts, 0, 1000, gpa);
        defer scan.deinit();
        var count: u64 = 0;
        while (try scan.next()) |entry| {
            if (entry.key < 30) {
                try std.testing.expect(entry.key == 0 or entry.key >= 5);
                try std.testing.expectEqual(entry.key * 5, entry.value);
            } else {
                try std.testing.expectEqual(entry.key / 40, entry.value);
            }
            count += 1;
        }
        try std.testing.expectEqual(@as(u64, 30), count);
        try scan.finish();
    }
    // The live frontier sees the rewrite of key 5 and the spread keys that
    // the delete-all batch never touched.
    {
        var scan = try db.scan(.accounts, 0, 1000, gpa);
        defer scan.deinit();
        var count: u64 = 0;
        while (try scan.next()) |entry| {
            switch (entry.key) {
                5 => try std.testing.expectEqual(@as(u64, 55), entry.value),
                30 => try std.testing.expectEqual(@as(u64, 300), entry.value),
                80, 120, 160, 200 => {},
                else => return error.TestUnexpectedResult,
            }
            count += 1;
        }
        try std.testing.expectEqual(@as(u64, 6), count);
        try scan.finish();
    }
    view.deinit();
    // Every construction allocation failure cleans up completely and a
    // retry on the same state succeeds.
    var failures: usize = 0;
    while (failures < 200) : (failures += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = failures });
        var scan = db.scan(.accounts, 0, 1000, failing.allocator()) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            failing.fail_index = std.math.maxInt(usize);
            var retry = try db.scan(.accounts, 0, 1000, failing.allocator());
            retry.deinit();
            continue;
        };
        scan.deinit();
        if (!failing.has_induced_failure) break;
    }
    try std.testing.expect(failures > 1 and failures < 200);
}
