//! Reproducible public-API scalability measurements.
//! Usage: scalability <empty-native-store-root> [trials=3]
//! Compile identical source against the baseline and candidate libraries.
//! JSONL counts requested allocator bytes, excluding stack/allocator metadata,
//! fixture construction, filesystem cache memory, and allocations inside std.Io.
const std = @import("std");
const builtin = @import("builtin");
const bucketlist = @import("bucketlist");
const checkpoints = @import("bucketlist-checkpoints");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const StageSchema = struct {
    pub const namespace = "benchmark.scalability.batch.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .records = bucketlist.Table(1, u64, [64]u8) };
};
const StageDb = bucketlist.Database(StageSchema);
const NativeSchema = struct {
    pub const namespace = "benchmark.scalability.native.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .records = bucketlist.Table(1, u64, [1024]u8) };
};
const NativeDb = bucketlist.Database(NativeSchema);
const NativeCheckpoints = checkpoints.Checkpoints(NativeDb);
const native_rows = 8192;
const native_advances = 17;
const native_metadata = "scalability-v1:exact-application-metadata:advance=17";

const Measurement = struct {
    duration_ns: u64,
    start_live_bytes: usize,
    end_live_bytes: usize,
    peak_live_bytes: usize,
    peak_extra_bytes: usize,
    peak_above_retained_bytes: usize,
    allocated_bytes: usize,
    alloc_calls: usize,
    resize_calls: usize,
    remap_calls: usize,
    free_calls: usize,
};

/// Tracks the allocator's logical requested allocations. A resize/remap counts
/// only positive growth, since allocator-internal remap copies are not visible
/// through the public allocator interface. All benchmark operations are serial.
const CountingAllocator = struct {
    child: Allocator,
    live_bytes: usize = 0,
    start_live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    allocated_bytes: usize = 0,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    free_calls: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free } };
    }

    fn begin(self: *CountingAllocator) void {
        self.start_live_bytes = self.live_bytes;
        self.peak_live_bytes = self.live_bytes;
        self.allocated_bytes = 0;
        self.alloc_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.free_calls = 0;
    }

    fn finish(self: *const CountingAllocator, duration_ns: u64) Measurement {
        return .{
            .duration_ns = duration_ns,
            .start_live_bytes = self.start_live_bytes,
            .end_live_bytes = self.live_bytes,
            .peak_live_bytes = self.peak_live_bytes,
            .peak_extra_bytes = self.peak_live_bytes - self.start_live_bytes,
            .peak_above_retained_bytes = self.peak_live_bytes - self.live_bytes,
            .allocated_bytes = self.allocated_bytes,
            .alloc_calls = self.alloc_calls,
            .resize_calls = self.resize_calls,
            .remap_calls = self.remap_calls,
            .free_calls = self.free_calls,
        };
    }

    fn added(self: *CountingAllocator, size: usize) void {
        self.live_bytes += size;
        self.allocated_bytes += size;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
    }

    fn changed(self: *CountingAllocator, previous: usize, current: usize) void {
        if (current >= previous) self.added(current - previous) else self.live_bytes -= previous - current;
    }

    fn allocate(context: *anyopaque, size: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(size, alignment, return_address) orelse return null;
        self.alloc_calls += 1;
        self.added(size);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: Alignment, size: usize, return_address: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, size, return_address)) return false;
        self.resize_calls += 1;
        self.changed(memory.len, size);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, size: usize, return_address: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, size, return_address) orelse return null;
        self.remap_calls += 1;
        self.changed(memory.len, size);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.free_calls += 1;
        self.live_bytes -= memory.len;
    }
};

