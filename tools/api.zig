const std = @import("std");
const lib = @import("bucketlist");
const Schema = struct {
    pub const namespace = "api";
    pub const version: u32 = 1;
    pub const tables = .{ .rows = lib.Table(1, u64, u64) };
};
const Db = lib.Database(Schema);
pub fn main() void {
    std.debug.print("bucketlist API — Experimental v1\n", .{});
    inline for (@typeInfo(lib).@"struct".decl_names) |name| {
        std.debug.print("export {s}\n", .{name});
    }
    describe("Database", Db);
    describe("Batch", Db.Batch);
    describe("Prepared", Db.Prepared);
    describe("ReadView", Db.ReadView);
    describe("Codec(u64)", lib.Codec(u64));
    describe("Bytes(32)", lib.Bytes(32));
}

fn describe(comptime label: []const u8, comptime Container: type) void {
    inline for (@typeInfo(Container).@"struct".decl_names) |name| {
        const T = @TypeOf(@field(Container, name));
        if (@typeInfo(T) == .@"fn") std.debug.print("{s}.{s}: {s}\n", .{ label, name, @typeName(T) });
    }
}
