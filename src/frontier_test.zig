const std = @import("std");
const frontiers = @import("frontier.zig");
const Hash = frontiers.Hash;
const Merge = frontiers.Merge;
const Frontier = frontiers.Frontier;
const empty_hash = frontiers.emptyHash();
fn MemorySource(comptime depth: usize) type {
    const buckets = @import("bucket.zig");
    return struct {
        base: *const @import("list.zig").List(depth),
        fresh: buckets.Bucket,

        fn find(self: @This(), hash: Hash) !buckets.Bucket {
            if (std.mem.eql(u8, &hash, &empty_hash)) return buckets.Bucket.empty();
            if (std.mem.eql(u8, &hash, &self.fresh.hash())) return self.fresh;
            for (self.base.levels) |level| {
                if (std.mem.eql(u8, &hash, &level.curr.hash())) return level.curr;
                if (std.mem.eql(u8, &hash, &level.snap.hash())) return level.snap;
                if (level.next) |pending| {
                    if (std.mem.eql(u8, &hash, &pending.hash())) return pending;
                }
            }
            // The test source deliberately cannot resolve newly produced
            // outputs: this proves all jobs in an advance are independent.
            return error.UnresolvedMergeDependency;
        }

        pub fn merge(self: @This(), job: Merge) !Hash {
            var output = try buckets.merge(std.testing.allocator, try self.find(job.older), try self.find(job.newer), job.drop_tombstones);
            defer output.release();
            return output.hash();
        }
    };
}

test "frontier: reordered independent jobs match memory levels and commitments" {
    const buckets = @import("bucket.zig");
    const Schema = struct {
        pub const namespace = "frontier.parity";
        pub const version = 1;
        pub const tables = .{ .rows = @import("schema.zig").Table(1, u8, u8) };
    };
    inline for (.{ 1, 2, 3, 11 }) |depth| {
        const Db = @import("database.zig").DatabaseWithDepth(Schema, depth);
        var db = Db.init(std.testing.allocator);
        defer db.deinit();
        var frontier = Frontier(depth).init();
        try std.testing.expectEqual(@TypeOf(db.engine).profileHash(), @TypeOf(frontier).profileHash());
        try std.testing.expectEqual(db.commitment().digest, frontier.commitment(Db.schema_hash).digest);
        var rng = std.Random.DefaultPrng.init(0xdecaf_391bed);
        const random = rng.random();
        for (1..257) |sequence| {
            var batch = try db.batch(std.testing.allocator);
            defer batch.deinit();
            if (sequence % 7 != 0) {
                const key = random.intRangeLessThan(u8, 0, 24);
                if (random.boolean()) {
                    if (db.get(.rows, key) != null) try batch.delete(.rows, key);
                } else {
                    const value = random.int(u8);
                    if (db.get(.rows, key) != value) try batch.put(.rows, key, value);
                }
            }
            var prepared = try db.prepareAdvance(std.testing.allocator, sequence, &batch);
            defer prepared.deinit();
            // The single staged effect is already normalized against the base.
            var fresh = try buckets.Bucket.fromSorted(std.testing.allocator, batch.changes.items);
            defer fresh.release();
            const source: MemorySource(depth) = .{ .base = &db.engine, .fresh = fresh };
            const work = try frontier.plan(sequence, fresh.hash());
            var results: [depth]Hash = undefined;
            var order: [depth]usize = undefined;
            for (order[0..work.count], 0..) |*item, i| item.* = i;
            random.shuffle(usize, order[0..work.count]);
            for (order[0..work.count]) |i| results[i] = try source.merge(work.merges()[i]);
            frontier = try work.finish(results[0..work.count]);
            try db.commit(&prepared);
            try frontier.validateShape();
            try std.testing.expectEqual(db.commitment().digest, frontier.commitment(Db.schema_hash).digest);
            try std.testing.expectEqual(db.commitment().bucket_list_root, frontier.root());
            try std.testing.expectEqual(db.commitment().continuation_hash, frontier.continuationHash());
            for (frontier.levels, db.engine.levels, 0..) |actual, expected, i| {
                try std.testing.expectEqual(expected.curr.hash(), actual.curr);
                try std.testing.expectEqual(expected.snap.hash(), actual.snap);
                try std.testing.expectEqual(expected.next != null, actual.next != null);
                if (actual.next) |pending| {
                    try std.testing.expectEqual(expected.next.?.hash(), pending);
                    const restored_source: MemorySource(depth) = .{ .base = &db.engine, .fresh = buckets.Bucket.empty() };
                    try std.testing.expectEqual(pending, try restored_source.merge(frontier.pendingJob(i).?));
                } else try std.testing.expectEqual(null, frontier.pendingJob(i));
            }
        }
    }
}

