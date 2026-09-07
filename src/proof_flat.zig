//! Flat self-delimiting framing for v2 proof messages (the wasm verifier's
//! transport). One linear buffer per proof: magic, u32be/u64be counts, and
//! u32be-length-prefixed byte fields, big-endian throughout. Decoding
//! borrows nothing from the wire and takes an explicit allocator, so a
//! freestanding verifier can decode into a fixed buffer allocator over
//! static memory; every decoded count is bounded by the remaining input
//! before any allocation. The hashed bucket bytes never use this format;
//! capnp remains the process-boundary transport, this is the minimal
//! artifact encoding. Layouts are specified in docs/format-v2.md.
const std = @import("std");
const proofs = @import("proofs.zig");

pub const visible_magic = "BKLFVIS1";
pub const range_magic = "BKLFRNG1";
pub const Error = error{ BadFlat, OutOfMemory };

fn appendInt(comptime T: type, out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: T) Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try out.appendSlice(gpa, &bytes);
}

fn appendBytes(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) Error!void {
    try appendInt(u32, out, gpa, @intCast(bytes.len));
    try out.appendSlice(gpa, bytes);
}

fn appendHash(out: *std.ArrayList(u8), gpa: std.mem.Allocator, hash: [32]u8) Error!void {
    try out.appendSlice(gpa, &hash);
}

fn appendSteps(out: *std.ArrayList(u8), gpa: std.mem.Allocator, steps: []const proofs.BlockPath.Step) Error!void {
    try appendInt(u32, out, gpa, @intCast(steps.len));
    for (steps) |step| {
        try out.append(gpa, @intFromBool(step.right));
        try appendHash(out, gpa, step.hash);
    }
}

fn appendLevels(out: *std.ArrayList(u8), gpa: std.mem.Allocator, levels: []const proofs.ChainLevel) Error!void {
    try appendInt(u32, out, gpa, @intCast(levels.len));
    for (levels) |level| {
        try appendHash(out, gpa, level.curr);
        try appendHash(out, gpa, level.snap);
        try out.append(gpa, @intFromBool(level.next != null));
        if (level.next) |pending| try appendHash(out, gpa, pending);
    }
}

/// Serialize a visible-state proof; the caller owns the returned buffer.
pub fn encodeVisible(gpa: std.mem.Allocator, proof: *const proofs.VisibleProof) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, visible_magic);
    try appendInt(u32, &out, gpa, proof.table);
    try appendBytes(&out, gpa, proof.key);
    if (proof.value) |value| {
        try out.append(gpa, 1);
        try appendBytes(&out, gpa, value);
    } else try out.append(gpa, 0);
    try out.append(gpa, @intFromBool(proof.absent));
    try appendInt(u32, &out, gpa, @intCast(proof.younger.len));
    for (proof.younger) |entry| try appendPlacement(&out, gpa, entry);
    try appendPlacement(&out, gpa, proof.deciding);
    try appendHash(&out, gpa, proof.schema_hash);
    try appendHash(&out, gpa, proof.profile_hash);
    try appendInt(u64, &out, gpa, proof.advance);
    try appendLevels(&out, gpa, proof.levels);
    return out.toOwnedSlice(gpa);
}

fn appendPlacement(out: *std.ArrayList(u8), gpa: std.mem.Allocator, entry: proofs.SlotPlacement) Error!void {
    try appendInt(u32, out, gpa, @intCast(entry.slot_level));
    try out.append(gpa, @intFromBool(entry.slot_snapshot));
    try appendBytes(out, gpa, entry.bucket.block);
    try appendInt(u64, out, gpa, entry.bucket.block_index);
    try appendInt(u64, out, gpa, entry.bucket.block_count);
    try appendInt(u64, out, gpa, entry.bucket.record_count);
    try appendSteps(out, gpa, entry.bucket.path.steps);
}

