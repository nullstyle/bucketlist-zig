//! Consensus agrees on bounded blind writes and their command ancestry.
//! The disk worker computes the database commitment after externalization.
const std = @import("std");
const bucketlist = @import("bucketlist");
const slcp = @import("slcp");
pub const Hash = [32]u8;
pub const network = "bucketlist-slcp-disk-example-v1";
pub const Name = bucketlist.Bytes(32);
pub const Schema = struct {
    pub const namespace = "example.slcp.disk-directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, u64, struct { balance: u64 }),
        .names = bucketlist.Table(2, Name, u64),
    };
};
pub const Command = struct {
    advance: u64,
    previous_command: Hash,
    account: u64,
    balance: u64,
    name: Name,
    delete_name: bool,
};
pub const Codec = bucketlist.Codec(Command);
pub const State = struct {
    advance: u64 = 0,
    command_hash: Hash = genesis(),
    previous: ?Command = null,
};

fn genesis() Hash {
    @setEvalBranchQuota(100_000);
    var result: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash("bucketlist.slcp-disk.genesis.v1\x00" ++ network, &result, .{});
    return result;
}

pub fn commandHash(command: Command) Hash {
    var bytes: [Codec.max_size]u8 = undefined;
    const encoded = Codec.encode(command, &bytes) catch unreachable;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("bucketlist.slcp-disk.command.v1\x00" ++ network);
    hash.update(encoded);
    return hash.finalResult();
}

pub fn structural(command: Command, slot: u64) bool {
    var bytes: [Codec.max_size]u8 = undefined;
    _ = Codec.encode(command, &bytes) catch return false;
    return command.advance != 0 and command.advance == slot and command.account >= 1 and command.account <= 26 and
        command.balance <= 1_000_000 and command.name.len == 1 and command.name.data[0] == 'a' + command.account - 1;
}

pub fn validate(state: *const State, command: Command, slot: u64) slcp.Validity {
    if (!structural(command, slot) or state.advance == std.math.maxInt(u64) or command.advance <= state.advance) return .invalid;
    if (command.advance > state.advance + 1) return .maybe_valid;
    if (!std.mem.eql(u8, &command.previous_command, &state.command_hash)) return .invalid;
    return .valid;
}

pub fn accepted(state: *State, command: Command) void {
    std.debug.assert(validate(state, command, command.advance) == .valid);
    state.* = .{ .advance = command.advance, .command_hash = commandHash(command), .previous = command };
}

pub fn restore(advance: u64, metadata: []const u8) !State {
    if (advance == 0) {
        if (metadata.len != 0) return error.InvalidGenesisMetadata;
        return .{};
    }
    const previous = Codec.decode(metadata) catch return error.InvalidCommandMetadata;
    if (!structural(previous, advance)) return error.InvalidCommandMetadata;
    return .{ .advance = advance, .command_hash = commandHash(previous), .previous = previous };
}

pub fn proposal(state: *const State) Command {
    const advance = state.advance + 1;
    return .{
        .advance = advance,
        .previous_command = state.command_hash,
        .account = 1,
        .balance = 100 + advance,
        .name = Name.init("a") catch unreachable,
        .delete_name = advance % 3 == 0,
    };
}

test "blind-write validity depends on the bounded command chain, including future values" {
    var state: State = .{};
    const first = proposal(&state);
    try std.testing.expectEqual(slcp.Validity.valid, validate(&state, first, 1));
    var changed = first;
    changed.previous_command[0] ^= 1;
    try std.testing.expectEqual(slcp.Validity.invalid, validate(&state, changed, 1));
    changed = first;
    changed.advance = 2;
    try std.testing.expectEqual(slcp.Validity.maybe_valid, validate(&state, changed, 2));
    changed.name.len = 33;
    try std.testing.expectEqual(slcp.Validity.invalid, validate(&state, changed, 2));
    accepted(&state, first);
    try std.testing.expectEqual(slcp.Validity.invalid, validate(&state, first, 1));
    var bytes: [Codec.max_size]u8 = undefined;
    const restored = try restore(1, try Codec.encode(first, &bytes));
    try std.testing.expectEqualDeep(state, restored);
    try std.testing.expectEqualDeep(proposal(&state), proposal(&restored));
    try std.testing.expectError(error.InvalidCommandMetadata, restore(2, try Codec.encode(first, &bytes)));
}
