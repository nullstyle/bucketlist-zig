//! Deterministic, bounded parser/property exerciser. This is a test executable,
//! not a safe way to derive a trusted checkpoint identity from untrusted bytes.
//! Run with --iterations N --seed N; the first N cases are a stable prefix.
const std = @import("std");
const codec = @import("codec.zig");
const bucket = @import("bucket.zig");
const database = @import("database.zig");
const schema = @import("schema.zig");
const proofs = @import("proofs.zig");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const Sha256 = std.crypto.hash.sha2.Sha256;
const max_input = 64 * 1024;
const magic = "bucketlist.checkpoint.v1\x00";
const header_len = magic.len + 72;

const Kind = enum(u16) { first = 1, second = 19, last = 65535 };
const Value = struct { balance: i64, active: bool, kind: Kind, note: codec.Bytes(8) };
const Schema = struct {
    pub const namespace = "bucketlist.portable.fuzz.v1";
    pub const version: u32 = 1;
    pub const tables = .{
        .rows = schema.Table(1, i16, Value),
        .blobs = schema.Table(7, codec.Bytes(8), [2]u32),
    };
};
pub const Options = struct { iterations: usize = 1000, seed: u64 = 0x6275636b65746c73, replay: ?Replay = null };

/// Exact-input replay through the same Guided oracle the campaigns use.
/// `raw` frames are parser inputs (selector byte included). `smith` frames are
/// Smith.slice inputs (u32 little-endian length plus bytes). `mapped` frames
/// are Zig fuzzer cache files `f/in*`: a 20-byte little-endian `<QIII>` header
/// (coverage digest, instance, test index, input length) followed by one Smith
/// frame of exactly that length. The mapped file is a fixed-size buffer, so
/// trailing padding after the input is allowed and ignored.
pub const ReplayFraming = enum { raw, smith, mapped };
pub const ReplayTarget = enum { codec, bucket, checkpoint, proof, probe };
pub const MappedHeader = struct { coverage: u64, instance: u32, test_index: u32, length: u32 };
pub const Replay = struct {
    target: ReplayTarget = .codec,
    framing: ReplayFraming = .raw,
    path: []const u8 = "",
    expect: ?GuidedOutcome = null,
    /// Error name the replay must fail with; "any" accepts every failure.
    expect_error: ?[]const u8 = null,
};
pub const Counts = struct { accepted: usize = 0, rejected: usize = 0, oom: usize = 0 };
pub const Stats = struct {
    seed: u64,
    cases: usize = 0,
    codec: Counts = .{},
    bucket: Counts = .{},
    checkpoint: Counts = .{},
    accepted_mutated_checkpoints: usize = 0,
    independent_identities: usize = 0,
    continuation_checks: usize = 0,
    live_continuation_checks: usize = 0,
    allocation_failures: usize = 0,
    peak_case_bytes: usize = 0,
};

const Db1 = database.DatabaseWithDepth(Schema, 1);
const Db3 = database.DatabaseWithDepth(Schema, 3);
const Db11 = database.DatabaseWithDepth(Schema, 11);
const Saved = union(enum) { one: Db1, three: Db3, eleven: Db11 };
const Fixture = struct { depth: usize, bytes: []u8, digest: Hash, saved: Saved };
const Corpus = struct {
    fixtures: std.ArrayList(Fixture) = .empty,
    frames: std.ArrayList([]const u8) = .empty,
    fn deinit(self: *Corpus, gpa: Allocator) void {
        self.frames.deinit(gpa);
        for (self.fixtures.items) |*fixture| {
            gpa.free(fixture.bytes);
            switch (fixture.saved) {
                inline else => |*db| db.deinit(),
            }
        }
        self.fixtures.deinit(gpa);
    }
    fn init(gpa: Allocator, seed: u64) !Corpus {
        var result: Corpus = .{};
        errdefer result.deinit(gpa);
        inline for (.{ 1, 3, 11 }) |depth| try result.history(depth, gpa, seed);
        return result;
    }
    fn history(self: *Corpus, comptime depth: usize, gpa: Allocator, seed: u64) !void {
        const Db = database.DatabaseWithDepth(Schema, depth);
        var db = Db.init(gpa);
        defer db.deinit();
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        for (0..129) |seq| {
            if (seq != 0) try advance(Db, &db, gpa, random, seq);
            switch (seq) {
                0, 1, 2, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128 => {},
                else => continue,
            }
            const bytes = try db.checkpoint(gpa);
            errdefer gpa.free(bytes);
            if (bytes.len >= max_input) return error.CorpusTooLarge;
            const layout = try outerLayout(bytes, depth);
            const digest = try candidateIdentity(bytes, depth);
            if (!std.mem.eql(u8, &digest, &db.commitment().digest)) return error.IndependentIdentityMismatch;
            // Reserve before append so fixture ownership has a single transfer.
            try self.fixtures.ensureUnusedCapacity(gpa, 1);
            try self.frames.ensureUnusedCapacity(gpa, layout.count);
            const saved: Saved = switch (depth) {
                1 => .{ .one = .{ .engine = db.engine.clone() } },
                3 => .{ .three = .{ .engine = db.engine.clone() } },
                11 => .{ .eleven = .{ .engine = db.engine.clone() } },
                else => unreachable,
            };
            self.fixtures.appendAssumeCapacity(.{ .depth = depth, .bytes = bytes, .digest = digest, .saved = saved });
            for (layout.frames[0..layout.count]) |frame| {
                const raw = bytes[frame.start..][0..frame.len];
                if (raw.len > bucket.empty_bytes.len) self.frames.appendAssumeCapacity(raw);
            }
        }
    }
};

fn randomValue(random: std.Random) Value {
    var note: codec.Bytes(8) = .{};
    note.len = random.uintLessThan(u32, 9);
    random.bytes(note.data[0..note.len]);
    return .{ .balance = random.int(i64), .active = random.boolean(), .kind = random.enumValue(Kind), .note = note };
}

fn advance(comptime Db: type, db: *Db, gpa: Allocator, random: std.Random, seq: u64) !void {
    var changes = try db.batch(gpa);
    defer changes.deinit();
    // Every history has live values, deletes, empty advances and last-call wins.
    if (seq % 5 != 0) {
        const key: i16 = @as(i16, @intCast(random.uintLessThan(u16, 17))) - 8;
        try changes.put(.rows, key, randomValue(random));
        if (seq % 3 == 0) try changes.delete(.rows, key);
        if (seq % 7 == 0) try changes.put(.rows, key, randomValue(random));
        const name = try codec.Bytes(8).init(&.{random.uintLessThan(u8, 8)});
        if (seq % 4 == 0) {
            try changes.delete(.blobs, name);
        } else {
            try changes.put(.blobs, name, .{ random.int(u32), random.int(u32) });
        }
    }
    var prepared = try db.prepareAdvance(gpa, seq, &changes);
    defer prepared.deinit();
    try db.commit(&prepared);
}

