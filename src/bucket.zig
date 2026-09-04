//! Immutable canonical sorted buckets with atomic shared ownership. The owning
//! allocator must support freeing on whichever thread drops the last reference.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Record = struct {
    table: u32,
    key: []const u8,
    /// Null means deletion; an empty non-null slice is a live empty value.
    value: ?[]const u8,
};

pub const domain = "bucketlist.bucket.v1\x00";
pub const empty_bytes = domain ++ "\x00\x00\x00\x00\x00\x00\x00\x00";

pub fn order(a: Record, b: Record) std.math.Order {
    if (a.table != b.table) return std.math.order(a.table, b.table);
    return std.mem.order(u8, a.key, b.key);
}

pub const Bucket = struct {
    const Storage = struct {
        gpa: Allocator,
        refs: std.atomic.Value(usize),
        encoded: []const u8,
        index: []const Record,
        digest: [32]u8,
    };

    storage: ?*const Storage = null,

    pub fn empty() Bucket {
        return .{};
    }

    pub fn retain(self: Bucket) Bucket {
        if (self.storage) |s| {
            _ = @constCast(&s.refs).fetchAdd(1, .monotonic);
        }
        return self;
    }

    pub fn release(self: *Bucket) void {
        if (self.storage) |s| {
            if (@constCast(&s.refs).fetchSub(1, .acq_rel) == 1) {
                const gpa = s.gpa;
                gpa.free(s.index);
                gpa.free(s.encoded);
                gpa.destroy(s);
            }
        }
        self.* = empty();
    }

    pub fn bytes(self: Bucket) []const u8 {
        return if (self.storage) |s| s.encoded else empty_bytes;
    }

    pub fn records(self: Bucket) []const Record {
        return if (self.storage) |s| s.index else &.{};
    }

    pub fn hash(self: Bucket) [32]u8 {
        if (self.storage) |s| return s.digest;
        var digest: [32]u8 = undefined;
        Sha256.hash(empty_bytes, &digest, .{});
        return digest;
    }

    /// Returns a tombstone as a Record with value=null, rather than treating it
    /// as an absent identity. The returned slices live as long as this bucket.
    pub fn lookup(self: Bucket, table: u32, key: []const u8) ?Record {
        const rows = self.records();
        const needle: Record = .{ .table = table, .key = key, .value = null };
        var lo: usize = 0;
        var hi = rows.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (order(rows[mid], needle)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return rows[mid],
            }
        }
        return null;
    }

    /// Copies strictly sorted, unique records into canonical owned storage.
    pub fn fromSorted(gpa: Allocator, rows: []const Record) !Bucket {
        var len: usize = empty_bytes.len;
        for (rows, 0..) |r, i| {
            if (i != 0 and order(rows[i - 1], r) != .lt)
                return error.InvalidRecordOrder;
            if (r.key.len > std.math.maxInt(u32)) return error.RecordTooLarge;
            len = std.math.add(usize, len, 9) catch return error.RecordTooLarge;
            len = std.math.add(usize, len, r.key.len) catch return error.RecordTooLarge;
            if (r.value) |v| {
                if (v.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                len = std.math.add(usize, len, 4) catch return error.RecordTooLarge;
                len = std.math.add(usize, len, v.len) catch return error.RecordTooLarge;
            }
        }
        if (rows.len == 0) return empty();
        const encoded = try gpa.alloc(u8, len);
        errdefer gpa.free(encoded);
        const index = try gpa.alloc(Record, rows.len);
        errdefer gpa.free(index);
        const s = try gpa.create(Storage);
        @memcpy(encoded[0..domain.len], domain);
        var pos: usize = domain.len;
        writeInt(u64, encoded, &pos, @intCast(rows.len));
        for (rows, index) |r, *dest| {
            writeInt(u32, encoded, &pos, r.table);
            writeInt(u32, encoded, &pos, @intCast(r.key.len));
            const key = encoded[pos..][0..r.key.len];
            @memcpy(key, r.key);
            pos += r.key.len;
            encoded[pos] = if (r.value != null) 1 else 0;
            pos += 1;
            var value: ?[]const u8 = null;
            if (r.value) |v| {
                writeInt(u32, encoded, &pos, @intCast(v.len));
                const target = encoded[pos..][0..v.len];
                @memcpy(target, v);
                pos += v.len;
                value = target;
            }
            dest.* = .{ .table = r.table, .key = key, .value = value };
        }
        std.debug.assert(pos == len);
        s.* = .{ .gpa = gpa, .refs = .init(1), .encoded = encoded, .index = index, .digest = undefined };
        Sha256.hash(encoded, &s.digest, .{});
        return .{ .storage = s };
    }

    /// Strict parser: rejects truncation, invalid tags, unordered/duplicate
    /// records and trailing data. Typed schema canonicality is checked above it.
    pub fn decode(gpa: Allocator, encoded: []const u8) !Bucket {
        if (encoded.len < empty_bytes.len or !std.mem.eql(u8, encoded[0..domain.len], domain))
            return error.InvalidBucket;
        var pos: usize = domain.len;
        const count = try readInt(u64, encoded, &pos);
        // Every record occupies at least 9 bytes. Check before allocating.
        if (count > (encoded.len - pos) / 9) return error.InvalidBucket;
        const rows = try gpa.alloc(Record, @intCast(count));
        defer gpa.free(rows);
        for (rows) |*r| {
            r.table = try readInt(u32, encoded, &pos);
            const key_len = try readInt(u32, encoded, &pos);
            r.key = try take(encoded, &pos, key_len);
            const tag = (try take(encoded, &pos, 1))[0];
            r.value = switch (tag) {
                0 => null,
                1 => try take(encoded, &pos, try readInt(u32, encoded, &pos)),
                else => return error.InvalidBucket,
            };
        }
        if (pos != encoded.len) return error.InvalidBucket;
        return fromSorted(gpa, rows);
    }
};

