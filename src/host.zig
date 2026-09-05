//! Bounded background publication for the native disk database. Admission never
//! performs filesystem I/O; a dedicated thread owns preparation and commit.
const std = @import("std");

pub fn Host(comptime Schema: type) type {
    return struct {
        const Self = @This();
        pub const Disk = @import("disk.zig").Database(Schema);
        pub const Batch = Disk.Batch;
        const Commitment = @typeInfo(@TypeOf(Disk.commitment)).@"fn".return_type.?;
        const Reference = @typeInfo(@TypeOf(Disk.reference)).@"fn".return_type.?;

        pub const Options = struct {
            /// Counts running and queued advances until durable publication.
            capacity: usize = 2,
            disk: Disk.Options = .{},
        };

        pub const Status = struct {
            accepted: u64,
            durable: u64,
            queued: usize,
            capacity: usize,
            failure: ?anyerror,
            /// Total trySubmit rejections for a full or contended ring.
            backpressure: u64 = 0,
        };

        pub const Snapshot = struct {
            commitment: Commitment,
            reference: Reference,
            metadata: []const u8,
            gpa: std.mem.Allocator,
            allocation: []u8,

            pub fn deinit(self: *Snapshot) void {
                self.gpa.free(self.allocation);
                self.* = undefined;
            }
        };

        const Entry = struct {
            batch: ?Batch = null,
            next: u64 = 0,
            metadata_len: usize = 0,
        };

        gpa: std.mem.Allocator,
        io: std.Io,
        options: Options,
        disk: *Disk,
        ring: []Entry,
        metadata_slots: []u8,
        backpressure: std.atomic.Value(u64) = .init(0),
        durable_metadata: []u8,
        durable_metadata_len: usize,
        durable_commitment: Commitment,
        durable_reference: Reference,
        mutex: std.Io.Mutex = .init,
        changed: std.Io.Condition = .init,
        thread: ?std.Thread = null,
        head: usize = 0,
        count: usize = 0,
        accepted: u64,
        paused: bool = false,
        stopping: bool = false,
        failure: ?anyerror = null,

        /// The allocator and Io, including each admitted Batch's allocator,
        /// must support use and freeing from the worker thread. Disk is private
        /// to that thread after create; observations use a copied durable cache.
        pub fn create(gpa: std.mem.Allocator, io: std.Io, path: []const u8, options: Options) !*Self {
            if (options.capacity == 0) return error.InvalidCapacity;
            const slot_bytes = std.math.mul(usize, options.capacity, options.disk.max_metadata_bytes) catch return error.InvalidCapacity;
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            const ring = try gpa.alloc(Entry, options.capacity);
            errdefer gpa.free(ring);
            for (ring) |*entry| entry.* = .{};
            const slots = try gpa.alloc(u8, slot_bytes);
            errdefer gpa.free(slots);
            const metadata = try gpa.alloc(u8, options.disk.max_metadata_bytes);
            errdefer gpa.free(metadata);
            const disk = try Disk.open(gpa, io, path, options.disk);
            errdefer disk.deinit();
            const initial_metadata = disk.metadata();
            if (initial_metadata.len > metadata.len) return error.TooLarge;
            @memcpy(metadata[0..initial_metadata.len], initial_metadata);
            self.* = .{
                .gpa = gpa,
                .io = io,
                .options = options,
                .disk = disk,
                .ring = ring,
                .metadata_slots = slots,
                .durable_metadata = metadata,
                .durable_metadata_len = initial_metadata.len,
                .durable_commitment = disk.commitment(),
                .durable_reference = disk.reference(),
                .accepted = disk.commitment().advance,
            };
            self.thread = try std.Thread.spawn(.{}, worker, .{self});
            return self;
        }

        /// No other caller may use this Host during deinit. Accepted work is
        /// drained, including paused work, unless a worker error prevents it.
        /// Every started thread is joined before owned storage is destroyed.
        pub fn deinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.paused = false;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
            self.thread.?.join();
            std.debug.assert(self.count == 0);
            self.disk.deinit();
            const gpa = self.gpa;
            gpa.free(self.ring);
            gpa.free(self.metadata_slots);
            gpa.free(self.durable_metadata);
            gpa.destroy(self);
        }

        /// Nonblocking admission. On success ownership moves into the queue
        /// and the caller's Batch becomes empty and safe to deinit or reuse.
        /// Every error leaves the Batch and accepted frontier unchanged.
        pub fn trySubmit(self: *Self, next: u64, batch: *Batch, metadata: []const u8) !void {
            if (!self.mutex.tryLock()) {
                _ = self.backpressure.fetchAdd(1, .monotonic);
                return error.Backpressure;
            }
            defer self.mutex.unlock(self.io);
            if (self.stopping) return error.Closed;
            if (self.failure) |err| return err;
            if (self.count == self.ring.len) {
                _ = self.backpressure.fetchAdd(1, .monotonic);
                return error.Backpressure;
            }
            if (self.accepted == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (next != self.accepted + 1) return error.InvalidSequence;
            if (metadata.len > self.options.disk.max_metadata_bytes) return error.TooLarge;
            try batch.checkLimits(self.options.disk);
            const tail = (self.head + self.count) % self.ring.len;
            const destination = self.slotMetadata(tail);
            @memcpy(destination[0..metadata.len], metadata);
            self.ring[tail] = .{ .batch = batch.*, .next = next, .metadata_len = metadata.len };
            batch.* = Batch.init(batch.gpa);
            self.count += 1;
            self.accepted = next;
            if (!self.paused) self.changed.signal(self.io);
        }

        pub fn status(self: *Self) Status {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return .{
                .accepted = self.accepted,
                .durable = self.durable_commitment.advance,
                .backpressure = self.backpressure.load(.monotonic),
                .queued = self.count,
                .capacity = self.ring.len,
                .failure = self.failure,
            };
        }

        /// Wait only for an already admitted sequence. A later failed advance
        /// does not invalidate success for a previously durable sequence.
        pub fn wait(self: *Self, sequence: u64) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (sequence > self.accepted) return error.NotAccepted;
            while (sequence > self.durable_commitment.advance) {
                if (self.failure) |err| return err;
                self.changed.waitUncancelable(self.io, &self.mutex);
            }
        }

        /// This snapshot owns its metadata and survives later publications or
        /// Host destruction. Allocation happens before acquiring the mutex.
        pub fn snapshot(self: *Self, gpa: std.mem.Allocator) !Snapshot {
            const bytes = try gpa.alloc(u8, self.options.disk.max_metadata_bytes);
            errdefer gpa.free(bytes);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const metadata = bytes[0..self.durable_metadata_len];
            @memcpy(metadata, self.durable_metadata[0..metadata.len]);
            return .{
                .commitment = self.durable_commitment,
                .reference = self.durable_reference,
                .metadata = metadata,
                .gpa = gpa,
                .allocation = bytes,
            };
        }

        /// Prevents starting the next entry; already running work continues.
        pub fn pause(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.paused = true;
            self.mutex.unlock(self.io);
        }

        pub fn resumeProcessing(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.paused = false;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        fn slotMetadata(self: *Self, index: usize) []u8 {
            const start = index * self.options.disk.max_metadata_bytes;
            return self.metadata_slots[start..][0..self.options.disk.max_metadata_bytes];
        }

        fn worker(self: *Self) void {
            while (true) {
                self.mutex.lockUncancelable(self.io);
                while (self.count == 0 or self.paused) {
                    if (self.stopping and self.count == 0) {
                        self.mutex.unlock(self.io);
                        return;
                    }
                    self.changed.waitUncancelable(self.io, &self.mutex);
                }
                const index = self.head;
                const entry = self.ring[index];
                // Keep the slot counted and its metadata pinned during I/O.
                self.ring[index].batch = null;
                self.mutex.unlock(self.io);
                var batch = entry.batch.?;
                const metadata = self.slotMetadata(index)[0..entry.metadata_len];
                self.publish(entry.next, &batch, metadata) catch |err| {
                    batch.deinit();
                    self.fail(err);
                    return;
                };
                batch.deinit();
            }
        }

        fn publish(self: *Self, next: u64, batch: *Batch, metadata: []const u8) !void {
            var prepared = try self.disk.prepare(next, batch, metadata);
            defer prepared.deinit();
            try prepared.commit();
            const commitment = self.disk.commitment();
            const reference = self.disk.reference();
            self.mutex.lockUncancelable(self.io);
            @memcpy(self.durable_metadata[0..metadata.len], metadata);
            self.durable_metadata_len = metadata.len;
            self.durable_commitment = commitment;
            self.durable_reference = reference;
            self.head = (self.head + 1) % self.ring.len;
            self.count -= 1;
            self.changed.broadcast(self.io);
            self.mutex.unlock(self.io);
        }

        fn fail(self: *Self, err: anyerror) void {
            self.mutex.lockUncancelable(self.io);
            self.failure = err;
            // The active batch was moved out of this entry and already freed.
            self.head = (self.head + 1) % self.ring.len;
            self.count -= 1;
            self.changed.broadcast(self.io);
            while (self.count != 0) {
                var abandoned = self.ring[self.head].batch.?;
                self.ring[self.head].batch = null;
                self.head = (self.head + 1) % self.ring.len;
                self.count -= 1;
                self.mutex.unlock(self.io);
                abandoned.deinit();
                self.mutex.lockUncancelable(self.io);
            }
            self.mutex.unlock(self.io);
        }
    };
}

