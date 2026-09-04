const std = @import("std");
const lib = @import("bucketlist");
const Schema = struct {
    pub const namespace = "benchmark";
    pub const version: u32 = 1;
    pub const tables = .{ .records = lib.Table(1, u64, [64]u8) };
};
const Db = lib.Database(Schema);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var db = Db.init(gpa);
    defer db.deinit();
    const steps = 4096;
    const rows = 1024;
    var timings: [steps]i96 = undefined;
    var map: [rows][64]u8 = @splat(@splat(0));
    var baseline_ns: i96 = 0;
    var baseline_sink: [32]u8 = @splat(0);
    for (1..steps + 1) |seq| {
        const key = seq % rows;
        var value: [64]u8 = @splat(@truncate(seq));
        std.mem.writeInt(u64, value[0..8], seq, .big);
        const start = std.Io.Clock.awake.now(init.io);
        var b = try db.batch(gpa);
        defer b.deinit();
        try b.put(.records, key, value);
        var p = try db.prepareAdvance(gpa, seq, &b);
        defer p.deinit();
        try db.commit(&p);
        // Include commitment computation, not only storage mutation.
        std.mem.doNotOptimizeAway(db.commitment());
        timings[seq - 1] = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
        map[key] = value;
        const baseline_start = std.Io.Clock.awake.now(init.io);
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(std.mem.asBytes(&map));
        baseline_sink = h.finalResult();
        baseline_ns += baseline_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    }
    std.mem.doNotOptimizeAway(baseline_sink);
    std.mem.sort(i96, &timings, {}, std.sort.asc(i96));
    const checkpoint_start = std.Io.Clock.awake.now(init.io);
    const bytes = try db.checkpoint(gpa);
    defer gpa.free(bytes);
    const checkpoint_ns = checkpoint_start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
    std.debug.print("[bench] advances={d} keys={d} value_bytes=64 p50_ns={d} p99_ns={d} max_ns={d} full_map_hash_mean_ns={d} checkpoint_bytes={d} checkpoint_ns={d}\n", .{
        steps, rows, timings[steps / 2], timings[steps * 99 / 100], timings[steps - 1], @divTrunc(baseline_ns, steps), bytes.len, checkpoint_ns,
    });
}