fn elapsed(io: std.Io, start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn writeRow(writer: *std.Io.Writer, row: anytype) !void {
    try std.json.Stringify.value(row, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn fixtureValue(comptime size: usize, key: u64, revision: u64) [size]u8 {
    var result: [size]u8 = @splat(@truncate(key *% 17 +% revision *% 29));
    std.mem.writeInt(u64, result[0..8], key, .big);
    std.mem.writeInt(u64, result[8..16], revision, .big);
    return result;
}

const Put = struct { key: u64, value: [64]u8 };

fn stageBenchmark(gpa: Allocator, io: std.Io, writer: *std.Io.Writer, rows: usize, trials: usize) !void {
    // Generate the permutation and both revisions before any measurement.
    const puts = try gpa.alloc(Put, rows * 2);
    defer gpa.free(puts);
    for (0..rows) |index| {
        const key = (index * 4051) & (rows - 1);
        puts[index] = .{ .key = key, .value = fixtureValue(64, key, 1) };
        puts[rows * 2 - 1 - index] = .{ .key = key, .value = fixtureValue(64, key, 2) };
    }
    for (0..trials) |trial| {
        var counter: CountingAllocator = .{ .child = gpa };
        const measured = counter.allocator();
        var db = StageDb.init(measured);
        var batch = try db.batch(measured);
        counter.begin();
        var start = std.Io.Clock.awake.now(io);
        for (puts[0..rows]) |put| try batch.put(.records, put.key, put.value);
        const unique = counter.finish(elapsed(io, start));
        counter.begin();
        start = std.Io.Clock.awake.now(io);
        for (puts[rows..]) |put| try batch.put(.records, put.key, put.value);
        const duplicates = counter.finish(elapsed(io, start));
        counter.begin();
        start = std.Io.Clock.awake.now(io);
        var prepared = try db.prepareAdvance(measured, 1, &batch);
        const prepare = counter.finish(elapsed(io, start));
        counter.begin();
        start = std.Io.Clock.awake.now(io);
        try db.commit(&prepared);
        const commit = counter.finish(elapsed(io, start));
        const digest = std.fmt.bytesToHex(db.commitment().digest, .lower);
        if (!std.mem.eql(u8, &db.get(.records, 0).?, &fixtureValue(64, 0, 2)) or
            !std.mem.eql(u8, &db.get(.records, rows - 1).?, &fixtureValue(64, rows - 1, 2))) return error.WrongStagedValue;
        prepared.deinit();
        batch.deinit();
        db.deinit();
        if (counter.live_bytes != 0) return error.LeakedBatchAllocation;
        try writeRow(writer, .{
            .case = "batch",
            .trial = trial,
            .rows = rows,
            .put_calls = rows * 2,
            .value_bytes = 64,
            .unique = unique,
            .duplicates = duplicates,
            .prepare = prepare,
            .commit = commit,
            .digest = digest[0..],
        });
    }
}

fn nativeFixture(gpa: Allocator) !NativeDb {
    var db = NativeDb.init(gpa);
    errdefer db.deinit();
    for (1..native_advances + 1) |advance| {
        var batch = try db.batch(gpa);
        defer batch.deinit();
        const count: usize = if (advance == 1) native_rows else 256;
        for (0..count) |index| {
            const key = if (advance == 1) (index * 4051) & (native_rows - 1) else ((advance * 256 + index) * 4051) & (native_rows - 1);
            try batch.put(.records, key, fixtureValue(1024, key, advance));
        }
        var prepared = try db.prepareAdvance(gpa, advance, &batch);
        defer prepared.deinit();
        try db.commit(&prepared);
    }
    return db;
}

fn nativeBenchmark(gpa: Allocator, io: std.Io, writer: *std.Io.Writer, path: []const u8, trials: usize) !void {
    // Database construction and the portable-size oracle are deliberately
    // outside counted allocators and timed save/load operations.
    var db = try nativeFixture(gpa);
    defer db.deinit();
    const portable_bytes = size: {
        const portable = try db.checkpoint(gpa);
        defer gpa.free(portable);
        break :size portable.len;
    };
    if (portable_bytes < 4 * 1024 * 1024) return error.NativeFixtureTooSmall;
    var view = db.readView();
    defer view.deinit();
    const digest = std.fmt.bytesToHex(view.commitment().digest, .lower);
    try writeRow(writer, .{
        .case = "native_fixture",
        .live_rows = native_rows,
        .value_bytes = 1024,
        .advances = native_advances,
        .portable_checkpoint_bytes = portable_bytes,
        .digest = digest[0..],
        .save_policy = "new_store_each_trial",
        .load_policy = "reopen_after_save_os_cache_not_evicted",
    });
    for (0..trials) |trial| {
        const store_path = try std.fmt.allocPrint(gpa, "{s}/native-{d}", .{ path, trial });
        defer gpa.free(store_path);
        var counter: CountingAllocator = .{ .child = gpa };
        const measured = counter.allocator();
        const reference, const save = saved: {
            var manager = try NativeCheckpoints.open(measured, io, store_path, .{});
            defer manager.deinit();
            if (try manager.current() != null) return error.StorageAlreadyInitialized;
            counter.begin();
            const start = std.Io.Clock.awake.now(io);
            const reference = try manager.save(&view, native_metadata);
            const measurement = counter.finish(elapsed(io, start));
            break :saved .{ reference, measurement };
        };
        if (counter.live_bytes != 0) return error.LeakedSaveAllocation;
        const load = loaded: {
            var manager = try NativeCheckpoints.open(measured, io, store_path, .{});
            defer manager.deinit();
            counter.begin();
            const start = std.Io.Clock.awake.now(io);
            var restored = try manager.load(measured, reference);
            const measurement = counter.finish(elapsed(io, start));
            defer restored.deinit();
            if (!std.mem.eql(u8, &db.commitment().digest, &restored.database.commitment().digest) or
                !std.mem.eql(u8, native_metadata, restored.metadata)) return error.RestoreMismatch;
            break :loaded measurement;
        };
        if (counter.live_bytes != 0) return error.LeakedLoadAllocation;
        const manifest = std.fmt.bytesToHex(reference.manifest_hash, .lower);
        try writeRow(writer, .{
            .case = "native_checkpoint",
            .trial = trial,
            .portable_checkpoint_bytes = portable_bytes,
            .save = save,
            .load = load,
            .manifest_hash = manifest[0..],
        });
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: scalability <empty-native-store-root> [trials=3]\n", .{});
        return error.MissingStoragePath;
    };
    const trials = if (args.next()) |argument| try std.fmt.parseInt(usize, argument, 10) else 3;
    if (trials == 0 or trials > 9 or args.next() != null) return error.InvalidArguments;
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    const writer = &output.interface;
    try writeRow(writer, .{
        .case = "configuration",
        .format = "bucketlist-scalability-v1",
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .cpu = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .allocator = "std.process.Init.gpa wrapped with requested-byte accounting",
        .trials = trials,
        .fixture_generation_timed = false,
    });
    for ([_]usize{ 1024, 4096, 16384 }) |rows| try stageBenchmark(init.gpa, init.io, writer, rows, trials);
    try nativeBenchmark(init.gpa, init.io, writer, path, trials);
}
