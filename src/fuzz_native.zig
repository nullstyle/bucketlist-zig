//! Deterministic randomized correctness checks over private synthetic stores.
//! Usage: fuzz-native [iterations=100] [seed=1] [fresh-path]
//! The optional path must not exist. Only the created directory is removed.
const std = @import("std");
const lib = @import("bucketlist");
const storage = @import("bucketlist-store");
const native = @import("disk.zig");
const Allocator = std.mem.Allocator;
const Hash = storage.Hash;
const Sha256 = std.crypto.hash.sha2.Sha256;
const bucket_domain = "bucketlist.bucket.v1\x00";
const manifest_domain = "bucketlist.disk-frontier.v1\x00";
const catalog_domain = "bucketlist.disk-current.v1\x00";
const manifest_header = manifest_domain.len + 72;
const limits: storage.MergeLimits = .{ .max_key_bytes = 8, .max_value_bytes = 8, .max_records = 16, .max_bucket_bytes = 1024 };
const Schema = struct {
    pub const namespace = "fuzz.native.synthetic";
    pub const version: u32 = 1;
    pub const tables = .{ .records = lib.Table(1, u64, u64), .flags = lib.Table(2, u8, bool) };
};
const Disk = native.Database(Schema);
const Category = enum {
    bucket_valid,
    bucket_value,
    bucket_domain,
    bucket_count,
    bucket_key_length,
    bucket_value_length,
    bucket_tag,
    bucket_order,
    bucket_truncation,
    bucket_trailing,
    bucket_random_edit,
    disk_history,
    disk_metadata,
    disk_domain,
    disk_schema,
    disk_profile,
    disk_shape,
    disk_tag,
    disk_truncation,
    disk_trailing,
    disk_metadata_length,
    disk_missing_bucket,
    disk_typed_value,
    disk_unknown_table,
    disk_pending,
};
const category_count = @typeInfo(Category).@"enum".field_names.len;
const Count = struct { accepted: usize = 0, rejected: usize = 0 };
const Counts = struct {
    categories: [category_count]Count = @splat(.{}),
    accepted: usize = 0,
    rejected: usize = 0,
    fn add(self: *Counts, category: Category, accepted: bool) void {
        if (accepted) {
            self.accepted += 1;
            self.categories[@backingInt(category)].accepted += 1;
        } else {
            self.rejected += 1;
            self.categories[@backingInt(category)].rejected += 1;
        }
    }
};

