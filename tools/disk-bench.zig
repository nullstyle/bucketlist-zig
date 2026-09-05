//! Native disk workload using only public library APIs.
//! disk-bench <empty-root> [mib=64] [batch-rows=64] [read-samples=32] [trials=1]
//! Requested allocation bytes exclude stack, allocator overhead/caches, std.Io
//! internals, and the separately reported bounded fixture buffers. File counts
//! measure public positional I/O calls and returned bytes, not physical media
//! traffic. Reopen and reads use the existing OS cache; no eviction is attempted.
const std = @import("std");
const builtin = @import("builtin");
const bucketlist = @import("bucketlist");
const native = @import("bucketlist-disk");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value(usize);
const value_size = 16 * 1024;
const Value = [value_size]u8;
const Hash = [32]u8;
const Schema = struct {
    pub const namespace = "benchmark.disk.workload.v1";
    pub const version: u32 = 1;
    pub const tables = .{ .records = bucketlist.Table(1, u64, Value) };
};
const Db = native.Database(Schema);
const Proof = struct { digest: Hash, reference: native.Reference };

const Counter = struct {
    child: Allocator = std.heap.smp_allocator,
    live: Atomic = .init(0),
    peak: Atomic = .init(0),
    allocated: Atomic = .init(0),
    allocations: Atomic = .init(0),
    frees: Atomic = .init(0),
    start_live: usize = 0,

    fn allocator(self: *Counter) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn begin(self: *Counter) void {
        self.start_live = self.live.load(.monotonic);
        self.peak.store(self.start_live, .monotonic);
        self.allocated.store(0, .monotonic);
        self.allocations.store(0, .monotonic);
        self.frees.store(0, .monotonic);
    }
    fn add(self: *Counter, n: usize) void {
        const live = self.live.fetchAdd(n, .monotonic) + n;
        _ = self.peak.fetchMax(live, .monotonic);
        _ = self.allocated.fetchAdd(n, .monotonic);
    }
    fn change(self: *Counter, old: usize, new: usize) void {
        if (new >= old) self.add(new - old) else _ = self.live.fetchSub(old - new, .monotonic);
    }
    fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const result = self.child.rawAlloc(n, alignment, ra) orelse return null;
        self.add(n);
        _ = self.allocations.fetchAdd(1, .monotonic);
        return result;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, n, ra)) return false;
        self.change(memory.len, n);
        return true;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const result = self.child.rawRemap(memory, alignment, n, ra) orelse return null;
        self.change(memory.len, n);
        return result;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        _ = self.live.fetchSub(memory.len, .monotonic);
        _ = self.frees.fetchAdd(1, .monotonic);
        self.child.rawFree(memory, alignment, ra);
    }
};

// The benchmark has one active Io wrapper for its entire process. Its pointer
// is initialized before any database/merge thread starts and never changes.
// Original userdata is preserved for all unmodified vtable callbacks.
var active_io: *IoCounter = undefined;
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

const Measurement = struct {
    elapsed_ns: u64,
    start_live_allocation_bytes: usize,
    live_allocation_bytes: usize,
    peak_allocation_bytes: usize,
    allocated_bytes: usize,
    allocation_calls: usize,
    free_calls: usize,
    positional_read_ops: usize,
    positional_read_bytes: usize,
    positional_write_ops: usize,
    positional_write_bytes: usize,
    file_sync_ops: usize,
};
const Meter = struct {
    counter: *Counter,
    io_counter: *IoCounter,
    start: std.Io.Timestamp = undefined,
    fn begin(self: *Meter) void {
        self.counter.begin();
        self.io_counter.begin();
        self.start = std.Io.Clock.awake.now(self.io_counter.original);
    }
    fn finish(self: *Meter) Measurement {
        return .{
            .elapsed_ns = @intCast(self.start.durationTo(std.Io.Clock.awake.now(self.io_counter.original)).nanoseconds),
            .start_live_allocation_bytes = self.counter.start_live,
            .live_allocation_bytes = self.counter.live.load(.monotonic),
            .peak_allocation_bytes = self.counter.peak.load(.monotonic),
            .allocated_bytes = self.counter.allocated.load(.monotonic),
            .allocation_calls = self.counter.allocations.load(.monotonic),
            .free_calls = self.counter.frees.load(.monotonic),
            .positional_read_ops = self.io_counter.read_ops.load(.monotonic),
            .positional_read_bytes = self.io_counter.read_bytes.load(.monotonic),
            .positional_write_ops = self.io_counter.write_ops.load(.monotonic),
            .positional_write_bytes = self.io_counter.write_bytes.load(.monotonic),
            .file_sync_ops = self.io_counter.sync_ops.load(.monotonic),
        };
    }
};