/// Streaming merge of the two indexes, newest wins by identity. Tombstones may
/// be omitted only when the caller proves no still-older bucket exists.
pub fn merge(gpa: Allocator, older: Bucket, newer: Bucket, drop_tombstones: bool) !Bucket {
    if (newer.records().len == 0 and !drop_tombstones) return older.retain();
    if (older.records().len == 0 and !drop_tombstones) return newer.retain();
    const old_rows = older.records();
    const new_rows = newer.records();
    var count: usize = 0;
    var cursor = MergeCursor{ .older = old_rows, .newer = new_rows };
    while (cursor.next()) |r| {
        if (!drop_tombstones or r.value != null) count += 1;
    }
    if (count == 0) return Bucket.empty();
    const rows = try gpa.alloc(Record, count);
    defer gpa.free(rows);
    cursor = .{ .older = old_rows, .newer = new_rows };
    var i: usize = 0;
    while (cursor.next()) |r| {
        if (!drop_tombstones or r.value != null) {
            rows[i] = r;
            i += 1;
        }
    }
    return Bucket.fromSorted(gpa, rows);
}

const MergeCursor = struct {
    older: []const Record,
    newer: []const Record,
    i: usize = 0,
    j: usize = 0,

    fn next(self: *MergeCursor) ?Record {
        if (self.i == self.older.len and self.j == self.newer.len) return null;
        if (self.i == self.older.len) {
            defer self.j += 1;
            return self.newer[self.j];
        }
        if (self.j == self.newer.len) {
            defer self.i += 1;
            return self.older[self.i];
        }
        switch (order(self.older[self.i], self.newer[self.j])) {
            .lt => {
                defer self.i += 1;
                return self.older[self.i];
            },
            .eq => {
                self.i += 1;
                defer self.j += 1;
                return self.newer[self.j];
            },
            .gt => {
                defer self.j += 1;
                return self.newer[self.j];
            },
        }
    }
};

fn writeInt(comptime T: type, bytes: []u8, pos: *usize, value: T) void {
    const n = @sizeOf(T);
    std.mem.writeInt(T, bytes[pos.*..][0..n], value, .big);
    pos.* += n;
}

fn readInt(comptime T: type, bytes: []const u8, pos: *usize) !T {
    const data = try take(bytes, pos, @sizeOf(T));
    return std.mem.readInt(T, data[0..@sizeOf(T)], .big);
}

fn take(bytes: []const u8, pos: *usize, len: usize) ![]const u8 {
    if (len > bytes.len - pos.*) return error.InvalidBucket;
    defer pos.* += len;
    return bytes[pos.*..][0..len];
}

