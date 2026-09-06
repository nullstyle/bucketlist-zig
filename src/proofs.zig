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

/// Derive the tree root from `leaf` at `index` within `leaf_count` leaves
/// and the claimed sibling `path`, enforcing the exact side structure the
/// canonical peak reduction demands for that leaf count.
pub fn foldBlockPath(leaf: Hash, index: usize, leaf_count: usize, path: BlockPath) PathError!Hash {
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
    return self_hash;
}

/// Verify a derived root against a trusted one.
pub fn verifyBlockPath(leaf: Hash, index: usize, leaf_count: usize, path: BlockPath, root: Hash) PathError!void {
    const derived = try foldBlockPath(leaf, index, leaf_count, path);
    if (!std.mem.eql(u8, &root, &derived)) return error.InvalidPath;
}

/// One frontier level as carried in a proof: the committed current,
/// snapshot, and optional pending-output hashes.
pub const ChainLevel = struct {
    curr: Hash,
    snap: Hash,
    next: ?Hash = null,
};

const level_domain = "bucketlist.level.v1\x00";
const list_domain = "bucketlist.list.v1\x00";
const continuation_domain = "bucketlist.continuation.v1\x00";
const database_domain = "bucketlist.database.v1\x00";

/// Recompute the database commitment from carried level state. The chain
/// composition is identical for v1 and v2 profiles; the profile hash itself
/// distinguishes them. Parity-pinned against tools/v2-vectors.py.
pub fn chainCommitment(schema_hash: Hash, profile_hash: Hash, advance: u64, levels: []const ChainLevel) Hash {
    var list = Sha256.init(.{});
    list.update(list_domain);
    list.update(&profile_hash);
    var continuation = Sha256.init(.{});
    continuation.update(continuation_domain);
    continuation.update(&profile_hash);
    for (levels, 0..) |level, i| {
        var level_hash = Sha256.init(.{});
        level_hash.update(level_domain);
        hashInt(u32, &level_hash, @intCast(i));
        level_hash.update(&level.curr);
        level_hash.update(&level.snap);
        list.update(&level_hash.finalResult());
        hashInt(u32, &continuation, @intCast(i));
        continuation.update(&[1]u8{@intFromBool(level.next != null)});
        if (level.next) |pending| continuation.update(&pending);
    }
    var database = Sha256.init(.{});
    database.update(database_domain);
    database.update(&schema_hash);
    database.update(&profile_hash);
    hashInt(u64, &database, advance);
    database.update(&list.finalResult());
    database.update(&continuation.finalResult());
    return database.finalResult();
}

/// Hash one block: binds its position and exact bytes.
pub fn blockHash(index: u64, block_bytes: []const u8) Hash {
    var h = Sha256.init(.{});
    h.update(block_domain);
    hashInt(u64, &h, index);
    h.update(block_bytes);
    return h.finalResult();
}

/// The v2 bucket hash over its counted contents and block root.
pub fn bucketHash(record_count: u64, block_count: u64, block_root: Hash) Hash {
    var h = Sha256.init(.{});
    h.update(bucket_domain);
    hashInt(u64, &h, record_count);
    hashInt(u64, &h, block_count);
    h.update(&block_root);
    return h.finalResult();
}

/// One bucket's authenticated content and position: the block bytes, their
/// index and the bucket's counts, and the sibling path to the block root.
pub const BucketProof = struct {
    block: []const u8,
    block_index: u64,
    block_count: u64,
    record_count: u64,
    path: BlockPath,
};

/// A single-bucket membership proof: the claimed visible record inside one
/// block, that block's position in one bucket, and the frontier state that
/// binds the bucket into the committed digest. Verifying establishes the
/// record's presence and the frontier chain; proving that no younger level
/// shadows it additionally requires the absence composition of the next
/// stage, documented in format-v2.md.
pub const MembershipProof = struct {
    table: u32,
    key: []const u8,
    /// null claims a deletion marker.
    value: ?[]const u8,
    slot_level: usize,
    /// true places the bucket in the level's snapshot, false in its current.
    slot_snapshot: bool,
    schema_hash: Hash,
    profile_hash: Hash,
    advance: u64,
    levels: []const ChainLevel,
    bucket: BucketProof,
};