// Fixed-size independent reference model. No production parser/merge is used.
const Row = struct {
    table: u32 = 1,
    key: [8]u8 = @splat(0),
    key_len: u8 = 8,
    value: [8]u8 = @splat(0),
    value_len: u8 = 8,
    live: bool = true,
    fn compare(a: Row, b: Row) std.math.Order {
        if (a.table != b.table) return std.math.order(a.table, b.table);
        return std.mem.order(u8, a.key[0..a.key_len], b.key[0..b.key_len]);
    }
};
const Model = struct {
    rows: [16]Row = undefined,
    len: usize = 0,
    fn encode(self: *const Model, buffer: *[1024]u8) []u8 {
        @memcpy(buffer[0..bucket_domain.len], bucket_domain);
        var position: usize = bucket_domain.len;
        putInt(u64, buffer, &position, @intCast(self.len));
        for (self.rows[0..self.len]) |row| {
            putInt(u32, buffer, &position, row.table);
            putInt(u32, buffer, &position, row.key_len);
            @memcpy(buffer[position..][0..row.key_len], row.key[0..row.key_len]);
            position += row.key_len;
            buffer[position] = @intFromBool(row.live);
            position += 1;
            if (row.live) {
                putInt(u32, buffer, &position, row.value_len);
                @memcpy(buffer[position..][0..row.value_len], row.value[0..row.value_len]);
                position += row.value_len;
            }
        }
        return buffer[0..position];
    }
    fn parse(bytes: []const u8) !Model {
        var reader: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try reader.take(bucket_domain.len), bucket_domain)) return error.BadSample;
        const count = try reader.int(u64);
        if (count > 16) return error.BadSample;
        var model: Model = .{};
        for (0..@intCast(count)) |i| {
            var row: Row = .{};
            row.table = try reader.int(u32);
            const key_len = try reader.int(u32);
            if (key_len > 8) return error.BadSample;
            row.key_len = @intCast(key_len);
            @memcpy(row.key[0..row.key_len], try reader.take(key_len));
            row.live = switch (try reader.int(u8)) {
                0 => false,
                1 => true,
                else => return error.BadSample,
            };
            if (row.live) {
                const value_len = try reader.int(u32);
                if (value_len > 8) return error.BadSample;
                row.value_len = @intCast(value_len);
                @memcpy(row.value[0..row.value_len], try reader.take(value_len));
            }
            if (i != 0 and Row.compare(model.rows[i - 1], row) != .lt) return error.BadSample;
            model.rows[i] = row;
            model.len += 1;
        }
        if (reader.position != bytes.len) return error.BadSample;
        return model;
    }
    fn merged(older: Model, newer: Model, drop: bool) Model {
        var output: Model = .{};
        var a: usize = 0;
        var b: usize = 0;
        while (a < older.len or b < newer.len) {
            const row = blk: {
                if (b == newer.len or (a < older.len and Row.compare(older.rows[a], newer.rows[b]) == .lt)) {
                    defer a += 1;
                    break :blk older.rows[a];
                }
                if (a < older.len and Row.compare(older.rows[a], newer.rows[b]) == .eq) a += 1;
                defer b += 1;
                break :blk newer.rows[b];
            };
            if (drop and !row.live) continue;
            output.rows[output.len] = row;
            output.len += 1;
        }
        return output;
    }
};

fn putInt(comptime T: type, buffer: []u8, position: *usize, value: T) void {
    std.mem.writeInt(T, buffer[position.*..][0..@sizeOf(T)], value, .big);
    position.* += @sizeOf(T);
}
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.position) return error.BadSample;
        const result = self.bytes[self.position..][0..len];
        self.position += len;
        return result;
    }
    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }
};
fn hash(bytes: []const u8) Hash {
    var result: Hash = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}
fn require(ok: bool) !void {
    if (!ok) return error.ConsistencyFailure;
}
fn expectedParseError(err: anyerror) bool {
    return switch (err) {
        error.InvalidBucket,
        error.TooLarge,
        error.InvalidManifest,
        error.SchemaMismatch,
        error.ProfileMismatch,
        error.InvalidTopology,
        error.InvalidRecord,
        error.NotFound,
        error.MetadataTooLarge,
        error.CommitmentMismatch,
        => true,
        else => false,
    };
}

fn randomModel(random: std.Random) Model {
    var model: Model = .{ .len = random.intRangeAtMost(usize, 2, 6) };
    for (model.rows[0..model.len], 0..) |*row, i| {
        row.* = .{ .live = i == 0 or random.boolean() };
        std.mem.writeInt(u64, &row.key, @intCast(i * 2), .big);
        std.mem.writeInt(u64, &row.value, random.int(u64), .big);
    }
    return model;
}

fn checkNativeScan(store: *storage.Store, blob: Hash, model: ?Model, encoded: []const u8) !bool {
    var cursor = store.scanBucket(blob, limits) catch |err| {
        if (!expectedParseError(err)) return err;
        try require(model == null);
        return false;
    };
    defer cursor.deinit();
    var actual: Model = .{};
    while (true) {
        const maybe_row = cursor.next() catch |err| {
            if (!expectedParseError(err)) return err;
            try require(model == null);
            return false;
        };
        const row = maybe_row orelse break;
        try require(actual.len < actual.rows.len and row.key.len <= 8);
        var owned: Row = .{ .table = row.table, .key_len = @intCast(row.key.len), .live = row.value != null };
        @memcpy(owned.key[0..row.key.len], row.key);
        if (row.value) |value| {
            try require(value.len <= 8);
            owned.value_len = @intCast(value.len);
            @memcpy(owned.value[0..value.len], value);
        }
        actual.rows[actual.len] = owned;
        actual.len += 1;
    }
    try require(model != null and actual.len == cursor.recordCount() and cursor.byteLength() == encoded.len);
    var buffer: [1024]u8 = undefined;
    try require(std.mem.eql(u8, encoded, actual.encode(&buffer)));
    return true;
}

