const std = @import("std");
const databases = @import("database.zig");
const schema = @import("schema.zig");
const gpa = std.testing.allocator;
const Db = databases.DatabaseWithDepth(struct {
    pub const namespace = "checkpoint.streaming";
    pub const version: u32 = 1;
    pub const tables = .{ .rows = schema.Table(1, u64, u64) };
}, 3);

fn advance(db: *Db, seq: u64) !void {
    var batch = try db.batch(gpa);
    defer batch.deinit();
    if (seq % 4 == 0) try batch.delete(.rows, seq % 13) else try batch.put(.rows, seq % 13, seq * 17);
    var prepared = try db.prepareAdvance(gpa, seq, &batch);
    defer prepared.deinit();
    try db.commit(&prepared);
}

/// Reuses and overwrites one buffer on EVERY call, including absent pending
/// frames. A restorer retaining borrowed slices would corrupt earlier buckets.
const ReusingSource = struct {
    layout: Db.CheckpointLayout,
    scratch: [4096]u8 = undefined,
    calls: usize = 0,
    fail_at: ?usize = null,
    omit_at: ?usize = null,

    pub fn bucket(self: *@This(), level: usize, slot: Db.CheckpointSlot) !?[]const u8 {
        const call = self.calls;
        self.calls += 1;
        try std.testing.expectEqual(call / 3, level);
        try std.testing.expectEqual(@as(Db.CheckpointSlot, @fromBackingInt(@intCast(call % 3))), slot);
        @memset(&self.scratch, 0xaa);
        if (self.fail_at == call) return error.SourceReadFailed;
        if (self.omit_at == call) return null;
        const frames = self.layout.levels[level];
        const frame = (switch (slot) {
            .current => frames.curr,
            .snapshot => frames.snap,
            .pending => frames.next,
        }) orelse return null;
        try std.testing.expect(frame.len <= self.scratch.len);
        @memcpy(self.scratch[0..frame.len], frame);
        return self.scratch[0..frame.len];
    }
};

test "borrowed checkpoint layouts preserve pinned views and reusable-source continuation" {
    var db = Db.init(gpa);
    defer db.deinit();
    for (1..66) |seq| {
        try advance(&db, seq);
        var view = db.readView();
        defer view.deinit();
        const layout = view.checkpointLayout();
        const portable = try view.checkpoint(gpa);
        defer gpa.free(portable);
        try std.testing.expectEqual(portable.len, try layout.encodedSize());
        try std.testing.expectEqualSlices(u8, portable[0..Db.CheckpointLayout.header_len], &layout.header);
        var source: ReusingSource = .{ .layout = layout };
        var restored = try Db.restoreFrom(gpa, &layout.header, &source, view.commitment().digest);
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 9), source.calls);
        @memset(&source.scratch, 0xff);
        try std.testing.expectEqual(db.commitment(), restored.commitment());
        for (0..13) |key| try std.testing.expectEqual(db.get(.rows, key), restored.get(.rows, key));
        var expected = try Db.restore(gpa, portable, db.commitment().digest);
        defer expected.deinit();
        try advance(&restored, seq + 1);
        try advance(&expected, seq + 1);
        try std.testing.expectEqual(expected.commitment(), restored.commitment());
    }
    var pinned = db.readView();
    defer pinned.deinit();
    const old = pinned.checkpointLayout();
    try advance(&db, 66);
    var source: ReusingSource = .{ .layout = old };
    var restored = try Db.restoreFrom(gpa, &old.header, &source, pinned.commitment().digest);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u64, 65), restored.commitment().advance);
}

test "checkpoint source errors and missing frames never return partial state" {
    var db = Db.init(gpa);
    defer db.deinit();
    for (1..10) |seq| try advance(&db, seq);
    var view = db.readView();
    defer view.deinit();
    const layout = view.checkpointLayout();
    for (0..9) |call| {
        var source: ReusingSource = .{ .layout = layout, .fail_at = call };
        try std.testing.expectError(error.SourceReadFailed, Db.restoreFrom(gpa, &layout.header, &source, view.commitment().digest));
        try std.testing.expectEqual(call + 1, source.calls);
    }
    var missing: ReusingSource = .{ .layout = layout, .omit_at = 0 };
    try std.testing.expectError(error.InvalidCheckpoint, Db.restoreFrom(gpa, &layout.header, &missing, view.commitment().digest));
    var pending: ReusingSource = .{ .layout = layout, .omit_at = 5 };
    try std.testing.expectError(error.InvalidTopology, Db.restoreFrom(gpa, &layout.header, &pending, view.commitment().digest));
    var wrong_digest: ReusingSource = .{ .layout = layout };
    try std.testing.expectError(error.CommitmentMismatch, Db.restoreFrom(gpa, &layout.header, &wrong_digest, @splat(0)));
    try std.testing.expectEqual(@as(u64, 9), db.commitment().advance);
}

test "checkpoint header rejects incompatible schema and framing before source reads" {
    var db = Db.init(gpa);
    defer db.deinit();
    var view = db.readView();
    defer view.deinit();
    const layout = view.checkpointLayout();
    var source: ReusingSource = .{ .layout = layout };
    for (0..layout.header.len) |n| {
        try std.testing.expectError(error.InvalidCheckpoint, Db.restoreFrom(gpa, layout.header[0..n], &source, view.commitment().digest));
    }
    for ([_]usize{ 0, "bucketlist.checkpoint.v1\x00".len, "bucketlist.checkpoint.v1\x00".len + 32 }) |offset| {
        var header = layout.header;
        header[offset] ^= 1;
        try std.testing.expectError(error.InvalidCheckpoint, Db.restoreFrom(gpa, &header, &source, view.commitment().digest));
    }
    try std.testing.expectEqual(@as(usize, 0), source.calls);
}

fn restoreWithAllocator(allocator: std.mem.Allocator, view: *const Db.ReadView) !void {
    const layout = view.checkpointLayout();
    var source: ReusingSource = .{ .layout = layout };
    var restored = try Db.restoreFrom(allocator, &layout.header, &source, view.commitment().digest);
    defer restored.deinit();
    try std.testing.expectEqual(view.commitment(), restored.commitment());
}

test "checkpoint reusable-source restore cleans up every allocation failure" {
    var db = Db.init(gpa);
    defer db.deinit();
    for (1..10) |seq| try advance(&db, seq);
    var view = db.readView();
    defer view.deinit();
    try std.testing.checkAllAllocationFailures(gpa, restoreWithAllocator, .{&view});
}
