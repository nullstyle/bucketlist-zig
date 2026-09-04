const lib = @import("bucketlist");
comptime {
    _ = lib.Table(1, [1025]u8, u64);
}
