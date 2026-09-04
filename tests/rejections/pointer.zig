const lib = @import("bucketlist");
comptime {
    _ = lib.Codec([]const u8);
}