/// Live requested bytes are bounded on every parser/property path. Disabling
/// resize/remap makes allocation-failure positions independent of the backing
/// allocator's ability to extend an allocation in place.
const Budget = struct {
    child: Allocator,
    limit: usize = 1024 * 1024,
    fail_at: ?usize = null,
    calls: usize = 0,
    failures: usize = 0,
    live: usize = 0,
    allocations: usize = 0,
    peak: usize = 0,
    fn allocator(self: *Budget) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        const call = self.calls;
        self.calls += 1;
        if (self.fail_at == call or n > self.limit - self.live) {
            self.failures += 1;
            return null;
        }
        const ptr = self.child.rawAlloc(n, alignment, ra) orelse return null;
        self.live += n;
        self.allocations += 1;
        self.peak = @max(self.peak, self.live);
        return ptr;
    }
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Budget = @ptrCast(@alignCast(ctx));
        self.child.rawFree(bytes, alignment, ra);
        self.live -= bytes.len;
        self.allocations -= 1;
    }
    fn check(self: *const Budget) !void {
        if (self.live != 0 or self.allocations != 0) return error.LeakedAllocation;
    }
};

const RecordPosition = struct {
    start: usize,
    end: usize,
    table: u32,
    key_length: usize,
    key: usize,
    key_len: usize,
    tag: usize,
    value_length: ?usize = null,
    value: ?usize = null,
    value_len: usize = 0,
};
const Records = struct { records: [128]RecordPosition = undefined, count: usize = 0 };
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (n > self.bytes.len - self.pos) return error.MalformedFixture;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
    fn int(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }
};

// Offset scanner is independent of Bucket.decode and used only on bounded data.
fn recordPositions(bytes: []const u8) !Records {
    var cursor: Cursor = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(bucket.domain.len), bucket.domain)) return error.MalformedFixture;
    const count = try cursor.int(u64);
    var result: Records = .{};
    if (count > result.records.len) return error.MalformedFixture;
    for (0..@intCast(count)) |i| {
        var record: RecordPosition = .{ .start = cursor.pos, .end = undefined, .table = try cursor.int(u32), .key_length = cursor.pos, .key = undefined, .key_len = undefined, .tag = undefined };
        record.key_len = try cursor.int(u32);
        record.key = cursor.pos;
        _ = try cursor.take(record.key_len);
        record.tag = cursor.pos;
        switch (try cursor.int(u8)) {
            0 => {},
            1 => {
                record.value_length = cursor.pos;
                record.value_len = try cursor.int(u32);
                record.value = cursor.pos;
                _ = try cursor.take(record.value_len);
            },
            else => return error.MalformedFixture,
        }
        record.end = cursor.pos;
        result.records[i] = record;
    }
    if (cursor.pos != bytes.len) return error.MalformedFixture;
    result.count = @intCast(count);
    return result;
}

const Frame = struct { length_at: usize, start: usize, len: usize, level: usize, slot: enum { curr, snap, next } };
const Layout = struct {
    frames: [33]Frame = undefined,
    count: usize = 0,
    flags: [11]usize = undefined,
};
fn outerLayout(bytes: []const u8, depth: usize) !Layout {
    var cursor: Cursor = .{ .bytes = bytes };
    _ = try cursor.take(header_len);
    var result: Layout = .{};
    for (0..depth) |level| {
        for (0..3) |slot| {
            if (slot == 2) {
                result.flags[level] = cursor.pos;
                switch (try cursor.int(u8)) {
                    0 => continue,
                    1 => {},
                    else => return error.MalformedFixture,
                }
            }
            const length_at = cursor.pos;
            const length = try cursor.int(u64);
            if (length > cursor.bytes.len - cursor.pos) return error.MalformedFixture;
            result.frames[result.count] = .{ .length_at = length_at, .start = cursor.pos, .len = @intCast(length), .level = level, .slot = @fromBackingInt(@intCast(slot)) };
            result.count += 1;
            _ = try cursor.take(@intCast(length));
        }
    }
    if (cursor.pos != bytes.len) return error.MalformedFixture;
    return result;
}

fn hashInt(h: *Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    h.update(&bytes);
}
fn rawHash(bytes: []const u8) Hash {
    var result: Hash = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}

/// Independent framing/hash specification. It intentionally accepts raw inner
/// bucket bytes: only production restore decides whether they are canonical,
/// schema-valid, and valid pending outputs for this sequence. Never use this
/// self-derived identity as a trust anchor in an application.
fn candidateIdentity(bytes: []const u8, depth: usize) !Hash {
    const layout = try outerLayout(bytes, depth);
    var profile = Sha256.init(.{});
    profile.update("bucketlist.profile.v1\x00");
    hashInt(&profile, u32, @intCast(depth));
    hashInt(&profile, u32, 4);
    const profile_hash = profile.finalResult();
    var root = Sha256.init(.{});
    root.update("bucketlist.list.v1\x00");
    root.update(&profile_hash);
    var continuation = Sha256.init(.{});
    continuation.update("bucketlist.continuation.v1\x00");
    continuation.update(&profile_hash);
    var index: usize = 0;
    for (0..depth) |level| {
        var level_hash = Sha256.init(.{});
        level_hash.update("bucketlist.level.v1\x00");
        hashInt(&level_hash, u32, @intCast(level));
        for (0..2) |_| {
            const frame = layout.frames[index];
            index += 1;
            level_hash.update(&rawHash(bytes[frame.start..][0..frame.len]));
        }
        root.update(&level_hash.finalResult());
        hashInt(&continuation, u32, @intCast(level));
        const present = bytes[layout.flags[level]];
        continuation.update(&.{present});
        if (present == 1) {
            const frame = layout.frames[index];
            index += 1;
            continuation.update(&rawHash(bytes[frame.start..][0..frame.len]));
        }
    }
    var identity = Sha256.init(.{});
    identity.update("bucketlist.database.v1\x00");
    identity.update(bytes[magic.len..][0..32]);
    identity.update(&profile_hash);
    identity.update(bytes[magic.len + 64 ..][0..8]);
    identity.update(&root.finalResult());
    identity.update(&continuation.finalResult());
    return identity.finalResult();
}

const Mutation = enum {
    unchanged,
    bit,
    truncate,
    trailing,
    domain,
    count_max,
    count_zero,
    key_length,
    tag,
    value_length,
    duplicate,
    order,
    value,
    unknown_table,
    typed_bool,
    typed_enum,
    typed_bytes,
};
const Effect = enum { unknown, invalid_bucket, invalid_typed };

