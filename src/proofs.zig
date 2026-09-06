//! Version-two block hashing primitives. Normative bytes: docs/format-v2.md.
//! Dependency-free pure computation; profiles gate these hashes, v1 is
//! untouched. Stage 2 adds proof structures on these foundations.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const block_domain = "bucketlist.block.v2\x00";
pub const node_domain = "bucketlist.blocknode.v2\x00";
pub const empty_domain = "bucketlist.block.v2.empty\x00";
pub const bucket_domain = "bucketlist.bucket.v2\x00";
pub const profile_domain = "bucketlist.profile.v2\x00";

pub const Hash = [32]u8;
pub const default_target_block_bytes: u32 = 65536;

pub fn emptyLeaf() Hash {
    var digest: Hash = undefined;
    Sha256.hash(empty_domain, &digest, .{});
    return digest;
}

pub fn profileHash(depth: u32, target_block_bytes: u32) Hash {
    var h = Sha256.init(.{});
    h.update(profile_domain);
    hashInt(u32, &h, depth);
    hashInt(u32, &h, 4);
    hashInt(u32, &h, target_block_bytes);
    return h.finalResult();
}

pub fn combine(left: Hash, right: Hash) Hash {
    var h = Sha256.init(.{});
    h.update(node_domain);
    h.update(&left);
    h.update(&right);
    return h.finalResult();
}

/// Incremental block-tree reduction: a rightmost peak of span 1 is appended
/// per leaf and merges with an equal-span right neighbor while possible; the
/// final root folds the remaining peaks left-to-right. Equivalent to the
/// balanced binary Merkle tree when the leaf count is a power of two, with
/// the binary decomposition of the count otherwise. O(log n) state.
pub const BlockTree = struct {
    const Node = struct { span: u64, hash: Hash };
    const max_peaks = 64;

    peaks: [max_peaks]Node = undefined,
    count: usize = 0,
    leaves: u64 = 0,

    pub fn append(self: *BlockTree, leaf: Hash) void {
        std.debug.assert(self.count < max_peaks);
        self.peaks[self.count] = .{ .span = 1, .hash = leaf };
        self.count += 1;
        self.leaves += 1;
        while (self.count >= 2) {
            const left = self.peaks[self.count - 2];
            const right = self.peaks[self.count - 1];
            if (left.span != right.span) break;
            self.peaks[self.count - 2] = .{ .span = left.span * 2, .hash = combine(left.hash, right.hash) };
            self.count -= 1;
        }
    }

    pub fn leafCount(self: *const BlockTree) u64 {
        return self.leaves;
    }

    pub fn root(self: *const BlockTree) Hash {
        std.debug.assert(self.leaves > 0);
        var acc = self.peaks[0].hash;
        for (self.peaks[1..self.count]) |peak| acc = combine(acc, peak.hash);
        return acc;
    }
};

/// Streams framed records into blocks under the greedy byte rule and reduces
/// block hashes to the v2 bucket hash. Records must arrive in canonical
/// order; framing is the caller's responsibility to validate.
pub const BucketHasher = struct {
    target: u32,
    tree: BlockTree = .{},
    block: Sha256 = Sha256.init(.{}),
    block_index: u64 = 0,
    block_bytes: u64 = 0,
    record_count: u64 = 0,
    block_open: bool = false,

    pub fn init(target_block_bytes: u32) BucketHasher {
        std.debug.assert(target_block_bytes > 0);
        return .{ .target = target_block_bytes };
    }

    pub fn appendRecord(self: *BucketHasher, table: u32, key: []const u8, value: ?[]const u8) void {
        if (!self.block_open) self.openBlock();
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], table, .big);
        std.mem.writeInt(u32, header[4..8], @intCast(key.len), .big);
        self.block.update(&header);
        self.block.update(key);
        self.block.update(&[1]u8{if (value == null) 0 else 1});
        if (value) |bytes| {
            var length: [4]u8 = undefined;
            std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
            self.block.update(&length);
            self.block.update(bytes);
            self.block_bytes += 13 + key.len + bytes.len;
        } else {
            self.block_bytes += 9 + key.len;
        }
        self.record_count += 1;
        if (self.block_bytes >= self.target) self.closeBlock();
    }

    pub fn recordCount(self: *const BucketHasher) u64 {
        return self.record_count;
    }
    pub fn blockCount(self: *const BucketHasher) u64 {
        return self.tree.leafCount() + @intFromBool(self.block_open);
    }

    pub fn final(self: *BucketHasher) Hash {
        if (self.block_open) self.closeBlock();
        const block_count = self.tree.leafCount();
        const block_root = if (block_count == 0) emptyLeaf() else self.tree.root();
        var h = Sha256.init(.{});
        h.update(bucket_domain);
        hashInt(u64, &h, self.record_count);
        hashInt(u64, &h, block_count);
        h.update(&block_root);
        return h.finalResult();
    }

    fn openBlock(self: *BucketHasher) void {
        self.block = Sha256.init(.{});
        self.block.update(block_domain);
        var index: [8]u8 = undefined;
        std.mem.writeInt(u64, &index, self.block_index, .big);
        self.block.update(&index);
        self.block_bytes = 0;
        self.block_open = true;
    }

    fn closeBlock(self: *BucketHasher) void {
        var leaf: Hash = undefined;
        self.block.final(&leaf);
        self.tree.append(leaf);
        self.block_index += 1;
        self.block_open = false;
    }
};