/// Serialize a range proof; the caller owns the returned buffer.
pub fn encodeRange(gpa: std.mem.Allocator, proof: *const proofs.RangeProof) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, range_magic);
    try appendInt(u32, &out, gpa, proof.table);
    try appendBytes(&out, gpa, proof.start);
    try appendBytes(&out, gpa, proof.end);
    try appendInt(u32, &out, gpa, @intCast(proof.entries.len));
    for (proof.entries) |entry| {
        try appendBytes(&out, gpa, entry.key);
        try appendBytes(&out, gpa, entry.value);
    }
    try appendInt(u32, &out, gpa, @intCast(proof.runs.len));
    for (proof.runs) |run| {
        try appendInt(u32, &out, gpa, @intCast(run.slot_level));
        try out.append(gpa, @intFromBool(run.slot_snapshot));
        try appendInt(u64, &out, gpa, run.block_count);
        try appendInt(u64, &out, gpa, run.record_count);
        try appendInt(u32, &out, gpa, @intCast(run.blocks.len));
        for (run.blocks) |*range_block| {
            try appendBytes(&out, gpa, range_block.block);
            try appendInt(u64, &out, gpa, range_block.block_index);
            try appendSteps(&out, gpa, range_block.path.steps);
        }
    }
    try appendHash(&out, gpa, proof.schema_hash);
    try appendHash(&out, gpa, proof.profile_hash);
    try appendInt(u64, &out, gpa, proof.advance);
    try appendLevels(&out, gpa, proof.levels);
    return out.toOwnedSlice(gpa);
}

/// Bounds-checked cursor over one flat buffer. Every take() verifies the
/// remaining input first, so declared counts are charged against bytes that
/// must actually be present before decoding allocates for them.
const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(self: *Cursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.position) return error.BadFlat;
        const out = self.bytes[self.position..][0..len];
        self.position += len;
        return out;
    }
    fn int(self: *Cursor, comptime T: type) Error!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .big);
    }
    fn hash(self: *Cursor) Error![32]u8 {
        const raw = try self.take(32);
        return raw[0..32].*;
    }
    fn count(self: *Cursor) Error!usize {
        return @intCast(try self.int(u32));
    }
    fn byte(self: *Cursor) Error!u8 {
        const raw = try self.take(1);
        return raw[0];
    }
    fn done(self: *const Cursor) Error!void {
        if (self.position != self.bytes.len) return error.BadFlat;
    }
};

fn decodeSteps(arena: std.mem.Allocator, cursor: *Cursor) Error!proofs.BlockPath {
    const count = try cursor.count();
    const raw = try cursor.take(count * 33);
    const steps = try arena.alloc(proofs.BlockPath.Step, count);
    for (steps, 0..) |*step, i| {
        const base = i * 33;
        step.* = .{ .right = raw[base] == 1, .hash = raw[base + 1 ..][0..32].* };
        if (raw[base] > 1) return error.BadFlat;
    }
    return .{ .steps = steps };
}

fn decodeLevels(arena: std.mem.Allocator, cursor: *Cursor) Error![]proofs.ChainLevel {
    const count = try cursor.count();
    const levels = try arena.alloc(proofs.ChainLevel, count);
    for (levels) |*level| {
        level.* = .{ .curr = try cursor.hash(), .snap = try cursor.hash() };
        const tag = try cursor.byte();
        if (tag > 1) return error.BadFlat;
        level.next = if (tag == 1) try cursor.hash() else null;
    }
    return levels;
}

fn decodePlacement(arena: std.mem.Allocator, cursor: *Cursor) Error!proofs.SlotPlacement {
    const slot_level = try cursor.int(u32);
    const snapshot = try cursor.byte();
    if (snapshot > 1) return error.BadFlat;
    // Assign through locals: the pinned compiler dislikes compound payload
    // expressions directly inside struct-literal fields.
    const block = try arena.dupe(u8, try cursor.take(try cursor.count()));
    const block_index = try cursor.int(u64);
    const block_count = try cursor.int(u64);
    const record_count = try cursor.int(u64);
    return .{
        .slot_level = @intCast(slot_level),
        .slot_snapshot = snapshot == 1,
        .bucket = .{
            .block = block,
            .block_index = block_index,
            .block_count = block_count,
            .record_count = record_count,
            .path = try decodeSteps(arena, cursor),
        },
    };
}

