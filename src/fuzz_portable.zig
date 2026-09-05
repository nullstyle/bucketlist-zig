//! Deterministic, bounded parser/property exerciser. This is a test executable,
//! not a safe way to derive a trusted checkpoint identity from untrusted bytes.
//! Run with --iterations N --seed N; the first N cases are a stable prefix.
const std = @import("std");
const codec = @import("codec.zig");
const bucket = @import("bucket.zig");
const database = @import("database.zig");
const schema = @import("schema.zig");
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
pub const Options = struct { iterations: usize = 1000, seed: u64 = 0x6275636b65746c73 };
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
    var rebuilt = bucket.Bucket.fromSorted(gpa, decoded.records()) catch |err| return if (err == error.OutOfMemory) err else error.BucketReencodeRejected;
    defer rebuilt.release();
    if (!std.mem.eql(u8, bytes, rebuilt.bytes()) or !std.mem.eql(u8, &decoded.hash(), &rawHash(bytes)) or !std.mem.eql(u8, &rebuilt.hash(), &decoded.hash())) return error.BucketRoundTripMismatch;
    const scanned = try recordPositions(bytes);
    if (scanned.count != decoded.records().len) return error.IndependentRecordMismatch;
    for (scanned.records[0..scanned.count], decoded.records(), 0..) |raw, record, i| {
        if (raw.table != record.table or !std.mem.eql(u8, bytes[raw.key..][0..raw.key_len], record.key)) return error.IndependentRecordMismatch;
        if ((raw.value != null) != (record.value != null)) return error.IndependentRecordMismatch;
        if (raw.value) |at| if (!std.mem.eql(u8, bytes[at..][0..raw.value_len], record.value.?)) return error.IndependentRecordMismatch;
        if (i > 0) {
            const previous = scanned.records[i - 1];
            if (previous.table > raw.table or (previous.table == raw.table and std.mem.order(u8, bytes[previous.key..][0..previous.key_len], record.key) != .lt)) return error.IndependentRecordMismatch;
        }
    }
}

fn checkCheckpoint(comptime depth: usize, gpa: Allocator, fixture: *const Fixture, bytes: []const u8, expected: Hash, seed: u64) !void {
    const Db = database.DatabaseWithDepth(Schema, depth);
    var restored = try Db.restore(gpa, bytes, expected);
    defer restored.deinit();
    const encoded = try restored.checkpoint(gpa);
    defer gpa.free(encoded);
    if (!std.mem.eql(u8, bytes, encoded)) return error.CheckpointRoundTripMismatch;
    // Unchanged checkpoints continue against a retained state built by real
    // advances before serialization. Mutated canonical states continue against
    // a second canonical restore. Neither baseline shares newly decoded storage.
    var again: Db = if (std.mem.eql(u8, bytes, fixture.bytes)) .{
        .engine = switch (depth) {
            1 => fixture.saved.one.engine.clone(),
            3 => fixture.saved.three.engine.clone(),
            11 => fixture.saved.eleven.engine.clone(),
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
        advance(Db, &restored, gpa, random_a.random(), seq + 1) catch |err| return if (err == error.OutOfMemory) err else error.ContinuationAdvanceRejected;
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
        } else return error.UnknownArgument;
    }
    const stats = try run(init.gpa, options);
    var output: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(init.io, &output);
    try std.json.Stringify.value(stats, .{}, &writer.interface);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
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
