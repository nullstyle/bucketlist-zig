//! Point-read latency across bucket depths, first-touch and warm.
//! read-bench <empty-root> [mib=64] [batch-rows=64] [samples=128]
//! Per-read latency uses the awake monotonic clock around one public `get`;
//! the OS page cache stays warm (open authenticates every bucket), so costs
//! measure parse and hash work plus logical positional I/O, not physical
//! media. Positional read counters are public-callback counts and returned
//! bytes, not disk traffic.
const std = @import("std");
const builtin = @import("builtin");
const bucketlist = @import("bucketlist");
const native = @import("bucketlist-disk");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value(usize);
const value_size = 16 * 1024;
const Value = [value_size]u8;
const Schema = struct {
    pub const namespace = "benchmark.read-path.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .records = bucketlist.Table(1, u64, Value) };
};
const Db = native.Database(Schema);

var active_io: *IoCounter = undefined;
const IoCounter = struct {
    original: std.Io,
    vtable: std.Io.VTable,
    read_ops: Atomic = .init(0),
    read_bytes: Atomic = .init(0),

    fn init(original: std.Io) IoCounter {
        var result: IoCounter = .{ .original = original, .vtable = original.vtable.* };
        result.vtable.fileReadPositional = read;
        return result;
    }
    fn io(self: *IoCounter) std.Io {
        return .{ .userdata = self.original.userdata, .vtable = &self.vtable };
    }
    fn begin(self: *IoCounter) void {
        self.read_ops.store(0, .monotonic);
        self.read_bytes.store(0, .monotonic);
    }
    fn read(userdata: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        _ = active_io.read_ops.fetchAdd(1, .monotonic);
        const n = try active_io.original.vtable.fileReadPositional(userdata, file, buffers, offset);
        _ = active_io.read_bytes.fetchAdd(n, .monotonic);
        return n;
    }
};

const Class = enum { deep, shallow, miss };

fn fixture(key: u64, revision: u64) Value {
    var value: Value = @splat(@truncate(key *% 17 +% revision *% 29));
    std.mem.writeInt(u64, value[0..8], key, .big);
    std.mem.writeInt(u64, value[8..16], revision, .big);
    return value;
}

fn keyFor(class: Class, rows: usize, i: usize) u64 {
    const span = rows / 8;
    const offset = (i * 4051) % span;
    return switch (class) {
        .deep => offset,
        .shallow => rows - span + offset,
        .miss => rows + offset,
    };
}