/// One sibling hop from a block leaf toward the tree root. Siblings cover
/// the balanced path inside the leaf's own peak, then the left fold of all
/// earlier peaks (one step, if any), then every later peak, right side.
pub const BlockPath = struct {
    pub const Step = struct { hash: Hash, right: bool };
    steps: []const Step,
};

/// Extract the sibling path for leaf `index` from the ordered leaf list
/// under the canonical peak reduction (equal-span merging with a final
/// left-to-right fold of the peaks). Caller owns the steps allocation.
pub fn blockPath(gpa: std.mem.Allocator, leaves: []const Hash, index: usize) error{ OutOfMemory, IndexOutOfBounds }!BlockPath {
    if (index >= leaves.len) return error.IndexOutOfBounds;
    const Peak = struct { span: u64, hash: Hash };
    var peaks: [64]Peak = undefined;
    var count: usize = 0;
    var ours: ?usize = null;
    var steps: std.ArrayList(BlockPath.Step) = .empty;
    errdefer steps.deinit(gpa);
    for (leaves, 0..) |leaf, i| {
        peaks[count] = .{ .span = 1, .hash = leaf };
        if (i == index) ours = count;
        count += 1;
        while (count >= 2) {
            const left = peaks[count - 2];
            const right = peaks[count - 1];
            if (left.span != right.span) break;
            if (ours != null and ours.? == count - 1) {
                try steps.append(gpa, .{ .hash = left.hash, .right = false });
                ours = count - 2;
            } else if (ours != null and ours.? == count - 2) {
                try steps.append(gpa, .{ .hash = right.hash, .right = true });
            }
            peaks[count - 2] = .{ .span = left.span * 2, .hash = combine(left.hash, right.hash) };
            count -= 1;
        }
    }
    const slot = ours orelse return error.IndexOutOfBounds;
    if (slot > 0) {
        var acc = peaks[0].hash;
        for (peaks[1..slot]) |peak| acc = combine(acc, peak.hash);
        try steps.append(gpa, .{ .hash = acc, .right = false });
    }
    for (peaks[slot + 1 .. count]) |peak| {
        try steps.append(gpa, .{ .hash = peak.hash, .right = true });
    }
    return .{ .steps = try steps.toOwnedSlice(gpa) };
}

pub const PathError = error{InvalidPath};

