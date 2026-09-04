//! Example state-machine adapter. The command carries final record values;
//! database roots are calculated during apply and bound into application headers.
const std = @import("std");
const bucketlist = @import("bucketlist");
const slcp = @import("slcp");
const Allocator = std.mem.Allocator;
const Hash = [32]u8;
pub const network = "bucketlist-directory-example-v1";
pub const Name = bucketlist.Bytes(32);
pub const Schema = struct {
    pub const namespace = "example.slcp.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, u64, struct { balance: u64 }),
        .names = bucketlist.Table(2, Name, u64),
    };
};
pub const Database = bucketlist.Database(Schema);
pub const Value = struct {
    advance: u64,
    previous_commitment: Hash,
    previous_header: Hash,
    account: u64,
    balance: u64,
    name: Name,
    remove_name: bool,
};
pub const ValueCodec = bucketlist.Codec(Value);
pub const DirectoryState = struct {
    database: Database,
    header: Hash = genesisHeader(),
    previous_value: ?Value = null,
};
pub const Snapshot = struct {
    checkpoint: []u8,
    advance: u64,
    digest: Hash,
    header: Hash,
    previous_value: ?Value,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.checkpoint);
        self.* = undefined;
    }

    pub fn clone(self: *const Snapshot, gpa: Allocator) Allocator.Error!Snapshot {
        var copy = self.*;
        copy.checkpoint = try gpa.dupe(u8, self.checkpoint);
        return copy;
    }
};

fn genesisHeader() Hash {
    @setEvalBranchQuota(100_000);
    var result: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash("bucketlist.directory.genesis.v1\x00" ++ network, &result, .{});
    return result;
}

fn headerAfter(value: Value, digest: Hash) Hash {
    var bytes: [ValueCodec.max_size]u8 = undefined;
    const encoded = ValueCodec.encode(value, &bytes) catch unreachable;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("bucketlist.directory.header.v1\x00" ++ network);
    hash.update(&value.previous_header);
    hash.update(encoded);
    hash.update(&digest);
    return hash.finalResult();
}

pub const Directory = struct {
    pub const State = DirectoryState;
    pub const Command = Value;
    pub const Obs = Snapshot;
    // The context is trusted local checkpoint material. A peer-supplied digest
    // in the same file is not a checkpoint certificate.
    pub const Context = ?*const Snapshot;
    pub const InitError = error{ OutOfMemory, InvalidSnapshot };

    pub fn initState(context: Context, gpa: Allocator) InitError!State {
        const snapshot = context orelse return .{ .database = Database.init(gpa) };
        var db = Database.restore(gpa, snapshot.checkpoint, snapshot.digest) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSnapshot,
        };
        errdefer db.deinit();
        if (db.commitment().advance != snapshot.advance) return error.InvalidSnapshot;
        if (snapshot.previous_value) |previous| {
            var canonical: [ValueCodec.max_size]u8 = undefined;
            _ = ValueCodec.encode(previous, &canonical) catch return error.InvalidSnapshot;
            if (snapshot.advance == 0 or previous.advance != snapshot.advance or
                !std.mem.eql(u8, &headerAfter(previous, snapshot.digest), &snapshot.header)) return error.InvalidSnapshot;
        } else if (snapshot.advance != 0 or !std.mem.eql(u8, &snapshot.header, &genesisHeader())) return error.InvalidSnapshot;
        return .{ .database = db, .header = snapshot.header, .previous_value = snapshot.previous_value };
    }

    pub fn deinitState(state: *State, _: Allocator) void {
        state.database.deinit();
    }

    pub fn initialSlot(state: *const State) u64 {
        return state.database.commitment().advance;
    }

    pub fn initialCommand(state: *const State) ?Command {
        return state.previous_value;
    }

    pub fn validate(state: *const State, cmd: Command, context: slcp.ValueContext) slcp.Validity {
        // This teaching database has 26 possible accounts and names, keeping
        // resource use bounded independently of the number of advances.
        var scratch: [ValueCodec.max_size]u8 = undefined;
        _ = ValueCodec.encode(cmd, &scratch) catch return .invalid;
        if (cmd.advance == 0 or cmd.advance != context.slot or cmd.account == 0 or cmd.account > 26 or
            cmd.balance > 1_000_000 or cmd.name.len != 1 or cmd.name.data[0] != 'a' + cmd.account - 1) return .invalid;
        const frontier = state.database.commitment();
        if (frontier.advance == std.math.maxInt(u64) or cmd.advance <= frontier.advance) return .invalid;
        // A lagging node lacks the predecessor. Its memory availability cannot
        // affect this verdict, and structural checks still run before it.
        if (cmd.advance > frontier.advance + 1) return .maybe_valid;
        if (!std.mem.eql(u8, &cmd.previous_commitment, &frontier.digest) or
            !std.mem.eql(u8, &cmd.previous_header, &state.header)) return .invalid;
        return .valid;
    }

    pub fn combine(_: *const State, commands: []const Command) Command {
        std.debug.assert(commands.len != 0);
        var selected = commands[0];
        var left: [ValueCodec.max_size]u8 = undefined;
        var right: [ValueCodec.max_size]u8 = undefined;
        for (commands[1..]) |cmd| {
            const candidate = ValueCodec.encode(cmd, &left) catch unreachable;
            const existing = ValueCodec.encode(selected, &right) catch unreachable;
            if (std.mem.order(u8, candidate, existing) == .lt) selected = cmd;
        }
        // Selecting one admitted candidate keeps its valid/maybe-valid verdict.
        return selected;
    }

    pub fn apply(state: *State, cmd: Command, gpa: Allocator) Allocator.Error!void {
        if (validate(state, cmd, .{ .slot = cmd.advance, .phase = .ballot }) != .valid)
            @panic("SLCP delivered an invalid directory successor");
        applyChecked(state, cmd, gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The only mutator owns the batch, encoding was checked, and the
            // advance/base were validated. Any other error is an invariant
            // violation; an agreed value must never be silently skipped.
            else => @panic("directory database invariant violated after validation"),
        };
    }

    fn applyChecked(state: *State, cmd: Command, gpa: Allocator) !void {
        var batch = try state.database.batch(gpa);
        defer batch.deinit();
        try batch.put(.accounts, cmd.account, .{ .balance = cmd.balance });
        if (cmd.remove_name) try batch.delete(.names, cmd.name) else try batch.put(.names, cmd.name, cmd.account);
        var prepared = try state.database.prepareAdvance(gpa, cmd.advance, &batch);
        defer prepared.deinit();
        try state.database.commit(&prepared);
        state.header = headerAfter(cmd, state.database.commitment().digest);
        state.previous_value = cmd;
    }

    pub fn observe(state: *const State, gpa: Allocator) Allocator.Error!Obs {
        const checkpoint = state.database.checkpoint(gpa) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // At most 52 distinct keys per bucket, bounded encodings, and the
            // fixed 11-level profile stay far below the 1 GiB checkpoint cap.
            else => @panic("bounded directory checkpoint invariant violated"),
        };
        return .{
            .checkpoint = checkpoint,
            .advance = state.database.commitment().advance,
            .digest = state.database.commitment().digest,
            .header = state.header,
            .previous_value = state.previous_value,
        };
    }

    pub fn deinitObs(obs: *Obs, gpa: Allocator) void {
        obs.deinit(gpa);
    }

    pub fn encode(cmd: Command, out: []u8) []u8 {
        const bytes = ValueCodec.encode(cmd, out) catch unreachable;
        return out[0..bytes.len];
    }

    pub fn decode(bytes: []const u8) ?Command {
        return ValueCodec.decode(bytes) catch null;
    }
};