fn mutateBucket(bytes: []u8, mode: Mutation, random: std.Random) Effect {
    if (bytes.len == 0) return .unknown;
    const records = recordPositions(bytes) catch {
        bytes[random.uintLessThan(usize, bytes.len)] ^= 1;
        return .unknown;
    };
    switch (mode) {
        .unchanged => return .unknown,
        .domain => {
            bytes[0] ^= 1;
            return .invalid_bucket;
        },
        .count_max => {
            @memset(bytes[bucket.domain.len..][0..8], 255);
            return .invalid_bucket;
        },
        .count_zero => {
            @memset(bytes[bucket.domain.len..][0..8], 0);
            return if (records.count > 0) .invalid_bucket else .unknown;
        },
        else => {},
    }
    if (records.count == 0) return .unknown;
    const r = records.records[random.uintLessThan(usize, records.count)];
    switch (mode) {
        .key_length => {
            @memset(bytes[r.key_length..][0..4], 255);
            return .invalid_bucket;
        },
        .tag => {
            bytes[r.tag] = 2 + random.uintLessThan(u8, 254);
            return .invalid_bucket;
        },
        .value_length => if (r.value_length) |at| {
            @memset(bytes[at..][0..4], 255);
            return .invalid_bucket;
        },
        .unknown_table => {
            @memset(bytes[r.start..][0..4], 255);
            return .invalid_typed;
        },
        .duplicate, .order => {
            for (records.records[1..records.count], 1..) |other, i| {
                const previous = records.records[i - 1];
                if (previous.table != other.table or previous.key_len != other.key_len) continue;
                if (mode == .duplicate) {
                    @memcpy(bytes[other.key..][0..other.key_len], bytes[previous.key..][0..previous.key_len]);
                } else {
                    for (bytes[other.key..][0..other.key_len], bytes[previous.key..][0..previous.key_len]) |*a, *b| std.mem.swap(u8, a, b);
                }
                return .invalid_bucket;
            }
        },
        .value, .typed_bool, .typed_enum, .typed_bytes => {
            for (records.records[0..records.count]) |row| {
                const at = row.value orelse continue;
                if (mode == .value and row.value_len > 0) {
                    bytes[at] ^= 1;
                    return .unknown;
                }
                if (row.table != 1 or row.value_len < 15) continue;
                switch (mode) {
                    .typed_bool => bytes[at + 8] = 2,
                    .typed_enum => @memset(bytes[at + 9 ..][0..2], 0),
                    .typed_bytes => @memset(bytes[at + 11 ..][0..4], 255),
                    else => unreachable,
                }
                return .invalid_typed;
            }
        },
        else => bytes[random.uintLessThan(usize, bytes.len)] ^= 1,
    }
    return .unknown;
}

fn checkBucket(gpa: Allocator, bytes: []const u8) !void {
    var decoded = try bucket.Bucket.decode(gpa, bytes);
    defer decoded.release();
    try checkDecodedBucket(gpa, bytes, decoded);
}

fn checkDecodedBucket(gpa: Allocator, bytes: []const u8, decoded: bucket.Bucket) !void {
    var rebuilt = bucket.Bucket.fromSorted(gpa, decoded.records()) catch |err| return if (err == error.OutOfMemory) err else error.BucketReencodeRejected;
    defer rebuilt.release();
    if (!std.mem.eql(u8, bytes, rebuilt.bytes()) or !std.mem.eql(u8, &decoded.hash(), &rawHash(bytes)) or !std.mem.eql(u8, &rebuilt.hash(), &decoded.hash())) return error.BucketRoundTripMismatch;
    // Mutation offset storage is capped at 128 records, but arbitrary canonical
    // buckets can contain more. This independent oracle streams all records.
    var cursor: Cursor = .{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(bucket.domain.len), bucket.domain)) return error.IndependentRecordMismatch;
    if (try cursor.int(u64) != decoded.records().len) return error.IndependentRecordMismatch;
    var previous_table: u32 = 0;
    var previous_key: []const u8 = &.{};
    for (decoded.records(), 0..) |record, i| {
        const table = try cursor.int(u32);
        const key = try cursor.take(try cursor.int(u32));
        const value: ?[]const u8 = switch (try cursor.int(u8)) {
            0 => null,
            1 => try cursor.take(try cursor.int(u32)),
            else => return error.IndependentRecordMismatch,
        };
        if (table != record.table or !std.mem.eql(u8, key, record.key)) return error.IndependentRecordMismatch;
        if ((value != null) != (record.value != null)) return error.IndependentRecordMismatch;
        if (value) |v| if (!std.mem.eql(u8, v, record.value.?)) return error.IndependentRecordMismatch;
        if (i > 0 and (previous_table > table or (previous_table == table and std.mem.order(u8, previous_key, key) != .lt))) {
            return error.IndependentRecordMismatch;
        }
        previous_table = table;
        previous_key = key;
    }
    if (cursor.pos != bytes.len) return error.IndependentRecordMismatch;
}

fn checkCheckpoint(comptime depth: usize, gpa: Allocator, fixture: *const Fixture, bytes: []const u8, expected: Hash, seed: u64) !void {
    const Db = database.DatabaseWithDepth(Schema, depth);
    var restored = try Db.restore(gpa, bytes, expected);
    defer restored.deinit();
    try checkRestoredCheckpoint(depth, gpa, fixture, &restored, bytes, seed);
}

fn checkRestoredCheckpoint(comptime depth: usize, gpa: Allocator, fixture: ?*const Fixture, restored: *database.DatabaseWithDepth(Schema, depth), bytes: []const u8, seed: u64) !void {
    const Db = database.DatabaseWithDepth(Schema, depth);
    const encoded = try restored.checkpoint(gpa);
    defer gpa.free(encoded);
    if (!std.mem.eql(u8, bytes, encoded)) return error.CheckpointRoundTripMismatch;
    // Unchanged checkpoints continue against a retained state built by real
    // advances before serialization. Mutated canonical states continue against
    // a second canonical restore. Neither baseline shares newly decoded storage.
    var again: Db = if (fixture != null and std.mem.eql(u8, bytes, fixture.?.bytes)) .{
        .engine = switch (depth) {
            1 => fixture.?.saved.one.engine.clone(),
            3 => fixture.?.saved.three.engine.clone(),
            11 => fixture.?.saved.eleven.engine.clone(),
            else => unreachable,
        },
    } else Db.restore(gpa, encoded, restored.commitment().digest) catch |err| return if (err == error.OutOfMemory) err else error.CheckpointReencodeRejected;
    defer again.deinit();
    var random_a = std.Random.DefaultPrng.init(seed);
    var random_b = std.Random.DefaultPrng.init(seed);
    const seq = restored.commitment().advance;
    if (seq == std.math.maxInt(u64)) {
        var changes = try restored.batch(gpa);
        defer changes.deinit();
        if (restored.prepareAdvance(gpa, 0, &changes)) |p| {
            var prepared = p;
            prepared.deinit();
            return error.ExhaustedSequenceAccepted;
        } else |err| if (err != error.SequenceExhausted) return err;
    } else {
        advance(Db, restored, gpa, random_a.random(), seq + 1) catch |err| return if (err == error.OutOfMemory) err else error.ContinuationAdvanceRejected;
        advance(Db, &again, gpa, random_b.random(), seq + 1) catch |err| return if (err == error.OutOfMemory) err else error.ContinuationAdvanceRejected;
        if (!std.meta.eql(restored.commitment(), again.commitment())) return error.ContinuationMismatch;
        const a = try restored.checkpoint(gpa);
        defer gpa.free(a);
        const b = try again.checkpoint(gpa);
        defer gpa.free(b);
        if (!std.mem.eql(u8, a, b)) return error.ContinuationMismatch;
    }
}

fn codecProperty(comptime T: type, bytes: []const u8) !bool {
    const value = codec.Codec(T).decode(bytes) catch return false;
    var output: [codec.Codec(T).max_size]u8 = undefined;
    const encoded = try codec.Codec(T).encode(value, &output);
    if (!std.mem.eql(u8, bytes, encoded)) return error.CodecRoundTripMismatch;
    return true;
}