fn json(writer: *std.Io.Writer, row: anytype) !void {
    try std.json.Stringify.value(row, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn fixture(key: u64, revision: u64) Value {
    var value: Value = @splat(@truncate(key *% 17 +% revision *% 29));
    std.mem.writeInt(u64, value[0..8], key, .big);
    std.mem.writeInt(u64, value[8..16], revision, .big);
    return value;
}

const Workload = enum { load, update, noop, delete, insert };
const Run = struct {
    writer: *std.Io.Writer,
    meter: Meter,
    trial: usize,
    workers: usize,
    rows: usize,
    live_rows: usize = 0,
    batch_rows: usize,
    values: []Value,
    keys: []u64,
    proofs: []Proof,
    expected: ?[]const Proof,
    digest_count: usize = 0,
    peak: usize = 0,
    total_ns: u64 = 0,
    total_read_bytes: usize = 0,
    total_read_ops: usize = 0,

    fn emit(self: *Run, phase: []const u8, workload: []const u8, operations: usize, commitment: native.Commitment, reference: ?native.Reference, measurement: Measurement, collected: usize) !void {
        self.peak = @max(self.peak, measurement.peak_allocation_bytes);
        self.total_ns += measurement.elapsed_ns;
        self.total_read_bytes += measurement.positional_read_bytes;
        self.total_read_ops += measurement.positional_read_ops;
        const hex = std.fmt.bytesToHex(commitment.digest, .lower);
        const manifest_hex = if (reference) |ref| std.fmt.bytesToHex(ref.manifest_hash, .lower) else undefined;
        try json(self.writer, .{
            .phase = phase,
            .workload = workload,
            .trial = self.trial,
            .merge_workers = self.workers,
            .records = self.live_rows,
            .logical_bytes = self.live_rows * value_size,
            .operations = operations,
            .advance = commitment.advance,
            .digest = hex[0..],
            .reference_manifest_hash = if (reference != null) manifest_hex[0..] else null,
            .collected_blobs = collected,
            .measurement = measurement,
        });
    }
    fn writes(self: *Run, db: *Db, workload: Workload) !void {
        const count = if (workload == .load) self.rows else self.rows / 4;
        var offset: usize = 0;
        while (offset < count) {
            const n = @min(self.batch_rows, count - offset);
            // Generate one bounded batch outside the allocator/timing window.
            for (0..n) |i| {
                const ordinal = ((offset + i) * 4051) % count;
                const key = switch (workload) {
                    .load => ordinal,
                    .update, .noop => ordinal * 4,
                    .delete => ordinal * 4 + 1,
                    .insert => self.rows + ordinal,
                };
                self.keys[i] = key;
                self.values[i] = fixture(key, switch (workload) {
                    .load => 1,
                    .update, .noop => 2,
                    .delete, .insert => 3,
                });
            }
            var batch = Db.Batch.initBounded(self.meter.counter.allocator(), self.batch_rows * (value_size + 32), self.batch_rows);
            var batch_open = true;
            defer if (batch_open) batch.deinit();
            self.meter.begin();
            for (self.keys[0..n], self.values[0..n]) |key, value| {
                if (workload == .delete) try batch.delete(.records, key) else try batch.put(.records, key, value);
            }
            try self.emit("stage", @tagName(workload), n, db.commitment(), db.reference(), self.meter.finish(), 0);
            const next = db.commitment().advance + 1;
            var metadata: [16]u8 = undefined;
            std.mem.writeInt(u64, metadata[0..8], next, .big);
            std.mem.writeInt(u64, metadata[8..16], self.rows, .big);
            self.meter.begin();
            var prepared = try db.prepare(next, &batch, &metadata);
            defer prepared.deinit();
            try self.emit("prepare", @tagName(workload), n, prepared.commitment(), null, self.meter.finish(), 0);
            self.meter.begin();
            try prepared.commit();
            const committed = self.meter.finish();
            switch (workload) {
                .load, .insert => self.live_rows += n,
                .delete => self.live_rows -= n,
                .update, .noop => {},
            }
            const commitment = db.commitment();
            const proof: Proof = .{ .digest = commitment.digest, .reference = db.reference() };
            self.proofs[self.digest_count] = proof;
            if (self.expected) |expected| if (!std.meta.eql(expected[self.digest_count], proof)) return error.WorkerCommitmentMismatch;
            self.digest_count += 1;
            try self.emit("commit", @tagName(workload), n, commitment, db.reference(), committed, 0);
            self.meter.begin();
            batch.deinit();
            batch_open = false;
            try self.emit("cleanup", @tagName(workload), n, commitment, db.reference(), self.meter.finish(), 0);
            offset += n;
        }
    }
    fn reads(self: *Run, db: *Db, phase: []const u8, samples: usize) !void {
        self.meter.begin();
        for (0..samples) |i| {
            const ordinal = ((i / 5) * 4051) % (self.rows / 4);
            const key = switch (i % 5) {
                0 => ordinal * 4,
                1 => ordinal * 4 + 2,
                2 => ordinal * 4 + 1,
                3 => self.rows + ordinal,
                4 => self.rows + self.rows / 4 + ordinal,
                else => unreachable,
            };
            const actual = try db.get(.records, @intCast(key));
            const revision: ?u64 = switch (i % 5) {
                0 => 2,
                1 => 1,
                3 => 3,
                else => null,
            };
            if (revision) |rev| {
                if (actual == null or !std.mem.eql(u8, &actual.?, &fixture(key, rev))) return error.IncorrectRecord;
            } else if (actual != null) return error.UnexpectedRecord;
        }
        try self.emit(phase, "verify_formula", samples, db.commitment(), db.reference(), self.meter.finish(), 0);
    }
};

fn run(gpa: Allocator, io_counter: *IoCounter, writer: *std.Io.Writer, root: []const u8, rows: usize, batch_rows: usize, samples: usize, trial: usize, workers: usize, expected: ?[]const Proof) ![]Proof {
    const path = try std.fmt.allocPrint(gpa, "{s}/trial-{d}-workers-{d}", .{ root, trial, workers });
    defer gpa.free(path);
    const advances = std.math.divCeil(usize, rows, batch_rows) catch unreachable;
    const sub_advances = std.math.divCeil(usize, rows / 4, batch_rows) catch unreachable;
    const proofs = try gpa.alloc(Proof, advances + 4 * sub_advances);
    errdefer gpa.free(proofs);
    const values = try gpa.alloc(Value, batch_rows);
    defer gpa.free(values);
    const keys = try gpa.alloc(u64, batch_rows);
    defer gpa.free(keys);
    var counter: Counter = .{};
    var context: Run = .{
        .writer = writer,
        .meter = .{ .counter = &counter, .io_counter = io_counter },
        .trial = trial,
        .workers = workers,
        .rows = rows,
        .batch_rows = batch_rows,
        .values = values,
        .keys = keys,
        .proofs = proofs,
        .expected = expected,
    };
    var options: Db.Options = .{ .merge_workers = workers, .max_metadata_bytes = 16 };
    context.meter.begin();
    var db = try Db.open(counter.allocator(), io_counter.io(), path, options);
    var open = true;
    defer if (open) db.deinit();
    if (db.commitment().advance != 0) return error.ExpectedEmptyStore;
    try context.emit("open", "genesis", 0, db.commitment(), db.reference(), context.meter.finish(), 0);
    inline for (std.meta.tags(Workload)) |workload| try context.writes(db, workload);
    if (context.live_rows != rows or context.digest_count != proofs.len) return error.WrongWorkloadSize;
    try context.reads(db, "get", samples);
    const final_commitment = db.commitment();
    options.expected = db.reference();
    context.meter.begin();
    db.deinit();
    open = false;
    try context.emit("close", "before_reopen", 0, final_commitment, options.expected, context.meter.finish(), 0);
    if (counter.live.load(.monotonic) != 0) return error.LeakedLibraryAllocation;
    context.meter.begin();
    db = try Db.open(counter.allocator(), io_counter.io(), path, options);
    open = true;
    if (!std.meta.eql(final_commitment, db.commitment())) return error.ReopenCommitmentMismatch;
    try context.emit("reopen", "authenticated_warm_cache", 0, db.commitment(), db.reference(), context.meter.finish(), 0);
    try context.reads(db, "get_reopened", samples);
    context.meter.begin();
    const collected = try db.collect(&.{});
    if (collected == 0) return error.ExpectedUnreachableBlobs;
    try context.emit("collect", "current_root", 0, db.commitment(), db.reference(), context.meter.finish(), collected);
    try context.reads(db, "get_after_collect", samples);
    context.meter.begin();
    db.deinit();
    open = false;
    try context.emit("close", "final", 0, final_commitment, options.expected, context.meter.finish(), 0);
    if (counter.live.load(.monotonic) != 0) return error.LeakedLibraryAllocation;
    const hex = std.fmt.bytesToHex(final_commitment.digest, .lower);
    const manifest_hex = std.fmt.bytesToHex(options.expected.?.manifest_hash, .lower);
    try json(writer, .{
        .phase = "summary",
        .trial = trial,
        .merge_workers = workers,
        .records = rows,
        .logical_bytes = rows * value_size,
        .advance = final_commitment.advance,
        .digest = hex[0..],
        .reference_manifest_hash = manifest_hex[0..],
        .verified_get_requests = samples * 3,
        .all_advance_digests_and_references_match = expected != null,
        .measured_elapsed_ns = context.total_ns,
        .peak_allocation_bytes = context.peak,
        .live_allocation_bytes = counter.live.load(.monotonic),
        .positional_read_bytes = context.total_read_bytes,
        .positional_read_ops = context.total_read_ops,
    });
    return proofs;
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
    const samples = try argument(&args, 32);
    const trials = try argument(&args, 1);
    if (args.next() != null or mib == 0 or mib > 4096 or !std.math.isPowerOfTwo(mib) or
        batch_rows == 0 or batch_rows > 256 or samples < 5 or samples > 4096 or trials == 0 or trials > 9) return error.InvalidArguments;
    // Dataset freshness affects deduplication, open, and collection timings.
    // Reject even an advance-zero database or unrelated files in the root.
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
    try json(writer, .{
        .phase = "configuration",
        .format = "bucketlist-disk-bench-v1",
        .zig = builtin.zig_version_string,
        .optimize = @tagName(builtin.mode),
        .cpu = @tagName(builtin.cpu.arch),
        .os = @tagName(builtin.os.tag),
        .mib = mib,
        .records = rows,
        .value_bytes = value_size,
        .batch_rows = batch_rows,
        .fixture_buffer_bytes = batch_rows * (value_size + @sizeOf(u64)),
        .comparison_bytes_per_advance_per_worker = @sizeOf(Proof),
        .record_counts = "deterministic model cardinality; point reads sample five value/absence classes",
        .read_samples_per_phase = samples,
        .trials = trials,
        .allocator = "thread-safe requested bytes over std.heap.smp_allocator; excludes fixture, stack, allocator overhead and std.Io allocations",
        .file_io = "public positional callbacks: returned bytes, not physical disk traffic; OS cache is not evicted",
        .fixture_generation_timed = false,
        .get_formula_verification_timed = true,
        .comparison = "identical commands, metadata, and every advance digest and reference across merge_workers=1 and2",
    });
    for (0..trials) |trial| {
        const expected = try run(init.gpa, &io_counter, writer, path, rows, batch_rows, samples, trial, 1, null);
        defer init.gpa.free(expected);
        const actual = try run(init.gpa, &io_counter, writer, path, rows, batch_rows, samples, trial, 2, expected);
        defer init.gpa.free(actual);
    }
}
