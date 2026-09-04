//! Deterministic factor-four BucketList with delayed next-current promotion.
const std = @import("std");
const bucket = @import("bucket.zig");
const Bucket = bucket.Bucket;
const Record = bucket.Record;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const default_depth = 11;
pub const Level = struct {
    curr: Bucket = .{},
    snap: Bucket = .{},
    /// Presence denotes a scheduled merge, including one whose output is empty.
    next: ?Bucket = null,
};

pub fn List(comptime depth: usize) type {
    if (depth == 0 or depth > 31) @compileError("BucketList depth must be in 1...31");
    return struct {
        const Self = @This();
        pub const level_count = depth;
        pub const profile_domain = "bucketlist.profile.v1\x00";
        pub const level_domain = "bucketlist.level.v1\x00";
        pub const root_domain = "bucketlist.list.v1\x00";
        pub const continuation_domain = "bucketlist.continuation.v1\x00";

        gpa: Allocator,
        seq: u64 = 0,
        levels: [depth]Level = @splat(.{}),

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (&self.levels) |*level| {
                level.curr.release();
                level.snap.release();
                if (level.next) |*next| next.release();
                level.next = null;
            }
            self.seq = 0;
        }

        /// O(depth), allocation-free. Bucket ownership is atomic; callers must
        /// synchronize acquisition from a list another thread is mutating.
        pub fn clone(self: *const Self) Self {
            var result = Self.init(self.gpa);
            result.seq = self.seq;
            for (self.levels, &result.levels) |source, *dest| {
                dest.curr = source.curr.retain();
                dest.snap = source.snap.retain();
                if (source.next) |next| dest.next = next.retain();
            }
            return result;
        }

        /// Exactly one sequence step, including empty batches. All failure
        /// paths preserve the original list, readable values and ownership.
        pub fn advance(self: *Self, next_seq: u64, sorted_records: []const Record) !void {
            if (self.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (next_seq != self.seq + 1) return error.InvalidSequence;
            var candidate = self.clone();
            errdefer candidate.deinit();
            try candidate.advanceInPlace(next_seq, sorted_records);
            self.deinit();
            self.* = candidate;
        }

        fn advanceInPlace(self: *Self, next_seq: u64, sorted_records: []const Record) !void {
            // Validating/building first makes invalid batches fail before work.
            var fresh = try Bucket.fromSorted(self.gpa, sorted_records);
            defer fresh.release();
            var i = depth - 1;
            while (i > 0) : (i -= 1) {
                if (!shouldSpill(next_seq, i - 1)) continue;
                const source = &self.levels[i - 1];
                source.snap.release();
                source.snap = source.curr;
                source.curr = Bucket.empty();
                const dest = &self.levels[i];
                // The prior pending result becomes visible only now.
                if (dest.next) |pending| {
                    dest.curr.release();
                    dest.curr = pending;
                    dest.next = null;
                }
                const old = if (mergeWithEmpty(next_seq, i)) Bucket.empty() else dest.curr;
                dest.next = try bucket.merge(self.gpa, old, source.snap, i == depth - 1);
            }
            // Level zero incorporates this batch immediately.
            const level0 = &self.levels[0];
            const current = try bucket.merge(self.gpa, level0.curr, fresh, depth == 1);
            level0.curr.release();
            level0.curr = current;
            self.seq = next_seq;
        }

        pub fn get(self: *const Self, table: u32, key: []const u8) ?[]const u8 {
            for (self.levels) |level| {
                if (level.curr.lookup(table, key)) |record| return record.value;
                if (level.snap.lookup(table, key)) |record| return record.value;
            }
            return null;
        }

        pub fn profileHash() [32]u8 {
            var h = Sha256.init(.{});
            h.update(profile_domain);
            hashInt(u32, &h, depth);
            hashInt(u32, &h, 4);
            return h.finalResult();
        }

        /// Commits to visible curr/snap topology. seq and pending work are
        /// intentionally bound by the outer database commitment instead.
        pub fn root(self: *const Self) [32]u8 {
            var h = Sha256.init(.{});
            h.update(root_domain);
            h.update(&profileHash());
            for (self.levels, 0..) |level, i| {
                var lh = Sha256.init(.{});
                lh.update(level_domain);
                hashInt(u32, &lh, @intCast(i));
                lh.update(&level.curr.hash());
                lh.update(&level.snap.hash());
                h.update(&lh.finalResult());
            }
            return h.finalResult();
        }

        /// Authenticates exact pending output presence and identity so an
        /// accepted checkpoint cannot silently substitute its future state.
        pub fn continuationHash(self: *const Self) [32]u8 {
            var h = Sha256.init(.{});
            h.update(continuation_domain);
            h.update(&profileHash());
            for (self.levels, 0..) |level, i| {
                hashInt(u32, &h, @intCast(i));
                h.update(&.{@intFromBool(level.next != null)});
                if (level.next) |pending| h.update(&pending.hash());
            }
            return h.finalResult();
        }

        /// Checks schedule shape and independently recomputes every pending
        /// output from its authenticated inputs. This is fallible and may be
        /// linear in the stored state, so call at restore rather than per read.
        /// Authentication against a trusted outer commitment is still required.
        pub fn validate(self: *const Self) !void {
            for (self.levels, 0..) |level, i| {
                if ((self.seq == 0 or (i > 0 and self.seq < 2 * half(i - 1))) and
                    level.curr.records().len != 0)
                    return error.InvalidTopology;
                if ((i == depth - 1 or self.seq < half(i)) and level.snap.records().len != 0)
                    return error.InvalidTopology;
                const has_pending = i != 0 and self.seq >= half(i - 1);
                if ((level.next != null) != has_pending) return error.InvalidTopology;
                if (i == depth - 1) {
                    for (level.curr.records()) |record| {
                        if (record.value == null) return error.InvalidTopology;
                    }
                }
                if (level.next) |pending| {
                    const old = if (mergeWithEmpty(self.seq, i)) Bucket.empty() else level.curr;
                    var expected = try bucket.merge(self.gpa, old, self.levels[i - 1].snap, i == depth - 1);
                    defer expected.release();
                    if (!std.mem.eql(u8, &expected.hash(), &pending.hash()))
                        return error.InvalidTopology;
                }
            }
        }

        /// 4^(level+1)/2; depth bound keeps the shift and lookahead in u64.
        pub fn half(level: usize) u64 {
            std.debug.assert(level < depth);
            return @as(u64, 1) << @as(u6, @intCast(2 * level + 1));
        }

        pub fn shouldSpill(seq: u64, level: usize) bool {
            return level != depth - 1 and seq % half(level) == 0;
        }

        fn mergeWithEmpty(seq: u64, level: usize) bool {
            if (level == 0 or level == depth - 1) return false;
            // Equivalent to testing whether roundDown(seq, half(level-1)) +
            // half(level-1) spills level, without overflowing near u64 maximum.
            return (seq / half(level - 1)) % 4 == 3;
        }
    };
}