fn json(writer: *std.Io.Writer, row: anytype) !void {
    try std.json.Stringify.value(row, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn measure(db: *Db, io_counter: *IoCounter, writer: *std.Io.Writer, phase: []const u8, class: Class, rows: usize, samples: usize, latencies: []u64, gpa: Allocator) !void {
    const clock = std.Io.Clock.awake;
    io_counter.begin();
    for (0..samples) |i| {
        const key = keyFor(class, rows, i);
        const start = clock.now(io_counter.original);
        const value = try db.get(.records, key);
        const end = clock.now(io_counter.original);
        latencies[i] = @intCast(start.durationTo(end).nanoseconds);
        switch (class) {
            .miss => if (value != null) return error.UnexpectedRecord,
            else => if (value == null or !std.mem.eql(u8, &value.?, &fixture(key, 1))) return error.IncorrectRecord,
        }
    }
    const sorted = try gpa.dupe(u64, latencies);
    defer gpa.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (latencies) |ns| sum += ns;
    const ops = io_counter.read_ops.load(.monotonic);
    const bytes = io_counter.read_bytes.load(.monotonic);
    try json(writer, .{
        .phase = phase,
        .class = @tagName(class),
        .samples = samples,
        .median_ns = sorted[samples / 2],
        .p90_ns = sorted[samples * 9 / 10],
        .p99_ns = sorted[samples * 99 / 100],
        .max_ns = sorted[samples - 1],
        .mean_ns = sum / samples,
        .read_ops = ops,
        .read_bytes = bytes,
        .read_bytes_per_read = bytes / samples,
    });
}

fn build(gpa: Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8, rows: usize, batch_rows: usize) !void {
    var db = try Db.open(gpa, io, path, .{ .merge_workers = 2, .max_metadata_bytes = 16 });
    defer db.deinit();
    const clock = std.Io.Clock.awake;
    var values = try gpa.alloc(Value, batch_rows);
    defer gpa.free(values);
    var keys = try gpa.alloc(u64, batch_rows);
    defer gpa.free(keys);
    const start = clock.now(io);
    var offset: usize = 0;
    var advance = db.commitment().advance;
    while (offset < rows) {
        const n = @min(batch_rows, rows - offset);
        var batch = Db.Batch.initBounded(gpa, batch_rows * (value_size + 32), batch_rows);
        defer batch.deinit();
        for (0..n) |i| {
            keys[i] = offset + i;
            values[i] = fixture(offset + i, 1);
            try batch.put(.records, keys[i], values[i]);
        }
        advance += 1;
        var metadata: [16]u8 = undefined;
        std.mem.writeInt(u64, metadata[0..8], advance, .big);
        std.mem.writeInt(u64, metadata[8..16], rows, .big);
        var prepared = try db.prepare(advance, &batch, &metadata);
        defer prepared.deinit();
        try prepared.commit();
        offset += n;
    }
    const elapsed = start.durationTo(clock.now(io)).nanoseconds;
    try json(writer, .{ .phase = "build", .records = rows, .elapsed_ns = @as(u64, @intCast(elapsed)) });
}

fn argument(args: *std.process.Args.Iterator, default: usize) !usize {
    return if (args.next()) |value| try std.fmt.parseInt(usize, value, 10) else default;
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.ExpectedEmptyStorePath;
    const mib = try argument(&args, 64);
    const batch_rows = try argument(&args, 64);
    const samples = try argument(&args, 128);
    if (args.next() != null or mib == 0 or mib > 4096 or !std.math.isPowerOfTwo(mib) or
        batch_rows == 0 or batch_rows > 256 or samples < 8 or samples > 4096) return error.InvalidArguments;
    var root_dir = try std.Io.Dir.cwd().createDirPathOpen(init.io, path, .{ .open_options = .{ .iterate = true } });
    defer root_dir.close(init.io);
    var entries = root_dir.iterate();
    if (try entries.next(init.io) != null) return error.ExpectedEmptyStorePath;
    const rows = mib * 1024 * 1024 / value_size;
    var io_counter = IoCounter.init(init.io);
    active_io = &io_counter;
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    const gpa: Allocator = std.heap.smp_allocator;

    // Report the physical bucket shape the depth classes point into.
    try build(gpa, io_counter.io(), writer, path, rows, batch_rows);
    // Report the physical bucket shape the depth classes point into.
    var blobs_dir = try root_dir.openDir(init.io, "blobs", .{ .iterate = true, .follow_symlinks = false });
    defer blobs_dir.close(init.io);
    var blob_count: usize = 0;
    var blob_bytes: u64 = 0;
    var largest_blob: u64 = 0;
    var blob_iter = blobs_dir.iterate();
    while (try blob_iter.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = try blobs_dir.statFile(init.io, entry.name, .{ .follow_symlinks = false });
        blob_count += 1;
        blob_bytes += stat.size;
        largest_blob = @max(largest_blob, stat.size);
    }
    try json(writer, .{
        .phase = "configuration",
        .format = "bucketlist-read-bench-v1",
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .cpu = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .mib = mib,
        .records = rows,
        .value_bytes = value_size,
        .batch_rows = batch_rows,
        .samples_per_class = samples,
        .blob_count = blob_count,
        .blob_total_bytes = blob_bytes,
        .largest_blob_bytes = largest_blob,
        .classes = "deep=first eighth of key space, shallow=last eighth, miss=beyond range",
    });

    const latencies = try gpa.alloc(u64, samples);
    defer gpa.free(latencies);
    {
        var db = try Db.open(gpa, io_counter.io(), path, .{});
        defer db.deinit();
        inline for (std.meta.tags(Class)) |class| {
            try measure(db, &io_counter, writer, "first_touch", class, rows, samples, latencies, gpa);
        }
        inline for (std.meta.tags(Class)) |class| {
            try measure(db, &io_counter, writer, "warm", class, rows, samples, latencies, gpa);
        }
    }
    {
        const clock = std.Io.Clock.awake;
        const start = clock.now(io_counter.original);
        var db = try Db.open(gpa, io_counter.io(), path, .{});
        defer db.deinit();
        const elapsed = start.durationTo(clock.now(io_counter.original)).nanoseconds;
        try json(writer, .{ .phase = "reopen", .elapsed_ns = @as(u64, @intCast(elapsed)) });
        inline for (std.meta.tags(Class)) |class| {
            try measure(db, &io_counter, writer, "first_touch_reopened", class, rows, samples, latencies, gpa);
        }
    }
}