fn bucketCase(gpa: Allocator, store: *storage.Store, category: Category, random: std.Random) !bool {
    const original = randomModel(random);
    var buffer: [1024]u8 = undefined;
    var bytes = original.encode(&buffer);
    const start = bucket_domain.len + 8;
    switch (category) {
        .bucket_valid => {},
        .bucket_value => bytes[start + 21] ^= random.intRangeAtMost(u8, 1, 255),
        .bucket_domain => bytes[random.uintLessThan(usize, bucket_domain.len)] ^= 1,
        .bucket_count => std.mem.writeInt(u64, bytes[bucket_domain.len..][0..8], random.int(u64), .big),
        .bucket_key_length => std.mem.writeInt(u32, bytes[start + 4 ..][0..4], random.intRangeAtMost(u32, 9, std.math.maxInt(u32)), .big),
        .bucket_value_length => std.mem.writeInt(u32, bytes[start + 17 ..][0..4], random.intRangeAtMost(u32, 9, std.math.maxInt(u32)), .big),
        .bucket_tag => bytes[start + 16] = random.intRangeAtMost(u8, 2, 255),
        .bucket_order => @memcpy(bytes[start + 29 + 8 ..][0..8], bytes[start + 8 ..][0..8]),
        .bucket_truncation => bytes = bytes[0..random.uintLessThan(usize, bytes.len)],
        .bucket_trailing => {
            buffer[bytes.len] = random.int(u8);
            bytes = buffer[0 .. bytes.len + 1];
        },
        .bucket_random_edit => bytes[random.uintLessThan(usize, bytes.len)] ^= random.intRangeAtMost(u8, 1, 255),
        else => unreachable,
    }
    const parsed = Model.parse(bytes) catch null;
    const blob = try store.putBlob(bytes); // Every sample has its correct SHA-256 name.
    const accepted = try checkNativeScan(store, blob, parsed, bytes);
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, random.uintLessThan(u64, 13), .big);
    if (store.lookupBucket(gpa, blob, 1, &key, limits)) |result_value| {
        var result = result_value;
        defer result.deinit(gpa);
        try require(accepted);
        var found: ?Row = null;
        for (parsed.?.rows[0..parsed.?.len]) |row| if (row.table == 1 and std.mem.eql(u8, row.key[0..row.key_len], &key)) {
            found = row;
            break;
        };
        if (found) |row| {
            if (row.live) {
                try require(result == .value);
                try require(std.mem.eql(u8, result.value, row.value[0..row.value_len]));
            } else try require(result == .tombstone);
        } else try require(result == .absent);
    } else |err| {
        if (!expectedParseError(err)) return err;
        try require(!accepted);
    }
    const older = randomModel(random);
    var old_buffer: [1024]u8 = undefined;
    const older_hash = try store.putBlob(older.encode(&old_buffer));
    const drop = random.boolean();
    if (store.mergeBuckets(older_hash, blob, drop, limits)) |merged_hash| {
        try require(accepted);
        const expected = Model.merged(older, parsed.?, drop);
        var expected_buffer: [1024]u8 = undefined;
        const expected_bytes = expected.encode(&expected_buffer);
        try require(std.mem.eql(u8, &merged_hash, &hash(expected_bytes)));
        _ = try checkNativeScan(store, merged_hash, expected, expected_bytes);
    } else |err| {
        if (!expectedParseError(err)) return err;
        try require(!accepted);
    }
    return accepted;
}