/// Decode a visible-state proof into `arena`; every count is bounds-charged.
pub fn decodeVisible(arena: std.mem.Allocator, bytes: []const u8) Error!proofs.VisibleProof {
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(visible_magic.len), visible_magic)) return error.BadFlat;
    const table = try cursor.int(u32);
    const key = try arena.dupe(u8, try cursor.take(try cursor.count()));
    const value = if (try cursor.byte() == 1) try arena.dupe(u8, try cursor.take(try cursor.count())) else null;
    const absent = (try cursor.byte()) == 1;
    const younger = try arena.alloc(proofs.SlotPlacement, try cursor.count());
    for (younger) |*entry| entry.* = try decodePlacement(arena, &cursor);
    const deciding = try decodePlacement(arena, &cursor);
    const schema_hash = try cursor.hash();
    const profile_hash = try cursor.hash();
    const advance = try cursor.int(u64);
    const levels = try decodeLevels(arena, &cursor);
    try cursor.done();
    return .{
        .table = table,
        .key = key,
        .value = value,
        .absent = absent,
        .younger = younger,
        .deciding = deciding,
        .schema_hash = schema_hash,
        .profile_hash = profile_hash,
        .advance = advance,
        .levels = levels,
    };
}

/// Decode a range proof into `arena`; every count is bounds-charged.
pub fn decodeRange(arena: std.mem.Allocator, bytes: []const u8) Error!proofs.RangeProof {
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(range_magic.len), range_magic)) return error.BadFlat;
    const table = try cursor.int(u32);
    const start = try arena.dupe(u8, try cursor.take(try cursor.count()));
    const end = try arena.dupe(u8, try cursor.take(try cursor.count()));
    const entries = try arena.alloc(proofs.RangeEntry, try cursor.count());
    for (entries) |*entry| {
        entry.* = .{
            .key = try arena.dupe(u8, try cursor.take(try cursor.count())),
            .value = try arena.dupe(u8, try cursor.take(try cursor.count())),
        };
    }
    const runs = try arena.alloc(proofs.RangeRun, try cursor.count());
    for (runs) |*run| {
        const slot_level = try cursor.int(u32);
        const snapshot = try cursor.byte();
        if (snapshot > 1) return error.BadFlat;
        const block_count = try cursor.int(u64);
        const record_count = try cursor.int(u64);
        const blocks = try arena.alloc(proofs.RangeBlock, try cursor.count());
        for (blocks) |*range_block| {
            const block = try arena.dupe(u8, try cursor.take(try cursor.count()));
            const block_index = try cursor.int(u64);
            range_block.* = .{
                .block = block,
                .block_index = block_index,
                .path = try decodeSteps(arena, &cursor),
            };
        }
        run.* = .{
            .slot_level = @intCast(slot_level),
            .slot_snapshot = snapshot == 1,
            .block_count = block_count,
            .record_count = record_count,
            .blocks = blocks,
        };
    }
    const schema_hash = try cursor.hash();
    const profile_hash = try cursor.hash();
    const advance = try cursor.int(u64);
    const levels = try decodeLevels(arena, &cursor);
    try cursor.done();
    return .{
        .table = table,
        .start = start,
        .end = end,
        .entries = entries,
        .runs = runs,
        .schema_hash = schema_hash,
        .profile_hash = profile_hash,
        .advance = advance,
        .levels = levels,
    };
}

const testing = std.testing;

