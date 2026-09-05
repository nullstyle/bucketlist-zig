//! Async disk host around an unchanged, pinned SLCP raw Node.
const std = @import("std");
const chain = @import("disk-command-chain");
const adapter = @import("disk-consensus-bridge");
const slcp = @import("slcp");
const Allocator = std.mem.Allocator;
const Host = adapter.Host;

fn writeAtomic(dir: std.Io.Dir, io: std.Io, name: []const u8, bytes: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer atomic.deinit(io);
    var buffer: [1024]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.replace(io);
}

fn readNumber(dir: std.Io.Dir, io: std.Io, gpa: Allocator, name: []const u8, missing: ?u64) !u64 {
    const bytes = dir.readFileAlloc(io, name, gpa, .limited(32)) catch |err| switch (err) {
        error.FileNotFound => return missing orelse return error.MissingControlFile,
        else => return err,
    };
    defer gpa.free(bytes);
    return std.fmt.parseInt(u64, std.mem.trim(u8, bytes, " \r\n"), 10);
}

fn report(dir: std.Io.Dir, io: std.Io, index: usize, advance: u64, digest: chain.Hash, metadata: []const u8) !void {
    const state = try chain.restore(advance, metadata);
    var hex: [chain.Codec.max_size * 2]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (metadata, 0..) |byte, offset| {
        hex[offset * 2] = alphabet[byte >> 4];
        hex[offset * 2 + 1] = alphabet[byte & 15];
    }
    var buffer: [1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{d} {s} {s} {s}\n", .{
        advance, std.fmt.bytesToHex(digest, .lower), std.fmt.bytesToHex(state.command_hash, .lower), hex[0 .. metadata.len * 2],
    });
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "node{d}-{d}.value", .{ index, advance });
    try writeAtomic(dir, io, name, line);
    const status_name = try std.fmt.bufPrint(&name_buffer, "node{d}.status", .{index});
    try writeAtomic(dir, io, status_name, line);
    std.debug.print("DURABLE {d} {s}", .{ index, line });
}