/// Verify that `leaf` at `index` within `leaf_count` leaves reaches `root`
/// through exactly the siblings `path` claims, with the side and structure
/// the canonical peak reduction demands for that leaf count.
pub fn verifyBlockPath(leaf: Hash, index: usize, leaf_count: usize, path: BlockPath, root: Hash) PathError!void {
    if (leaf_count == 0 or index >= leaf_count) return error.InvalidPath;
    // Reconstruct the peak shape: binary decomposition of leaf_count,
    // spans largest first.
    var peak_count: usize = 0;
    var offset: u64 = 0;
    var local: u64 = 0;
    var ours: usize = 0;
    var span: u64 = 0;
    var slot: u6 = 63;
    while (true) : (slot -= 1) {
        const bit = @as(u64, 1) << slot;
        if (leaf_count & bit != 0) {
            if (span == 0) {
                if (index < offset + bit) {
                    local = index - offset;
                    ours = peak_count;
                    span = bit;
                } else offset += bit;
            }
            peak_count += 1;
        }
        if (slot == 0) break;
    }
    if (span == 0) return error.InvalidPath;
    var self_hash = leaf;
    var step: usize = 0;
    const balanced: u6 = @intCast(@ctz(span));
    var level: u6 = 0;
    while (level < balanced) : (level += 1) {
        if (step >= path.steps.len) return error.InvalidPath;
        const hop = path.steps[step];
        const right = (local >> @intCast(level)) & 1 == 0;
        if (hop.right != right) return error.InvalidPath;
        self_hash = if (right) combine(self_hash, hop.hash) else combine(hop.hash, self_hash);
        step += 1;
    }
    if (ours > 0) {
        if (step >= path.steps.len) return error.InvalidPath;
        if (path.steps[step].right) return error.InvalidPath;
        self_hash = combine(path.steps[step].hash, self_hash);
        step += 1;
    }
    var later: usize = ours + 1;
    while (later < peak_count) : (later += 1) {
        if (step >= path.steps.len) return error.InvalidPath;
        if (!path.steps[step].right) return error.InvalidPath;
        self_hash = combine(self_hash, path.steps[step].hash);
        step += 1;
    }
    if (step != path.steps.len) return error.InvalidPath;
    if (!std.mem.eql(u8, &root, &self_hash)) return error.InvalidPath;
}

fn hashInt(comptime T: type, h: *Sha256, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    h.update(&bytes);
}

const testing = std.testing;

fn expectLiteral(digest: Hash, hex: []const u8) !void {
    var expected: Hash = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try testing.expectEqualSlices(u8, &expected, &digest);
}

fn stream(count: usize, parity: u8, target: u32) Hash {
    var hasher = BucketHasher.init(target);
    for (0..count) |i| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @as(u32, @intCast(i)) * 2 + parity, .big);
        var value: [4]u8 = undefined;
        std.mem.writeInt(u32, &value, @as(u32, @intCast(i)), .big);
        hasher.appendRecord(1, &key, &value);
    }
    return hasher.final();
}

// Literals below were produced by the independent model in
// tools/v2-vectors.py; regenerate there, never here.
test "v2 bucket hashes match the independent model" {
    try expectLiteral(stream(0, 0, 128), "013dce769819e34e82bcbccd3d2d3f24dfbddd1d99f3f2647a99465105d78952");
    try expectLiteral(stream(1, 0, 128), "e7a69a24d8e0a471ed9a3cd4bbffcc64417add136dc50cbcca4e5b412a73fc55");
    try expectLiteral(stream(7, 0, 128), "44f67a04b9d07e3f940104cfdf17453c2f0f4df39d31525625e9c093df330677");
    try expectLiteral(stream(8, 0, 128), "05cdb008aa260d44263f694d683da3b43c90d6f5cde6a00c4347f9a492685447");
    try expectLiteral(stream(100, 0, 128), "d4831204d0136b08e5eff62e17aa6f8dc223ece70e5abc3f14e4a0973293dad2");
    try expectLiteral(stream(100, 1, 128), "f18694bc15c7a8016edf1bdc39d6c5d9765dce9e40221b9da9d1e141095827bf");
    try expectLiteral(stream(100, 0, 21), "8ba2e8bd1222221a29c87dba7b0604419f14786bf43f4cffb04cb4a7adc62e75");
    try expectLiteral(stream(1000, 0, 65536), "284d8b641d58e04abffcb5271bbe8524a116d62345d1e0fb3b253f9fe5d0695c");
}