fn hashInt(comptime T: type, h: *Sha256, value: T) void {
    var encoded: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &encoded, value, .big);
    h.update(&encoded);
}

test "factor-four schedule preserves delayed promotion at simultaneous boundaries" {
    var list = List(3).init(std.testing.allocator);
    defer list.deinit();
    const expected_counts = [_][9]usize{
        // L0 curr/snap/next, L1 curr/snap/next, L2 curr/snap/next.
        .{ 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 1, 0, 0, 0, 1, 0, 0, 0 },
        .{ 2, 1, 0, 0, 0, 1, 0, 0, 0 },
        .{ 1, 2, 0, 1, 0, 3, 0, 0, 0 },
        .{ 2, 2, 0, 1, 0, 3, 0, 0, 0 },
        .{ 1, 2, 0, 3, 0, 2, 0, 0, 0 },
        .{ 2, 2, 0, 3, 0, 2, 0, 0, 0 },
        .{ 1, 2, 0, 2, 3, 4, 0, 0, 3 },
    };
    for (expected_counts, 1..) |counts, seq| {
        const key = [_]u8{@intCast(seq)};
        try list.advance(seq, &.{.{ .table = 1, .key = &key, .value = "v" }});
        try list.validate();
        for (list.levels, 0..) |level, i| {
            try std.testing.expectEqual(counts[3 * i], level.curr.records().len);
            try std.testing.expectEqual(counts[3 * i + 1], level.snap.records().len);
            try std.testing.expectEqual(counts[3 * i + 2], if (level.next) |n| n.records().len else 0);
        }
        for (1..seq + 1) |inserted| {
            const k = [_]u8{@intCast(inserted)};
            try std.testing.expectEqualSlices(u8, "v", list.get(1, &k).?);
        }
    }
}

