const lib = @import("bucketlist");
comptime {
    _ = lib.Codec(f64);
}