const Runtime = struct {
    gpa: Allocator,
    io: std.Io,
    host: *Host,
    bridge: *adapter.Bridge,
    index: usize,
    journal_path: []const u8,
    peer: ?[]const u8,
    port: u16 = 0,
    node: ?*slcp.Node = null,
    requested_watermark: u64 = 0,

    fn closeNode(self: *Runtime) void {
        if (self.node) |node| {
            self.node = null;
            node.deinit();
        }
    }

    fn acknowledgePublished(self: *Runtime, durable: u64) !?u64 {
        const node = self.node orelse return null;
        if (durable > self.requested_watermark) {
            node.acknowledgeDurable(durable) catch |err| switch (err) {
                // Publication can win the race with the delivery callback's
                // return. Retry next loop; a closed/failed Node is recreated.
                error.AheadOfDelivery, error.NodeClosed, error.NodeFailed => return null,
                else => return err,
            };
            self.requested_watermark = durable;
        }
        const applied = node.durableApplicationSlot() orelse return error.DurabilityDisabled;
        if (applied > durable) return error.UnpublishedDurabilityAcknowledgment;
        return applied;
    }

    fn startNode(self: *Runtime) !u64 {
        std.debug.assert(self.node == null);
        const status = self.host.status();
        if (status.accepted != status.durable) return error.OutstandingWorkAtRestart;
        var snapshot = try self.host.snapshot(self.gpa);
        defer snapshot.deinit();
        const state = try chain.restore(snapshot.commitment.advance, snapshot.metadata);
        if (state.advance == std.math.maxInt(u64)) return error.SequenceExhausted;
        // SLCP's explicit start_slot describes an independently imported
        // checkpoint ahead of the journal. Its default selects journal replay.
        // Inspect while no Node owns the journal, then close before creation.
        const start_slot: u64 = blk: {
            var journal = try slcp.store.Store.open(self.gpa, self.io, self.journal_path);
            defer journal.deinit();
            var recovered = try journal.recover(self.gpa);
            defer slcp.store.Store.deinitRecovery(self.gpa, &recovered);
            break :blk if (state.advance > (recovered.externalized_hwm orelse 0)) state.advance + 1 else 1;
        };
        self.bridge.* = adapter.Bridge.init(self.gpa, self.io, self.host, state);
        const seeds = [_][32]u8{ @splat(0x71), @splat(0x72), @splat(0x73) };
        var ids: [3][32]u8 = undefined;
        for (seeds, &ids) |seed, *id| id.* = (try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed)).public_key.toBytes();
        var diagnostic: slcp.node.Diagnostic = .{};
        self.node = slcp.Node.createWithRecovery(self.gpa, self.io, .{
            .network = chain.network,
            .secret_seed = seeds[self.index],
            .quorum = slcp.Quorum.of(2, &ids),
            .listen_port = self.port,
            .peers = if (self.peer) |peer| &.{peer} else &.{},
            .data_dir = self.journal_path,
            .start_slot = start_slot,
            .max_value_bytes = chain.Codec.max_size,
            .answering_window_slots = adapter.answering_window,
            .driver = self.bridge.driver(),
            .delivery = self.bridge.delivery(),
            .diagnostic = &diagnostic,
        }, .{
            .hook = self.bridge.recovery(),
            .retain_until_durable = true,
            .previous_value = if (state.advance != 0) .{ .slot = state.advance, .bytes = snapshot.metadata } else null,
        }) catch |err| {
            std.debug.print("START_FAILED {d} {s}: {s}\n", .{ self.index, @errorName(err), diagnostic.message() });
            return err;
        };
        self.requested_watermark = state.advance;
        self.port = self.node.?.boundPort();
        std.debug.print("BOOT {d} {d} replayed={d} accepted={d}\n", .{
            self.index, state.advance, self.bridge.replayed, self.bridge.observation().state.advance,
        });
        return state.advance;
    }
};