const TestSchema = struct {
    pub const namespace = "host.tests";
    pub const version = 1;
    pub const tables = .{ .rows = @import("bucketlist").Table(1, u64, u64) };
};

fn testPath(tmp: *std.testing.TmpDir, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

// Tests may retry transient lock contention because they are outside consensus
// callbacks. Actual callers choose their own policy for any Backpressure.
fn submitTest(host: *Host(TestSchema), next: u64, batch: *Host(TestSchema).Batch, metadata: []const u8) !void {
    for (0..10000) |_| {
        host.trySubmit(next, batch, metadata) catch |err| switch (err) {
            error.Backpressure => {
                try std.Thread.yield();
                continue;
            },
            else => return err,
        };
        return;
    }
    return error.AdmissionDidNotProgress;
}

test "host: nonblocking admission preserves rejected ownership and durable snapshots" {
    const testing = std.testing;
    const H = Host(TestSchema);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const host = try H.create(testing.allocator, testing.io, try testPath(&tmp, &path), .{
        .capacity = 2,
        .disk = .{ .max_metadata_bytes = 4, .max_batch_changes = 1 },
    });
    defer host.deinit();
    host.pause();
    var first = H.Batch.init(testing.allocator);
    defer first.deinit();
    try first.put(.rows, 1, 10);
    const first_key = first.changes.items[0].key.ptr;
    try testing.expectError(error.NotAccepted, host.wait(1));
    try testing.expectError(error.InvalidSequence, submitTest(host, 2, &first, "one"));
    try testing.expectError(error.TooLarge, submitTest(host, 1, &first, "large"));
    try testing.expectEqual(first_key, first.changes.items[0].key.ptr);
    {
        host.mutex.lockUncancelable(testing.io);
        defer host.mutex.unlock(testing.io);
        try testing.expectError(error.Backpressure, host.trySubmit(1, &first, "one"));
    }
    try testing.expectEqual(@as(u64, 1), host.status().backpressure);
    var too_many = H.Batch.init(testing.allocator);
    defer too_many.deinit();
    try too_many.put(.rows, 1, 1);
    try too_many.put(.rows, 2, 2);
    try testing.expectError(error.BatchTooLarge, submitTest(host, 1, &too_many, "one"));
    try testing.expectEqual(@as(usize, 2), too_many.changes.items.len);
    var metadata = [_]u8{ 'o', 'n', 'e' };
    try submitTest(host, 1, &first, &metadata);
    @memset(&metadata, 'x');
    try testing.expectEqual(@as(usize, 0), first.changes.items.len);
    var second = H.Batch.init(testing.allocator);
    defer second.deinit();
    try second.put(.rows, 1, 20);
    var second_metadata = [_]u8{ 't', 'w', 'o' };
    try submitTest(host, 2, &second, &second_metadata);
    @memset(&second_metadata, 'y');
    const status = host.status();
    try testing.expectEqual(@as(u64, 2), status.accepted);
    try testing.expectEqual(@as(u64, 0), status.durable);
    try testing.expectEqual(@as(usize, 2), status.queued);
    try testing.expectEqual(@as(usize, 2), status.capacity);
    try testing.expectEqual(null, status.failure);
    var third = H.Batch.init(testing.allocator);
    defer third.deinit();
    try third.put(.rows, 1, 30);
    const third_key = third.changes.items[0].key.ptr;
    try testing.expectError(error.Backpressure, host.trySubmit(3, &third, "tre"));
    try testing.expectEqual(@as(u64, 2), host.status().backpressure);
    try testing.expectEqual(third_key, third.changes.items[0].key.ptr);
    var genesis = try host.snapshot(testing.allocator);
    defer genesis.deinit();
    try testing.expectEqual(@as(u64, 0), genesis.commitment.advance);
    host.resumeProcessing();
    try host.wait(2);
    var snapshot = try host.snapshot(testing.allocator);
    defer snapshot.deinit();
    try testing.expectEqualStrings("two", snapshot.metadata);
    try testing.expectEqual(@as(u64, 2), snapshot.commitment.advance);
    try testing.expectEqual(snapshot.commitment.digest, snapshot.reference.database_digest);
    try submitTest(host, 3, &third, "tre");
    try host.wait(3);
    var latest = try host.snapshot(testing.allocator);
    defer latest.deinit();
    try testing.expectEqualStrings("tre", latest.metadata);
    try testing.expectEqualStrings("two", snapshot.metadata);
    try testing.expectEqual(@as(u64, 0), genesis.commitment.advance);
    var expected = @import("bucketlist").Database(TestSchema).init(testing.allocator);
    defer expected.deinit();
    for (1..4) |sequence| {
        var batch = try expected.batch(testing.allocator);
        defer batch.deinit();
        try batch.put(.rows, 1, sequence * 10);
        var prepared = try expected.prepareAdvance(testing.allocator, sequence, &batch);
        defer prepared.deinit();
        try expected.commit(&prepared);
    }
    try testing.expectEqual(expected.commitment(), latest.commitment);
}

test "host: shutdown resumes and drains accepted work before closing the disk" {
    const testing = std.testing;
    const H = Host(TestSchema);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, &buffer);
    {
        const host = try H.create(testing.allocator, testing.io, path, .{});
        defer host.deinit();
        host.pause();
        for (1..3) |sequence| {
            var batch = H.Batch.init(testing.allocator);
            defer batch.deinit();
            try batch.put(.rows, sequence, sequence * 10);
            try submitTest(host, sequence, &batch, "drained");
        }
        try testing.expectEqual(@as(u64, 0), host.status().durable);
    }
    const disk = try H.Disk.open(testing.allocator, testing.io, path, .{});
    defer disk.deinit();
    try testing.expectEqual(@as(u64, 2), disk.commitment().advance);
    try testing.expectEqual(@as(?u64, 10), try disk.get(.rows, 1));
    try testing.expectEqual(@as(?u64, 20), try disk.get(.rows, 2));
    try testing.expectEqualStrings("drained", disk.metadata());
}