fn codecCase(index: usize, random: std.Random) !bool {
    var bytes: [128]u8 = undefined;
    const type_index = index % 6;
    const mode = (index / 6) % 8;
    var len: usize = switch (type_index) {
        0 => (try codec.Codec(Value).encode(randomValue(random), &bytes)).len,
        1 => (try codec.Codec(i64).encode(random.int(i64), &bytes)).len,
        2 => (try codec.Codec(bool).encode(random.boolean(), &bytes)).len,
        3 => (try codec.Codec(Kind).encode(random.enumValue(Kind), &bytes)).len,
        4 => (try codec.Codec([3]i16).encode(.{ random.int(i16), random.int(i16), random.int(i16) }, &bytes)).len,
        5 => (try codec.Codec(codec.Bytes(0)).encode(.{}, &bytes)).len,
        else => unreachable,
    };
    switch (mode) {
        0 => {},
        1 => bytes[random.uintLessThan(usize, len)] ^= 1,
        2 => len = random.uintLessThan(usize, len),
        3 => {
            bytes[len] = random.int(u8);
            len += 1;
        },
        4 => {
            len = random.uintLessThan(usize, bytes.len);
            random.bytes(bytes[0..len]);
        },
        5 => @memset(bytes[0..len], 255),
        6 => @memset(bytes[0..len], 0),
        7 => {
            // Invalid in-memory Bytes storage must never be silently normalized.
            var invalid: codec.Bytes(8) = .{};
            if (random.boolean()) invalid.len = 9 else invalid.data[7] = 1;
            if (codec.Codec(codec.Bytes(8)).encode(invalid, &bytes)) |_| return error.NonCanonicalBytesAccepted else |err| if (err != error.NonCanonical) return err;
            return false;
        },
        else => unreachable,
    }
    const accepted = try switch (type_index) {
        0 => codecProperty(Value, bytes[0..len]),
        1 => codecProperty(i64, bytes[0..len]),
        2 => codecProperty(bool, bytes[0..len]),
        3 => codecProperty(Kind, bytes[0..len]),
        4 => codecProperty([3]i16, bytes[0..len]),
        5 => codecProperty(codec.Bytes(0), bytes[0..len]),
        else => unreachable,
    };
    if (mode == 0 and !accepted) return error.CanonicalInputRejected;
    return accepted;
}

fn expectedParserError(err: anyerror) bool {
    return switch (err) {
        error.InvalidBucket, error.InvalidRecordOrder, error.InvalidCheckpoint, error.InvalidTopology, error.CommitmentMismatch => true,
        else => false,
    };
}

fn caseResult(result: anyerror!void, counts: *Counts, must_reject: bool, must_accept: bool) !void {
    if (result) |_| {
        if (must_reject) return error.MalformedInputAccepted;
        counts.accepted += 1;
    } else |err| {
        if (must_accept and err != error.OutOfMemory) return error.CanonicalInputRejected;
        if (err == error.OutOfMemory) counts.oom += 1 else if (expectedParserError(err)) counts.rejected += 1 else return err;
    }
}

pub fn run(gpa: Allocator, options: Options) !Stats {
    var corpus = try Corpus.init(gpa, options.seed);
    defer corpus.deinit(gpa);
    var stats: Stats = .{ .seed = options.seed };
    var prng = std.Random.DefaultPrng.init(options.seed ^ 0x66757a7a2d763100);
    const random = prng.random();
    for (0..options.iterations) |index| {
        var budget: Budget = .{ .child = gpa };
        if (index % 17 == 0) budget.fail_at = (index / 17) % 128;
        if (index % 19 == 0) budget.limit = 256;
        const result = runCase(&corpus, &stats, budget.allocator(), index, random);
        budget.check() catch |err| {
            std.debug.print("portable fuzz failure: seed={d} case={d} target={d} error={s}\n", .{ options.seed, index, index % 3, @errorName(err) });
            return err;
        };
        result catch |err| {
            std.debug.print("portable fuzz failure: seed={d} case={d} target={d} mutation={d} error={s}\n", .{ options.seed, index, index % 3, (index / 3) % @typeInfo(Mutation).@"enum".field_names.len, @errorName(err) });
            return err;
        };
        stats.allocation_failures += budget.failures;
        stats.peak_case_bytes = @max(stats.peak_case_bytes, budget.peak);
        stats.cases += 1;
    }
    return stats;
}

fn runCase(corpus: *const Corpus, stats: *Stats, gpa: Allocator, index: usize, random: std.Random) !void {
    const ordinal = index / 3;
    if (index % 3 == 0) {
        if (try codecCase(ordinal, random)) stats.codec.accepted += 1 else stats.codec.rejected += 1;
        return;
    }
    const mode: Mutation = @fromBackingInt(@intCast(ordinal % @typeInfo(Mutation).@"enum".field_names.len));
    var scratch: [max_input + 1]u8 = undefined;
    if (index % 3 == 1) {
        const raw = if (ordinal % 23 == 0) bucket.empty_bytes else corpus.frames.items[random.uintLessThan(usize, corpus.frames.items.len)];
        @memcpy(scratch[0..raw.len], raw);
        var len = raw.len;
        var must_reject = false;
        switch (mode) {
            .truncate => {
                len = random.uintLessThan(usize, len);
                must_reject = true;
            },
            .trailing => {
                scratch[len] = random.int(u8);
                len += 1;
                must_reject = true;
            },
            else => must_reject = mutateBucket(scratch[0..len], mode, random) == .invalid_bucket,
        }
        return caseResult(checkBucket(gpa, scratch[0..len]), &stats.bucket, must_reject, std.mem.eql(u8, raw, scratch[0..len]));
    }
    const fixture = &corpus.fixtures.items[random.uintLessThan(usize, corpus.fixtures.items.len)];
    @memcpy(scratch[0..fixture.bytes.len], fixture.bytes);
    var len = fixture.bytes.len;
    const layout = try outerLayout(fixture.bytes, fixture.depth);
    var must_reject = false;
    // Every fourth cycle exercises outer lengths/flags/header/sequence directly.
    if ((ordinal / @typeInfo(Mutation).@"enum".field_names.len) % 4 == 3) {
        switch (ordinal % 7) {
            0 => {
                @memset(scratch[layout.frames[0].length_at..][0..8], 255);
                must_reject = true;
            },
            1 => {
                scratch[layout.flags[random.uintLessThan(usize, fixture.depth)]] = 2;
                must_reject = true;
            },
            2 => {
                scratch[random.uintLessThan(usize, magic.len)] ^= 1;
                must_reject = true;
            },
            3 => {
                scratch[magic.len + random.uintLessThan(usize, 64)] ^= 1;
                must_reject = true;
            },
            4 => std.mem.writeInt(u64, scratch[magic.len + 64 ..][0..8], random.int(u64), .big),
            5 => scratch[layout.flags[0]] ^= 1,
            6 => @memset(scratch[magic.len + 64 ..][0..8], 0),
            else => unreachable,
        }
    } else switch (mode) {
        .truncate => {
            len = random.uintLessThan(usize, len);
            must_reject = true;
        },
        .trailing => {
            scratch[len] = random.int(u8);
            len += 1;
            must_reject = true;
        },
        else => {
            var frame = layout.frames[random.uintLessThan(usize, layout.count)];
            // Prefer populated frames for structural/typed mutations; continue
            // sampling empty frames on unchanged/domain/count cases.
            if (mode != .unchanged and mode != .domain and frame.len == bucket.empty_bytes.len) {
                for (layout.frames[0..layout.count]) |candidate| if (candidate.len > bucket.empty_bytes.len) {
                    frame = candidate;
                    break;
                };
            }
            must_reject = mutateBucket(scratch[frame.start..][0..frame.len], mode, random) != .unknown;
        },
    }
    const expected = candidateIdentity(scratch[0..len], fixture.depth) catch fixture.digest;
    if (!std.mem.eql(u8, &expected, &fixture.digest)) stats.independent_identities += 1;
    const accepted_before = stats.checkpoint.accepted;
    const continuation_seed = random.int(u64);
    const unchanged = std.mem.eql(u8, fixture.bytes, scratch[0..len]);
    switch (fixture.depth) {
        1 => try caseResult(checkCheckpoint(1, gpa, fixture, scratch[0..len], expected, continuation_seed), &stats.checkpoint, must_reject, unchanged),
        3 => try caseResult(checkCheckpoint(3, gpa, fixture, scratch[0..len], expected, continuation_seed), &stats.checkpoint, must_reject, unchanged),
        11 => try caseResult(checkCheckpoint(11, gpa, fixture, scratch[0..len], expected, continuation_seed), &stats.checkpoint, must_reject, unchanged),
        else => unreachable,
    }
    if (stats.checkpoint.accepted > accepted_before) {
        stats.continuation_checks += 1;
        if (unchanged) stats.live_continuation_checks += 1 else stats.accepted_mutated_checkpoints += 1;
    }
}

