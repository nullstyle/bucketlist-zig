const std = @import("std");
const lib = @import("bucketlist");
const native = @import("bucketlist-store");
const checkpoints = @import("checkpoints.zig");
const gpa = std.testing.allocator;
const io = std.testing.io;
const Schema = struct {
    pub const namespace = "checkpoint.tests";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = lib.Table(1, u64, u64),
        .names = lib.Table(2, lib.Bytes(16), u64),
    };
};
const Db = lib.Database(Schema);
const Checkpoints = checkpoints.Checkpoints(Db);

test "checkpoints: include manager publication fault regressions" {
    std.testing.refAllDecls(Checkpoints);
}

fn advance(db: *Db, seq: u64) !void {
    var batch = try db.batch(gpa);
    defer batch.deinit();
    try batch.put(.accounts, seq % 9, seq * 17);
    const name = try lib.Bytes(16).init("owner");
    if (seq % 3 == 0) try batch.delete(.names, name) else try batch.put(.names, name, seq);
    var prepared = try db.prepareAdvance(gpa, seq, &batch);
    defer prepared.deinit();
    try db.commit(&prepared);
}

fn tmpPath(tmp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const n = try tmp.dir.realPath(io, buffer);
    return buffer[0..n];
}

fn save(manager: *Checkpoints, db: *Db, metadata: []const u8) !checkpoints.Reference {
    var view = db.readView();
    defer view.deinit();
    return manager.save(&view, metadata);
}

test "checkpoints: exact two-table continuation and metadata across spill boundaries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    const boundaries = [_]u64{ 0, 1, 7, 8, 9, 31, 32, 33, 63, 64, 65 };
    for (boundaries) |boundary| {
        while (db.commitment().advance < boundary) try advance(&db, db.commitment().advance + 1);
        const metadata = [_]u8{ 0, @intCast(boundary), 255, 0 };
        const trusted = blk: {
            var manager = try Checkpoints.open(gpa, io, path, .{});
            defer manager.deinit();
            const reference = try save(&manager, &db, &metadata);
            try std.testing.expectEqual(db.commitment().digest, reference.database_digest);
            try std.testing.expectEqual(reference, (try manager.current()).?);
            try std.testing.expectEqual(reference, try save(&manager, &db, &metadata));
            break :blk reference;
        };
        var manager = try Checkpoints.open(gpa, io, path, .{});
        defer manager.deinit();
        var restored = try manager.load(gpa, trusted);
        defer restored.deinit();
        try std.testing.expectEqualSlices(u8, &metadata, restored.metadata);
        try std.testing.expectEqual(db.commitment(), restored.database.commitment());
        try std.testing.expectEqual(db.get(.accounts, boundary % 9), restored.database.get(.accounts, boundary % 9));
        // The live database stays at the checkpoint; compare the next actual
        // update with a separately prepared advance, including pending merges.
        const next = boundary + 1;
        try advance(&restored.database, next);
        const encoded = try db.checkpoint(gpa);
        defer gpa.free(encoded);
        var portable = try Db.restore(gpa, encoded, trusted.database_digest);
        defer portable.deinit();
        try advance(&portable, next);
        try std.testing.expectEqual(portable.commitment(), restored.database.commitment());
    }
}