const History = struct { reference: native.Reference, manifest: []u8, sequence: u64 };
fn publish(store: *storage.Store, reference: native.Reference) !void {
    var bytes: [catalog_domain.len + 64]u8 = undefined;
    @memcpy(bytes[0..catalog_domain.len], catalog_domain);
    @memcpy(bytes[catalog_domain.len..][0..32], &reference.manifest_hash);
    @memcpy(bytes[catalog_domain.len + 32 ..], &reference.database_digest);
    try store.publish(&bytes);
}
fn verifyCatalog(gpa: Allocator, store: *storage.Store, reference: native.Reference) !void {
    const bytes = (try store.readManifest(gpa, 1024)) orelse return error.ConsistencyFailure;
    defer gpa.free(bytes);
    try require(bytes.len == catalog_domain.len + 64);
    try require(std.mem.eql(u8, bytes[catalog_domain.len..][0..32], &reference.manifest_hash));
    try require(std.mem.eql(u8, bytes[catalog_domain.len + 32 ..], &reference.database_digest));
}
fn manifestDigest(bytes: []const u8) !Hash {
    var reader: Reader = .{ .bytes = bytes };
    _ = try reader.take(manifest_domain.len);
    const schema_hash = try reader.take(32);
    const profile_hash = try reader.take(32);
    const sequence = try reader.take(8);
    var root = Sha256.init(.{});
    root.update("bucketlist.list.v1\x00");
    root.update(profile_hash);
    var continuation = Sha256.init(.{});
    continuation.update("bucketlist.continuation.v1\x00");
    continuation.update(profile_hash);
    for (0..11) |i| {
        var index: [4]u8 = undefined;
        std.mem.writeInt(u32, &index, @intCast(i), .big);
        var level = Sha256.init(.{});
        level.update("bucketlist.level.v1\x00");
        level.update(&index);
        level.update(try reader.take(64));
        root.update(&level.finalResult());
        const tag = try reader.int(u8);
        if (tag > 1) return error.BadSample;
        continuation.update(&index);
        continuation.update(&.{tag});
        if (tag == 1) continuation.update(try reader.take(32));
    }
    _ = try reader.take(try reader.int(u32));
    if (reader.position != bytes.len) return error.BadSample;
    var database = Sha256.init(.{});
    database.update("bucketlist.database.v1\x00");
    database.update(schema_hash);
    database.update(profile_hash);
    database.update(sequence);
    database.update(&root.finalResult());
    database.update(&continuation.finalResult());
    return database.finalResult();
}
fn verifyHistory(db: *Disk, sequence: u64) !void {
    try require(db.commitment().advance == sequence);
    for (1..5) |key| {
        const value = try db.get(.records, key);
        try require(value == if (key <= sequence) @as(?u64, key * 17) else null);
    }
    try require((try db.get(.flags, 1)).? == (sequence % 2 != 0));
}
fn setupHistory(gpa: Allocator, io: std.Io, path: []const u8, history: *[4]History) !void {
    {
        const db = try Disk.open(gpa, io, path, .{ .merge_workers = 1, .max_metadata_bytes = 64 });
        defer db.deinit();
        for (history, 1..) |*item, sequence| {
            var batch = Disk.Batch.init(gpa);
            defer batch.deinit();
            try batch.put(.records, @intCast(sequence), sequence * 17);
            try batch.put(.flags, 1, sequence % 2 != 0);
            var prepared = try db.prepare(sequence, &batch, &.{@intCast(sequence)});
            defer prepared.deinit();
            try prepared.commit();
            item.* = .{ .reference = db.reference(), .sequence = sequence, .manifest = &.{} };
        }
    }
    var store = try storage.Store.open(gpa, io, path);
    defer store.deinit();
    for (history) |*item| {
        item.manifest = try store.getBlob(gpa, item.reference.manifest_hash, 2048);
        try require(std.mem.eql(u8, &item.reference.database_digest, &try manifestDigest(item.manifest)));
    }
}