pub const GuidedTarget = enum { codec, bucket, checkpoint, proof };
pub const GuidedOutcome = enum { accepted, rejected, oom };
pub const GuidedResult = struct { outcome: GuidedOutcome, peak_case_bytes: usize };
pub const max_guided_input_bytes = max_input;

/// The self-hosted AArch64 backend silently skips std.testing.fuzz. This
/// counter lets the guided tests fail instead of passing vacuously there.
var guided_executions: usize = 0;

/// Test-harness interface for corpus export and exact raw or Smith-input replay.
/// Corpus construction is outside both the fuzz callback and its 1 MiB budget.
/// Raw codec inputs start with a type selector modulo 6; raw checkpoints start
/// with a profile selector modulo 3 (depths 1, 3, 11). Buckets have no selector.
pub const Guided = struct {
    gpa: Allocator,
    corpus: Corpus,
    seeds: [4]Seeds = .{ .{}, .{}, .{}, .{} },

    const Seeds = struct {
        raw: std.ArrayList([]const u8) = .empty,
        smith: std.ArrayList([]const u8) = .empty,

        fn deinit(self: *Seeds, gpa: Allocator) void {
            for (self.smith.items) |bytes| gpa.free(bytes);
            self.raw.deinit(gpa);
            self.smith.deinit(gpa);
        }
    };

    pub fn init(gpa: Allocator) !Guided {
        var self: Guided = .{ .gpa = gpa, .corpus = try Corpus.init(gpa, 1) };
        errdefer self.deinit();
        try self.addCodecSeed(0, Value, .{ .balance = std.math.minInt(i64), .active = false, .kind = .first, .note = .{} });
        try self.addCodecSeed(0, Value, .{ .balance = std.math.maxInt(i64), .active = true, .kind = .last, .note = try codec.Bytes(8).init("abcdefgh") });
        try self.addCodecSeed(1, i64, std.math.minInt(i64));
        try self.addCodecSeed(1, i64, std.math.maxInt(i64));
        try self.addCodecSeed(2, bool, false);
        try self.addCodecSeed(2, bool, true);
        inline for (.{ Kind.first, Kind.second, Kind.last }) |kind| try self.addCodecSeed(3, Kind, kind);
        try self.addCodecSeed(4, [3]i16, .{ std.math.minInt(i16), 0, std.math.maxInt(i16) });
        try self.addCodecSeed(5, codec.Bytes(0), .{});
        try self.addSeed(.bucket, null, bucket.empty_bytes);
        for (self.corpus.frames.items) |frame| try self.addSeed(.bucket, null, frame);
        for (self.corpus.fixtures.items) |fixture| try self.addSeed(.checkpoint, switch (fixture.depth) {
            1 => 0,
            3 => 1,
            11 => 2,
            else => unreachable,
        }, fixture.bytes);
        try self.addLargeSeeds();
        return self;
    }

    pub fn deinit(self: *Guided) void {
        for (&self.seeds) |*seeds| seeds.deinit(self.gpa);
        self.corpus.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn seedInputs(self: *const Guided, target: GuidedTarget) []const []const u8 {
        return self.seeds[@backingInt(target)].raw.items;
    }

    /// Smith.slice reads a u32 little-endian length followed by that many bytes.
    /// Keep this framing separate from the parser input used by replay().
    pub fn smithCorpus(self: *const Guided, target: GuidedTarget) []const []const u8 {
        return self.seeds[@backingInt(target)].smith.items;
    }

    fn addSeed(self: *Guided, target: GuidedTarget, selector: ?u8, bytes: []const u8) !void {
        const raw_len = bytes.len + @intFromBool(selector != null);
        if (raw_len > max_input) return error.CorpusTooLarge;
        const framed = try self.gpa.alloc(u8, 4 + raw_len);
        errdefer self.gpa.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(raw_len), .little);
        if (selector) |byte| framed[4] = byte;
        @memcpy(framed[4 + @as(usize, @intFromBool(selector != null)) ..], bytes);
        const seeds = &self.seeds[@backingInt(target)];
        try seeds.raw.ensureUnusedCapacity(self.gpa, 1);
        try seeds.smith.ensureUnusedCapacity(self.gpa, 1);
        seeds.raw.appendAssumeCapacity(framed[4..]);
        seeds.smith.appendAssumeCapacity(framed);
    }

    fn addCodecSeed(self: *Guided, selector: u8, comptime T: type, value: T) !void {
        var encoded: [codec.Codec(T).max_size]u8 = undefined;
        try self.addSeed(.codec, selector, try codec.Codec(T).encode(value, &encoded));
    }

    fn addLargeSeeds(self: *Guided) !void {
        // These seeds deliberately exceed the mutation offset scanner's cap.
        var keys: [129][2]u8 = undefined;
        var records: [129]bucket.Record = undefined;
        for (&keys, &records, 0..) |*key, *record, i| {
            std.mem.writeInt(u16, key, @intCast(i), .big);
            record.* = .{ .table = 1, .key = key, .value = null };
        }
        var many = try bucket.Bucket.fromSorted(self.gpa, &records);
        defer many.release();
        try self.addSeed(.bucket, null, many.bytes());
        var db = Db1.init(self.gpa);
        defer db.deinit();
        var changes = try db.batch(self.gpa);
        defer changes.deinit();
        for (0..129) |i| try changes.put(.rows, @intCast(i), .{ .balance = @intCast(i), .active = true, .kind = .second, .note = .{} });
        var prepared = try db.prepareAdvance(self.gpa, 1, &changes);
        defer prepared.deinit();
        try db.commit(&prepared);
        const checkpoint = try db.checkpoint(self.gpa);
        defer self.gpa.free(checkpoint);
        try self.addSeed(.checkpoint, 0, checkpoint);
        try self.addSeed(.proof, null, &.{ 0, 3, 40, 2, 5, 9, 1, 7, 4, 8, 6 });
    }

    pub fn replay(self: *const Guided, target: GuidedTarget, input: []const u8) !GuidedResult {
        if (input.len > max_input) return error.InputTooLarge;
        var budget: Budget = .{ .child = self.gpa };
        const result = self.checkInput(target, budget.allocator(), input);
        try budget.check();
        const outcome = result catch |err| switch (err) {
            error.OutOfMemory => GuidedOutcome.oom,
            else => return err,
        };
        return .{ .outcome = outcome, .peak_case_bytes = budget.peak };
    }

    /// Replay the bytes stored by Zig's fuzzer, including Smith.slice framing.
    pub fn replaySmith(self: *const Guided, target: GuidedTarget, saved_input: []const u8) !GuidedResult {
        var smith: std.testing.Smith = .{ .in = saved_input };
        return self.fromSmith(target, &smith);
    }

    fn fromSmith(self: *const Guided, target: GuidedTarget, smith: *std.testing.Smith) !GuidedResult {
        var bytes: [max_input]u8 = undefined;
        const len = smith.slice(&bytes);
        guided_executions += 1;
        return self.replay(target, bytes[0..len]);
    }

    fn checkInput(self: *const Guided, target: GuidedTarget, gpa: Allocator, input: []const u8) !GuidedOutcome {
        switch (target) {
            .proof => {
                if (input.len < 10) return .rejected;
                return try self.checkProofOracle(gpa, input);
            },
            .codec => {
                if (input.len == 0) return .rejected;
                const bytes = input[1..];
                const accepted = try switch (input[0] % 6) {
                    0 => codecProperty(Value, bytes),
                    1 => codecProperty(i64, bytes),
                    2 => codecProperty(bool, bytes),
                    3 => codecProperty(Kind, bytes),
                    4 => codecProperty([3]i16, bytes),
                    5 => codecProperty(codec.Bytes(0), bytes),
                    else => unreachable,
                };
                return if (accepted) .accepted else .rejected;
            },
            .bucket => {
                var decoded = bucket.Bucket.decode(gpa, input) catch |err| return if (expectedParserError(err)) .rejected else err;
                defer decoded.release();
                // Only initial parser errors are rejection. No property failure
                // after acceptance is swallowed, even if it shares an error name.
                try checkDecodedBucket(gpa, input, decoded);
                return .accepted;
            },
            .checkpoint => {
                if (input.len == 0) return .rejected;
                return switch (input[0] % 3) {
                    0 => self.checkGuidedCheckpoint(1, gpa, input[1..]),
                    1 => self.checkGuidedCheckpoint(3, gpa, input[1..]),
                    2 => self.checkGuidedCheckpoint(11, gpa, input[1..]),
                    else => unreachable,
                };
            },
        }
    }

    fn checkGuidedCheckpoint(self: *const Guided, comptime depth: usize, gpa: Allocator, bytes: []const u8) !GuidedOutcome {
        const Db = database.DatabaseWithDepth(Schema, depth);
        // This independently recomputed identity is TEST ONLY. It intentionally
        // bypasses a stale fixture digest so typed/topology validation is reached.
        const expected: Hash = candidateIdentity(bytes, depth) catch @splat(0);
        var restored = Db.restore(gpa, bytes, expected) catch |err| return if (expectedParserError(err)) .rejected else err;
        defer restored.deinit();
        if (!std.mem.eql(u8, &expected, &restored.commitment().digest)) return error.IndependentIdentityMismatch;
        var fixture: ?*const Fixture = null;
        for (self.corpus.fixtures.items) |*candidate| {
            if (candidate.depth == depth and std.mem.eql(u8, candidate.bytes, bytes)) {
                fixture = candidate;
                break;
            }
        }
        const hash = rawHash(bytes);
        try checkRestoredCheckpoint(depth, gpa, fixture, &restored, bytes, std.mem.readInt(u64, hash[0..8], .big));
        return .accepted;
    }

    /// Deterministic v2 proof oracle: Smith bytes shape a small fixture,
    /// the honestly built membership proof must verify against its digest,
    /// and one of nine selector-picked forgeries must be rejected.
    fn checkProofOracle(self: *const Guided, gpa: Allocator, input: []const u8) !GuidedOutcome {
        _ = self;
        const count: usize = 2 + input[1] % 7;
        const target: u32 = 21 + input[3] % 44;
        // Frame sorted distinct records: table 1, u16 keys, 2-byte values.
        var blocks: [8][80]u8 = undefined;
        var block_lens: [8]usize = @splat(0);
        var block_sizes: [8]u64 = @splat(0);
        var block_count: usize = 0;
        var keys: [8]u16 = undefined;
        for (0..count) |i| {
            if (block_lens[block_count] == 0 and block_count > 0 and false) unreachable;
            const key: u16 = @intCast(i * 2 + input[2] % 2 * 0);
            keys[i] = key;
            const value = [2]u8{ input[(4 + i * 2) % input.len], input[(5 + i * 2) % input.len] };
            var record: [9 + 2 + 4 + 2]u8 = undefined;
            std.mem.writeInt(u32, record[0..4], 1, .big);
            std.mem.writeInt(u32, record[4..8], 2, .big);
            std.mem.writeInt(u16, record[8..10], key, .big);
            record[10] = 1;
            std.mem.writeInt(u32, record[11..15], 2, .big);
            record[15] = value[0];
            record[16] = value[1];
            const b = &blocks[block_count];
            @memcpy(b[block_lens[block_count]..][0..17], &record);
            block_lens[block_count] += 17;
            block_sizes[block_count] += 17;
            if (block_sizes[block_count] >= target) block_count += 1;
        }
        if (block_lens[block_count] > 0) block_count += 1;
        var leaves: [8][32]u8 = undefined;
        var tree: proofs.BlockTree = .{};
        for (0..block_count) |i| {
            leaves[i] = proofs.blockHash(@intCast(i), blocks[i][0..block_lens[i]]);
            tree.append(leaves[i]);
        }
        const bucket_hash = proofs.bucketHash(@intCast(count), @intCast(block_count), tree.root());
        var schema_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input[0..8], &schema_hash, .{});
        const profile = proofs.profileHash(4, target);
        var levels: [4]proofs.ChainLevel = undefined;
        const empty_bucket = proofs.emptyBucketHash();
        for (&levels, 0..) |*level, i| {
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(&[_]u8{ input[6], input[7], @intCast(i) }, &hash, .{});
            level.* = .{ .curr = hash, .snap = empty_bucket };
        }
        levels[0].curr = empty_bucket;
        levels[0].snap = empty_bucket;
        levels[1].curr = bucket_hash;
        const advance_number: u64 = std.mem.readInt(u16, input[8..10], .big);
        const digest = proofs.chainCommitment(schema_hash, profile, advance_number, &levels);
        // Locate the chosen record's block.
        const chosen = input[4] % count;
        var block_index: usize = 0;
        {
            var seen: usize = 0;
            for (0..block_count) |i| {
                const records_here = block_lens[i] / 17;
                if (chosen < seen + records_here) {
                    block_index = i;
                    break;
                }
                seen += records_here;
            }
        }
        var key_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &key_bytes, keys[chosen], .big);
        var value_bytes: [2]u8 = undefined;
        {
            const offset = block_index * 17 * 0 + block_lens[0..].len * 0; // value lives inside the record
            _ = offset;
            // Recompute the record's value from the same input derivation.
            value_bytes[0] = input[(4 + chosen * 2) % input.len];
            value_bytes[1] = input[(5 + chosen * 2) % input.len];
        }
        const path = try proofs.blockPath(gpa, leaves[0..block_count], block_index);
        defer gpa.free(path.steps);
        var proof = proofs.MembershipProof{
            .table = 1,
            .key = &key_bytes,
            .value = &value_bytes,
            .slot_level = 1,
            .slot_snapshot = false,
            .schema_hash = schema_hash,
            .profile_hash = profile,
            .advance = advance_number,
            .levels = &levels,
            .bucket = .{
                .block = blocks[block_index][0..block_lens[block_index]],
                .block_index = @intCast(block_index),
                .block_count = @intCast(block_count),
                .record_count = @intCast(count),
                .path = path,
            },
        };
        try proofs.verifyMembership(&proof, digest);
        // Selector-picked forgery must fail.
        const selector = input[0] % 9;
        var wrong_digest = digest;
        switch (selector) {
            0 => wrong_digest[0] ^= 0xFF,
            1 => proof.bucket.record_count += 1,
            2 => proof.bucket.block_count += 1,
            3 => proof.bucket.block_index +%= 1,
            4 => {
                var mutated = try gpa.dupe(u8, proof.bucket.block);
                defer gpa.free(mutated);
                mutated[mutated.len - 1] ^= 0xFF;
                proof.bucket.block = mutated;
                if (proofs.verifyMembership(&proof, wrong_digest)) |_| return error.ForgedProofAccepted else |_| {}
                return .accepted;
            },
            5 => proof.slot_snapshot = true,
            6 => proof.advance +%= 1,
            7 => {
                var flipped: [2]u8 = value_bytes;
                flipped[0] ^= 0xFF;
                proof.value = &flipped;
            },
            8 => proof.slot_level = 2,
            else => {},
        }
        if (proofs.verifyMembership(&proof, wrong_digest)) |_| return error.ForgedProofAccepted else |_| {}
        return .accepted;
    }

    fn fuzzCodec(self: *const Guided, smith: *std.testing.Smith) anyerror!void {
        _ = try self.fromSmith(.codec, smith);
    }
    fn fuzzBucket(self: *const Guided, smith: *std.testing.Smith) anyerror!void {
        _ = try self.fromSmith(.bucket, smith);
    }
    fn fuzzCheckpoint(self: *const Guided, smith: *std.testing.Smith) anyerror!void {
        _ = try self.fromSmith(.checkpoint, smith);
    }
    fn fuzzProof(self: *const Guided, smith: *std.testing.Smith) anyerror!void {
        _ = try self.fromSmith(.proof, smith);
    }
};

