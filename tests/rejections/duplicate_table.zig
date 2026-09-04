const lib = @import("bucketlist");
const S = struct {
    pub const namespace = "bad";
    pub const version: u32 = 1;
    pub const tables = .{ .a = lib.Table(1, u64, u64), .b = lib.Table(1, u64, u64) };
};
comptime {
    _ = lib.Definition(S);
}
