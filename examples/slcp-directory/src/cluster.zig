const std = @import("std");
const app = @import("app.zig");
const slcp = @import("slcp");
const Node = app.Node;
const Allocator = std.mem.Allocator;

const Track = struct {
    hashes: [13]?[32]u8 = @splat(null),
    headers: [13]?[32]u8 = @splat(null),
    last: ?app.Snapshot = null,

    fn deinit(self: *Track, gpa: Allocator) void {
        if (self.last) |*snapshot| snapshot.deinit(gpa);
    }

    fn note(self: *Track, gpa: Allocator, applied: Node.Applied) !void {
        try std.testing.expectEqual(applied.slot, applied.obs.advance);
        try std.testing.expectEqual(applied.slot, applied.obs.previous_value.?.advance);
        if (applied.slot < self.hashes.len) {
            self.hashes[@intCast(applied.slot)] = applied.obs.digest;
            self.headers[@intCast(applied.slot)] = applied.obs.header;
        }
        if (self.last) |*previous| previous.deinit(gpa);
        self.last = try applied.obs.clone(gpa);
    }
};

fn pump(gpa: Allocator, nodes: []const *Node, tracks: []const *Track, target: u64) !void {
    var waited: u64 = 0;
    while (waited < 90_000) {
        var done = true;
        for (nodes, tracks) |node, track| {
            if (track.last == null or track.last.?.advance < target) done = false;
            if (try node.waitApplied(.{ .timeout_ms = 10 })) |applied| {
                defer node.release(applied);
                try track.note(gpa, applied);
                if (applied.slot < target) try node.propose(app.proposal(&applied.obs, 1, applied.slot + 10));
            }
            waited += 10;
        }
        if (done) return;
    }
    for (tracks, 0..) |track, index| std.debug.print("node {d}: last advance {d}, target {d}\n", .{ index, if (track.last) |s| s.advance else 0, target });
    return error.ClusterTimeout;
}

fn key(seed: [32]u8) ![32]u8 {
    return (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed)).public_key.toBytes();
}

test "three SLCP loopback nodes converge across spills, checkpoint restart, and journal replay" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var path_buffers: [3][std.fs.max_path_bytes]u8 = undefined;
    var paths: [3][]const u8 = undefined;
    for (&path_buffers, &paths, 0..) |*buffer, *path, index| path.* = try std.fmt.bufPrint(buffer, "{s}/node-{d}", .{ root, index });
    const seeds = [_][32]u8{ @splat(0x61), @splat(0x62), @splat(0x63) };
    const ids = [_][32]u8{ try key(seeds[0]), try key(seeds[1]), try key(seeds[2]) };
    const quorum = slcp.Quorum.of(2, &ids);
    var genesis_state = try app.Directory.initState(null, gpa);
    defer app.Directory.deinitState(&genesis_state, gpa);
    var genesis = try app.Directory.observe(&genesis_state, gpa);
    defer genesis.deinit(gpa);
    var tracks: [3]Track = @splat(.{});
    defer for (&tracks) |*track| track.deinit(gpa);
    var diagnostics: [3]slcp.node.Diagnostic = @splat(.{});
    var nodes: [3]*Node = undefined;
    var initialized: usize = 0;
    defer for (nodes[0..initialized]) |node| node.deinit();
    var peer_buffer: [32]u8 = undefined;
    nodes[0] = try Node.create(gpa, io, .{
        .network = app.network,
        .secret_seed = seeds[0],
        .quorum = quorum,
        .listen_port = 0,
        .data_dir = paths[0],
        .diagnostic = &diagnostics[0],
    }, null);
    initialized = 1;
    const peer = try std.fmt.bufPrint(&peer_buffer, "127.0.0.1:{d}", .{nodes[0].raw().boundPort()});
    for (1..3) |index| {
        nodes[index] = try Node.create(gpa, io, .{
            .network = app.network,
            .secret_seed = seeds[index],
            .quorum = quorum,
            .listen_port = 0,
            .peers = &.{peer},
            .data_dir = paths[index],
            .diagnostic = &diagnostics[index],
        }, null);
        initialized += 1;
    }
    for (nodes, 0..) |node, index| try node.propose(app.proposal(&genesis, 1, index + 10));
    try pump(gpa, &nodes, &.{ &tracks[0], &tracks[1], &tracks[2] }, 7);
    for (1..8) |advance| for (1..3) |index| {
        try std.testing.expectEqualSlices(u8, &tracks[0].hashes[advance].?, &tracks[index].hashes[advance].?);
        try std.testing.expectEqualSlices(u8, &tracks[0].headers[advance].?, &tracks[index].headers[advance].?);
    };
    // Preserve the advance-7 checkpoint, then let the node's journal reach 9.
    // Restarting from 7 must replay exact values 8 and 9 before live advance 10.
    var checkpoint7 = try tracks[2].last.?.clone(gpa);
    defer checkpoint7.deinit(gpa);
    for (nodes, &tracks) |node, *track| try node.propose(app.proposal(&track.last.?, 1, 17));
    try pump(gpa, &nodes, &.{ &tracks[0], &tracks[1], &tracks[2] }, 9);
    nodes[2].deinit();
    initialized = 2;
    var peer2_buffer: [32]u8 = undefined;
    const peer2 = try std.fmt.bufPrint(&peer2_buffer, "127.0.0.1:{d}", .{nodes[0].raw().boundPort()});
    nodes[2] = try Node.create(gpa, io, .{
        .network = app.network,
        .secret_seed = seeds[2],
        .quorum = quorum,
        .listen_port = 0,
        .peers = &.{peer2},
        .data_dir = paths[2],
        .diagnostic = &diagnostics[2],
    }, &checkpoint7);
    initialized = 3;
    // Replay observations are queued during create. They prove 1..7 were not
    // applied again and the exact prior consensus command survived the restore.
    for (8..10) |advance| {
        const replayed = (try nodes[2].waitApplied(.{ .timeout_ms = 1000 })) orelse return error.MissingReplay;
        defer nodes[2].release(replayed);
        try std.testing.expectEqual(@as(u64, @intCast(advance)), replayed.slot);
        try std.testing.expectEqualSlices(u8, &tracks[0].hashes[advance].?, &replayed.obs.digest);
        try std.testing.expectEqualSlices(u8, &tracks[0].headers[advance].?, &replayed.obs.header);
        try tracks[2].note(gpa, replayed);
    }
    for (nodes, &tracks) |node, *track| try node.propose(app.proposal(&track.last.?, 1, 19));
    try pump(gpa, &nodes, &.{ &tracks[0], &tracks[1], &tracks[2] }, 12);
    for (8..13) |advance| for (1..3) |index| {
        try std.testing.expectEqualSlices(u8, &tracks[0].hashes[advance].?, &tracks[index].hashes[advance].?);
        try std.testing.expectEqualSlices(u8, &tracks[0].headers[advance].?, &tracks[index].headers[advance].?);
    };
}
