//! Production workload qualification harness (three pre-registered shapes).
//!
//! workload-bench ledger  <empty-root> [advances=50000] [keys=1000000] [seed=1] [compress] [pre_publish]
//!   Sustained consensus-node writing: batches of 50-200 changes, 85% puts /
//!   15% deletes over a bounded key space; 93% of values 32-64 B, 6% 256 B-
//!   1 KiB, 1% blobs 1-64 KiB. Reports commit latency distribution and
//!   write amplification (positional write bytes per logical advance byte).
//!   The optional trailing policy strings select compression ("compress")
//!   and the pre_publish durability barrier ("pre_publish"); any other
//!   value (or omission) keeps the default off.
//!
//! workload-bench zipf <empty-root> [keys=500000] [ops=200000] [skew=1.0] [seed=1]
//!   Read serving: builds the key space, then a 95/5 read/write mix over a
//!   Zipf-Mandelbrot key distribution. Reports read and write latency
//!   distributions and sustained ops/sec under realistic skew.
//!
//! workload-bench catchup <empty-root> [history=20000] [suffix=5000] [keys=200000] [seed=1]
//!   Rejoin after downtime: reopen-with-validation wall time and read
//!   traffic at scale, then fastest-possible suffix replay throughput and
//!   the second reopen delta.
//!
//! Positional I/O counters measure logical traffic through public
//! callbacks, not physical media; the OS page cache stays warm.
const std = @import("std");
const builtin = @import("builtin");
const bucketlist = @import("bucketlist");
const native = @import("bucketlist-disk");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value(usize);
const max_value = 64 * 1024;
const Hash = [32]u8;
const Schema = struct {
    pub const namespace = "benchmark.workload.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .accounts = bucketlist.Table(1, u64, bucketlist.Bytes(max_value)) };
};
const Db = native.Database(Schema);

var active_io: *IoCounter = undefined;
var compress_flag: bool = false;
var relaxed_durability: bool = false;
const IoCounter = struct {
    original: std.Io,
    vtable: std.Io.VTable,
    read_ops: Atomic = .init(0),
    read_bytes: Atomic = .init(0),
    write_ops: Atomic = .init(0),
    write_bytes: Atomic = .init(0),
    sync_ops: Atomic = .init(0),

    fn init(original: std.Io) IoCounter {
        var result: IoCounter = .{ .original = original, .vtable = original.vtable.* };
        result.vtable.fileReadPositional = read;
        result.vtable.fileWritePositional = write;
        result.vtable.fileSync = sync;
        return result;
    }
    fn io(self: *IoCounter) std.Io {
        return .{ .userdata = self.original.userdata, .vtable = &self.vtable };
    }
    fn begin(self: *IoCounter) void {
        self.read_ops.store(0, .monotonic);
        self.read_bytes.store(0, .monotonic);
        self.write_ops.store(0, .monotonic);
        self.write_bytes.store(0, .monotonic);
        self.sync_ops.store(0, .monotonic);
    }
    fn read(userdata: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        _ = active_io.read_ops.fetchAdd(1, .monotonic);
        const n = try active_io.original.vtable.fileReadPositional(userdata, file, buffers, offset);
        _ = active_io.read_bytes.fetchAdd(n, .monotonic);
        return n;
    }
    fn write(userdata: ?*anyopaque, file: std.Io.File, header: []const u8, buffers: []const []const u8, splat: usize, offset: u64) std.Io.File.WritePositionalError!usize {
        _ = active_io.write_ops.fetchAdd(1, .monotonic);
        const n = try active_io.original.vtable.fileWritePositional(userdata, file, header, buffers, splat, offset);
        _ = active_io.write_bytes.fetchAdd(n, .monotonic);
        return n;
    }
    fn sync(userdata: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
        _ = active_io.sync_ops.fetchAdd(1, .monotonic);
        return active_io.original.vtable.fileSync(userdata, file);
    }
};