test "v2 blocking follows the greedy byte rule" {
    // One oversized record closes its own block; boundaries are byte-driven.
    var hasher = BucketHasher.init(21);
    hasher.appendRecord(1, "k", "0123456789abcdefghijklm"); // 23 framing bytes
    try testing.expectEqual(@as(u64, 1), hasher.blockCount());
    hasher.appendRecord(1, "l", "v"); // 11 bytes: stays open below target 21
    try testing.expectEqual(@as(u64, 2), hasher.blockCount());
    _ = hasher.final();
    // The same oversized record reaches the target immediately in a tight
    // hasher and only closes at final() in a loose one; both must agree.
    var tight = BucketHasher.init(21);
    tight.appendRecord(1, "k", "0123456789abcdefghijklm");
    var loose = BucketHasher.init(128);
    loose.appendRecord(1, "k", "0123456789abcdefghijklm");
    try testing.expectEqualSlices(u8, &tight.final(), &loose.final());
    // A different target changes block boundaries and therefore the hash.
    try testing.expect(!std.mem.eql(u8, &stream(100, 0, 128), &stream(100, 0, 21)));
}

test "v2 profile hash binds depth, factor, and block target" {
    const a = profileHash(11, default_target_block_bytes);
    try testing.expect(a[0] != 0);
    try testing.expect(!std.mem.eql(u8, &a, &profileHash(10, default_target_block_bytes)));
    try testing.expect(!std.mem.eql(u8, &a, &profileHash(11, 65535)));
}

test "v2 block tree matches the balanced tree at powers of two" {
    var leaves: [8]Hash = undefined;
    for (&leaves, 0..) |*leaf, i| {
        leaf.* = @splat(@intCast(i));
    }
    var tree: BlockTree = .{};
    for (leaves) |leaf| tree.append(leaf);
    const level1 = [4]Hash{
        combine(leaves[0], leaves[1]),
        combine(leaves[2], leaves[3]),
        combine(leaves[4], leaves[5]),
        combine(leaves[6], leaves[7]),
    };
    const level2 = [2]Hash{
        combine(level1[0], level1[1]),
        combine(level1[2], level1[3]),
    };
    try testing.expectEqualSlices(u8, &combine(level2[0], level2[1]), &tree.root());
}
test "block paths verify and reject every mutation class" {
    const gpa = testing.allocator;
    for ([_]usize{ 1, 2, 3, 7, 8, 100 }) |count| {
        var leaves: [100]Hash = undefined;
        for (&leaves, 0..) |*leaf, i| {
            var source: Hash = undefined;
            Sha256.hash(std.mem.asBytes(&[_]usize{ count, i }), &source, .{});
            leaf.* = source;
        }
        var tree: BlockTree = .{};
        for (leaves[0..count]) |leaf| tree.append(leaf);
        const root = tree.root();
        for (0..count) |index| {
            const path = try blockPath(gpa, leaves[0..count], index);
            defer gpa.free(path.steps);
            try verifyBlockPath(leaves[index], index, count, path, root);
            // Wrong index, flipped side, bad sibling, extra step, and wrong
            // root must all fail. Leaf counts whose shape still admits this
            // path (3 vs 4 at an early index) are disambiguated one level
            // up: the bucket hash binds block_count. The last leaf's tail
            // shape differs under count+1, so it must fail here.
            if (count > 1) {
                try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], (index + 1) % count, count, path, root));
                if (index == count - 1) {
                    try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], index, count + 1, path, root));
                }
                var flipped = try gpa.dupe(BlockPath.Step, path.steps);
                defer gpa.free(flipped);
                flipped[0].right = !flipped[0].right;
                try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], index, count, .{ .steps = flipped }, root));
                flipped[0].right = !flipped[0].right;
                flipped[0].hash[0] ^= 0xff;
                try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], index, count, .{ .steps = flipped }, root));
            }
            var bad_root = root;
            bad_root[0] ^= 0xff;
            try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], index, count, path, bad_root));
            if (path.steps.len > 0) {
                const longer = try gpa.alloc(BlockPath.Step, path.steps.len + 1);
                defer gpa.free(longer);
                @memcpy(longer[0..path.steps.len], path.steps);
                longer[path.steps.len] = path.steps[path.steps.len - 1];
                try testing.expectError(error.InvalidPath, verifyBlockPath(leaves[index], index, count, .{ .steps = longer }, root));
            }
        }
    }
}