pub const ProofError = error{ InvalidProof, UnknownRecord };

/// Fully verify a membership proof against a trusted commitment digest.
pub fn verifyMembership(proof: *const MembershipProof, expected_digest: Hash) error{ InvalidProof, UnknownRecord }!void {
    const b = &proof.bucket;
    if (b.block_count == 0 or b.block_index >= b.block_count or proof.slot_level >= proof.levels.len)
        return error.InvalidProof;
    // The block must parse in canonical order and contain the target.
    var position: usize = 0;
    var found = false;
    var previous: ?[]const u8 = null;
    var previous_table: u32 = 0;
    while (position < b.block.len) {
        if (position + 8 > b.block.len) return error.InvalidProof;
        const table = std.mem.readInt(u32, b.block[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, b.block[position + 4 ..][0..4], .big);
        if (key_len > b.block.len or position + 8 + key_len > b.block.len) return error.InvalidProof;
        const key = b.block[position + 8 ..][0..key_len];
        position += 8 + key_len;
        if (position + 1 > b.block.len) return error.InvalidProof;
        const tag = b.block[position];
        position += 1;
        var value: ?[]const u8 = null;
        if (tag == 1) {
            if (position + 4 > b.block.len) return error.InvalidProof;
            const value_len = std.mem.readInt(u32, b.block[position..][0..4], .big);
            if (value_len > b.block.len or position + 4 + value_len > b.block.len) return error.InvalidProof;
            value = b.block[position + 4 ..][0..value_len];
            position += 4 + value_len;
        } else if (tag != 0) return error.InvalidProof;
        if (previous) |prev| {
            if (previous_table == table and std.mem.order(u8, prev, key) != .lt) return error.InvalidProof;
            if (previous_table > table) return error.InvalidProof;
        }
        previous = key;
        previous_table = table;
        if (table == proof.table and std.mem.eql(u8, key, proof.key)) {
            if (found) return error.InvalidProof;
            found = true;
            const has_value = value != null;
            if (has_value != (proof.value != null)) return error.UnknownRecord;
            if (proof.value) |claimed| {
                if (!std.mem.eql(u8, claimed, value.?)) return error.UnknownRecord;
            }
        }
    }
    if (position != b.block.len or !found) return error.UnknownRecord;
    try verifyPlacement(&proof.bucket, proof.slot_level, proof.slot_snapshot, proof.levels, proof.schema_hash, proof.profile_hash, proof.advance, expected_digest);
}

/// Block hash -> path -> root -> bucket hash -> claimed slot -> digest.
fn verifyPlacement(b: *const BucketProof, slot_level: usize, slot_snapshot: bool, levels: []const ChainLevel, schema_hash: Hash, profile_hash: Hash, advance: u64, expected_digest: Hash) error{InvalidProof}!void {
    if (slot_level >= levels.len) return error.InvalidProof;
    const leaf = blockHash(b.block_index, b.block);
    const root = foldBlockPath(leaf, @intCast(b.block_index), @intCast(b.block_count), b.path) catch return error.InvalidProof;
    const bucket = bucketHash(b.record_count, b.block_count, root);
    const slot_hash = if (slot_snapshot) &levels[slot_level].snap else &levels[slot_level].curr;
    if (!std.mem.eql(u8, slot_hash, &bucket)) return error.InvalidProof;
    const digest = chainCommitment(schema_hash, profile_hash, advance, levels);
    if (!std.mem.eql(u8, &digest, &expected_digest)) return error.InvalidProof;
}

/// A single-bucket absence proof: the key does not exist in this bucket.
/// The carried block must bracket the key -- strictly between two adjacent
/// records, before the first record of block zero, or after the last record
/// of the final block; anything else could hide the key in another block.
pub const AbsenceProof = struct {
    table: u32,
    key: []const u8,
    slot_level: usize,
    slot_snapshot: bool,
    schema_hash: Hash,
    profile_hash: Hash,
    advance: u64,
    levels: []const ChainLevel,
    bucket: BucketProof,
};

pub fn verifyAbsence(proof: *const AbsenceProof, expected_digest: Hash) error{ InvalidProof, PresentRecord }!void {
    const b = &proof.bucket;
    if (b.block_count == 0 or b.block_index >= b.block_count) return error.InvalidProof;
    var position: usize = 0;
    var before_first = true;
    var after_last = true;
    var previous_key: ?[]const u8 = null;
    var previous_table: u32 = 0;
    while (position < b.block.len) {
        if (position + 8 > b.block.len) return error.InvalidProof;
        const table = std.mem.readInt(u32, b.block[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, b.block[position + 4 ..][0..4], .big);
        if (key_len > b.block.len or position + 8 + key_len > b.block.len) return error.InvalidProof;
        const key = b.block[position + 8 ..][0..key_len];
        position += 8 + key_len;
        if (position + 1 > b.block.len) return error.InvalidProof;
        const tag = b.block[position];
        position += 1;
        if (tag == 1) {
            if (position + 4 > b.block.len) return error.InvalidProof;
            const value_len = std.mem.readInt(u32, b.block[position..][0..4], .big);
            if (value_len > b.block.len or position + 4 + value_len > b.block.len) return error.InvalidProof;
            position += 4 + value_len;
        } else if (tag != 0) return error.InvalidProof;
        if (previous_key) |prev| {
            if (previous_table == table and std.mem.order(u8, prev, key) != .lt) return error.InvalidProof;
            if (previous_table > table) return error.InvalidProof;
        }
        const order: std.math.Order = if (table != proof.table)
            (if (table < proof.table) .lt else .gt)
        else
            std.mem.order(u8, key, proof.key);
        switch (order) {
            .eq => return error.PresentRecord,
            // This record sorts after the target, so the target is not
            // after-everything; vice versa for .lt.
            .gt => after_last = false,
            .lt => before_first = false,
        }
        previous_key = key;
        previous_table = table;
    }
    if (position != b.block.len) return error.InvalidProof;
    // Between adjacent records is the default valid bracket. Sorting before
    // every record is valid only for block zero; after every record only
    // for the final block; otherwise the key could hide in another block.
    if (before_first and b.block_index != 0) return error.InvalidProof;
    if (after_last and b.block_index + 1 != b.block_count) return error.InvalidProof;
    try verifyPlacement(b, proof.slot_level, proof.slot_snapshot, proof.levels, proof.schema_hash, proof.profile_hash, proof.advance, expected_digest);
}

/// The v2 hash of a bucket with zero records: computable by any verifier,
/// so uncovered younger slots holding it need no absence proof.
pub fn emptyBucketHash() Hash {
    return bucketHash(0, 0, emptyLeaf());
}

fn slotOrdinal(slot_level: usize, slot_snapshot: bool) usize {
    return 2 * slot_level + @intFromBool(slot_snapshot);
}

/// A bucket's authenticated content placed in one frontier slot.
pub const SlotPlacement = struct {
    slot_level: usize,
    slot_snapshot: bool,
    bucket: BucketProof,
};

/// The composite proof for a key's visible state: every younger slot either
/// proves absence or is the computable empty bucket, and the deciding slot
/// proves the claimed membership or final absence. Slots are ordered
/// youngest-first (level ascending, current before snapshot), matching the
/// database's own lookup order.
pub const VisibleProof = struct {
    table: u32,
    key: []const u8,
    /// The claimed visible value; null with `absent` false claims a
    /// tombstone, null with `absent` true claims full absence.
    value: ?[]const u8,
    absent: bool,
    younger: []const SlotPlacement,
    deciding: SlotPlacement,
    schema_hash: Hash,
    profile_hash: Hash,
    advance: u64,
    levels: []const ChainLevel,
};

/// Parse a block and require the claimed record with its exact value class.
fn claimInBlock(block: []const u8, table: u32, key: []const u8, value: ?[]const u8) error{ InvalidProof, UnknownRecord }!void {
    var position: usize = 0;
    var found = false;
    var previous_key: ?[]const u8 = null;
    var previous_table: u32 = 0;
    while (position < block.len) {
        if (position + 8 > block.len) return error.InvalidProof;
        const record_table = std.mem.readInt(u32, block[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, block[position + 4 ..][0..4], .big);
        if (key_len > block.len or position + 8 + key_len > block.len) return error.InvalidProof;
        const record_key = block[position + 8 ..][0..key_len];
        position += 8 + key_len;
        if (position + 1 > block.len) return error.InvalidProof;
        const tag = block[position];
        position += 1;
        var record_value: ?[]const u8 = null;
        if (tag == 1) {
            if (position + 4 > block.len) return error.InvalidProof;
            const value_len = std.mem.readInt(u32, block[position..][0..4], .big);
            if (value_len > block.len or position + 4 + value_len > block.len) return error.InvalidProof;
            record_value = block[position + 4 ..][0..value_len];
            position += 4 + value_len;
        } else if (tag != 0) return error.InvalidProof;
        if (previous_key) |prev| {
            if (previous_table == record_table and std.mem.order(u8, prev, record_key) != .lt) return error.InvalidProof;
            if (previous_table > record_table) return error.InvalidProof;
        }
        previous_key = record_key;
        previous_table = record_table;
        if (record_table == table and std.mem.eql(u8, record_key, key)) {
            if (found) return error.InvalidProof;
            found = true;
            if ((record_value != null) != (value != null)) return error.UnknownRecord;
            if (value) |claimed| {
                if (!std.mem.eql(u8, claimed, record_value.?)) return error.UnknownRecord;
            }
        }
    }
    if (position != block.len or !found) return error.UnknownRecord;
}

/// Parse a block and require the key to be absent under the bracketing rule.
fn absentInBlock(b: *const BucketProof, table: u32, key: []const u8) error{ InvalidProof, PresentRecord }!void {
    var position: usize = 0;
    var before_first = true;
    var after_last = true;
    var previous_key: ?[]const u8 = null;
    var previous_table: u32 = 0;
    while (position < b.block.len) {
        if (position + 8 > b.block.len) return error.InvalidProof;
        const record_table = std.mem.readInt(u32, b.block[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, b.block[position + 4 ..][0..4], .big);
        if (key_len > b.block.len or position + 8 + key_len > b.block.len) return error.InvalidProof;
        const record_key = b.block[position + 8 ..][0..key_len];
        position += 8 + key_len;
        if (position + 1 > b.block.len) return error.InvalidProof;
        const tag = b.block[position];
        position += 1;
        if (tag == 1) {
            if (position + 4 > b.block.len) return error.InvalidProof;
            const value_len = std.mem.readInt(u32, b.block[position..][0..4], .big);
            if (value_len > b.block.len or position + 4 + value_len > b.block.len) return error.InvalidProof;
            position += 4 + value_len;
        } else if (tag != 0) return error.InvalidProof;
        if (previous_key) |prev| {
            if (previous_table == record_table and std.mem.order(u8, prev, record_key) != .lt) return error.InvalidProof;
            if (previous_table > record_table) return error.InvalidProof;
        }
        previous_key = record_key;
        previous_table = record_table;
        const order: std.math.Order = if (record_table != table)
            (if (record_table < table) .lt else .gt)
        else
            std.mem.order(u8, record_key, key);
        switch (order) {
            .eq => return error.PresentRecord,
            .gt => after_last = false,
            .lt => before_first = false,
        }
    }
    if (position != b.block.len) return error.InvalidProof;
    if (before_first and b.block_index != 0) return error.InvalidProof;
    if (after_last and b.block_index + 1 != b.block_count) return error.InvalidProof;
}

/// Verify the composite visible-state proof against one trusted digest.
pub fn verifyVisible(proof: *const VisibleProof, expected_digest: Hash) error{ InvalidProof, PresentRecord, UnknownRecord }!void {
    const deciding_ordinal = slotOrdinal(proof.deciding.slot_level, proof.deciding.slot_snapshot);
    if (proof.deciding.slot_level >= proof.levels.len) return error.InvalidProof;
    var previous: ?usize = null;
    for (proof.younger) |entry| {
        if (entry.slot_level >= proof.levels.len) return error.InvalidProof;
        const ordinal = slotOrdinal(entry.slot_level, entry.slot_snapshot);
        if ((previous != null and ordinal <= previous.?) or ordinal >= deciding_ordinal) return error.InvalidProof;
        previous = ordinal;
        try absentInBlock(&entry.bucket, proof.table, proof.key);
        try verifyPlacement(&entry.bucket, entry.slot_level, entry.slot_snapshot, proof.levels, proof.schema_hash, proof.profile_hash, proof.advance, expected_digest);
    }
    // Every slot strictly younger than the deciding one must be covered by
    // an absence entry or hold the computable empty-bucket hash.
    const empty = emptyBucketHash();
    for (proof.levels[0..proof.deciding.slot_level], 0..) |level, level_index| {
        for ([_]struct { hash: Hash, ordinal: usize }{
            .{ .hash = level.curr, .ordinal = slotOrdinal(level_index, false) },
            .{ .hash = level.snap, .ordinal = slotOrdinal(level_index, true) },
        }) |slot| {
            if (slot.ordinal >= deciding_ordinal) break;
            var covered = std.mem.eql(u8, &slot.hash, &empty);
            for (proof.younger) |entry| {
                if (slotOrdinal(entry.slot_level, entry.slot_snapshot) == slot.ordinal) covered = true;
            }
            if (!covered) return error.InvalidProof;
        }
    }
    if (proof.absent) {
        try absentInBlock(&proof.deciding.bucket, proof.table, proof.key);
    } else {
        try claimInBlock(proof.deciding.bucket.block, proof.table, proof.key, proof.value);
    }
    try verifyPlacement(&proof.deciding.bucket, proof.deciding.slot_level, proof.deciding.slot_snapshot, proof.levels, proof.schema_hash, proof.profile_hash, proof.advance, expected_digest);
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

test "chain commitment matches the independent model" {
    const schema: Hash = blk: {
        var digest: Hash = undefined;
        var schema_seed: [4]u8 = undefined;
        std.mem.writeInt(u32, &schema_seed, 900, .big);
        Sha256.hash(&schema_seed, &digest, .{});
        break :blk digest;
    };
    const profile: Hash = blk: {
        var digest: Hash = undefined;
        var profile_seed: [4]u8 = undefined;
        std.mem.writeInt(u32, &profile_seed, 901, .big);
        Sha256.hash(&profile_seed, &digest, .{});
        break :blk digest;
    };
    var levels: [11]ChainLevel = undefined;
    for (&levels, 0..) |*level, i| {
        var curr: Hash = undefined;
        var seed: [4]u8 = undefined;
        std.mem.writeInt(u32, &seed, 10 * @as(u32, @intCast(i)) + 1, .big);
        Sha256.hash(&seed, &curr, .{});
        var snap: Hash = undefined;
        std.mem.writeInt(u32, &seed, 10 * @as(u32, @intCast(i)) + 2, .big);
        Sha256.hash(&seed, &snap, .{});
        level.* = .{ .curr = curr, .snap = snap };
    }
    try expectLiteral(chainCommitment(schema, profile, 5, &levels), "0b055fabc93fb93fc2b89f6f5ae00c2f339ade44bbad48d064eb39dffce64d65");
    var pending: Hash = undefined;
    var pending_seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &pending_seed, 83, .big);
    Sha256.hash(&pending_seed, &pending, .{});
    for (&levels, 0..) |*level, i| {
        var curr: Hash = undefined;
        var seed: [4]u8 = undefined;
        std.mem.writeInt(u32, &seed, 20 * @as(u32, @intCast(i)) + 1, .big);
        Sha256.hash(&seed, &curr, .{});
        var snap: Hash = undefined;
        std.mem.writeInt(u32, &seed, 20 * @as(u32, @intCast(i)) + 2, .big);
        Sha256.hash(&seed, &snap, .{});
        level.* = .{ .curr = curr, .snap = snap, .next = if (i == 4) pending else null };
    }
    try expectLiteral(chainCommitment(schema, profile, 70, &levels), "2c409e9107d8614fc1bd34b99d705ef0791148ad67d20846f7580b13aafde554");
}

test "membership proof verifies and rejects every mutation class" {
    const gpa = testing.allocator;
    var block0: [42]u8 = undefined;
    var block1: [21]u8 = undefined;
    {
        var position: usize = 0;
        for (0..3) |i| {
            const target: []u8 = if (i < 2) block0[position..] else block1[position - 42 ..];
            std.mem.writeInt(u32, target[0..4], 1, .big);
            std.mem.writeInt(u32, target[4..8], 4, .big);
            std.mem.writeInt(u32, target[8..12], @intCast(2 * i), .big);
            target[12] = 1;
            std.mem.writeInt(u32, target[13..17], 4, .big);
            std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
            position += 21;
        }
    }
    const leaves = [_]Hash{ blockHash(0, &block0), blockHash(1, &block1) };
    var tree: BlockTree = .{};
    for (leaves) |leaf| tree.append(leaf);
    const root = tree.root();
    // Independent literal from tools/v2-vectors.py over this exact fixture.
    const bucket = bucketHash(3, 2, root);
    try expectLiteral(bucket, "adf7316823f6a0ffc11d3a406c7d22ecb81ca642b68c466f5b54108f5ef24c0d");
    var schema: Hash = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 900, .big);
    Sha256.hash(&seed, &schema, .{});
    const profile = profileHash(11, 42);
    var levels: [11]ChainLevel = undefined;
    for (&levels, 0..) |*level, i| {
        var hash: Hash = undefined;
        std.mem.writeInt(u32, &seed, @intCast(50 + i), .big);
        Sha256.hash(&seed, &hash, .{});
        level.* = .{ .curr = hash, .snap = hash };
    }
    levels[2].curr = bucket;
    const expected = chainCommitment(schema, profile, 9, &levels);
    const path = try blockPath(gpa, &leaves, 0);
    defer gpa.free(path.steps);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 2, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 1, .big);
    var proof = MembershipProof{
        .table = 1,
        .key = &key,
        .value = &value,
        .slot_level = 2,
        .slot_snapshot = false,
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 9,
        .levels = &levels,
        .bucket = .{ .block = &block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = path },
    };
    try verifyMembership(&proof, expected);
    // Claim mutations.
    var wrong_value = value;
    wrong_value[0] ^= 0xff;
    proof.value = &wrong_value;
    try testing.expectError(error.UnknownRecord, verifyMembership(&proof, expected));
    proof.value = &value;
    proof.value = null;
    try testing.expectError(error.UnknownRecord, verifyMembership(&proof, expected));
    proof.value = &value;
    var absent_key: [4]u8 = undefined;
    std.mem.writeInt(u32, &absent_key, 6, .big);
    proof.key = &absent_key;
    try testing.expectError(error.UnknownRecord, verifyMembership(&proof, expected));
    proof.key = &key;
    // Structure mutations.
    proof.bucket.block_index = 1;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.bucket.block_index = 0;
    proof.bucket.record_count = 4;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.bucket.record_count = 3;
    proof.bucket.block_count = 3;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.bucket.block_count = 2;
    proof.slot_snapshot = true;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.slot_snapshot = false;
    proof.slot_level = 3;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.slot_level = 2;
    var tampered_levels = levels;
    tampered_levels[5].curr[0] ^= 0xff;
    proof.levels = &tampered_levels;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.levels = &levels;
    proof.advance = 10;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.advance = 9;
    var tampered_step = try gpa.dupe(BlockPath.Step, path.steps);
    defer gpa.free(tampered_step);
    tampered_step[0].hash[0] ^= 0xff;
    proof.bucket.path = .{ .steps = tampered_step };
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    proof.bucket.path = path;
    var wrong_digest = expected;
    wrong_digest[0] ^= 0xff;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, wrong_digest));
    // Mutating another record's bytes leaves the claim intact but breaks
    // the block hash; mutating the claimed record's value breaks the claim.
    var tampered_block = block0;
    tampered_block[17] ^= 0xff;
    proof.bucket.block = &tampered_block;
    try testing.expectError(error.InvalidProof, verifyMembership(&proof, expected));
    tampered_block[17] ^= 0xff;
    tampered_block[21 + 17] ^= 0xff;
    proof.bucket.block = &tampered_block;
    try testing.expectError(error.UnknownRecord, verifyMembership(&proof, expected));
}

