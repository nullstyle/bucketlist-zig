//! capnp wire framing for v2 proof messages (schema/proof.capnp).
//! The hashed bucket bytes never use this format; this module only moves
//! the already-verified proof structures across process boundaries and
//! hands them back to the dependency-free core verifier.
const std = @import("std");
const lib = @import("bucketlist");
const gen = @import("proof_gen.zig");
const capnpc = @import("capnpc-zig");
const proofs = lib.proofs;

pub const Error = error{ OutOfMemory, InvalidMessage, InvalidProof, PresentRecord, UnknownRecord, IoFailed };

/// Serialize a generated visible-state proof into a capnp message builder.
pub fn write(gpa: std.mem.Allocator, proof: *const proofs.VisibleProof, builder: *capnpc.message.MessageBuilder) !void {
    _ = gpa;
    var root = try gen.VisibleProof.Builder.init(builder);
    try root.setTable(proof.table);
    try root.setKey(proof.key);
    if (proof.value) |value| try root.setValue(value);
    try root.setAbsent(proof.absent);
    const younger = try root.initYounger(@intCast(proof.younger.len));
    for (proof.younger, 0..) |entry, i| {
        var slot = try younger.get(@intCast(i));
        try writePlacement(&slot, entry);
    }
    var deciding_slot = try root.initDeciding();
    try writePlacement(&deciding_slot, proof.deciding);
    var schema_slot = try root.initSchemaHash();
    try schema_slot.setBytes(&proof.schema_hash);
    var profile_slot = try root.initProfileHash();
    try profile_slot.setBytes(&proof.profile_hash);
    try root.setAdvance(proof.advance);
    const levels = try root.initLevels(@intCast(proof.levels.len));
    for (proof.levels, 0..) |level, i| {
        var out = try levels.get(@intCast(i));
        var curr_slot = try out.initCurr();
        try curr_slot.setBytes(&level.curr);
        var snap_slot = try out.initSnap();
        try snap_slot.setBytes(&level.snap);
        if (level.next) |pending| {
            var next_slot = try out.initNext();
            try next_slot.setBytes(&pending);
        }
    }
}

fn writePlacement(slot: *gen.SlotPlacement.Builder, entry: proofs.SlotPlacement) !void {
    try slot.setSlotLevel(@intCast(entry.slot_level));
    try slot.setSlotSnapshot(entry.slot_snapshot);
    var bucket = try slot.initBucket();
    try bucket.setBlock(entry.bucket.block);
    try bucket.setBlockIndex(entry.bucket.block_index);
    try bucket.setBlockCount(entry.bucket.block_count);
    try bucket.setRecordCount(entry.bucket.record_count);
    var path = try bucket.initPath(@intCast(entry.bucket.path.steps.len));
    for (entry.bucket.path.steps, 0..) |step, i| {
        var out = try path.get(@intCast(i));
        var hash_slot = try out.initHash();
        try hash_slot.setBytes(&step.hash);
        try out.setRight(step.right);
    }
}

/// Assemble the core proof structure from a decoded message. Caller owns
/// every allocation through `arena`.
pub fn read(arena: std.mem.Allocator, msg: *const capnpc.message.Message) Error!proofs.VisibleProof {
    const root = gen.VisibleProof.Reader.init(msg) catch return error.InvalidMessage;
    const table = root.getTable() catch return error.InvalidMessage;
    const absent = root.getAbsent() catch return error.InvalidMessage;
    const advance = root.getAdvance() catch return error.InvalidMessage;
    const younger_list = root.getYounger() catch return error.InvalidMessage;
    const levels_list = root.getLevels() catch return error.InvalidMessage;
    const younger = try arena.alloc(proofs.SlotPlacement, @intCast(younger_list.len()));
    errdefer arena.free(younger);
    for (younger, 0..) |*entry, i| {
        const item = younger_list.get(@intCast(i)) catch return error.InvalidMessage;
        entry.* = try readPlacement(arena, item);
    }
    const levels = try arena.alloc(proofs.ChainLevel, @intCast(levels_list.len()));
    errdefer arena.free(levels);
    for (levels, 0..) |*level, i| {
        const row = levels_list.get(@intCast(i)) catch return error.InvalidMessage;
        level.* = .{
            .curr = try readHash(row.getCurr() catch return error.InvalidMessage),
            .snap = try readHash(row.getSnap() catch return error.InvalidMessage),
            .next = if (row.hasNext()) try readHash(row.getNext() catch return error.InvalidMessage) else null,
        };
    }
    return .{
        .table = table,
        .key = try arena.dupe(u8, root.getKey() catch return error.InvalidMessage),
        .value = if (root.hasValue()) try arena.dupe(u8, root.getValue() catch return error.InvalidMessage) else null,
        .absent = absent,
        .younger = younger,
        .deciding = try readPlacement(arena, root.getDeciding() catch return error.InvalidMessage),
        .schema_hash = try readHash(root.getSchemaHash() catch return error.InvalidMessage),
        .profile_hash = try readHash(root.getProfileHash() catch return error.InvalidMessage),
        .advance = advance,
        .levels = levels,
    };
}

