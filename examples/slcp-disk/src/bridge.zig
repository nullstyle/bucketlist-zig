//! Bounded application hand-off through SLCP's raw delivery seam.
//! Successful delivery means "accepted by the disk host"; publication and its
//! commitment happen later. Backpressure latches SLCP after journal append.
const std = @import("std");
const chain = @import("disk-command-chain");
const native = @import("bucketlist-disk");
const slcp = @import("slcp");
const Allocator = std.mem.Allocator;
pub const Host = native.Host(chain.Schema);
pub const capacity = 2;
pub const answering_window: u8 = 16;

comptime {
    // The controlled catch-up fixture keeps its lag within the peer-answering
    // window. Actual journal retention is pinned by the published watermark.
    if (answering_window <= capacity + 1) @compileError("fixture backlog must fit within the peer-answering window");
}

pub const Observation = struct { state: chain.State, failure: ?anyerror };
pub const Bridge = struct {
    gpa: Allocator,
    io: std.Io,
    host: *Host,
    state: chain.State,
    observed: chain.State,
    creating_thread: std.Thread.Id,
    mu: std.Io.Mutex = .init,
    failure: ?anyerror = null,
    replayed: u64 = 0,

    pub fn init(gpa: Allocator, io: std.Io, host: *Host, state: chain.State) Bridge {
        return .{ .gpa = gpa, .io = io, .host = host, .state = state, .observed = state, .creating_thread = std.Thread.getCurrentId() };
    }

    pub fn observation(self: *Bridge) Observation {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return .{ .state = self.observed, .failure = self.failure };
    }

    pub fn driver(self: *Bridge) slcp.Driver {
        return .{ .ctx = self, .validate_value = validate, .combine_candidates = combine };
    }

    pub fn delivery(self: *Bridge) slcp.DeliveryHook {
        return .{ .ctx = self, .on_externalized = externalized, .on_failed = failed };
    }

    pub fn recovery(self: *Bridge) slcp.node.RecoveryHook {
        return .{ .ctx = self, .on_recovered = recovered };
    }

    fn validate(context: *anyopaque, slot: u64, bytes: []const u8, _: bool) slcp.Validity {
        const self: *Bridge = @ptrCast(@alignCast(context));
        const command = chain.Codec.decode(bytes) catch return .invalid;
        return chain.validate(&self.state, command, slot);
    }

    fn combine(context: *anyopaque, slot: u64, candidates: []const []const u8, gpa: Allocator, out: *std.ArrayList(u8)) slcp.DriverError!void {
        if (candidates.len == 0) return error.DriverFault;
        var selected = candidates[0];
        for (candidates[1..]) |candidate| {
            if (std.mem.order(u8, candidate, selected) == .lt) selected = candidate;
        }
        if (validate(context, slot, selected, false) == .invalid) return error.DriverFault;
        try out.appendSlice(gpa, selected);
    }

    fn externalized(context: *anyopaque, slot: u64, bytes: []const u8) anyerror!void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (slot <= self.state.advance) return;
        const command = chain.Codec.decode(bytes) catch return error.InvalidAgreedCommand;
        if (chain.validate(&self.state, command, slot) != .valid) return error.NonContiguousCommand;
        var batch = Host.Batch.init(self.gpa);
        defer batch.deinit();
        try batch.put(.accounts, command.account, .{ .balance = command.balance });
        if (command.delete_name) try batch.delete(.names, command.name) else try batch.put(.names, command.name, command.account);
        const is_recovery = std.Thread.getCurrentId() == self.creating_thread;
        while (true) {
            self.host.trySubmit(slot, &batch, bytes) catch |err| switch (err) {
                error.Backpressure => {
                    if (!is_recovery) return error.DiskBackpressure;
                    // Recovery runs on the caller, and may retry a transient
                    // Host mutex conflict without blocking the engine thread.
                    try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
                    continue;
                },
                else => return err,
            };
            break;
        }
        // Only recovery runs on the caller's creating thread. Live delivery
        // never waits for the worker or performs filesystem operations.
        if (is_recovery) {
            try self.host.wait(slot);
            self.replayed += 1;
        }
        chain.accepted(&self.state, command);
        self.mu.lockUncancelable(self.io);
        self.observed = self.state;
        self.mu.unlock(self.io);
    }

    fn failed(context: *anyopaque, err: anyerror) void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.failure == null) self.failure = err;
    }

    fn recovered(context: *anyopaque, view: slcp.node.RecoveryView) anyerror!void {
        const self: *Bridge = @ptrCast(@alignCast(context));
        if (self.state.advance == std.math.maxInt(u64)) return error.SequenceExhausted;
        if (view.journal_tail) |tail| {
            if (tail.last > self.state.advance and tail.contiguous_from > self.state.advance + 1) return error.MissingRequiredJournal;
        } else if (view.externalized_hwm != null) return error.MissingRequiredJournal;
    }
};

test "raw driver selects an admitted command without disk access" {
    // Validation and candidate selection never inspect the Host.
    var unused_host: Host = undefined;
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &unused_host, .{});
    const command = chain.proposal(&bridge.state);
    var alternative = command;
    alternative.balance += 1;
    var a: [chain.Codec.max_size]u8 = undefined;
    var b: [chain.Codec.max_size]u8 = undefined;
    const first = try chain.Codec.encode(command, &a);
    const second = try chain.Codec.encode(alternative, &b);
    const driver = bridge.driver();
    try std.testing.expectEqual(slcp.Validity.valid, driver.validate_value(driver.ctx, 1, first, false));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try driver.combine_candidates(driver.ctx, 1, &.{ second, first }, std.testing.allocator, &output);
    try std.testing.expectEqualSlices(u8, first, output.items);
    try std.testing.expectError(error.DriverFault, driver.combine_candidates(driver.ctx, 1, &.{}, std.testing.allocator, &output));
}

test "startup rejects a missing required journal suffix before disk replay" {
    var unused_host: Host = undefined;
    var bridge = Bridge.init(std.testing.allocator, std.testing.io, &unused_host, .{ .advance = 7 });
    const hook = bridge.recovery();
    try hook.on_recovered(hook.ctx, .{ .externalized_hwm = 10, .journal_tail = .{ .first = 3, .contiguous_from = 8, .last = 10 } });
    try std.testing.expectError(error.MissingRequiredJournal, hook.on_recovered(hook.ctx, .{
        .externalized_hwm = 10,
        .journal_tail = .{ .first = 3, .contiguous_from = 9, .last = 10 },
    }));
    try std.testing.expectError(error.MissingRequiredJournal, hook.on_recovered(hook.ctx, .{ .externalized_hwm = 10, .journal_tail = null }));
    // An independent trusted checkpoint may lead an empty local journal; main
    // supplies its exact previous command and explicit successor start_slot.
    try hook.on_recovered(hook.ctx, .{ .externalized_hwm = null, .journal_tail = null });
}