fn json(writer: *std.Io.Writer, row: anytype) !void {
    try std.json.Stringify.value(row, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn quantiles(sorted: []const u64, n: usize) struct { p50: u64, p90: u64, p99: u64, max: u64 } {
    return .{
        .p50 = sorted[n / 2],
        .p90 = sorted[n * 9 / 10],
        .p99 = sorted[n * 99 / 100],
        .max = sorted[n - 1],
    };
}

/// Ledger value distribution: mostly small, some medium, rare blobs.
fn fillValue(random: std.Random, key: u64, buffer: []u8) usize {
    const roll = random.uintLessThan(u32, 100);
    const size: usize = if (roll < 93)
        32 + random.uintAtMost(usize, 32)
    else if (roll < 99)
        256 + random.uintAtMost(usize, 768)
    else
        1024 + random.uintAtMost(usize, max_value - 1024);
    for (buffer[0..size], 0..) |*byte, i| byte.* = @truncate(key *% 17 +% i);
    return size;
}

fn blobStats(root: []const u8, io: std.Io) !struct { count: usize, bytes: u64, largest: u64 } {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var blobs = try dir.openDir(io, "blobs", .{ .iterate = true, .follow_symlinks = false });
    defer blobs.close(io);
    var count: usize = 0;
    var bytes: u64 = 0;
    var largest: u64 = 0;
    var iter = blobs.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = try blobs.statFile(io, entry.name, .{ .follow_symlinks = false });
        count += 1;
        bytes += stat.size;
        largest = @max(largest, stat.size);
    }
    return .{ .count = count, .bytes = bytes, .largest = largest };
}

fn advanceOnce(db: *Db, gpa: Allocator, random: std.Random, keys: u64, batch_max: usize, delete_pct: u32, buffer: []u8) !struct { ns: u64, logical: u64 } {
    const clock = std.Io.Clock.awake;
    const io = active_io.original;
    const changes = 50 + random.uintAtMost(usize, batch_max - 50);
    var batch = Db.Batch.initBounded(gpa, batch_max * (max_value + 32), batch_max);
    defer batch.deinit();
    var logical: u64 = 0;
    for (0..changes) |_| {
        const key = random.uintAtMost(u64, keys - 1);
        if (random.uintLessThan(u32, 100) < delete_pct) {
            try batch.delete(.accounts, key);
            logical += 8;
        } else {
            const size = fillValue(random, key, buffer);
            try batch.put(.accounts, key, try bucketlist.Bytes(max_value).init(buffer[0..size]));
            logical += 8 + size;
        }
    }
    const next = db.commitment().advance + 1;
    var metadata: [16]u8 = undefined;
    std.mem.writeInt(u64, metadata[0..8], next, .big);
    const t0 = clock.now(io);
    var prepared = try db.prepare(next, &batch, &metadata);
    defer prepared.deinit();
    try prepared.commit();
    const t1 = clock.now(io);
    return .{ .ns = @intCast(t0.durationTo(t1).nanoseconds), .logical = logical };
}

fn runLedger(gpa: Allocator, writer: *std.Io.Writer, path: []const u8, advances: usize, keys: u64, seed: u64) !void {
    const clock = std.Io.Clock.awake;
    const io = active_io.original;
    var db = try Db.open(gpa, active_io.io(), path, .{
        .merge_workers = 2,
        .max_metadata_bytes = 16,
        .compression = compress_flag,
        .durability = if (relaxed_durability) .pre_publish else .per_blob,
    });
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var value_buffer: [max_value]u8 = undefined;
    const latencies = try gpa.alloc(u64, advances);
    defer gpa.free(latencies);
    var logical_bytes: u64 = 0;
    active_io.begin();
    const start = clock.now(io);
    for (0..advances) |i| {
        const result = try advanceOnce(db, gpa, random, keys, 200, 15, &value_buffer);
        latencies[i] = result.ns;
        logical_bytes += result.logical;
    }
    const elapsed = start.durationTo(clock.now(io)).nanoseconds;
    const sorted = try gpa.dupe(u64, latencies);
    defer gpa.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    const q = quantiles(sorted, advances);
    const blobs = try blobStats(path, io);
    const advance_count = db.commitment().advance;
    try json(writer, .{
        .phase = "ledger-commit",
        .advances = advance_count,
        .changes_per_batch = "50-200",
        .put_delete_ratio = "85/15",
        .elapsed_ns = @as(u64, @intCast(elapsed)),
        .advances_per_second = @as(f64, @floatFromInt(advances)) / (@as(f64, @floatFromInt(elapsed)) / 1e9),
        .commit_p50_ns = q.p50,
        .commit_p90_ns = q.p90,
        .commit_p99_ns = q.p99,
        .commit_max_ns = q.max,
        .logical_payload_bytes = logical_bytes,
        .positional_write_bytes = active_io.write_bytes.load(.monotonic),
        .write_amplification = @as(f64, @floatFromInt(active_io.write_bytes.load(.monotonic))) / @as(f64, @floatFromInt(logical_bytes)),
        .positional_read_bytes = active_io.read_bytes.load(.monotonic),
        .sync_ops = active_io.sync_ops.load(.monotonic),
        .blob_count = blobs.count,
        .blob_total_bytes = blobs.bytes,
        .largest_blob_bytes = blobs.largest,
        .compressed = compress_flag,
        .durability = if (relaxed_durability) "pre_publish" else "per_blob",
    });
}

fn zipfSample(random: std.Random, cdf: []const f64) u64 {
    const u = random.float(f64);
    var lo: usize = 0;
    var hi: usize = cdf.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cdf[mid] < u) lo = mid + 1 else hi = mid;
    }
    return @intCast(@min(lo, cdf.len - 1));
}

