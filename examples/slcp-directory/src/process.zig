//! Test host: filesystem publication runs on the observation-consumer thread,
//! outside SLCP's apply callback. tools/slcp-smoke.sh controls and kills it.
const std = @import("std");
const app = @import("directory-app");
const bucketlist = @import("bucketlist");
const storage = @import("bucketlist-store");
const slcp = @import("slcp");
const Allocator = std.mem.Allocator;
const Manifest = struct {
    checkpoint_blob: [32]u8,
    advance: u64,
    digest: [32]u8,
    header: [32]u8,
    previous_value: app.Value,
};
const ManifestCodec = bucketlist.Codec(Manifest);

fn loadSnapshot(store: *storage.Store, gpa: Allocator) !?app.Snapshot {
    const bytes = (try store.readManifest(gpa, ManifestCodec.max_size)) orelse return null;
    defer gpa.free(bytes);
    const manifest = try ManifestCodec.decode(bytes);
    const checkpoint = try store.getBlob(gpa, manifest.checkpoint_blob, 1024 * 1024);
    return .{
        .checkpoint = checkpoint,
        .advance = manifest.advance,
        .digest = manifest.digest,
        .header = manifest.header,
        .previous_value = manifest.previous_value,
    };
}

fn saveSnapshot(store: *storage.Store, snapshot: *const app.Snapshot) !void {
    const blob = try store.putBlob(snapshot.checkpoint);
    const manifest: Manifest = .{
        .checkpoint_blob = blob,
        .advance = snapshot.advance,
        .digest = snapshot.digest,
        .header = snapshot.header,
        .previous_value = snapshot.previous_value.?,
    };
    var buffer: [ManifestCodec.max_size]u8 = undefined;
    try store.publish(try ManifestCodec.encode(manifest, &buffer));
}

fn writeAtomic(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer file.deinit(io);
    var buffer: [1024]u8 = undefined;
    var writer = file.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try file.replace(io);
}

fn targetAdvance(dir: std.Io.Dir, io: std.Io, gpa: Allocator) !u64 {
    const bytes = try dir.readFileAlloc(io, "target", gpa, .limited(32));
    defer gpa.free(bytes);
    return std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " \r\n"), 10);
}

fn report(dir: std.Io.Dir, io: std.Io, index: usize, snapshot: *const app.Snapshot) !void {
    var command_buffer: [app.ValueCodec.max_size]u8 = undefined;
    const command = try app.ValueCodec.encode(snapshot.previous_value.?, &command_buffer);
    var hex: [app.ValueCodec.max_size * 2]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (command, 0..) |byte, pos| {
        hex[pos * 2] = alphabet[byte >> 4];
        hex[pos * 2 + 1] = alphabet[byte & 15];
    }
    var line_buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buffer, "{d} {s} {s} {s}\n", .{
        snapshot.advance,                            std.fmt.bytesToHex(snapshot.digest, .lower),
        std.fmt.bytesToHex(snapshot.header, .lower), hex[0 .. command.len * 2],
    });
    var filename_buffer: [64]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filename_buffer, "node{d}-{d}.value", .{ index, snapshot.advance });
    try writeAtomic(dir, io, filename, line);
    const status = try std.fmt.bufPrint(&filename_buffer, "node{d}.status", .{index});
    try writeAtomic(dir, io, status, line);
    std.debug.print("APPLIED {d} {s}", .{ index, line });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    const index = try std.fmt.parseInt(usize, args.next() orelse return error.MissingIndex, 10);
    if (index > 2) return error.BadIndex;
    const checkpoint_limit = try std.fmt.parseInt(u64, args.next() orelse return error.MissingCheckpointLimit, 10);
    const peer = args.next();
    var directory = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer directory.close(io);
    const journal_path = try std.fmt.allocPrint(gpa, "{s}/node{d}-journal", .{ root, index });
    defer gpa.free(journal_path);
    const snapshot_path = try std.fmt.allocPrint(gpa, "{s}/node{d}-snapshots", .{ root, index });
    defer gpa.free(snapshot_path);
    var store = try storage.Store.open(gpa, io, snapshot_path);
    defer store.deinit();
    var boot = try loadSnapshot(&store, gpa);
    defer if (boot) |*snapshot| snapshot.deinit(gpa);
    const seeds = [_][32]u8{ @splat(0x61), @splat(0x62), @splat(0x63) };
    var ids: [3][32]u8 = undefined;
    for (seeds, &ids) |seed, *id| id.* = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed)).public_key.toBytes();
    var diagnostic: slcp.node.Diagnostic = .{};
    const node = try app.Node.create(gpa, io, .{
        .network = app.network,
        .secret_seed = seeds[index],
        .quorum = slcp.Quorum.of(2, &ids),
        .listen_port = 0,
        .peers = if (peer) |endpoint| &.{endpoint} else &.{},
        .data_dir = journal_path,
        .diagnostic = &diagnostic,
    }, if (boot) |*snapshot| snapshot else null);
    defer node.deinit();
    var current = if (boot) |*snapshot| try snapshot.clone(gpa) else blk: {
        var genesis = try app.Directory.initState(null, gpa);
        defer app.Directory.deinitState(&genesis, gpa);
        break :blk try app.Directory.observe(&genesis, gpa);
    };
    defer current.deinit(gpa);
    var ready_name_buffer: [32]u8 = undefined;
    const ready_name = try std.fmt.bufPrint(&ready_name_buffer, "node{d}.ready", .{index});
    var ready_buffer: [32]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "127.0.0.1:{d}\n", .{node.raw().boundPort()});
    try writeAtomic(directory, io, ready_name, ready);
    std.debug.print("BOOT {d} {d}\n", .{ index, current.advance });
    var proposed: u64 = 0;
    while (true) {
        if (try node.waitApplied(.{ .timeout_ms = 25 })) |applied| {
            defer node.release(applied);
            if (applied.slot != current.advance + 1) return error.NonContiguousApply;
            current.deinit(gpa);
            current = try applied.obs.clone(gpa);
            if (current.advance <= checkpoint_limit) try saveSnapshot(&store, &current);
            try report(directory, io, index, &current);
            proposed = 0;
        } else {
            const target = try targetAdvance(directory, io, gpa);
            if (current.advance < target and proposed != current.advance + 1) {
                try node.propose(app.proposal(&current, 1, current.advance + 10));
                proposed = current.advance + 1;
            }
        }
    }
}
