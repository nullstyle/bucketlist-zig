//! Allocation-free v1 scheduling over immutable bucket identities. The host
//! owns bucket verification, merge execution, retention, and publication.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Hash = [32]u8;
pub const Commitment = struct {
    advance: u64,
    bucket_list_root: Hash,
    continuation_hash: Hash,
    digest: Hash,
};

const empty_hash: Hash = blk: {
    @setEvalBranchQuota(10000);
    var digest: Hash = undefined;
    Sha256.hash("bucketlist.bucket.v1\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x00", &digest, .{});
    break :blk digest;
};

pub fn emptyHash() Hash {
    return empty_hash;
}

pub const Level = struct {
    curr: Hash = empty_hash,
    snap: Hash = empty_hash,
    /// A present empty hash is a scheduled result, distinct from no result.
    next: ?Hash = null,
};

pub const Merge = struct {
    /// Level zero updates current; every other job creates a pending result.
    level: usize,
    older: Hash,
    newer: Hash,
    drop_tombstones: bool,
};

pub fn Frontier(comptime depth: usize) type {
    if (depth == 0 or depth > 31) @compileError("BucketList depth must be in 1...31");
    return struct {
        const Self = @This();
        pub const level_count = depth;
        pub const Error = error{ SequenceExhausted, InvalidSequence, InvalidResultCount, InvalidTopology };

        seq: u64 = 0,
        levels: [depth]Level = @splat(.{}),

        pub fn init() Self {
            return .{};
        }

        /// A plan is incomplete state, not a publishable frontier. All inputs
        /// refer to the committed base or fresh bucket: jobs can run in any
        /// order, but every result is needed before finish and publication.
        pub const Plan = struct {
            jobs: [depth]Merge = undefined,
            count: usize = 0,
            candidate: Self,

            pub fn merges(self: *const Plan) []const Merge {
                return self.jobs[0..self.count];
            }

            /// Results correspond to merges() indices, not completion order.
            /// The host must verify each result's bytes and merge provenance.
            pub fn finish(self: *const Plan, results: []const Hash) Error!Self {
                if (results.len != self.count) return error.InvalidResultCount;
                var result = self.candidate;
                for (self.merges(), results) |job, hash| {
                    if (job.level == 0) {
                        result.levels[0].curr = hash;
                    } else {
                        result.levels[job.level].next = hash;
                    }
                }
                return result;
            }
        };

        /// Exactly one logical advance, including an empty fresh bucket.
        /// Planning copies only hashes and never mutates the committed base.
        pub fn plan(self: *const Self, next_seq: u64, fresh: Hash) Error!Plan {
            if (self.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (next_seq != self.seq + 1) return error.InvalidSequence;
            var result: Plan = .{ .candidate = self.* };
            var i = depth - 1;
            while (i > 0) : (i -= 1) {
                if (!shouldSpill(next_seq, i - 1)) continue;
                const source = &result.candidate.levels[i - 1];
                // Capture the old current before this source level receives
                // its own promotion later in the descending traversal.
                source.snap = source.curr;
                source.curr = empty_hash;
                const dest = &result.candidate.levels[i];
                if (dest.next) |pending| {
                    dest.curr = pending;
                    dest.next = null;
                }
                result.jobs[result.count] = .{
                    .level = i,
                    .older = if (mergeWithEmpty(next_seq, i)) empty_hash else dest.curr,
                    .newer = source.snap,
                    .drop_tombstones = i == depth - 1,
                };
                result.count += 1;
            }
            result.jobs[result.count] = .{
                .level = 0,
                .older = result.candidate.levels[0].curr,
                .newer = fresh,
                .drop_tombstones = depth == 1,
            };
            result.count += 1;
            result.candidate.seq = next_seq;
            return result;
        }

        /// Synchronous convenience for hosts with context.merge(Merge)!Hash.
        /// A callback failure leaves this frontier untouched; the host owns
        /// cleanup of any successfully produced, unpublished bucket files.
        pub fn advance(self: *Self, next_seq: u64, fresh: Hash, context: anytype) !void {
            const work = try self.plan(next_seq, fresh);
            var results: [depth]Hash = undefined;
            for (work.merges(), 0..) |job, i| results[i] = try context.merge(job);
            self.* = try work.finish(results[0..work.count]);
        }

        pub fn profileHash() Hash {
            var h = Sha256.init(.{});
            h.update("bucketlist.profile.v1\x00");
            hashInt(u32, &h, depth);
            hashInt(u32, &h, 4);
            return h.finalResult();
        }

        pub fn root(self: *const Self) Hash {
            var h = Sha256.init(.{});
            h.update("bucketlist.list.v1\x00");
            h.update(&profileHash());
            for (self.levels, 0..) |level, i| {
                var lh = Sha256.init(.{});
                lh.update("bucketlist.level.v1\x00");
                hashInt(u32, &lh, @intCast(i));
                lh.update(&level.curr);
                lh.update(&level.snap);
                h.update(&lh.finalResult());
            }
            return h.finalResult();
        }

        pub fn continuationHash(self: *const Self) Hash {
            var h = Sha256.init(.{});
            h.update("bucketlist.continuation.v1\x00");
            h.update(&profileHash());
            for (self.levels, 0..) |level, i| {
                hashInt(u32, &h, @intCast(i));
                h.update(&.{@intFromBool(level.next != null)});
                if (level.next) |pending| h.update(&pending);
            }
            return h.finalResult();
        }

        pub fn commitment(self: *const Self, schema_hash: Hash) Commitment {
            const list_root = self.root();
            const continuation = self.continuationHash();
            var h = Sha256.init(.{});
            h.update("bucketlist.database.v1\x00");
            h.update(&schema_hash);
            h.update(&profileHash());
            hashInt(u64, &h, self.seq);
            h.update(&list_root);
            h.update(&continuation);
            return .{
                .advance = self.seq,
                .bucket_list_root = list_root,
                .continuation_hash = continuation,
                .digest = h.finalResult(),
            };
        }

        /// Checks only hash-visible shape. Restore must additionally verify
        /// canonical typed bucket contents, terminal tombstone exclusion,
        /// pending merge outputs, and the trusted database commitment.
        pub fn validateShape(self: *const Self) Error!void {
            for (self.levels, 0..) |level, i| {
                if ((self.seq == 0 or (i > 0 and self.seq < 2 * half(i - 1))) and
                    !std.mem.eql(u8, &level.curr, &empty_hash))
                    return error.InvalidTopology;
                if ((i == depth - 1 or self.seq < half(i)) and
                    !std.mem.eql(u8, &level.snap, &empty_hash))
                    return error.InvalidTopology;
                const has_pending = i != 0 and self.seq >= half(i - 1);
                if ((level.next != null) != has_pending) return error.InvalidTopology;
            }
        }

        /// Reconstructs the authenticated inputs of an existing pending
        /// output. The host recomputes it and compares against levels[i].next.
        pub fn pendingJob(self: *const Self, level: usize) ?Merge {
            std.debug.assert(level < depth);
            if (level == 0 or self.levels[level].next == null) return null;
            return .{
                .level = level,
                .older = if (mergeWithEmpty(self.seq, level)) empty_hash else self.levels[level].curr,
                .newer = self.levels[level - 1].snap,
                .drop_tombstones = level == depth - 1,
            };
        }

        fn half(level: usize) u64 {
            std.debug.assert(level < depth);
            return @as(u64, 1) << @as(u6, @intCast(2 * level + 1));
        }

        fn shouldSpill(sequence: u64, level: usize) bool {
            return level != depth - 1 and sequence % half(level) == 0;
        }

        fn mergeWithEmpty(sequence: u64, level: usize) bool {
            if (level == 0 or level == depth - 1) return false;
            return (sequence / half(level - 1)) % 4 == 3;
        }
    };
}

fn hashInt(comptime T: type, h: *Sha256, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    h.update(&bytes);
}