test "checkpoints: GC retains current and explicit history, then releases history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    var manager = try Checkpoints.open(gpa, io, path, .{});
    try std.testing.expect((try manager.current()) == null);
    for (1..8) |seq| try advance(&db, seq);
    const old = try save(&manager, &db, "previous command at seven");
    try advance(&db, 8);
    const current = try save(&manager, &db, "previous command at eight");
    manager.deinit();
    const orphan = blk: {
        var store = try native.Store.open(gpa, io, path);
        defer store.deinit();
        break :blk try store.putBlob("unpublished staging output");
    };
    manager = try Checkpoints.open(gpa, io, path, .{});
    defer manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), try manager.collect(&.{old}));
    {
        var loaded = try manager.load(gpa, old);
        defer loaded.deinit();
        try std.testing.expectEqual(@as(u64, 7), loaded.database.commitment().advance);
    }
    try std.testing.expect((try manager.collect(&.{})) >= 1);
    try std.testing.expectError(error.NotFound, manager.load(gpa, old));
    var loaded = try manager.load(gpa, current);
    defer loaded.deinit();
    try std.testing.expectEqual(db.commitment(), loaded.database.commitment());
    var name: [70]u8 = undefined;
    const removed_path = try std.fmt.bufPrint(&name, "blobs/{s}", .{std.fmt.bytesToHex(orphan, .lower)});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, removed_path, .{ .follow_symlinks = false }));
}

test "checkpoints: wrong reference and corrupt retained inputs cannot trigger GC" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    var manager = try Checkpoints.open(gpa, io, path, .{});
    const reference = try save(&manager, &db, "exact previous value");
    var wrong = reference;
    wrong.database_digest[0] ^= 1;
    try std.testing.expectError(error.CommitmentMismatch, manager.load(gpa, wrong));
    manager.deinit();
    const orphan = blk: {
        var store = try native.Store.open(gpa, io, path);
        defer store.deinit();
        break :blk try store.putBlob("must survive failed collection");
    };
    manager = try Checkpoints.open(gpa, io, path, .{});
    try std.testing.expectError(error.CommitmentMismatch, manager.collect(&.{wrong}));
    // All production-profile genesis levels share this canonical empty bucket.
    var empty_hash: native.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash("bucketlist.bucket.v1\x00\x00\x00\x00\x00\x00\x00\x00\x00", &empty_hash, .{});
    var name: [70]u8 = undefined;
    const corrupt_path = try std.fmt.bufPrint(&name, "blobs/{s}", .{std.fmt.bytesToHex(empty_hash, .lower)});
    const file = try tmp.dir.openFile(io, corrupt_path, .{ .mode = .read_write });
    try file.setLength(io, 0);
    file.close(io);
    try std.testing.expectError(error.CorruptBlob, manager.load(gpa, reference));
    try std.testing.expectError(error.CorruptBlob, manager.collect(&.{}));
    manager.deinit();
    var store = try native.Store.open(gpa, io, path);
    defer store.deinit();
    const kept = try store.getBlob(gpa, orphan, 100);
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("must survive failed collection", kept);
}

test "checkpoints: metadata participates in reference authentication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    var manager = try Checkpoints.open(gpa, io, path, .{});
    defer manager.deinit();
    const a = try save(&manager, &db, "value A");
    const b = try save(&manager, &db, "value B");
    try std.testing.expectEqual(a.database_digest, b.database_digest);
    try std.testing.expect(!std.mem.eql(u8, &a.manifest_hash, &b.manifest_hash));
    var loaded = try manager.load(gpa, a);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("value A", loaded.metadata);
    try std.testing.expectEqual(b, (try manager.current()).?);
}

test "checkpoints: inclusive bounds fail before changing the published frontier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    const encoded = try db.checkpoint(gpa);
    defer gpa.free(encoded);
    var manager = try Checkpoints.open(gpa, io, path, .{
        .max_checkpoint_bytes = encoded.len,
        .max_metadata_bytes = 4,
    });
    const reference = try save(&manager, &db, "1234");
    try std.testing.expectError(error.TooLarge, save(&manager, &db, "12345"));
    try std.testing.expectEqual(reference, (try manager.current()).?);
    try advance(&db, 1);
    try std.testing.expectError(error.TooLarge, save(&manager, &db, "1234"));
    try std.testing.expectEqual(reference, (try manager.current()).?);
    manager.deinit();
    manager = try Checkpoints.open(gpa, io, path, .{ .max_metadata_bytes = 3 });
    try std.testing.expectError(error.TooLarge, manager.load(gpa, reference));
    manager.deinit();
    manager = try Checkpoints.open(gpa, io, path, .{ .max_checkpoint_bytes = encoded.len - 1 });
    defer manager.deinit();
    try std.testing.expectError(error.TooLarge, manager.load(gpa, reference));
}