pub const Node = slcp.OwnedAppNode(Directory);

pub fn proposal(snapshot: *const Snapshot, account: u64, balance: u64) Value {
    return .{
        .advance = snapshot.advance + 1,
        .previous_commitment = snapshot.digest,
        .previous_header = snapshot.header,
        .account = account,
        .balance = balance,
        .name = Name.init(&.{@intCast('a' + account - 1)}) catch unreachable,
        .remove_name = (snapshot.advance + 1) % 3 == 0,
    };
}

test "bounded codec, future validation, total deterministic combine, and exact snapshot predecessor" {
    const gpa = std.testing.allocator;
    var state = try Directory.initState(null, gpa);
    defer Directory.deinitState(&state, gpa);
    var genesis = try Directory.observe(&state, gpa);
    defer genesis.deinit(gpa);
    const first = proposal(&genesis, 1, 7);
    var alternate = first;
    alternate.balance = 8;
    const future_context: slcp.ValueContext = .{ .slot = 2, .phase = .nomination };
    var future = first;
    future.advance = 2;
    try std.testing.expectEqual(slcp.Validity.maybe_valid, Directory.validate(&state, future, future_context));
    future.balance = 1_000_001;
    try std.testing.expectEqual(slcp.Validity.invalid, Directory.validate(&state, future, future_context));
    const immediate: slcp.ValueContext = .{ .slot = 1, .phase = .ballot };
    const combined = Directory.combine(&state, &.{ alternate, first });
    try std.testing.expectEqualDeep(first, combined);
    try std.testing.expectEqualDeep(combined, Directory.combine(&state, &.{ first, alternate }));
    try std.testing.expectEqual(slcp.Validity.valid, Directory.validate(&state, combined, immediate));
    var bytes: [ValueCodec.max_size]u8 = undefined;
    try std.testing.expectEqualDeep(first, Directory.decode(Directory.encode(first, &bytes)).?);
    try Directory.apply(&state, first, gpa);
    try std.testing.expectEqual(@as(u64, 7), state.database.get(.accounts, 1).?.balance);
    try std.testing.expectEqual(@as(u64, 1), state.database.get(.names, first.name).?);
    var snapshot = try Directory.observe(&state, gpa);
    defer snapshot.deinit(gpa);
    var malformed = snapshot;
    malformed.previous_value.?.name.data[2] = 1;
    try std.testing.expectError(error.InvalidSnapshot, Directory.initState(&malformed, gpa));
    var restored = try Directory.initState(&snapshot, gpa);
    defer Directory.deinitState(&restored, gpa);
    try std.testing.expectEqualDeep(first, Directory.initialCommand(&restored).?);
    try std.testing.expectEqual(@as(u64, 1), Directory.initialSlot(&restored));
    const next = proposal(&snapshot, 1, 9);
    try Directory.apply(&state, next, gpa);
    try Directory.apply(&restored, next, gpa);
    try std.testing.expectEqualSlices(u8, &state.header, &restored.header);
    try std.testing.expectEqualSlices(u8, &state.database.commitment().digest, &restored.database.commitment().digest);
}

test {
    _ = @import("cluster.zig");
}