test "flat roundtrips preserve visible and range verification" {
    // Reuse the core fixture shape: one deciding bucket with keys 0,1 in
    // one block; every other slot empty.
    var block: [42]u8 = undefined;
    for (0..2) |i| {
        const target: []u8 = block[i * 21 ..];
        std.mem.writeInt(u32, target[0..4], 1, .big);
        std.mem.writeInt(u32, target[4..8], 4, .big);
        std.mem.writeInt(u32, target[8..12], @intCast(i), .big);
        target[12] = 1;
        std.mem.writeInt(u32, target[13..17], 4, .big);
        std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
    }
    const leaf = proofs.blockHash(0, &block);
    const bucket = proofs.bucketHash(2, 1, leaf);
    var schema: [32]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 903, .big);
    std.crypto.hash.sha2.Sha256.hash(&seed, &schema, .{});
    const profile = proofs.profileHash(11, 42);
    var levels: [11]proofs.ChainLevel = undefined;
    const empty_bucket = proofs.emptyBucketHash();
    for (&levels, 0..) |*level, i| {
        var filler: [32]u8 = undefined;
        std.mem.writeInt(u32, &seed, @intCast(40 + i), .big);
        std.crypto.hash.sha2.Sha256.hash(&seed, &filler, .{});
        level.* = .{
            .curr = if (i == 2) bucket else if (i < 2) empty_bucket else filler,
            .snap = if (i < 2) empty_bucket else filler,
        };
    }
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 1, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 1, .big);
    var end: [4]u8 = undefined;
    std.mem.writeInt(u32, &end, 2, .big);
    const digest = proofs.chainCommitment(schema, profile, 6, &levels);

    const visible = proofs.VisibleProof{
        .table = 1,
        .key = &key,
        .value = &value,
        .absent = false,
        .younger = &.{},
        .deciding = .{ .slot_level = 2, .slot_snapshot = false, .bucket = .{ .block = &block, .block_index = 0, .block_count = 1, .record_count = 2, .path = .{ .steps = &.{} } } },
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 6,
        .levels = &levels,
    };
    try proofs.verifyVisible(&visible, digest);
    const flat_visible = try encodeVisible(testing.allocator, &visible);
    defer testing.allocator.free(flat_visible);
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const decoded = try decodeVisible(arena_state.allocator(), flat_visible);
        try proofs.verifyVisible(&decoded, digest);
        // Truncations and a flipped magic byte fail decoding.
        try testing.expectError(error.BadFlat, decodeVisible(arena_state.allocator(), flat_visible[0 .. flat_visible.len - 1]));
        var corrupt = try testing.allocator.dupe(u8, flat_visible);
        defer testing.allocator.free(corrupt);
        corrupt[0] ^= 0xff;
        try testing.expectError(error.BadFlat, decodeVisible(arena_state.allocator(), corrupt));
    }

    const entries = [_]proofs.RangeEntry{.{ .key = &key, .value = &value }};
    const runs = [_]proofs.RangeRun{.{
        .slot_level = 2,
        .slot_snapshot = false,
        .block_count = 1,
        .record_count = 2,
        .blocks = &.{.{ .block = &block, .block_index = 0, .path = .{ .steps = &.{} } }},
    }};
    // The range proof needs every non-empty slot covered; only the deciding
    // slot holds data here.
    var range_levels: [11]proofs.ChainLevel = @splat(.{ .curr = empty_bucket, .snap = empty_bucket });
    range_levels[2].curr = bucket;
    const range_digest = proofs.chainCommitment(schema, profile, 6, &range_levels);
    const range = proofs.RangeProof{
        .table = 1,
        .start = &key,
        .end = &end,
        .entries = &entries,
        .runs = &runs,
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 6,
        .levels = &range_levels,
    };
    try proofs.verifyRange(&range, range_digest);
    const flat_range = try encodeRange(testing.allocator, &range);
    defer testing.allocator.free(flat_range);
    {
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const decoded = try decodeRange(arena_state.allocator(), flat_range);
        try proofs.verifyRange(&decoded, range_digest);
        try testing.expectError(error.BadFlat, decodeRange(arena_state.allocator(), flat_range[1..]));
        // A declared count larger than the buffer can pay for fails closed
        // before any allocation.
        var liar = try testing.allocator.dupe(u8, flat_range);
        defer testing.allocator.free(liar);
        liar[range_magic.len + 4 ..][0..4].* = .{ 0xff, 0xff, 0xff, 0xff }; // start length
        try testing.expectError(error.BadFlat, decodeRange(arena_state.allocator(), liar));
    }
}