test "literal canonical bucket frames, owned storage and strict parsing" {
    const gpa = std.testing.allocator;
    var source_key = [_]u8{'k'};
    var source_value = [_]u8{'v'};
    var bucket = try Bucket.fromSorted(gpa, &.{.{ .table = 7, .key = &source_key, .value = &source_value }});
    defer bucket.release();
    const expected = domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x07\x00\x00\x00\x01k\x01\x00\x00\x00\x01v";
    try std.testing.expectEqualSlices(u8, expected, bucket.bytes());
    var hex: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&hex, "f0c97d1ffee7489cfcb47d1eba0918147cd67b220cbb5db08b045de3118ab940"), &bucket.hash());
    try std.testing.expectEqualSlices(u8, try std.fmt.hexToBytes(&hex, "7076a8bba14bcc34e17a8a22d54a16d13b09247075da48782dac74352f01ac12"), &Bucket.empty().hash());
    source_key[0] = 'x';
    source_value[0] = 'x';
    try std.testing.expectEqualSlices(u8, "v", bucket.lookup(7, "k").?.value.?);
    var copy = try Bucket.decode(gpa, expected);
    defer copy.release();
    try std.testing.expectEqual(bucket.hash(), copy.hash());
    var pinned = bucket.retain();
    defer pinned.release();
    bucket.release();
    try std.testing.expectEqualSlices(u8, "v", pinned.lookup(7, "k").?.value.?);
    for (0..expected.len) |n| {
        try std.testing.expectError(error.InvalidBucket, Bucket.decode(gpa, expected[0..n]));
    }
    try std.testing.expectError(error.InvalidBucket, Bucket.decode(gpa, expected ++ "x"));
    var malformed: [expected.len]u8 = undefined;
    @memcpy(&malformed, expected);
    malformed[empty_bytes.len + 9] = 2;
    try std.testing.expectError(error.InvalidBucket, Bucket.decode(gpa, &malformed));
    @memcpy(malformed[domain.len..][0..8], "\xff\xff\xff\xff\xff\xff\xff\xff");
    try std.testing.expectError(error.InvalidBucket, Bucket.decode(gpa, &malformed));
    try std.testing.expectError(error.InvalidRecordOrder, Bucket.fromSorted(gpa, &.{
        .{ .table = 1, .key = "k", .value = "v" },
        .{ .table = 1, .key = "k", .value = null },
    }));
}

test "newest wins and terminal merges remove deletion markers" {
    const gpa = std.testing.allocator;
    var old = try Bucket.fromSorted(gpa, &.{
        .{ .table = 1, .key = "a", .value = "old" },
        .{ .table = 1, .key = "b", .value = "old" },
        .{ .table = 2, .key = "a", .value = "other table" },
    });
    defer old.release();
    var new = try Bucket.fromSorted(gpa, &.{
        .{ .table = 1, .key = "a", .value = null },
        .{ .table = 1, .key = "b", .value = "new" },
        .{ .table = 1, .key = "c", .value = "" },
    });
    defer new.release();
    var merged = try merge(gpa, old, new, false);
    defer merged.release();
    try std.testing.expectEqual(@as(usize, 4), merged.records().len);
    try std.testing.expect(merged.lookup(1, "a").?.value == null);
    try std.testing.expectEqualSlices(u8, "new", merged.lookup(1, "b").?.value.?);
    try std.testing.expectEqualSlices(u8, "", merged.lookup(1, "c").?.value.?);
    try std.testing.expectEqualSlices(u8, "other table", merged.lookup(2, "a").?.value.?);
    var terminal = try merge(gpa, old, new, true);
    defer terminal.release();
    try std.testing.expect(terminal.lookup(1, "a") == null);
    try std.testing.expectEqual(@as(usize, 3), terminal.records().len);
}

test "every exposed path to retained bucket content is read-only" {
    var original = try Bucket.fromSorted(std.testing.allocator, &.{.{ .table = 1, .key = "key", .value = "value" }});
    defer original.release();
    var pinned = original.retain();
    defer pinned.release();
    // Checking only bytes()/records() misses public backing-field aliases.
    // These type-level assertions prevent mutation through any exposed slice
    // without the caller explicitly violating const ownership with @constCast.
    try std.testing.expect(@typeInfo(@TypeOf(pinned.storage.?)).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.storage.?.encoded)).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.storage.?.index)).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.bytes())).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.records())).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.records()[0].key)).pointer.attrs.@"const");
    try std.testing.expect(@typeInfo(@TypeOf(pinned.records()[0].value.?)).pointer.attrs.@"const");
}