test "portable guided: codec" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    const corpus = guided.smithCorpus(.codec);
    const executed = guided_executions;
    try std.testing.fuzz(@as(*const Guided, &guided), Guided.fuzzCodec, .{ .corpus = corpus });
    try std.testing.expect(guided_executions >= executed + corpus.len + 1);
}

test "portable guided: bucket" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    const corpus = guided.smithCorpus(.bucket);
    const executed = guided_executions;
    try std.testing.fuzz(@as(*const Guided, &guided), Guided.fuzzBucket, .{ .corpus = corpus });
    try std.testing.expect(guided_executions >= executed + corpus.len + 1);
}

test "portable guided: proof" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    const corpus = guided.smithCorpus(.proof);
    const executed = guided_executions;
    try std.testing.fuzz(@as(*const Guided, &guided), Guided.fuzzProof, .{ .corpus = corpus });
    try std.testing.expect(guided_executions >= executed + corpus.len + 1);
}

test "portable guided: checkpoint" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    const corpus = guided.smithCorpus(.checkpoint);
    const executed = guided_executions;
    try std.testing.fuzz(@as(*const Guided, &guided), Guided.fuzzCheckpoint, .{ .corpus = corpus });
    try std.testing.expect(guided_executions >= executed + corpus.len + 1);
}