fn runZipf(gpa: Allocator, writer: *std.Io.Writer, path: []const u8, keys: u64, ops: usize, skew: f64, seed: u64) !void {
    const clock = std.Io.Clock.awake;
    const io = active_io.io();
    const real_io = active_io.original;
    var db = try Db.open(gpa, io, path, .{ .merge_workers = 2, .max_metadata_bytes = 16 });
    defer db.deinit();
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var value_buffer: [max_value]u8 = undefined;
    // Build phase: 64-byte values, 200 keys per advance.
    active_io.begin();
    const build_start = clock.now(real_io);
    {
        var key: u64 = 0;
        while (key < keys) {
            const slice = @min(@as(usize, 200), @as(usize, @intCast(keys - key)));
            var batch = Db.Batch.initBounded(gpa, 200 * (max_value + 32), 200);
            defer batch.deinit();
            for (0..slice) |i| {
                const k = key + @as(u64, @intCast(i));
                const size = fillValue(random, k, &value_buffer);
                try batch.put(.accounts, k, try bucketlist.Bytes(max_value).init(value_buffer[0..size]));
            }
            const next = db.commitment().advance + 1;
            var prepared = try db.prepare(next, &batch, "zipf-build");
            defer prepared.deinit();
            try prepared.commit();
            key += slice;
        }
    }
    const build_elapsed = build_start.durationTo(clock.now(real_io)).nanoseconds;
    const build_blobs = try blobStats(path, real_io);
    // Zipf-Mandelbrot CDF over ranks [0, keys).
    const cdf = try gpa.alloc(f64, keys);
    defer gpa.free(cdf);
    {
        var total: f64 = 0;
        for (cdf, 0..) |*w, i| {
            total += 1.0 / std.math.pow(f64, @as(f64, @floatFromInt(i)) + 1.0, skew);
            w.* = total;
        }
        for (cdf) |*w| w.* /= total;
    }
    const read_lat = try gpa.alloc(u64, ops);
    defer gpa.free(read_lat);
    const write_lat = try gpa.alloc(u64, ops);
    defer gpa.free(write_lat);
    var reads: usize = 0;
    var writes: usize = 0;
    active_io.begin();
    const mixed_start = clock.now(real_io);
    for (0..ops) |_| {
        const key = zipfSample(random, cdf);
        if (random.uintLessThan(u32, 100) < 95) {
            const t0 = clock.now(real_io);
            const value = try db.get(.accounts, key);
            const t1 = clock.now(real_io);
            if (value == null) return error.MissingKey;
            read_lat[reads] = @intCast(t0.durationTo(t1).nanoseconds);
            reads += 1;
        } else {
            const size = fillValue(random, key, &value_buffer);
            var batch = Db.Batch.initBounded(gpa, max_value + 32, 1);
            defer batch.deinit();
            try batch.put(.accounts, key, try bucketlist.Bytes(max_value).init(value_buffer[0..size]));
            const next = db.commitment().advance + 1;
            const t0 = clock.now(real_io);
            var prepared = try db.prepare(next, &batch, "zipf-write");
            defer prepared.deinit();
            try prepared.commit();
            const t1 = clock.now(real_io);
            write_lat[writes] = @intCast(t0.durationTo(t1).nanoseconds);
            writes += 1;
        }
    }
    const mixed_elapsed = mixed_start.durationTo(clock.now(real_io)).nanoseconds;
    const sorted_reads = try gpa.dupe(u64, read_lat[0..reads]);
    defer gpa.free(sorted_reads);
    std.mem.sort(u64, sorted_reads, {}, std.sort.asc(u64));
    const qr = quantiles(sorted_reads, reads);
    const sorted_writes = try gpa.dupe(u64, write_lat[0..writes]);
    defer gpa.free(sorted_writes);
    std.mem.sort(u64, sorted_writes, {}, std.sort.asc(u64));
    const qw = quantiles(sorted_writes, writes);
    try json(writer, .{
        .phase = "zipf-build",
        .keys = keys,
        .elapsed_ns = @as(u64, @intCast(build_elapsed)),
        .blob_total_bytes = build_blobs.bytes,
    });
    try json(writer, .{
        .phase = "zipf-mixed",
        .skew = skew,
        .read_write_ratio = "95/5",
        .operations = ops,
        .reads = reads,
        .writes = writes,
        .elapsed_ns = @as(u64, @intCast(mixed_elapsed)),
        .ops_per_second = @as(f64, @floatFromInt(ops)) / (@as(f64, @floatFromInt(mixed_elapsed)) / 1e9),
        .read_p50_ns = qr.p50,
        .read_p90_ns = qr.p90,
        .read_p99_ns = qr.p99,
        .read_max_ns = qr.max,
        .write_p50_ns = qw.p50,
        .write_p99_ns = qw.p99,
        .positional_read_bytes = active_io.read_bytes.load(.monotonic),
        .positional_write_bytes = active_io.write_bytes.load(.monotonic),
    });
}