fn readHash(reader: gen.Hash.Reader) Error![32]u8 {
    const bytes = reader.getBytes() catch return error.InvalidMessage;
    if (bytes.len != 32) return error.InvalidMessage;
    return bytes[0..32].*;
}

/// Serialize a generated range proof into a capnp message builder.
pub fn writeRange(proof: *const proofs.RangeProof, builder: *capnpc.message.MessageBuilder) !void {
    var root = try gen.RangeProof.Builder.init(builder);
    try root.setTable(proof.table);
    try root.setStart(proof.start);
    try root.setEnd(proof.end);
    const entries = try root.initEntries(@intCast(proof.entries.len));
    for (proof.entries, 0..) |entry, i| {
        var out = try entries.get(@intCast(i));
        try out.setKey(entry.key);
        try out.setValue(entry.value);
    }
    const runs = try root.initRuns(@intCast(proof.runs.len));
    for (proof.runs, 0..) |run, i| {
        var out = try runs.get(@intCast(i));
        try out.setSlotLevel(@intCast(run.slot_level));
        try out.setSlotSnapshot(run.slot_snapshot);
        try out.setBlockCount(run.block_count);
        try out.setRecordCount(run.record_count);
        const blocks = try out.initBlocks(@intCast(run.blocks.len));
        for (run.blocks, 0..) |*range_block, b| {
            var slot = try blocks.get(@intCast(b));
            try slot.setBlock(range_block.block);
            try slot.setBlockIndex(range_block.block_index);
            var path = try slot.initPath(@intCast(range_block.path.steps.len));
            for (range_block.path.steps, 0..) |step, s| {
                var row = try path.get(@intCast(s));
                var hash_slot = try row.initHash();
                try hash_slot.setBytes(&step.hash);
                try row.setRight(step.right);
            }
        }
    }
    var schema_slot = try root.initSchemaHash();
    try schema_slot.setBytes(&proof.schema_hash);
    var profile_slot = try root.initProfileHash();
    try profile_slot.setBytes(&proof.profile_hash);
    try root.setAdvance(proof.advance);
    const levels = try root.initLevels(@intCast(proof.levels.len));
    for (proof.levels, 0..) |level, i| {
        var out = try levels.get(@intCast(i));
        var curr_slot = try out.initCurr();
        try curr_slot.setBytes(&level.curr);
        var snap_slot = try out.initSnap();
        try snap_slot.setBytes(&level.snap);
        if (level.next) |pending| {
            var next_slot = try out.initNext();
            try next_slot.setBytes(&pending);
        }
    }
}