test "absence proof brackets the key and rejects boundary lies" {
    const gpa = testing.allocator;
    var block0: [42]u8 = undefined;
    var block1: [21]u8 = undefined;
    {
        var position: usize = 0;
        for (0..3) |i| {
            const target: []u8 = if (i < 2) block0[position..] else block1[position - 42 ..];
            std.mem.writeInt(u32, target[0..4], 1, .big);
            std.mem.writeInt(u32, target[4..8], 4, .big);
            std.mem.writeInt(u32, target[8..12], @intCast(2 * i), .big);
            target[12] = 1;
            std.mem.writeInt(u32, target[13..17], 4, .big);
            std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
            position += 21;
        }
    }
    const leaves = [_]Hash{ blockHash(0, &block0), blockHash(1, &block1) };
    const root = combine(leaves[0], leaves[1]);
    const bucket = bucketHash(3, 2, root);
    var schema: Hash = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 900, .big);
    Sha256.hash(&seed, &schema, .{});
    const profile = profileHash(11, 42);
    var levels: [11]ChainLevel = undefined;
    for (&levels, 0..) |*level, i| {
        var hash: Hash = undefined;
        std.mem.writeInt(u32, &seed, @intCast(50 + i), .big);
        Sha256.hash(&seed, &hash, .{});
        level.* = .{ .curr = hash, .snap = hash };
    }
    levels[2].snap = bucket;
    const expected = chainCommitment(schema, profile, 9, &levels);
    const path0 = try blockPath(gpa, &leaves, 0);
    defer gpa.free(path0.steps);
    const path1 = try blockPath(gpa, &leaves, 1);
    defer gpa.free(path1.steps);
    // Key 1 sits strictly between block zero's records (keys 0 and 2).
    var between: [4]u8 = undefined;
    std.mem.writeInt(u32, &between, 1, .big);
    var proof = AbsenceProof{
        .table = 1,
        .key = &between,
        .slot_level = 2,
        .slot_snapshot = true,
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 9,
        .levels = &levels,
        .bucket = .{ .block = &block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = path0 },
    };
    try verifyAbsence(&proof, expected);
    // A present key cannot be proven absent.
    var present: [4]u8 = undefined;
    std.mem.writeInt(u32, &present, 2, .big);
    proof.key = &present;
    try testing.expectError(error.PresentRecord, verifyAbsence(&proof, expected));
    // Key 5 sorts after block one's last record (final block): absent.
    var beyond: [4]u8 = undefined;
    std.mem.writeInt(u32, &beyond, 5, .big);
    proof.key = &beyond;
    proof.bucket = .{ .block = &block1, .block_index = 1, .block_count = 2, .record_count = 3, .path = path1 };
    try verifyAbsence(&proof, expected);
    // The same after-last key via block ZERO (not the final block) is a
    // boundary lie: the key could hide in block one.
    proof.bucket = .{ .block = &block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = path0 };
    try testing.expectError(error.InvalidProof, verifyAbsence(&proof, expected));
    // Before-first is valid only in block zero; via block one it is a lie.
    var before: [4]u8 = undefined;
    std.mem.writeInt(u32, &before, 3, .big);
    proof.key = &before;
    proof.bucket = .{ .block = &block1, .block_index = 1, .block_count = 2, .record_count = 3, .path = path1 };
    try testing.expectError(error.InvalidProof, verifyAbsence(&proof, expected));
    // Placement and digest forgeries still fail.
    proof.key = &between;
    proof.bucket = .{ .block = &block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = path0 };
    proof.advance = 10;
    try testing.expectError(error.InvalidProof, verifyAbsence(&proof, expected));
    proof.advance = 9;
    var wrong_digest = expected;
    wrong_digest[0] ^= 0xff;
    try testing.expectError(error.InvalidProof, verifyAbsence(&proof, wrong_digest));
}