fn runCatchup(gpa: Allocator, writer: *std.Io.Writer, path: []const u8, history: usize, suffix: usize, keys: u64, seed: u64) !void {
    const clock = std.Io.Clock.awake;
    const io = active_io.original;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var value_buffer: [max_value]u8 = undefined;
    {
        var db = try Db.open(gpa, active_io.io(), path, .{ .merge_workers = 2, .max_metadata_bytes = 16 });
        active_io.begin();
        const build_start = clock.now(io);
        for (0..history) |_| {
            _ = try advanceOnce(db, gpa, random, keys, 120, 15, &value_buffer);
        }
        const build_elapsed = build_start.durationTo(clock.now(io)).nanoseconds;
        const blobs = try blobStats(path, io);
        try json(writer, .{
            .phase = "catchup-history",
            .advances = history,
            .elapsed_ns = @as(u64, @intCast(build_elapsed)),
            .blob_total_bytes = blobs.bytes,
            .blob_count = blobs.count,
        });
        // Reopen with full validation: the restart floor every operator pays.
        const reference = db.reference();
        db.deinit();
        active_io.begin();
        const r0 = clock.now(io);
        var reopened = try Db.open(gpa, active_io.io(), path, .{ .merge_workers = 2, .expected = reference });
        const r1 = clock.now(io);
        const reopen_ns = r0.durationTo(r1).nanoseconds;
        const reopen_read_bytes = active_io.read_bytes.load(.monotonic);
        // Fastest-possible suffix replay.
        active_io.begin();
        const p0 = clock.now(io);
        for (0..suffix) |_| {
            _ = try advanceOnce(reopened, gpa, random, keys, 120, 15, &value_buffer);
        }
        const p1 = clock.now(io);
        const replay_ns = p0.durationTo(p1).nanoseconds;
        const suffix_reference = reopened.reference();
        reopened.deinit();
        active_io.begin();
        const r2 = clock.now(io);
        var second = try Db.open(gpa, active_io.io(), path, .{ .merge_workers = 2, .expected = suffix_reference });
        const r3 = clock.now(io);
        const reopen2_ns = r2.durationTo(r3).nanoseconds;
        second.deinit();
        try json(writer, .{
            .phase = "catchup-reopen",
            .advances_validated = history,
            .reopen_ns = @as(u64, @intCast(reopen_ns)),
            .positional_read_bytes = reopen_read_bytes,
            .validated_gib_per_second = @as(f64, @floatFromInt(blobs.bytes)) / 1024.0 / 1024.0 / 1024.0 / (@as(f64, @floatFromInt(reopen_ns)) / 1e9),
        });
        try json(writer, .{
            .phase = "catchup-replay",
            .advances = suffix,
            .elapsed_ns = @as(u64, @intCast(replay_ns)),
            .advances_per_second = @as(f64, @floatFromInt(suffix)) / (@as(f64, @floatFromInt(replay_ns)) / 1e9),
            .positional_write_bytes = active_io.write_bytes.load(.monotonic),
        });
        try json(writer, .{
            .phase = "catchup-reopen-2",
            .advances_validated = history + suffix,
            .reopen_ns = @as(u64, @intCast(reopen2_ns)),
        });
    }
}