/// Assemble the core range proof structure from a decoded message. Caller
/// owns every allocation through `arena`.
pub fn readRange(arena: std.mem.Allocator, msg: *const capnpc.message.Message) Error!proofs.RangeProof {
    const root = gen.RangeProof.Reader.init(msg) catch return error.InvalidMessage;
    const table = root.getTable() catch return error.InvalidMessage;
    const advance = root.getAdvance() catch return error.InvalidMessage;
    const entries_list = root.getEntries() catch return error.InvalidMessage;
    const runs_list = root.getRuns() catch return error.InvalidMessage;
    const levels_list = root.getLevels() catch return error.InvalidMessage;
    const entries = try arena.alloc(proofs.RangeEntry, @intCast(entries_list.len()));
    errdefer arena.free(entries);
    for (entries, 0..) |*entry, i| {
        const row = entries_list.get(@intCast(i)) catch return error.InvalidMessage;
        entry.* = .{
            .key = try arena.dupe(u8, row.getKey() catch return error.InvalidMessage),
            .value = try arena.dupe(u8, row.getValue() catch return error.InvalidMessage),
        };
    }
    const runs = try arena.alloc(proofs.RangeRun, @intCast(runs_list.len()));
    errdefer arena.free(runs);
    for (runs, 0..) |*run, i| {
        const row = runs_list.get(@intCast(i)) catch return error.InvalidMessage;
        const blocks_list = row.getBlocks() catch return error.InvalidMessage;
        const blocks = try arena.alloc(proofs.RangeBlock, @intCast(blocks_list.len()));
        for (blocks, 0..) |*block, b| {
            const item = blocks_list.get(@intCast(b)) catch return error.InvalidMessage;
            const path_list = item.getPath() catch return error.InvalidMessage;
            const steps = try arena.alloc(proofs.BlockPath.Step, @intCast(path_list.len()));
            for (steps, 0..) |*step, s| {
                const hop = path_list.get(@intCast(s)) catch return error.InvalidMessage;
                step.* = .{ .hash = try readHash(hop.getHash() catch return error.InvalidMessage), .right = hop.getRight() catch return error.InvalidMessage };
            }
            block.* = .{
                .block = try arena.dupe(u8, item.getBlock() catch return error.InvalidMessage),
                .block_index = item.getBlockIndex() catch return error.InvalidMessage,
                .path = .{ .steps = steps },
            };
        }
        run.* = .{
            .slot_level = @intCast(row.getSlotLevel() catch return error.InvalidMessage),
            .slot_snapshot = row.getSlotSnapshot() catch return error.InvalidMessage,
            .block_count = row.getBlockCount() catch return error.InvalidMessage,
            .record_count = row.getRecordCount() catch return error.InvalidMessage,
            .blocks = blocks,
        };
    }
    const levels = try arena.alloc(proofs.ChainLevel, @intCast(levels_list.len()));
    errdefer arena.free(levels);
    for (levels, 0..) |*level, i| {
        const row = levels_list.get(@intCast(i)) catch return error.InvalidMessage;
        level.* = .{
            .curr = try readHash(row.getCurr() catch return error.InvalidMessage),
            .snap = try readHash(row.getSnap() catch return error.InvalidMessage),
            .next = if (row.hasNext()) try readHash(row.getNext() catch return error.InvalidMessage) else null,
        };
    }
    return .{
        .table = table,
        .start = try arena.dupe(u8, root.getStart() catch return error.InvalidMessage),
        .end = try arena.dupe(u8, root.getEnd() catch return error.InvalidMessage),
        .entries = entries,
        .runs = runs,
        .schema_hash = try readHash(root.getSchemaHash() catch return error.InvalidMessage),
        .profile_hash = try readHash(root.getProfileHash() catch return error.InvalidMessage),
        .advance = advance,
        .levels = levels,
    };
}

fn readPlacement(arena: std.mem.Allocator, reader: gen.SlotPlacement.Reader) Error!proofs.SlotPlacement {
    const bucket = reader.getBucket() catch return error.InvalidMessage;
    const path_list = bucket.getPath() catch return error.InvalidMessage;
    const steps = try arena.alloc(proofs.BlockPath.Step, @intCast(path_list.len()));
    for (steps, 0..) |*step, i| {
        const row = path_list.get(@intCast(i)) catch return error.InvalidMessage;
        step.* = .{ .hash = try readHash(row.getHash() catch return error.InvalidMessage), .right = row.getRight() catch return error.InvalidMessage };
    }
    return .{
        .slot_level = @intCast(reader.getSlotLevel() catch return error.InvalidMessage),
        .slot_snapshot = reader.getSlotSnapshot() catch return error.InvalidMessage,
        .bucket = .{
            .block = try arena.dupe(u8, bucket.getBlock() catch return error.InvalidMessage),
            .block_index = bucket.getBlockIndex() catch return error.InvalidMessage,
            .block_count = bucket.getBlockCount() catch return error.InvalidMessage,
            .record_count = bucket.getRecordCount() catch return error.InvalidMessage,
            .path = .{ .steps = steps },
        },
    };
}