fn inspectJournal(init: std.process.Init, path: []const u8) !void {
    var store = try slcp.store.Store.open(init.gpa, init.io, path);
    defer store.deinit();
    var recovery = try store.recover(init.gpa);
    defer slcp.store.Store.deinitRecovery(init.gpa, &recovery);
    if (recovery.ext_tail.len == 0) return error.EmptyJournal;
    var buffer: [128]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try output.interface.print("{d} {d} {d}\n", .{
        recovery.ext_tail[0].slot, recovery.ext_tail[recovery.ext_tail.len - 1].slot, recovery.ext_tail.len,
    });
    try output.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const root = args.next() orelse return error.MissingRoot;
    if (std.mem.eql(u8, root, "--inspect-journal")) {
        return inspectJournal(init, args.next() orelse return error.MissingJournalPath);
    }
    const index = try std.fmt.parseInt(usize, args.next() orelse return error.MissingIndex, 10);
    if (index > 2) return error.BadIndex;
    const peer = args.next();
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    const disk_path = try std.fmt.allocPrint(gpa, "{s}/node{d}-database", .{ root, index });
    defer gpa.free(disk_path);
    const journal_path = try std.fmt.allocPrint(gpa, "{s}/node{d}-journal", .{ root, index });
    defer gpa.free(journal_path);
    const host = try Host.create(gpa, io, disk_path, .{
        .capacity = adapter.capacity,
        .disk = .{ .merge_workers = 2, .max_metadata_bytes = chain.Codec.max_size },
    });
    defer host.deinit();
    const bridge = try gpa.create(adapter.Bridge);
    defer gpa.destroy(bridge);
    var runtime: Runtime = .{ .gpa = gpa, .io = io, .host = host, .bridge = bridge, .index = index, .journal_path = journal_path, .peer = peer };
    defer runtime.closeNode();
    _ = try runtime.startNode();
    var ready_name_buffer: [32]u8 = undefined;
    const ready_name = try std.fmt.bufPrint(&ready_name_buffer, "node{d}.ready", .{index});
    var ready_buffer: [32]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "127.0.0.1:{d}\n", .{runtime.port});
    try writeAtomic(dir, io, ready_name, ready);
    var pause_name_buffer: [32]u8 = undefined;
    const pause_name = try std.fmt.bufPrint(&pause_name_buffer, "node{d}.pause", .{index});
    var paused = false;
    var reported: u64 = 0;
    var reported_watermark: u64 = 0;
    var proposed: u64 = 0;
    var status = host.status();
    while (true) {
        const requested_pause = (try readNumber(dir, io, gpa, pause_name, 0)) != 0;
        if (requested_pause != paused) {
            if (requested_pause) {
                status = host.status();
                host.pause();
            } else host.resumeProcessing();
            paused = requested_pause;
            var name_buffer: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "node{d}.paused", .{index});
            try writeAtomic(dir, io, name, if (paused) "1\n" else "0\n");
            std.debug.print("PAUSED {d} {any}\n", .{ index, paused });
        }
        // A paused maintenance fixture does not contend with admission by
        // polling the Host lock. Resume refreshes this cached observation.
        if (!paused) status = host.status();
        if (status.failure) |failure| {
            std.debug.print("DISK_FAILED {d} {s}\n", .{ index, @errorName(failure) });
            return error.DiskWorkerFailed;
        }
        if (status.accepted < status.durable or status.accepted - status.durable > status.capacity or
            status.capacity + 1 >= adapter.answering_window) return error.UnsafeJournalRetention;
        if (status.durable > reported) {
            var snapshot = try host.snapshot(gpa);
            defer snapshot.deinit();
            try report(dir, io, index, snapshot.commitment.advance, snapshot.commitment.digest, snapshot.metadata);
            reported = snapshot.commitment.advance;
        }
        if (runtime.node != null) {
            const observation = bridge.observation();
            if (observation.failure) |failure| {
                runtime.closeNode();
                if (failure != error.DiskBackpressure) {
                    std.debug.print("CONSENSUS_FAILED {d} {s}\n", .{ index, @errorName(failure) });
                    return error.ConsensusFailed;
                }
                const pressure = host.status();
                var line_buffer: [128]u8 = undefined;
                const line = try std.fmt.bufPrint(&line_buffer, "{d} {d} {d} {d}\n", .{ pressure.durable, pressure.accepted, pressure.queued, pressure.capacity });
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "node{d}.backpressure", .{index});
                try writeAtomic(dir, io, name, line);
                std.debug.print("BACKPRESSURE {d} {s}", .{ index, line });
            } else {
                if (try runtime.acknowledgePublished(status.durable)) |watermark| {
                    if (watermark > reported_watermark) {
                        var name_buffer: [32]u8 = undefined;
                        var line_buffer: [32]u8 = undefined;
                        const name = try std.fmt.bufPrint(&name_buffer, "node{d}.watermark", .{index});
                        const line = try std.fmt.bufPrint(&line_buffer, "{d}\n", .{watermark});
                        try writeAtomic(dir, io, name, line);
                        reported_watermark = watermark;
                    }
                }
                const target = try readNumber(dir, io, gpa, "target", null);
                // Proposal throttling is local host policy. Validity never
                // inspects queue pressure, disk timing, or machine resources.
                if (!paused and observation.state.advance < target and status.accepted == status.durable and
                    observation.state.advance == status.accepted and proposed != observation.state.advance + 1)
                {
                    const command = chain.proposal(&observation.state);
                    var command_buffer: [chain.Codec.max_size]u8 = undefined;
                    try runtime.node.?.propose(try chain.Codec.encode(command, &command_buffer));
                    proposed = command.advance;
                }
            }
        } else if (!paused and status.accepted == status.durable) {
            _ = try runtime.startNode();
            proposed = 0;
        }
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}
