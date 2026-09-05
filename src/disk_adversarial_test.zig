const std = @import("std");
const lib = @import("bucketlist");
const native = @import("disk.zig");
const storage = @import("bucketlist-store");
const gpa = std.testing.allocator;
const io = std.testing.io;
const Hash = storage.Hash;
const manifest_domain = "bucketlist.disk-frontier.v1\x00";
const catalog_domain = "bucketlist.disk-current.v1\x00";
const bucket_domain = "bucketlist.bucket.v1\x00";
const header_len = manifest_domain.len + 32 + 32 + 8;

fn pathOf(tmp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(io, buffer);
    return buffer[0..len];
}

/// Enforces live requested bytes, not total process RSS. Fixture construction,
/// stacks, filesystem cache, and the std.Io backend are outside this budget.
/// Tests configure one merge worker, so this wrapper is deliberately serial.
const BudgetAllocator = struct {
    child: std.mem.Allocator = gpa,
    limit: usize,
    live: usize = 0,
    peak: usize = 0,
    denied: usize = 0,

    fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }
    fn admits(self: *BudgetAllocator, old: usize, size: usize) bool {
        if (size > self.limit - (self.live - old)) {
            self.denied += 1;
            return false;
        }
        return true;
    }
    fn changed(self: *BudgetAllocator, old: usize, size: usize) void {
        self.live = self.live - old + size;
        self.peak = @max(self.peak, self.live);
    }
    fn allocate(context: *anyopaque, size: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(0, size)) return null;
        const result = self.child.rawAlloc(size, alignment, address) orelse return null;
        self.changed(0, size);
        return result;
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(bytes.len, size)) return false;
        if (!self.child.rawResize(bytes, alignment, size, address)) return false;
        self.changed(bytes.len, size);
        return true;
    }
    fn remap(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, size: usize, address: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        if (!self.admits(bytes.len, size)) return null;
        const result = self.child.rawRemap(bytes, alignment, size, address) orelse return null;
        self.changed(bytes.len, size);
        return result;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(bytes, alignment, address);
        self.changed(bytes.len, 0);
    }
};

const LargeSchema = struct {
    pub const namespace = "disk.adversarial.large";
    pub const version: u32 = 1;
    pub const tables = .{ .records = lib.Table(1, u64, [4096]u8) };
};
const LargeDisk = native.Database(LargeSchema);

fn largeValue(key: u64) [4096]u8 {
    var bytes: [4096]u8 = @splat(0x5a);
    std.mem.writeInt(u64, bytes[0..8], key, .big);
    return bytes;
}