test "visible proof composes absence, membership, and the empty-slot rule" {
    // Deciding bucket: keys 0,2 (two blocks at target 42). Younger bucket:
    // key 8 (one block). The proven key 1 is bracketed in the deciding one.
    var deciding_block0: [42]u8 = undefined;
    var deciding_block1: [21]u8 = undefined;
    var younger_block: [21]u8 = undefined;
    {
        var position: usize = 0;
        for (0..3) |i| {
            const target: []u8 = if (i < 2) deciding_block0[position..] else deciding_block1[position - 42 ..];
            std.mem.writeInt(u32, target[0..4], 1, .big);
            std.mem.writeInt(u32, target[4..8], 4, .big);
            std.mem.writeInt(u32, target[8..12], @intCast(i), .big);
            target[12] = 1;
            std.mem.writeInt(u32, target[13..17], 4, .big);
            std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
            position += 21;
        }
        std.mem.writeInt(u32, younger_block[0..4], 1, .big);
        std.mem.writeInt(u32, younger_block[4..8], 4, .big);
        std.mem.writeInt(u32, younger_block[8..12], 8, .big);
        younger_block[12] = 1;
        std.mem.writeInt(u32, younger_block[13..17], 4, .big);
        std.mem.writeInt(u32, younger_block[17..21], 8, .big);
    }
    const deciding_leaves = [_]Hash{ blockHash(0, &deciding_block0), blockHash(1, &deciding_block1) };
    const deciding_path = try blockPath(std.heap.page_allocator, &deciding_leaves, 0);
    defer std.heap.page_allocator.free(deciding_path.steps);
    const deciding_bucket = bucketHash(3, 2, combine(deciding_leaves[0], deciding_leaves[1]));
    const younger_bucket = bucketHash(1, 1, blockHash(0, &younger_block));
    var schema: Hash = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 900, .big);
    Sha256.hash(&seed, &schema, .{});
    const profile = profileHash(11, 42);
    var levels: [11]ChainLevel = undefined;
    const empty = emptyBucketHash();
    for (&levels, 0..) |*level, i| {
        var hash: Hash = undefined;
        std.mem.writeInt(u32, &seed, @intCast(70 + i), .big);
        Sha256.hash(&seed, &hash, .{});
        // Uncovered younger slots (everything before the deciding slot)
        // must hold the empty-bucket hash or carry an absence entry.
        const young = i < 3;
        level.* = .{
            .curr = if (i == 0) younger_bucket else if (i == 3) deciding_bucket else if (young) empty else hash,
            .snap = if (young) empty else hash,
        };
    }
    const expected = chainCommitment(schema, profile, 11, &levels);
    const no_steps: []const BlockPath.Step = &.{};
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 1, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 1, .big);
    const younger_entry: SlotPlacement = .{
        .slot_level = 0,
        .slot_snapshot = false,
        .bucket = .{ .block = &younger_block, .block_index = 0, .block_count = 1, .record_count = 1, .path = .{ .steps = no_steps } },
    };
    var proof = VisibleProof{
        .table = 1,
        .key = &key,
        .value = &value,
        .absent = false,
        .younger = &.{younger_entry},
        .deciding = .{
            .slot_level = 3,
            .slot_snapshot = false,
            .bucket = .{ .block = &deciding_block0, .block_index = 0, .block_count = 2, .record_count = 3, .path = deciding_path },
        },
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 11,
        .levels = &levels,
    };
    try verifyVisible(&proof, expected);
    // Dropping the younger absence entry opens an uncovered non-empty slot.
    proof.younger = &.{};
    try testing.expectError(error.InvalidProof, verifyVisible(&proof, expected));
    proof.younger = &.{younger_entry};
    // An out-of-order or later-slot entry is rejected.
    const misordered: SlotPlacement = .{ .slot_level = 3, .slot_snapshot = false, .bucket = younger_entry.bucket };
    proof.younger = &.{misordered};
    try testing.expectError(error.InvalidProof, verifyVisible(&proof, expected));
    proof.younger = &.{younger_entry};
    // If the younger bucket contained the key, its absence proof fails.
    var young_hold: [21]u8 = younger_block;
    std.mem.writeInt(u32, young_hold[8..12], 1, .big);
    var young_levels = levels;
    const hold_leaf = blockHash(0, &young_hold);
    young_levels[0].curr = bucketHash(1, 1, hold_leaf);
    proof.levels = &young_levels;
    proof.deciding.bucket.block = &deciding_block0;
    const hold_expected = chainCommitment(schema, profile, 11, &young_levels);
    var young_proof = proof;
    young_proof.younger = &.{.{ .slot_level = 0, .slot_snapshot = false, .bucket = .{ .block = &young_hold, .block_index = 0, .block_count = 1, .record_count = 1, .path = .{ .steps = no_steps } } }};
    try testing.expectError(error.PresentRecord, verifyVisible(&young_proof, hold_expected));
    proof.levels = &levels;
    // Claiming absence when the deciding bucket holds the record.
    proof.absent = true;
    try testing.expectError(error.PresentRecord, verifyVisible(&proof, expected));
    proof.absent = false;
    // Digest forgery.
    var wrong = expected;
    wrong[0] ^= 0xff;
    try testing.expectError(error.InvalidProof, verifyVisible(&proof, wrong));
}