fn argument(args: *std.process.Args.Iterator, default: usize) !usize {
    return if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else default;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return error.ExpectedMode;
    const path = args.next() orelse return error.ExpectedEmptyStorePath;
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{ .open_options = .{ .iterate = true } });
    defer root_dir.close(init.io);
    var entries = root_dir.iterate();
    if (try entries.next(init.io) != null) return error.ExpectedEmptyStorePath;
    var io_counter = IoCounter.init(init.io);
    active_io = &io_counter;
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    const gpa: Allocator = std.heap.smp_allocator;
    try json(writer, .{
        .phase = "configuration",
        .format = "bucketlist-workload-bench-v1",
        .mode = mode,
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .cpu = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
    });
    if (std.mem.eql(u8, mode, "ledger")) {
        const advances = try argument(&args, 50_000);
        const keys = try argument(&args, 1_000_000);
        const seed = try argument(&args, 1);
        // Fourth and fifth arguments are policy strings: "compress" (vs any
        // other value) and "pre_publish" (vs any other value).
        if (args.next()) |flag| compress_flag = std.mem.eql(u8, flag, "compress");
        if (args.next()) |flag| relaxed_durability = std.mem.eql(u8, flag, "pre_publish");
        try runLedger(gpa, writer, path, advances, @intCast(keys), @intCast(seed));
    } else if (std.mem.eql(u8, mode, "zipf")) {
        const keys = try argument(&args, 500_000);
        const ops = try argument(&args, 200_000);
        const skew_x10 = try argument(&args, 10);
        const seed = try argument(&args, 1);
        try runZipf(gpa, writer, path, @intCast(keys), ops, @as(f64, @floatFromInt(skew_x10)) / 10.0, @intCast(seed));
    } else if (std.mem.eql(u8, mode, "catchup")) {
        const history = try argument(&args, 20_000);
        const suffix = try argument(&args, 5_000);
        const keys = try argument(&args, 200_000);
        const seed = try argument(&args, 1);
        try runCatchup(gpa, writer, path, history, suffix, @intCast(keys), @intCast(seed));
    } else return error.UnknownMode;
}