test "disk: database larger than 1 MiB reopens reads advances and collects under 128 KiB" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const first = blk: {
        const db = try LargeDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        var batch = LargeDisk.Batch.init(gpa);
        defer batch.deinit();
        for (0..384) |key| try batch.put(.records, key, largeValue(key));
        var prepared = try db.prepare(1, &batch, "large-first");
        defer prepared.deinit();
        try prepared.commit();
        break :blk db.reference();
    };
    // Build an independent portable expected result before starting the
    // constrained phase. No portable Database survives into that phase.
    const expected = blk: {
        const Memory = lib.Database(LargeSchema);
        var db = Memory.init(gpa);
        defer db.deinit();
        {
            var batch = try db.batch(gpa);
            defer batch.deinit();
            for (0..384) |key| try batch.put(.records, key, largeValue(key));
            var prepared = try db.prepareAdvance(gpa, 1, &batch);
            defer prepared.deinit();
            try db.commit(&prepared);
        }
        try std.testing.expectEqual(first.database_digest, db.commitment().digest);
        {
            var batch = try db.batch(gpa);
            defer batch.deinit();
            try batch.put(.records, 0, largeValue(9999));
            var prepared = try db.prepareAdvance(gpa, 2, &batch);
            defer prepared.deinit();
            try db.commit(&prepared);
        }
        break :blk db.commitment();
    };
    // Confirm a single persisted bucket exceeds twelve times the live budget.
    const bucket_size = blk: {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        const manifest = try store.getBlob(gpa, first.manifest_hash, 4096);
        defer gpa.free(manifest);
        const bucket_hash = manifest[header_len..][0..32].*;
        var scan = try store.scanBucket(bucket_hash, .{ .max_key_bytes = 8, .max_value_bytes = 4096 });
        defer scan.deinit();
        try scan.finish();
        try std.testing.expect(scan.byteLength() > 12 * 128 * 1024);
        break :blk scan.byteLength();
    };
    var budget: BudgetAllocator = .{ .limit = 128 * 1024 };
    const limited = budget.allocator();
    const second = blk: {
        const db = try LargeDisk.open(limited, io, path, .{ .merge_workers = 1, .expected = first });
        defer db.deinit();
        try std.testing.expectEqual(largeValue(383), (try db.get(.records, 383)).?);
        try std.testing.expect(try db.get(.records, 500) == null);
        const pinned = try db.readView();
        defer pinned.deinit();
        var batch = LargeDisk.Batch.initBounded(limited, 8192, 2);
        defer batch.deinit();
        try batch.put(.records, 0, largeValue(9999));
        var prepared = try db.prepare(2, &batch, "large-second");
        defer prepared.deinit();
        try prepared.commit();
        try std.testing.expectEqual(expected, db.commitment());
        try std.testing.expectEqual(largeValue(9999), (try db.get(.records, 0)).?);
        try std.testing.expectEqual(largeValue(0), (try pinned.get(.records, 0)).?);
        _ = try db.collect(&.{});
        try std.testing.expectEqual(largeValue(0), (try pinned.get(.records, 0)).?);
        break :blk db.reference();
    };
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    {
        const db = try LargeDisk.open(limited, io, path, .{ .merge_workers = 1, .expected = second });
        defer db.deinit();
        try std.testing.expectEqual(expected, db.commitment());
        try std.testing.expectEqualStrings("large-second", db.metadata());
        try std.testing.expectEqual(largeValue(383), (try db.get(.records, 383)).?);
        _ = try db.collect(&.{});
    }
    try std.testing.expectEqual(@as(usize, 0), budget.live);
    try std.testing.expectEqual(@as(usize, 0), budget.denied);
    try std.testing.expect(budget.peak <= budget.limit);
    std.debug.print("[disk-budget] bucket={d} live_peak={d} budget={d} denied={d}\n", .{ bucket_size, budget.peak, budget.limit, budget.denied });
}

const SmallSchema = struct {
    pub const namespace = "disk.adversarial.small";
    pub const version: u32 = 1;
    pub const tables = .{ .records = lib.Table(1, u64, u64), .flags = lib.Table(2, u8, bool) };
};
const SmallDisk = native.Database(SmallSchema);

fn advanceSmall(db: *SmallDisk, sequence: u64) !void {
    var batch = SmallDisk.Batch.init(gpa);
    defer batch.deinit();
    try batch.put(.records, sequence % 3, sequence * 17);
    try batch.put(.flags, 1, sequence % 2 == 1);
    var prepared = try db.prepare(sequence, &batch, "small-frontier");
    defer prepared.deinit();
    try prepared.commit();
}

fn publishReference(store: *storage.Store, reference: native.Reference) !void {
    var catalog: [catalog_domain.len + 64]u8 = undefined;
    @memcpy(catalog[0..catalog_domain.len], catalog_domain);
    @memcpy(catalog[catalog_domain.len..][0..32], &reference.manifest_hash);
    @memcpy(catalog[catalog_domain.len + 32 ..][0..32], &reference.database_digest);
    try store.publish(&catalog);
}