test "wire roundtrip preserves proof verification" {
    const testing = std.testing;
    // Rebuild the membership fixture from the core tests.
    var block0: [42]u8 = undefined;
    for (0..2) |i| {
        const target: []u8 = block0[i * 21 ..];
        std.mem.writeInt(u32, target[0..4], 1, .big);
        std.mem.writeInt(u32, target[4..8], 4, .big);
        std.mem.writeInt(u32, target[8..12], @intCast(i), .big);
        target[12] = 1;
        std.mem.writeInt(u32, target[13..17], 4, .big);
        std.mem.writeInt(u32, target[17..21], @intCast(i), .big);
    }
    const leaves = [_][32]u8{proofs.blockHash(0, &block0)};
    const bucket = proofs.bucketHash(2, 1, leaves[0]);
    var schema: [32]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 900, .big);
    std.crypto.hash.sha2.Sha256.hash(&seed, &schema, .{});
    const profile = proofs.profileHash(11, 42);
    var levels: [11]proofs.ChainLevel = undefined;
    const empty_bucket = proofs.emptyBucketHash();
    for (&levels, 0..) |*level, i| {
        var hash: [32]u8 = undefined;
        std.mem.writeInt(u32, &seed, @intCast(50 + i), .big);
        std.crypto.hash.sha2.Sha256.hash(&seed, &hash, .{});
        // Slots younger than the deciding one must be empty or covered.
        const young = i < 2;
        level.* = .{
            .curr = if (i == 2) bucket else if (young) empty_bucket else hash,
            .snap = if (young) empty_bucket else hash,
        };
    }
    const digest = proofs.chainCommitment(schema, profile, 9, &levels);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 1, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 1, .big);
    var proof: proofs.VisibleProof = .{
        .table = 1,
        .key = &key,
        .value = &value,
        .absent = false,
        .younger = &.{},
        .deciding = .{ .slot_level = 2, .slot_snapshot = false, .bucket = .{ .block = &block0, .block_index = 0, .block_count = 1, .record_count = 2, .path = .{ .steps = &.{} } } },
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 9,
        .levels = &levels,
    };
    proofs.verifyVisible(&proof, digest) catch unreachable;

    var builder = capnpc.message.MessageBuilder.init(testing.allocator);
    defer builder.deinit();
    try write(testing.allocator, &proof, &builder);
    const bytes = try builder.toBytes();
    defer testing.allocator.free(bytes);
    var msg = try capnpc.message.Message.init(testing.allocator, bytes, .{});
    defer msg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const decoded = try read(arena_state.allocator(), &msg);
    try proofs.verifyVisible(&decoded, digest);
    var wrong = digest;
    wrong[0] ^= 0xff;
    try testing.expectError(error.InvalidProof, proofs.verifyVisible(&decoded, wrong));
}

test "range wire roundtrip preserves proof verification" {
    const testing = std.testing;
    var block0: [42]u8 = undefined;
    for (0..2) |i| {
        const target: []u8 = block0[i * 21 ..];
        std.mem.writeInt(u32, target[0..4], 1, .big);
        std.mem.writeInt(u32, target[4..8], 4, .big);
        std.mem.writeInt(u32, target[8..12], @intCast(i), .big);
        target[12] = 1;
        std.mem.writeInt(u32, target[13..17], 4, .big);
        std.mem.writeInt(u32, target[17..21], @intCast(7 + i), .big);
    }
    const leaf = proofs.blockHash(0, &block0);
    const bucket = proofs.bucketHash(2, 1, leaf);
    var schema: [32]u8 = undefined;
    var seed: [4]u8 = undefined;
    std.mem.writeInt(u32, &seed, 902, .big);
    std.crypto.hash.sha2.Sha256.hash(&seed, &schema, .{});
    const profile = proofs.profileHash(11, 42);
    var levels: [11]proofs.ChainLevel = undefined;
    const empty_bucket = proofs.emptyBucketHash();
    for (&levels, 0..) |*level, i| {
        level.* = .{
            .curr = if (i == 2) bucket else empty_bucket,
            .snap = empty_bucket,
        };
    }
    const digest = proofs.chainCommitment(schema, profile, 4, &levels);
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 0, .big);
    var value: [4]u8 = undefined;
    std.mem.writeInt(u32, &value, 7, .big);
    var end: [4]u8 = undefined;
    std.mem.writeInt(u32, &end, 1, .big);
    const entries = [_]proofs.RangeEntry{.{ .key = &key, .value = &value }};
    const runs = [_]proofs.RangeRun{.{
        .slot_level = 2,
        .slot_snapshot = false,
        .block_count = 1,
        .record_count = 2,
        .blocks = &.{.{ .block = &block0, .block_index = 0, .path = .{ .steps = &.{} } }},
    }};
    var proof: proofs.RangeProof = .{
        .table = 1,
        .start = &key,
        .end = &end,
        .entries = &entries,
        .runs = &runs,
        .schema_hash = schema,
        .profile_hash = profile,
        .advance = 4,
        .levels = &levels,
    };
    proofs.verifyRange(&proof, digest) catch unreachable;

    var builder = capnpc.message.MessageBuilder.init(testing.allocator);
    defer builder.deinit();
    try writeRange(&proof, &builder);
    const bytes = try builder.toBytes();
    defer testing.allocator.free(bytes);
    var msg = try capnpc.message.Message.init(testing.allocator, bytes, .{});
    defer msg.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const decoded = try readRange(arena_state.allocator(), &msg);
    try proofs.verifyRange(&decoded, digest);
    var wrong = digest;
    wrong[0] ^= 0xff;
    try testing.expectError(error.InvalidProof, proofs.verifyRange(&decoded, wrong));
    // A decoded claim edit must fail verification.
    var forged = decoded;
    var edited = [_]proofs.RangeEntry{decoded.entries[0]};
    edited[0].value = decoded.entries[0].value[0..0];
    forged.entries = &edited;
    try testing.expectError(error.InvalidProof, proofs.verifyRange(&forged, digest));
}