test "host: missing input latches failure and abandons later accepted batches" {
    const testing = std.testing;
    const H = Host(TestSchema);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const host = try H.create(testing.allocator, testing.io, try testPath(&tmp, &buffer), .{});
    defer host.deinit();
    host.pause();
    var before = try host.snapshot(testing.allocator);
    defer before.deinit();
    for (1..3) |sequence| {
        var batch = H.Batch.init(testing.allocator);
        defer batch.deinit();
        try batch.put(.rows, sequence, sequence);
        try submitTest(host, sequence, &batch, "unpublished");
    }
    var name_buffer: [70]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "blobs/{s}", .{std.fmt.bytesToHex(@import("frontier.zig").emptyHash(), .lower)});
    try tmp.dir.deleteFile(testing.io, name);
    host.resumeProcessing();
    try testing.expectError(error.NotFound, host.wait(2));
    const failed = host.status();
    try testing.expectEqual(@as(u64, 0), failed.durable);
    try testing.expectEqual(@as(u64, 2), failed.accepted);
    try testing.expectEqual(@as(?anyerror, error.NotFound), failed.failure);
    try host.wait(0);
    var rejected = H.Batch.init(testing.allocator);
    defer rejected.deinit();
    try rejected.put(.rows, 3, 3);
    const key = rejected.changes.items[0].key.ptr;
    try testing.expectError(error.NotFound, submitTest(host, 3, &rejected, "rejected"));
    try testing.expectEqual(key, rejected.changes.items[0].key.ptr);
    var after = try host.snapshot(testing.allocator);
    defer after.deinit();
    try testing.expectEqual(before.commitment, after.commitment);
    try testing.expectEqual(before.reference, after.reference);
    try testing.expectEqualSlices(u8, before.metadata, after.metadata);
}