test "disk: external expected reference rejects rollback and incompatible schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    var first: native.Reference = undefined;
    const second = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        try advanceSmall(db, 1);
        first = db.reference();
        try advanceSmall(db, 2);
        break :blk db.reference();
    };
    const WrongSchema = struct {
        pub const namespace = "disk.adversarial.wrong";
        pub const version: u32 = 1;
        pub const tables = SmallSchema.tables;
    };
    try std.testing.expectError(error.SchemaMismatch, native.Database(WrongSchema).open(gpa, io, path, .{ .merge_workers = 1 }));
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        try publishReference(&store, first);
    }
    try std.testing.expectError(error.CommitmentMismatch, SmallDisk.open(gpa, io, path, .{ .merge_workers = 1, .expected = second }));
    // Local integrity alone intentionally does not assert freshness.
    const old = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
    defer old.deinit();
    try std.testing.expectEqual(first, old.reference());
    try std.testing.expectEqual(@as(u64, 1), old.commitment().advance);
}

test "disk: missing populated catalog fails closed and preserves immutable files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const reference = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        try advanceSmall(db, 1);
        break :blk db.reference();
    };
    const original_manifest = blk: {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        break :blk try store.getBlob(gpa, reference.manifest_hash, 4096);
    };
    defer gpa.free(original_manifest);
    const bucket_hash = original_manifest[header_len..][0..32].*;
    try tmp.dir.deleteFile(io, "manifest");
    try std.testing.expectError(error.MissingManifest, SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 }));
    var store = try storage.Store.open(gpa, io, path);
    defer store.deinit();
    try std.testing.expect(try store.readManifest(gpa, 4096) == null);
    const retained_manifest = try store.getBlob(gpa, reference.manifest_hash, 4096);
    defer gpa.free(retained_manifest);
    try std.testing.expectEqualSlices(u8, original_manifest, retained_manifest);
    var cursor = try store.scanBucket(bucket_hash, .{ .max_key_bytes = 8, .max_value_bytes = 8 });
    defer cursor.deinit();
    try cursor.finish();
    try std.testing.expect(cursor.recordCount() > 0);
}

test "disk: interrupted genesis with only initial blobs can retry publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const original = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        try std.testing.expectEqual(@as(u64, 0), db.commitment().advance);
        break :blk db.reference();
    };
    // The interrupted boundary is after immutable genesis files are durable
    // and before the first catalog is published.
    try tmp.dir.deleteFile(io, "manifest");
    const recovered = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
    defer recovered.deinit();
    try std.testing.expectEqual(original, recovered.reference());
    try std.testing.expectEqual(@as(u64, 0), recovered.commitment().advance);
    try std.testing.expectEqualStrings("", recovered.metadata());
    try std.testing.expect(try recovered.get(.records, 1) == null);
}

test "disk: corrupt canonical bucket tail fails reopen and releases store lock" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const reference = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        try advanceSmall(db, 1);
        break :blk db.reference();
    };
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        const manifest = try store.getBlob(gpa, reference.manifest_hash, 4096);
        defer gpa.free(manifest);
        const hash = manifest[header_len..][0..32].*;
        const bytes = try store.getBlob(gpa, hash, 4096);
        defer gpa.free(bytes);
        const name = std.fmt.bytesToHex(hash, .lower);
        const file = try store.blobs.openFile(io, &name, .{ .mode = .read_write });
        defer file.close(io);
        // The last record is bool=true. false is still canonical, so the
        // content-hash check must reject the changed tail at verified EOF.
        try file.writePositionalAll(io, "\x00", bytes.len - 1);
    }
    try std.testing.expectError(error.CorruptBlob, SmallDisk.open(gpa, io, path, .{ .merge_workers = 1, .expected = reference }));
    var unlocked = try storage.Store.open(gpa, io, path);
    defer unlocked.deinit();
}