test "frontier: simultaneous spills capture old current before lower promotion" {
    var frontier = Frontier(3).init();
    frontier.seq = 7;
    const old_l1: Hash = @splat(1);
    const prior_l1_next: Hash = @splat(2);
    frontier.levels[1].curr = old_l1;
    frontier.levels[1].next = prior_l1_next;
    const work = try frontier.plan(8, empty_hash);
    try std.testing.expectEqual(@as(usize, 3), work.count);
    try std.testing.expectEqual(@as(usize, 2), work.jobs[0].level);
    try std.testing.expectEqual(old_l1, work.jobs[0].newer);
    try std.testing.expect(work.jobs[0].drop_tombstones);
    try std.testing.expectEqual(prior_l1_next, work.jobs[1].older);
    const complete = try work.finish(&.{ empty_hash, empty_hash, empty_hash });
    try std.testing.expectEqual(old_l1, complete.levels[1].snap);
    try std.testing.expectEqual(prior_l1_next, complete.levels[1].curr);
    try complete.validateShape();
}

test "frontier: failed work and incomplete results preserve the base" {
    const Context = struct {
        fail_at: usize,
        calls: usize = 0,
        pub fn merge(self: *@This(), _: Merge) !Hash {
            const index = self.calls;
            self.calls += 1;
            if (index == self.fail_at) return error.MergeFailed;
            return empty_hash;
        }
    };
    var frontier = Frontier(3).init();
    frontier.seq = 7;
    frontier.levels[1].next = empty_hash;
    const before = frontier;
    const work = try frontier.plan(8, empty_hash);
    try std.testing.expectError(error.InvalidResultCount, work.finish(&.{empty_hash}));
    try std.testing.expectError(error.InvalidResultCount, work.finish(&.{ empty_hash, empty_hash, empty_hash, empty_hash }));
    for (0..work.count) |fail_at| {
        var context: Context = .{ .fail_at = fail_at };
        try std.testing.expectError(error.MergeFailed, frontier.advance(8, empty_hash, &context));
        try std.testing.expectEqualDeep(before, frontier);
    }
    try std.testing.expectError(error.InvalidSequence, frontier.plan(9, empty_hash));
    try std.testing.expectEqualDeep(before, frontier);
}

test "frontier: empty pending presence and shape remain authenticated" {
    var frontier = Frontier(3).init();
    const initial_root = frontier.root();
    const initial_continuation = frontier.continuationHash();
    frontier = try (try frontier.plan(1, empty_hash)).finish(&.{empty_hash});
    frontier = try (try frontier.plan(2, empty_hash)).finish(&.{ empty_hash, empty_hash });
    try frontier.validateShape();
    try std.testing.expectEqual(initial_root, frontier.root());
    try std.testing.expect(!std.mem.eql(u8, &initial_continuation, &frontier.continuationHash()));
    try std.testing.expectEqual(empty_hash, frontier.levels[1].next.?);
    var invalid = frontier;
    invalid.levels[1].next = null;
    try std.testing.expectError(error.InvalidTopology, invalid.validateShape());
    invalid = frontier;
    invalid.levels[2].snap = @splat(3);
    try std.testing.expectError(error.InvalidTopology, invalid.validateShape());
    invalid = frontier;
    invalid.levels[1].curr = @splat(4);
    try std.testing.expectError(error.InvalidTopology, invalid.validateShape());
    invalid = frontier;
    invalid.levels[0].next = empty_hash;
    try std.testing.expectError(error.InvalidTopology, invalid.validateShape());
}

test "frontier: maximum sequence and depth avoid lookahead overflow" {
    var frontier = Frontier(31).init();
    frontier.seq = std.math.maxInt(u64) - 1;
    for (frontier.levels[1..]) |*level| level.next = empty_hash;
    try frontier.validateShape();
    const before_root = frontier.root();
    const work = try frontier.plan(std.math.maxInt(u64), empty_hash);
    frontier = try work.finish(&.{empty_hash});
    try frontier.validateShape();
    try std.testing.expectEqual(before_root, frontier.root());
    try std.testing.expectError(error.SequenceExhausted, frontier.plan(0, empty_hash));
}