test "host: catalog publication failure never advances the durable observation" {
    const testing = std.testing;
    const H = Host(TestSchema);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const host = try H.create(testing.allocator, testing.io, try testPath(&tmp, &buffer), .{});
    defer host.deinit();
    host.pause();
    var before = try host.snapshot(testing.allocator);
    defer before.deinit();
    var batch = H.Batch.init(testing.allocator);
    defer batch.deinit();
    try batch.put(.rows, 1, 10);
    try submitTest(host, 1, &batch, "cannot publish");
    // Replace the catalog destination with a directory. Preparation can write
    // all immutable blobs, but atomic catalog replacement must fail.
    try tmp.dir.deleteFile(testing.io, "manifest");
    try tmp.dir.createDirPath(testing.io, "manifest");
    host.resumeProcessing();
    try testing.expectError(error.IoFailed, host.wait(1));
    var after = try host.snapshot(testing.allocator);
    defer after.deinit();
    try testing.expectEqual(before.commitment, after.commitment);
    try testing.expectEqual(before.reference, after.reference);
    try testing.expectEqual(@as(?anyerror, error.IoFailed), host.status().failure);
}

test "host: admission uses preallocated storage and snapshot OOM preserves state" {
    const testing = std.testing;
    const H = Host(TestSchema);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    // One merge worker keeps this test-only allocator confined to one thread
    // while disk work runs; the publisher is paused while its limit is changed.
    const host = try H.create(failing.allocator(), testing.io, try testPath(&tmp, &buffer), .{ .disk = .{ .merge_workers = 1 } });
    defer host.deinit();
    host.pause();
    var batch = H.Batch.init(testing.allocator);
    defer batch.deinit();
    try batch.put(.rows, 1, 1);
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    try submitTest(host, 1, &batch, "owned without admission allocation");
    try testing.expect(!failing.has_induced_failure);
    var snapshot_failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, host.snapshot(snapshot_failing.allocator()));
    const state = host.status();
    try testing.expectEqual(@as(u64, 1), state.accepted);
    try testing.expectEqual(@as(u64, 0), state.durable);
    try testing.expectEqual(@as(usize, 1), state.queued);
}