/// Independently recomputes the v1 outer commitment from the hash-only local
/// manifest, so a forged pending output passes the outer-digest comparison and
/// must still fail the engine's semantic continuation verification.
fn digestFromManifest(manifest: []const u8) Hash {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const schema_hash = manifest[manifest_domain.len..][0..32];
    const profile_hash = manifest[manifest_domain.len + 32 ..][0..32];
    const sequence = manifest[manifest_domain.len + 64 ..][0..8];
    var root = Sha256.init(.{});
    root.update("bucketlist.list.v1\x00");
    root.update(profile_hash);
    var continuation = Sha256.init(.{});
    continuation.update("bucketlist.continuation.v1\x00");
    continuation.update(profile_hash);
    var position: usize = header_len;
    for (0..11) |i| {
        var index: [4]u8 = undefined;
        std.mem.writeInt(u32, &index, @intCast(i), .big);
        var level = Sha256.init(.{});
        level.update("bucketlist.level.v1\x00");
        level.update(&index);
        level.update(manifest[position..][0..64]);
        root.update(&level.finalResult());
        position += 64;
        const present = manifest[position];
        position += 1;
        continuation.update(&index);
        continuation.update(&.{present});
        if (present == 1) {
            continuation.update(manifest[position..][0..32]);
            position += 32;
        }
    }
    var database = Sha256.init(.{});
    database.update("bucketlist.database.v1\x00");
    database.update(schema_hash);
    database.update(profile_hash);
    database.update(sequence);
    database.update(&root.finalResult());
    database.update(&continuation.finalResult());
    return database.finalResult();
}

test "disk: self-consistent forged pending hash cannot reopen or authorize garbage collection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const current = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        try advanceSmall(db, 1);
        try advanceSmall(db, 2);
        break :blk db.reference();
    };
    var forged: native.Reference = undefined;
    var orphan: Hash = undefined;
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        const manifest = try store.getBlob(gpa, current.manifest_hash, 4096);
        defer gpa.free(manifest);
        try std.testing.expectEqual(current.database_digest, digestFromManifest(manifest));
        const pending_at = header_len + 65 + 65;
        try std.testing.expectEqual(@as(u8, 1), manifest[pending_at - 1]);
        var empty_hash: Hash = undefined;
        std.crypto.hash.sha2.Sha256.hash(bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x00", &empty_hash, .{});
        @memcpy(manifest[pending_at..][0..32], &empty_hash);
        forged = .{ .manifest_hash = try store.putBlob(manifest), .database_digest = digestFromManifest(manifest) };
        try std.testing.expect(!std.mem.eql(u8, &current.database_digest, &forged.database_digest));
        orphan = try store.putBlob("must survive unsuccessful retained-root validation");
    }
    {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1, .expected = current });
        defer db.deinit();
        try std.testing.expectError(error.InvalidTopology, db.collect(&.{forged}));
        try std.testing.expectEqual(current, db.reference());
        try std.testing.expectEqual(@as(?u64, 34), try db.get(.records, 2));
    }
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        const kept = try store.getBlob(gpa, orphan, 100);
        defer gpa.free(kept);
        try std.testing.expectEqualStrings("must survive unsuccessful retained-root validation", kept);
        try publishReference(&store, forged);
    }
    try std.testing.expectError(error.InvalidTopology, SmallDisk.open(gpa, io, path, .{ .merge_workers = 1, .expected = forged }));
    var store = try storage.Store.open(gpa, io, path);
    defer store.deinit();
    const catalog = (try store.readManifest(gpa, catalog_domain.len + 64)).?;
    defer gpa.free(catalog);
    try std.testing.expectEqualSlices(u8, &forged.manifest_hash, catalog[catalog_domain.len..][0..32]);
}

fn reopenWithAllocator(allocator: std.mem.Allocator, path: []const u8, reference: native.Reference) !void {
    const db = try SmallDisk.open(allocator, io, path, .{ .merge_workers = 1, .expected = reference });
    defer db.deinit();
    try std.testing.expectEqual(reference, db.reference());
    try std.testing.expectEqualStrings("small-frontier", db.metadata());
    try std.testing.expectEqual(@as(?u64, 153), try db.get(.records, 0));
}

test "disk: every populated reopen allocation can fail without leaking or changing frontier" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try pathOf(&tmp, &buffer);
    const reference = blk: {
        const db = try SmallDisk.open(gpa, io, path, .{ .merge_workers = 1 });
        defer db.deinit();
        for (1..10) |sequence| try advanceSmall(db, sequence);
        break :blk db.reference();
    };
    try std.testing.checkAllAllocationFailures(gpa, reopenWithAllocator, .{ path, reference });
    try reopenWithAllocator(gpa, path, reference);
}