/// Synthetic failing target proving fail-closed wrapper behavior end to end.
/// Only -Dguided-probe=true arms it; the corpus deliberately does not fail, so
/// ordinary runs pass and a campaign must discover the failing first byte.
const probe_max_input = 64;

fn checkProbeInput(input: []const u8) !void {
    if (input.len > 0 and input[0] == 42) return error.SyntheticProbeFailure;
}

fn fuzzProbe(_: void, smith: *std.testing.Smith) anyerror!void {
    if (!build_options.synthetic_probe) return;
    var buffer: [probe_max_input]u8 = undefined;
    try checkProbeInput(buffer[0..smith.slice(&buffer)]);
}

fn replayProbeInput(framing: ReplayFraming, payload: []const u8) !GuidedResult {
    if (!build_options.synthetic_probe) return error.ProbeDisabled;
    if (framing == .raw) {
        try checkProbeInput(payload);
        return .{ .outcome = .accepted, .peak_case_bytes = payload.len };
    }
    var smith: std.testing.Smith = .{ .in = payload };
    var buffer: [probe_max_input]u8 = undefined;
    const len = smith.slice(&buffer);
    try checkProbeInput(buffer[0..len]);
    return .{ .outcome = .accepted, .peak_case_bytes = len };
}

test "portable guided probe: synthetic failure" {
    try std.testing.fuzz({}, fuzzProbe, .{ .corpus = &.{"\x29\x00\x00\x00"} });
}

test "portable fuzz: guided raw replay and Smith corpus include more than 128 records" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    inline for (.{ GuidedTarget.codec, GuidedTarget.bucket, GuidedTarget.checkpoint }) |target| {
        for (guided.seedInputs(target), guided.smithCorpus(target)) |raw, framed| {
            const result = try guided.replay(target, raw);
            try std.testing.expectEqual(GuidedOutcome.accepted, result.outcome);
            try std.testing.expect(result.peak_case_bytes <= 1024 * 1024);
            try std.testing.expectEqualDeep(result, try guided.replaySmith(target, framed));
        }
    }
    const seeds = guided.seedInputs(.bucket);
    const large = seeds[seeds.len - 1];
    try std.testing.expectEqual(@as(u64, 129), std.mem.readInt(u64, large[bucket.domain.len..][0..8], .big));
    try std.testing.expectError(error.MalformedFixture, recordPositions(large));
    try std.testing.expectEqual(GuidedOutcome.accepted, (try guided.replay(.bucket, large)).outcome);
    // A near-64 KiB canonical bucket exercises the streaming oracle at the
    // maximum input scale, with O(1) scanner storage and bounded owned storage.
    var dense: [max_input]u8 = undefined;
    @memcpy(dense[0..bucket.domain.len], bucket.domain);
    const count = (dense.len - bucket.empty_bytes.len) / 9;
    std.mem.writeInt(u64, dense[bucket.domain.len..][0..8], count, .big);
    var pos: usize = bucket.empty_bytes.len;
    for (0..count) |table| {
        std.mem.writeInt(u32, dense[pos..][0..4], @intCast(table), .big);
        @memset(dense[pos + 4 ..][0..5], 0); // Empty key, tombstone value.
        pos += 9;
    }
    const result = try guided.replay(.bucket, dense[0..pos]);
    try std.testing.expect(result.outcome == .accepted or result.outcome == .oom);
    try std.testing.expect(result.peak_case_bytes <= 1024 * 1024);
    const too_large: [max_input + 1]u8 = @splat(0);
    try std.testing.expectError(error.InputTooLarge, guided.replay(.bucket, &too_large));
}