fn loadWithAllocator(allocator: std.mem.Allocator, manager: *Checkpoints, reference: checkpoints.Reference) !void {
    var restored = try manager.load(allocator, reference);
    defer restored.deinit();
    try std.testing.expectEqualStrings("allocation failure recovery", restored.metadata);
    try std.testing.expectEqual(@as(u64, 153), restored.database.get(.accounts, 0).?);
}

test "checkpoints: every restore allocation can fail without leaks or frontier changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    for (1..10) |seq| try advance(&db, seq);
    var manager = try Checkpoints.open(gpa, io, path, .{});
    defer manager.deinit();
    const reference = try save(&manager, &db, "allocation failure recovery");
    try std.testing.checkAllAllocationFailures(gpa, loadWithAllocator, .{ &manager, reference });
    try std.testing.expectEqual(reference, (try manager.current()).?);
}

test "checkpoints: hash-valid malformed manifests reject framing and hostile lengths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &buffer);
    var db = Db.init(gpa);
    defer db.deinit();
    const trusted = blk: {
        var manager = try Checkpoints.open(gpa, io, path, .{});
        defer manager.deinit();
        break :blk try save(&manager, &db, "m");
    };
    var invalid: std.ArrayList(checkpoints.Reference) = .empty;
    defer invalid.deinit(gpa);
    {
        var store = try native.Store.open(gpa, io, path);
        defer store.deinit();
        const original = try store.getBlob(gpa, trusted.manifest_hash, 4096);
        defer gpa.free(original);
        // Offsets come from the versioned public local storage format.
        const domain_len = "bucketlist.native-checkpoint.v1\x00".len;
        const metadata_len_at = domain_len + 32;
        const portable_at = metadata_len_at + 8 + 1;
        const levels_at = portable_at + "bucketlist.checkpoint.v1\x00".len + 32 + 32 + 8;
        const bucket_at = levels_at + 1;
        const pending_at = bucket_at + 2 * (8 + 32);
        for ([_]usize{ 0, domain_len - 1, metadata_len_at + 7, portable_at, levels_at, bucket_at + 39, original.len - 1 }) |n| {
            try invalid.append(gpa, .{ .manifest_hash = try store.putBlob(original[0..n]), .database_digest = trusted.database_digest });
        }
        const mutation_offsets = [_]usize{ 0, portable_at, levels_at, pending_at, metadata_len_at, bucket_at };
        for (mutation_offsets, 0..) |offset, mutation| {
            const changed = try gpa.dupe(u8, original);
            defer gpa.free(changed);
            switch (mutation) {
                0, 1 => changed[offset] ^= 1,
                2 => changed[offset] = 32,
                3 => changed[offset] = 2,
                4, 5 => @memset(changed[offset..][0..8], 255),
                else => unreachable,
            }
            try invalid.append(gpa, .{ .manifest_hash = try store.putBlob(changed), .database_digest = trusted.database_digest });
        }
        const trailing = try std.mem.concat(gpa, u8, &.{ original, "\x00" });
        defer gpa.free(trailing);
        try invalid.append(gpa, .{ .manifest_hash = try store.putBlob(trailing), .database_digest = trusted.database_digest });
    }
    var manager = try Checkpoints.open(gpa, io, path, .{});
    defer manager.deinit();
    for (invalid.items) |reference| {
        if (manager.load(gpa, reference)) |value| {
            var accepted = value;
            accepted.deinit();
            return error.AcceptedMalformedManifest;
        } else |err| switch (err) {
            error.InvalidCheckpoint, error.TooLarge => {},
            else => return err,
        }
    }
    try std.testing.expectEqual(trusted, (try manager.current()).?);
}