fn diskCase(gpa: Allocator, io: std.Io, path: []const u8, history: *const [4]History, category: Category, random: std.Random) !bool {
    const base = history[3];
    const original = history[if (category == .disk_pending) 1 else if (category == .disk_typed_value or category == .disk_unknown_table) 0 else random.uintLessThan(usize, history.len)];
    var buffer: [2048]u8 = undefined;
    @memcpy(buffer[0..original.manifest.len], original.manifest);
    var bytes = buffer[0..original.manifest.len];
    const should_accept = category == .disk_history or category == .disk_metadata;
    var candidate: native.Reference = undefined;
    const sentinel_bytes = "native randomized correctness sentinel";
    var sentinel: Hash = undefined;
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        switch (category) {
            .disk_history => {},
            .disk_metadata => bytes[bytes.len - 1] ^= random.intRangeAtMost(u8, 1, 255),
            .disk_domain => bytes[0] ^= 1,
            .disk_schema => bytes[manifest_domain.len + random.uintLessThan(usize, 32)] ^= 1,
            .disk_profile => bytes[manifest_domain.len + 32 + random.uintLessThan(usize, 32)] ^= 1,
            .disk_shape => @memset(bytes[manifest_domain.len + 64 ..][0..8], 0),
            .disk_tag => bytes[manifest_header + 64] = random.intRangeAtMost(u8, 2, 255),
            .disk_truncation => bytes = bytes[0..random.uintLessThan(usize, bytes.len)],
            .disk_trailing => {
                buffer[bytes.len] = random.int(u8);
                bytes = buffer[0 .. bytes.len + 1];
            },
            .disk_metadata_length => @memset(bytes[bytes.len - 5 ..][0..4], 0xff),
            .disk_missing_bucket => {
                var missing: Hash = undefined;
                random.bytes(&missing);
                @memcpy(bytes[manifest_header..][0..32], &missing);
            },
            .disk_typed_value, .disk_unknown_table => {
                var invalid: Model = .{ .len = 1 };
                invalid.rows[0] = .{ .table = if (category == .disk_unknown_table) 99 else 2, .key_len = 1, .value_len = 1 };
                invalid.rows[0].key[0] = 1;
                invalid.rows[0].value[0] = if (category == .disk_typed_value) random.intRangeAtMost(u8, 2, 255) else 1;
                var bad_buffer: [1024]u8 = undefined;
                const bad_hash = try store.putBlob(invalid.encode(&bad_buffer));
                @memcpy(bytes[manifest_header..][0..32], &bad_hash);
            },
            .disk_pending => {
                const offset = manifest_header + 130;
                try require(bytes[offset - 1] == 1);
                @memcpy(bytes[offset..][0..32], &hash(bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x00"));
            },
            else => unreachable,
        }
        candidate = .{ .manifest_hash = try store.putBlob(bytes), .database_digest = manifestDigest(bytes) catch original.reference.database_digest };
        sentinel = try store.putBlob(sentinel_bytes);
        try verifyCatalog(gpa, &store, base.reference);
    }
    if (!should_accept) {
        const db = try Disk.open(gpa, io, path, .{ .merge_workers = 1, .max_metadata_bytes = 64, .expected = base.reference });
        defer db.deinit();
        if (db.collect(&.{candidate})) |_| return error.UnexpectedCollection else |err| if (!expectedParseError(err)) return err;
        try require(std.meta.eql(base.reference, db.reference()));
        try verifyHistory(db, base.sequence);
        try require(std.mem.eql(u8, db.metadata(), &.{@intCast(base.sequence)}));
    }
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        const retained = try store.getBlob(gpa, sentinel, 128);
        defer gpa.free(retained);
        try require(std.mem.eql(u8, retained, sentinel_bytes));
        try verifyCatalog(gpa, &store, base.reference);
        try publish(&store, candidate);
    }
    if (Disk.open(gpa, io, path, .{ .merge_workers = 1, .max_metadata_bytes = 64, .expected = candidate })) |db| {
        defer db.deinit();
        try require(should_accept and std.meta.eql(candidate, db.reference()));
        try verifyHistory(db, original.sequence);
        try require(std.mem.eql(u8, db.metadata(), bytes[bytes.len - 1 ..]));
    } else |err| {
        if (!expectedParseError(err)) return err;
        try require(!should_accept);
    }
    {
        var store = try storage.Store.open(gpa, io, path);
        defer store.deinit();
        // Recovery may reject, but must never silently repair the chosen catalog.
        try verifyCatalog(gpa, &store, candidate);
        try publish(&store, base.reference);
    }
    const restored = try Disk.open(gpa, io, path, .{ .merge_workers = 1, .max_metadata_bytes = 64, .expected = base.reference });
    defer restored.deinit();
    try verifyHistory(restored, base.sequence);
    return should_accept;
}