test "portable fuzz: guided checkpoint identity reaches typed and topology rejection" {
    var guided = try Guided.init(std.testing.allocator);
    defer guided.deinit();
    const fixture = &guided.corpus.fixtures.items[13 + 4]; // Depth 3, advance 8.
    var input: [max_input]u8 = undefined;
    input[0] = 1;
    const bytes = input[1..][0..fixture.bytes.len];
    @memcpy(bytes, fixture.bytes);
    const layout = try outerLayout(bytes, 3);
    var prng = std.Random.DefaultPrng.init(37);
    for (layout.frames[0..layout.count]) |frame| {
        if (mutateBucket(bytes[frame.start..][0..frame.len], .typed_bool, prng.random()) == .invalid_typed) break;
    } else return error.MissingTypedSeed;
    const typed_identity = try candidateIdentity(bytes, 3);
    try std.testing.expect(!std.mem.eql(u8, &typed_identity, &fixture.digest));
    try std.testing.expectError(error.InvalidCheckpoint, Db3.restore(std.testing.allocator, bytes, typed_identity));
    try std.testing.expectEqual(GuidedOutcome.rejected, (try guided.replay(.checkpoint, input[0 .. bytes.len + 1])).outcome);

    @memcpy(bytes, fixture.bytes);
    @memset(bytes[magic.len + 64 ..][0..8], 0); // Nonempty genesis is impossible.
    const topology_identity = try candidateIdentity(bytes, 3);
    try std.testing.expect(!std.mem.eql(u8, &topology_identity, &fixture.digest));
    try std.testing.expectError(error.InvalidTopology, Db3.restore(std.testing.allocator, bytes, topology_identity));
    try std.testing.expectEqual(GuidedOutcome.rejected, (try guided.replay(.checkpoint, input[0 .. bytes.len + 1])).outcome);
}

pub fn main(init: std.process.Init) !void {
    var options: Options = .{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        const value = args.next() orelse return error.MissingArgument;
        if (std.mem.eql(u8, arg, "--iterations")) {
            options.iterations = try std.fmt.parseInt(usize, value, 0);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            options.seed = try std.fmt.parseInt(u64, value, 0);
        } else if (std.mem.eql(u8, arg, "--replay-target")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.target = std.meta.stringToEnum(ReplayTarget, value) orelse return error.UnknownReplayTarget;
        } else if (std.mem.eql(u8, arg, "--replay-raw")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.framing = .raw;
            options.replay.?.path = value;
        } else if (std.mem.eql(u8, arg, "--replay-smith")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.framing = .smith;
            options.replay.?.path = value;
        } else if (std.mem.eql(u8, arg, "--replay-mapped")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.framing = .mapped;
            options.replay.?.path = value;
        } else if (std.mem.eql(u8, arg, "--expect")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.expect = std.meta.stringToEnum(GuidedOutcome, value) orelse return error.UnknownReplayOutcome;
        } else if (std.mem.eql(u8, arg, "--expect-error")) {
            if (options.replay == null) options.replay = .{};
            options.replay.?.expect_error = value;
        } else return error.UnknownArgument;
    }
    if (options.replay) |replay| return runReplay(init, replay);
    const stats = try run(init.gpa, options);
    var output: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &output);
    try std.json.Stringify.value(stats, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn runReplay(init: std.process.Init, replay: Replay) !void {
    if (replay.path.len == 0) return error.MissingReplayInput;
    const gpa = init.gpa;
    const file = try std.Io.Dir.cwd().readFileAlloc(init.io, replay.path, gpa, .limited(20 + 4 + max_input));
    defer gpa.free(file);
    var mapped: ?MappedHeader = null;
    const payload = switch (replay.framing) {
        .raw, .smith => file,
        .mapped => mapped: {
            if (file.len < 20) return error.MappedInputTruncated;
            const header: MappedHeader = .{
                .coverage = std.mem.readInt(u64, file[0..8], .little),
                .instance = std.mem.readInt(u32, file[8..12], .little),
                .test_index = std.mem.readInt(u32, file[12..16], .little),
                .length = std.mem.readInt(u32, file[16..20], .little),
            };
            if (header.length > 4 + max_input) return error.MappedInputTooLarge;
            if (file.len < 20 + @as(usize, header.length)) return error.MappedInputTruncated;
            mapped = header;
            break :mapped file[20..][0..header.length];
        },
    };
    var guided = try Guided.init(gpa);
    defer guided.deinit();
    const result: anyerror!GuidedResult = if (replay.target == .probe)
        replayProbeInput(replay.framing, payload)
    else if (replay.framing == .raw)
        guided.replay(guidedTarget(replay.target), payload)
    else
        guided.replaySmith(guidedTarget(replay.target), payload);
    var output: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &output);
    if (result) |value| {
        if (replay.expect_error != null) return error.ReplayExpectedError;
        if (replay.expect) |wanted| if (value.outcome != wanted) return error.ReplayOutcomeMismatch;
        try std.json.Stringify.value(.{ .target = replay.target, .framing = replay.framing, .outcome = value.outcome, .peak_case_bytes = value.peak_case_bytes, .mapped = mapped }, .{}, &writer.interface);
    } else |err| {
        if (replay.expect_error) |wanted| {
            if (!std.mem.eql(u8, wanted, "any") and !std.mem.eql(u8, wanted, @errorName(err))) {
                std.debug.print("replay error mismatch: expected {s}, got {s}\n", .{ wanted, @errorName(err) });
                return error.ReplayErrorMismatch;
            }
            try std.json.Stringify.value(.{ .target = replay.target, .framing = replay.framing, .outcome = "error", .error_name = @errorName(err), .mapped = mapped }, .{}, &writer.interface);
        } else return err;
    }
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn guidedTarget(target: ReplayTarget) GuidedTarget {
    return switch (target) {
        .codec => .codec,
        .bucket => .bucket,
        .checkpoint => .checkpoint,
        .proof => .proof,
        .probe => unreachable,
    };
}

test "portable fuzz: deterministic 1000-case parser and continuation smoke" {
    const options: Options = .{};
    const stats = try run(std.testing.allocator, options);
    try std.testing.expectEqual(options.iterations, stats.cases);
    try std.testing.expect(stats.codec.accepted > 0 and stats.codec.rejected > 0);
    try std.testing.expect(stats.bucket.accepted > 0 and stats.bucket.rejected > 0 and stats.bucket.oom > 0);
    try std.testing.expect(stats.checkpoint.accepted > 0 and stats.checkpoint.rejected > 0 and stats.checkpoint.oom > 0);
    try std.testing.expect(stats.independent_identities > 0 and stats.accepted_mutated_checkpoints > 0);
    try std.testing.expect(stats.continuation_checks > 0 and stats.allocation_failures > 0);
    try std.testing.expect(stats.live_continuation_checks > 0);
}

test "portable fuzz: allocation failures across restore, reencode, and continuation" {
    const gpa = std.testing.allocator;
    var corpus = try Corpus.init(gpa, 1);
    defer corpus.deinit(gpa);
    const fixture = &corpus.fixtures.items[13 + 4]; // depth 3, advance 8: a pending merge exists.
    var baseline: Budget = .{ .child = gpa };
    try checkCheckpoint(3, baseline.allocator(), fixture, fixture.bytes, fixture.digest, 37);
    try baseline.check();
    try std.testing.expect(baseline.calls > 10);
    for (0..baseline.calls) |fail_at| {
        var budget: Budget = .{ .child = gpa, .fail_at = fail_at };
        try std.testing.expectError(error.OutOfMemory, checkCheckpoint(3, budget.allocator(), fixture, fixture.bytes, fixture.digest, 37));
        try budget.check();
        try std.testing.expectEqual(@as(usize, 1), budget.failures);
    }
}