test "host: active publication counts against capacity and pause preserves it" {
    const testing = std.testing;
    const H = Host(TestSchema);
    const Gate = struct {
        var armed: std.atomic.Value(bool) = .init(false);
        var reached: std.Io.Event = .unset;
        var proceed: std.Io.Event = .unset;

        fn create(ctx: ?*anyopaque, dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
            if (std.mem.eql(u8, name, "manifest") and armed.swap(false, .acq_rel)) {
                reached.set(testing.io);
                proceed.waitUncancelable(testing.io);
            }
            return testing.io.vtable.dirCreateFileAtomic(ctx, dir, name, options);
        }
    };
    Gate.armed.store(false, .release);
    Gate.reached = .unset;
    Gate.proceed = .unset;
    var vtable = testing.io.vtable.*;
    vtable.dirCreateFileAtomic = Gate.create;
    const io: std.Io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const host = try H.create(testing.allocator, io, try testPath(&tmp, &buffer), .{});
    defer host.deinit();
    // Every assertion/error path must release the worker before joining it.
    defer Gate.proceed.set(testing.io);
    Gate.armed.store(true, .release);
    var first = H.Batch.init(testing.allocator);
    defer first.deinit();
    try first.put(.rows, 1, 10);
    try submitTest(host, 1, &first, "first");
    try Gate.reached.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    // Actual file publication is now held outside the Host mutex. Neither
    // status nor admission should wait for the filesystem operation.
    const active = host.status();
    try testing.expectEqual(@as(u64, 0), active.durable);
    try testing.expectEqual(@as(usize, 1), active.queued);
    host.pause();
    var second = H.Batch.init(testing.allocator);
    defer second.deinit();
    try second.put(.rows, 2, 20);
    try submitTest(host, 2, &second, "second");
    var rejected = H.Batch.init(testing.allocator);
    defer rejected.deinit();
    try rejected.put(.rows, 3, 30);
    try testing.expectError(error.Backpressure, host.trySubmit(3, &rejected, "third"));
    try testing.expectEqual(@as(usize, 1), rejected.changes.items.len);
    Gate.proceed.set(testing.io);
    try host.wait(1);
    const paused = host.status();
    try testing.expectEqual(@as(u64, 1), paused.durable);
    try testing.expectEqual(@as(u64, 2), paused.accepted);
    try testing.expectEqual(@as(usize, 1), paused.queued);
    var first_snapshot = try host.snapshot(testing.allocator);
    defer first_snapshot.deinit();
    try testing.expectEqualStrings("first", first_snapshot.metadata);
    host.resumeProcessing();
    try host.wait(2);
    var second_snapshot = try host.snapshot(testing.allocator);
    defer second_snapshot.deinit();
    try testing.expectEqualStrings("second", second_snapshot.metadata);
    try testing.expectEqualStrings("first", first_snapshot.metadata);
}