test "empty advances preserve schedule, and pending content is separately authenticated" {
    var list = List(3).init(std.testing.allocator);
    defer list.deinit();
    const genesis_root = list.root();
    const genesis_continuation = list.continuationHash();
    try list.advance(1, &.{});
    try std.testing.expectEqual(genesis_root, list.root());
    try std.testing.expectEqual(genesis_continuation, list.continuationHash());
    try list.advance(2, &.{});
    try std.testing.expect(list.levels[1].next != null);
    try std.testing.expectEqual(genesis_root, list.root());
    try std.testing.expect(!std.mem.eql(u8, &genesis_continuation, &list.continuationHash()));
    try list.validate();
    var corrupt = list.clone();
    defer corrupt.deinit();
    corrupt.levels[1].next.?.release();
    corrupt.levels[1].next = try Bucket.fromSorted(std.testing.allocator, &.{.{ .table = 1, .key = "x", .value = "forged" }});
    try std.testing.expectEqual(list.root(), corrupt.root());
    try std.testing.expect(!std.mem.eql(u8, &list.continuationHash(), &corrupt.continuationHash()));
    try std.testing.expectError(error.InvalidTopology, corrupt.validate());
    try list.advance(3, &.{});
    try std.testing.expectError(error.InvalidSequence, list.advance(5, &.{}));
    list.seq = std.math.maxInt(u64);
    try std.testing.expectError(error.SequenceExhausted, list.advance(0, &.{}));
}

test "random history agrees with logical map through terminal tombstone compaction" {
    inline for (.{ 1, 2, 3, 11 }) |depth| {
        var list = List(depth).init(std.testing.allocator);
        defer list.deinit();
        var duplicate = List(depth).init(std.testing.allocator);
        defer duplicate.deinit();
        var oracle: [32]?u8 = @splat(null);
        var rng = std.Random.DefaultPrng.init(0x391bed);
        const random = rng.random();
        for (1..513) |seq| {
            const k = random.intRangeLessThan(u8, 0, oracle.len);
            const v = random.int(u8);
            const erase = random.boolean();
            const row: Record = .{ .table = 1, .key = &.{k}, .value = if (erase) null else &.{v} };
            const rows: []const Record = if (seq % 7 == 0) &.{} else &.{row};
            try list.advance(seq, rows);
            try duplicate.advance(seq, rows);
            if (rows.len != 0) oracle[k] = if (erase) null else v;
            for (oracle, 0..) |expected, key| {
                const actual = list.get(1, &.{@intCast(key)});
                try std.testing.expectEqual(expected, if (actual) |bytes| bytes[0] else null);
            }
            try std.testing.expectEqual(list.root(), duplicate.root());
            try std.testing.expectEqual(list.continuationHash(), duplicate.continuationHash());
            try list.validate();
        }
    }
}

fn failingAdvance(gpa: Allocator) !void {
    var list = List(3).init(gpa);
    defer list.deinit();
    for (1..8) |seq| {
        const key = [_]u8{@intCast(seq)};
        try list.advance(seq, &.{.{ .table = 1, .key = &key, .value = "before" }});
    }
    var snapshot = list.clone();
    defer snapshot.deinit();
    const before_root = list.root();
    const before_next = list.continuationHash();
    list.advance(8, &.{.{ .table = 1, .key = "\x01", .value = "after" }}) catch |err| {
        try std.testing.expectEqual(before_root, list.root());
        try std.testing.expectEqual(before_next, list.continuationHash());
        try std.testing.expectEqual(@as(u64, 7), list.seq);
        try std.testing.expectEqualSlices(u8, "before", list.get(1, "\x01").?);
        return err;
    };
    try std.testing.expectEqualSlices(u8, "before", snapshot.get(1, "\x01").?);
    try std.testing.expectEqualSlices(u8, "after", list.get(1, "\x01").?);
}

test "allocation failures leave lists and retained read snapshots intact" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failingAdvance, .{});
}