fn run(gpa: Allocator, io: std.Io, root: []const u8, iterations: usize, seed: u64, writer: *std.Io.Writer) !Counts {
    const bucket_path = try std.fs.path.join(gpa, &.{ root, "buckets" });
    defer gpa.free(bucket_path);
    const disk_path = try std.fs.path.join(gpa, &.{ root, "disk" });
    defer gpa.free(disk_path);
    var store = try storage.Store.open(gpa, io, bucket_path);
    defer store.deinit();
    var history: [4]History = @splat(.{ .reference = undefined, .sequence = 0, .manifest = &.{} });
    defer for (history) |item| gpa.free(item.manifest);
    try setupHistory(gpa, io, disk_path, &history);
    var prng = std.Random.DefaultPrng.init(seed);
    var counts: Counts = .{};
    for (0..iterations) |index| {
        const category: Category = @fromBackingInt(@intCast(index % category_count));
        const accepted = (if (@backingInt(category) <= @backingInt(Category.bucket_random_edit))
            bucketCase(gpa, &store, category, prng.random())
        else
            diskCase(gpa, io, disk_path, &history, category, prng.random())) catch |err| {
            try std.json.Stringify.value(.{ .suite = "native", .status = "failed", .seed = seed, .case_index = index, .category = @tagName(category), .failure = @errorName(err), .reproduce_iterations = index + 1 }, .{}, writer);
            try writer.writeByte('\n');
            try writer.flush();
            return err;
        };
        counts.add(category, accepted);
    }
    return counts;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const iterations = if (args.next()) |arg| try std.fmt.parseInt(usize, arg, 0) else 100;
    const seed = if (args.next()) |arg| try std.fmt.parseInt(u64, arg, 0) else 1;
    const requested_path = args.next();
    if (iterations == 0 or iterations > 100000 or args.next() != null) return error.InvalidArguments;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var nonce: [8]u8 = undefined;
    init.io.random(&nonce);
    const root = requested_path orelse blk: {
        try std.Io.Dir.cwd().createDirPath(init.io, ".zig-cache");
        break :blk try std.fmt.bufPrint(&path_buffer, ".zig-cache/fuzz-native-{d}-{s}", .{ seed, std.fmt.bytesToHex(nonce, .lower) });
    };
    // Exclusive creation is the boundary authorizing this harness's cleanup.
    // An existing path is rejected; no caller-owned contents are traversed.
    try std.Io.Dir.cwd().createDir(init.io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, root) catch @panic("native fuzz cleanup failed");
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    var allocator_open = true;
    defer if (allocator_open) {
        if (debug_allocator.deinit() == .leak) @panic("native fuzz allocation leak");
    };
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    const counts = try run(debug_allocator.allocator(), init.io, root, iterations, seed, writer);
    const allocator_status = debug_allocator.deinit();
    allocator_open = false;
    if (allocator_status == .leak) return error.AllocationLeak;
    const CategoryCount = struct { category: []const u8, accepted: usize, rejected: usize };
    var categories: [category_count]CategoryCount = undefined;
    for (&categories, 0..) |*item, i| item.* = .{ .category = @tagName(@as(Category, @fromBackingInt(@intCast(i)))), .accepted = counts.categories[i].accepted, .rejected = counts.categories[i].rejected };
    try std.json.Stringify.value(.{ .suite = "native", .status = "passed", .seed = seed, .iterations = iterations, .accepted = counts.accepted, .rejected = counts.rejected, .allocation_leaks = false, .categories = categories }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}