test "production profile golden roots from independent Python model" {
    // Each advance n inserts table=1, key=the single byte n, value="v".
    // Generated with hashlib/struct and dictionary merges; see structure.md.
    const Vector = struct { seq: u64, root: []const u8, continuation: []const u8 };
    const vectors = [_]Vector{
        .{ .seq = 0, .root = "0f7cb01455040129fac75fe61b3684b8aa49c176d9fbebb24d838f2f9e5ee73e", .continuation = "d7a4d7eb08e7c2d334d5ab6b9935fffd84b939a5cf4755c8eb396b2a2344dbef" },
        .{ .seq = 1, .root = "8ef66ed65c5a0a1b37b5e9446412a398c4f421e9c54e40c302ab452d2f286807", .continuation = "d7a4d7eb08e7c2d334d5ab6b9935fffd84b939a5cf4755c8eb396b2a2344dbef" },
        .{ .seq = 2, .root = "a5753dece26f6a1484df8040d3b70316afe99d1db971842a22a50a74e376ca82", .continuation = "8434e022af73434dd195db5e008b87050492f9e8d2ef14d2358972cccc8c7c9d" },
        .{ .seq = 3, .root = "37fbcd7e8c54cf892007a7c2890d13a4878ba55784a08aabd6141eebad7d3364", .continuation = "8434e022af73434dd195db5e008b87050492f9e8d2ef14d2358972cccc8c7c9d" },
        .{ .seq = 4, .root = "85b6d593a3cace4622e453c1ff3c4f9b9d9158bc1b89889a01ae93ed48e24821", .continuation = "458b729dc523d6611682ebd41e4e1e90be50fd05233ad85eaf97b2f5df7147fe" },
        .{ .seq = 6, .root = "2a0e336b3c4cf612009070a8966b8abdcf9ac88515b54d738fed8fd73e49b61a", .continuation = "f9a7b78844b68a2b06230cdcbc2f0ff390ba039ec10de1c2a6ffcfeafe2eb8a1" },
        .{ .seq = 8, .root = "8d2f2bbde6229e37acea325e9bbc7904dd74f5379f43760efc0b84aab3fce71a", .continuation = "eaf3a9544705bee005918e5458ca1b1e2da9ebb42d1d213519ead5877dae6206" },
        .{ .seq = 32, .root = "2dd17beefca88b80be7065b095297f53691fa5ee664bbeed25d7e5a20e8db1cc", .continuation = "e644f0d7a43024bac3ee55f30cb617dc1142f087adeb40a24d2fcbbd0e5d961d" },
        .{ .seq = 64, .root = "1816d91d38c88320bce372b45edabfceb85ddc80f8c13ba4f79aa5ff19658fdf", .continuation = "4c117f490bca77a052cc056f462c0f91a971f99c0756af76661cca33b17b6d77" },
    };
    var list = List(default_depth).init(std.testing.allocator);
    defer list.deinit();
    var expected: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, "734e3f46c604ea4273d1cad1d0e9a2fdea98454b0318fc9b51a25e65a5040961"), &List(default_depth).profileHash());
    for (vectors) |vector| {
        while (list.seq < vector.seq) {
            const seq = list.seq + 1;
            const key = [_]u8{@intCast(seq)};
            try list.advance(seq, &.{.{ .table = 1, .key = &key, .value = "v" }});
        }
        try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, vector.root), &list.root());
        try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&expected, vector.continuation), &list.continuationHash());
    }
}

test "equal logical maps at equal advances may have different structural roots" {
    var a = List(3).init(std.testing.allocator);
    defer a.deinit();
    var b = List(3).init(std.testing.allocator);
    defer b.deinit();
    const rows = [_]Record{.{ .table = 1, .key = "x", .value = "value" }};
    try a.advance(1, &rows);
    try a.advance(2, &.{});
    try b.advance(1, &.{});
    try b.advance(2, &rows);
    try std.testing.expectEqualSlices(u8, a.get(1, "x").?, b.get(1, "x").?);
    try std.testing.expect(!std.mem.eql(u8, &a.root(), &b.root()));
}

test "last u64 advances and largest supported profile avoid lookahead overflow" {
    var list = List(31).init(std.testing.allocator);
    defer list.deinit();
    // The exact topology of an all-empty history at this mature sequence can
    // be constructed directly without executing 2^64 empty advances.
    list.seq = std.math.maxInt(u64) - 2;
    for (list.levels[1..]) |*level| level.next = Bucket.empty();
    try list.validate();
    const before_root = list.root();
    const before_continuation = list.continuationHash();
    try list.advance(std.math.maxInt(u64) - 1, &.{});
    try list.advance(std.math.maxInt(u64), &.{});
    try list.validate();
    try std.testing.expectEqual(before_root, list.root());
    try std.testing.expectEqual(before_continuation, list.continuationHash());
    try std.testing.expectError(error.SequenceExhausted, list.advance(0, &.{}));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), list.seq);
}
