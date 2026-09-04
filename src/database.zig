const std = @import("std");
const schema = @import("schema.zig");
const codec = @import("codec.zig");
const bucket = @import("bucket.zig");
const lists = @import("list.zig");
const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Commitment = struct {
    advance: u64,
    bucket_list_root: Hash,
    continuation_hash: Hash,
    digest: Hash,
};

/// One writer, explicit ownership, and immutable pinned read views.
/// Database/Batch/Prepared/ReadView are owned values: do not copy them.
pub fn Database(comptime S: type) type {
    return DatabaseWithDepth(S, 11);
}

/// Reduced profiles are for tests; depth changes every commitment.
pub fn DatabaseWithDepth(comptime S: type, comptime depth: usize) type {
    const Def = schema.Definition(S);
    const Name = Def.TableName;
    const Engine = lists.List(depth);
    return struct {
        const Self = @This();
        pub const Schema = S;
        pub const TableName = Name;
        pub const schema_hash = Def.hash();
        pub const max_checkpoint_bytes = 1024 * 1024 * 1024;
        pub const Error = Allocator.Error || error{
            BatchActive,
            ClosedBatch,
            StaleBase,
            WrongAdvance,
            SequenceExhausted,
            NonCanonical,
            InvalidCheckpoint,
            CommitmentMismatch,
            NoSpace,
        };
        engine: Engine,
        batch_open: bool = false,
        batch_token: u64 = 0,

        pub fn init(gpa: Allocator) Self {
            return .{ .engine = Engine.init(gpa) };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.batch_open);
            self.engine.deinit();
            self.* = undefined;
        }

        pub fn commitment(self: *const Self) Commitment {
            return engineCommitment(&self.engine);
        }

        fn engineCommitment(engine: *const Engine) Commitment {
            const root = engine.root();
            const continuation = engine.continuationHash();
            var h = Sha256.init(.{});
            h.update("bucketlist.database.v1\x00");
            h.update(&schema_hash);
            h.update(&Engine.profileHash());
            var seq: [8]u8 = undefined;
            std.mem.writeInt(u64, &seq, engine.seq, .big);
            h.update(&seq);
            h.update(&root);
            h.update(&continuation);
            return .{ .advance = engine.seq, .bucket_list_root = root, .continuation_hash = continuation, .digest = h.finalResult() };
        }

        pub fn get(self: *const Self, comptime name: Name, key: Def.table(name).Key) ?Def.table(name).Value {
            return getFrom(&self.engine, name, key);
        }

        fn getFrom(engine: *const Engine, comptime name: Name, key: Def.table(name).Key) ?Def.table(name).Value {
            const T = Def.table(name);
            var buf: [codec.Codec(T.Key).max_size]u8 = undefined;
            const bytes = codec.Codec(T.Key).encode(key, &buf) catch return null;
            const value = engine.get(T.id, bytes) orelse return null;
            return codec.Codec(T.Value).decode(value) catch unreachable;
        }

        pub fn batch(self: *Self, gpa: Allocator) Error!Batch {
            if (self.batch_open) return error.BatchActive;
            if (self.batch_token == std.math.maxInt(u64)) return error.SequenceExhausted;
            self.batch_token += 1;
            self.batch_open = true;
            return .{ .owner = self, .gpa = gpa, .token = self.batch_token, .base = self.commitment().digest };
        }

        pub const Batch = struct {
            owner: *Self,
            gpa: Allocator,
            token: u64,
            base: Hash,
            changes: std.ArrayList(bucket.Record) = .empty,
            sealed: bool = false,

            pub fn deinit(self: *Batch) void {
                for (self.changes.items) |record| freeRecord(self.gpa, record);
                self.changes.deinit(self.gpa);
                if (self.owner.batch_token == self.token) self.owner.batch_open = false;
                self.* = undefined;
            }

            fn check(self: *const Batch) Error!void {
                if (self.sealed or !self.owner.batch_open or self.owner.batch_token != self.token) return error.ClosedBatch;
                if (!std.mem.eql(u8, &self.base, &self.owner.commitment().digest)) return error.StaleBase;
            }

            pub fn put(self: *Batch, comptime name: Name, key: Def.table(name).Key, value: Def.table(name).Value) Error!void {
                try self.check();
                const T = Def.table(name);
                const key_bytes = try encodeAlloc(T.Key, self.gpa, key);
                errdefer self.gpa.free(key_bytes);
                const value_bytes = try encodeAlloc(T.Value, self.gpa, value);
                errdefer self.gpa.free(value_bytes);
                try self.replace(.{ .table = T.id, .key = key_bytes, .value = value_bytes });
            }

            pub fn delete(self: *Batch, comptime name: Name, key: Def.table(name).Key) Error!void {
                try self.check();
                const T = Def.table(name);
                const key_bytes = try encodeAlloc(T.Key, self.gpa, key);
                errdefer self.gpa.free(key_bytes);
                try self.replace(.{ .table = T.id, .key = key_bytes, .value = null });
            }

            fn replace(self: *Batch, record: bucket.Record) Allocator.Error!void {
                for (self.changes.items) |*old| {
                    if (old.table == record.table and std.mem.eql(u8, old.key, record.key)) {
                        freeRecord(self.gpa, old.*);
                        old.* = record;
                        return;
                    }
                }
                try self.changes.append(self.gpa, record);
            }
        };

        fn encodeAlloc(comptime T: type, gpa: Allocator, value: T) Error![]u8 {
            const C = codec.Codec(T);
            const buf = try gpa.alloc(u8, C.max_size);
            errdefer gpa.free(buf);
            const encoded = try C.encode(value, buf);
            return try gpa.realloc(buf, encoded.len);
        }

        fn freeRecord(gpa: Allocator, record: bucket.Record) void {
            gpa.free(record.key);
            if (record.value) |v| gpa.free(v);
        }

        fn less(_: void, a: bucket.Record, b: bucket.Record) bool {
            if (a.table != b.table) return a.table < b.table;
            return std.mem.order(u8, a.key, b.key) == .lt;
        }

        pub const Prepared = struct {
            owner: *Self,
            token: u64,
            base: Hash,
            state: ?Engine,
            pub fn deinit(self: *Prepared) void {
                if (self.state) |*state| state.deinit();
                self.state = null;
            }
            pub fn commitment(self: *const Prepared) Commitment {
                return engineCommitment(&self.state.?);
            }
        };

        /// gpa owns newly prepared buckets and must outlive the committed
        /// database and any retained read views, including views on other threads.
        pub fn prepareAdvance(self: *Self, gpa: Allocator, next: u64, changes: *Batch) !Prepared {
            try changes.check();
            if (changes.owner != self) return error.StaleBase;
            if (self.engine.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (next != self.engine.seq + 1) return error.WrongAdvance;
            const records = try gpa.alloc(bucket.Record, changes.changes.items.len);
            defer gpa.free(records);
            var count: usize = 0;
            for (changes.changes.items) |r| {
                const old = self.engine.get(r.table, r.key);
                if (r.value) |v| {
                    if (old) |ov| if (std.mem.eql(u8, ov, v)) continue;
                } else if (old == null) continue;
                records[count] = r;
                count += 1;
            }
            std.mem.sort(bucket.Record, records[0..count], {}, less);
            var candidate = self.engine.clone();
            candidate.gpa = gpa;
            errdefer candidate.deinit();
            try candidate.advance(next, records[0..count]);
            changes.sealed = true;
            return .{ .owner = self, .token = changes.token, .base = changes.base, .state = candidate };
        }

        pub fn commit(self: *Self, prepared: *Prepared) Error!void {
            if (prepared.state == null or prepared.owner != self or !self.batch_open or prepared.token != self.batch_token or
                !std.mem.eql(u8, &prepared.base, &self.commitment().digest)) return error.StaleBase;
            self.engine.deinit();
            self.engine = prepared.state.?;
            prepared.state = null;
            self.batch_open = false;
        }

        pub fn readView(self: *const Self) ReadView {
            return .{ .engine = self.engine.clone() };
        }

        pub const ReadView = struct {
            engine: Engine,
            pub fn deinit(self: *ReadView) void {
                self.engine.deinit();
                self.* = undefined;
            }
            pub fn get(self: *const ReadView, comptime name: Name, key: Def.table(name).Key) ?Def.table(name).Value {
                return getFrom(&self.engine, name, key);
            }
            pub fn commitment(self: *const ReadView) Commitment {
                return engineCommitment(&self.engine);
            }
            pub fn checkpoint(self: *const ReadView, gpa: Allocator) ![]u8 {
                return encodeCheckpoint(&self.engine, gpa);
            }
            pub fn iterator(self: *const ReadView, comptime name: Name) Iterator(name) {
                return .{ .view = self };
            }
        };

        pub fn Iterator(comptime name: Name) type {
            const T = Def.table(name);
            return struct {
                view: *const ReadView,
                positions: [depth * 2]usize = @splat(0),
                pub const Row = struct { key: T.Key, value: T.Value };
                pub fn next(self: *@This()) ?Row {
                    while (true) {
                        var selected: ?bucket.Record = null;
                        for (0..depth * 2) |i| {
                            const level = &self.view.engine.levels[i / 2];
                            const records = (if (i % 2 == 0) level.curr else level.snap).records();
                            while (self.positions[i] < records.len and records[self.positions[i]].table < T.id) self.positions[i] += 1;
                            if (self.positions[i] == records.len) continue;
                            const r = records[self.positions[i]];
                            if (r.table != T.id) continue;
                            if (selected == null or std.mem.order(u8, r.key, selected.?.key) == .lt) selected = r;
                        }
                        const record = selected orelse return null;
                        // Advance every copy of the selected key; lowest level/current wins.
                        for (0..depth * 2) |i| {
                            const level = &self.view.engine.levels[i / 2];
                            const records = (if (i % 2 == 0) level.curr else level.snap).records();
                            if (self.positions[i] < records.len) {
                                const r = records[self.positions[i]];
                                if (r.table == T.id and std.mem.eql(u8, r.key, record.key)) self.positions[i] += 1;
                            }
                        }
                        if (record.value) |value| return .{
                            .key = codec.Codec(T.Key).decode(record.key) catch unreachable,
                            .value = codec.Codec(T.Value).decode(value) catch unreachable,
                        };
                    }
                }
            };
        }

        const checkpoint_magic = "bucketlist.checkpoint.v1\x00";
        pub fn checkpoint(self: *const Self, gpa: Allocator) ![]u8 {
            return encodeCheckpoint(&self.engine, gpa);
        }

        fn encodeCheckpoint(engine: *const Engine, gpa: Allocator) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, checkpoint_magic);
            try out.appendSlice(gpa, &schema_hash);
            try out.appendSlice(gpa, &Engine.profileHash());
            var seq: [8]u8 = undefined;
            std.mem.writeInt(u64, &seq, engine.seq, .big);
            try out.appendSlice(gpa, &seq);
            for (engine.levels) |level| {
                try appendBucket(gpa, &out, level.curr);
                try appendBucket(gpa, &out, level.snap);
                if (out.items.len >= max_checkpoint_bytes) return error.InvalidCheckpoint;
                try out.append(gpa, @intFromBool(level.next != null));
                if (level.next) |b| try appendBucket(gpa, &out, b);
            }
            return out.toOwnedSlice(gpa);
        }

        fn appendBucket(gpa: Allocator, out: *std.ArrayList(u8), b: bucket.Bucket) !void {
            const bytes = b.bytes();
            if (out.items.len > max_checkpoint_bytes or bytes.len > max_checkpoint_bytes - out.items.len or
                8 > max_checkpoint_bytes - out.items.len - bytes.len) return error.InvalidCheckpoint;
            var size: [8]u8 = undefined;
            std.mem.writeInt(u64, &size, bytes.len, .big);
            try out.appendSlice(gpa, &size);
            try out.appendSlice(gpa, bytes);
        }

        /// `expected` must come from a trusted local frontier or application
        /// certificate. A digest read from the same untrusted file is not trust.
        pub fn restore(gpa: Allocator, bytes: []const u8, expected: Hash) !Self {
            if (bytes.len > max_checkpoint_bytes) return error.InvalidCheckpoint;
            var cursor = Cursor{ .bytes = bytes };
            if (!std.mem.eql(u8, try cursor.take(checkpoint_magic.len), checkpoint_magic) or
                !std.mem.eql(u8, try cursor.take(32), &schema_hash) or
                !std.mem.eql(u8, try cursor.take(32), &Engine.profileHash())) return error.InvalidCheckpoint;
            var self = Self.init(gpa);
            errdefer self.deinit();
            self.engine.seq = std.mem.readInt(u64, (try cursor.take(8))[0..8], .big);
            for (&self.engine.levels) |*level| {
                level.curr = try readBucket(gpa, &cursor);
                level.snap = try readBucket(gpa, &cursor);
                switch ((try cursor.take(1))[0]) {
                    0 => {},
                    1 => level.next = try readBucket(gpa, &cursor),
                    else => return error.InvalidCheckpoint,
                }
            }
            if (cursor.pos != bytes.len) return error.InvalidCheckpoint;
            try self.engine.validate();
            if (!std.mem.eql(u8, &self.commitment().digest, &expected)) return error.CommitmentMismatch;
            return self;
        }

        fn readBucket(gpa: Allocator, cursor: *Cursor) !bucket.Bucket {
            const n = std.mem.readInt(u64, (try cursor.take(8))[0..8], .big);
            if (n > cursor.bytes.len - cursor.pos) return error.InvalidCheckpoint;
            var b = try bucket.Bucket.decode(gpa, try cursor.take(@intCast(n)));
            errdefer b.release();
            for (b.records()) |record| {
                var found = false;
                inline for (@typeInfo(Name).@"enum".field_names) |field_name| {
                    const T = Def.table(@field(Name, field_name));
                    if (record.table == T.id) {
                        _ = codec.Codec(T.Key).decode(record.key) catch return error.InvalidCheckpoint;
                        if (record.value) |v| _ = codec.Codec(T.Value).decode(v) catch return error.InvalidCheckpoint;
                        found = true;
                    }
                }
                if (!found) return error.InvalidCheckpoint;
            }
            return b;
        }
        const Cursor = struct {
            bytes: []const u8,
            pos: usize = 0,
            fn take(self: *Cursor, n: usize) error{InvalidCheckpoint}![]const u8 {
                if (n > self.bytes.len - self.pos) return error.InvalidCheckpoint;
                defer self.pos += n;
                return self.bytes[self.pos..][0..n];
            }
        };
    };
}

const TestSchema = struct {
    pub const namespace = "test.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = schema.Table(1, u64, struct { balance: i64, active: bool }),
        .names = schema.Table(2, codec.Bytes(16), u64),
    };
};
const TestDb = DatabaseWithDepth(TestSchema, 3);

test "two tables atomic publication, owned views, checkpoint continuation" {
    const gpa = std.testing.allocator;
    var db = TestDb.init(gpa);
    defer db.deinit();
    const name = try codec.Bytes(16).init("alice");
    {
        var batch = try db.batch(gpa);
        defer batch.deinit();
        try batch.put(.accounts, 1, .{ .balance = 5, .active = true });
        try batch.put(.names, name, 1);
        var p = try db.prepareAdvance(gpa, 1, &batch);
        defer p.deinit();
        try std.testing.expect(db.get(.accounts, 1) == null);
        try db.commit(&p);
    }
    var view = db.readView();
    defer view.deinit();
    for (2..100) |seq| {
        var batch = try db.batch(gpa);
        defer batch.deinit();
        try batch.put(.accounts, 1, .{ .balance = @intCast(seq), .active = true });
        if (seq == 7) try batch.delete(.names, name);
        var p = try db.prepareAdvance(gpa, seq, &batch);
        defer p.deinit();
        try db.commit(&p);
        const checkpoint = try db.checkpoint(gpa);
        defer gpa.free(checkpoint);
        var restored = try TestDb.restore(gpa, checkpoint, db.commitment().digest);
        defer restored.deinit();
        try std.testing.expectEqual(db.commitment(), restored.commitment());
        var b = try restored.batch(gpa);
        defer b.deinit();
        var future = try restored.prepareAdvance(gpa, seq + 1, &b);
        defer future.deinit();
        // Independent empty continuation from the live database matches.
        var live = try db.batch(gpa);
        defer live.deinit();
        var expected = try db.prepareAdvance(gpa, seq + 1, &live);
        defer expected.deinit();
        try std.testing.expectEqual(expected.commitment(), future.commitment());
    }
    try std.testing.expectEqual(@as(i64, 5), view.get(.accounts, 1).?.balance);
    try std.testing.expectEqual(@as(u64, 1), view.get(.names, name).?);
    try std.testing.expect(db.get(.names, name) == null);
    var rows = view.iterator(.accounts);
    try std.testing.expectEqual(@as(u64, 1), rows.next().?.key);
    try std.testing.expect(rows.next() == null);
}

test "batch coalesces final no-ops; input order independent; stale base rejected" {
    const gpa = std.testing.allocator;
    var a = TestDb.init(gpa);
    defer a.deinit();
    var b = TestDb.init(gpa);
    defer b.deinit();
    var ba = try a.batch(gpa);
    defer ba.deinit();
    var bb = try b.batch(gpa);
    defer bb.deinit();
    for (0..5) |i| try ba.put(.accounts, i, .{ .balance = @intCast(i), .active = true });
    for (0..5) |i| try bb.put(.accounts, 4 - i, .{ .balance = @intCast(4 - i), .active = true });
    try ba.put(.accounts, 9, .{ .balance = 42, .active = false });
    try ba.delete(.accounts, 9);
    var pa = try a.prepareAdvance(gpa, 1, &ba);
    defer pa.deinit();
    var pb = try b.prepareAdvance(gpa, 1, &bb);
    defer pb.deinit();
    try std.testing.expectEqual(pa.commitment(), pb.commitment());
    try std.testing.expectError(error.StaleBase, b.commit(&pa));
    try a.commit(&pa);
    try std.testing.expectError(error.StaleBase, a.commit(&pa));
}

test "checkpoint corruption and wrong trust anchor rejected" {
    const gpa = std.testing.allocator;
    var db = TestDb.init(gpa);
    defer db.deinit();
    var b = try db.batch(gpa);
    defer b.deinit();
    try b.put(.accounts, 1, .{ .balance = 17, .active = true });
    var p = try db.prepareAdvance(gpa, 1, &b);
    defer p.deinit();
    try db.commit(&p);
    const bytes = try db.checkpoint(gpa);
    defer gpa.free(bytes);
    try std.testing.expectError(error.CommitmentMismatch, TestDb.restore(gpa, bytes, @splat(0)));
    for (0..bytes.len) |len| {
        if (TestDb.restore(gpa, bytes[0..len], db.commitment().digest)) |value| {
            var bad = value;
            bad.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
}

fn oomScenario(gpa: Allocator) !void {
    var db = TestDb.init(gpa);
    defer db.deinit();
    const before = db.commitment();
    var b = try db.batch(gpa);
    defer b.deinit();
    try b.put(.accounts, 1, .{ .balance = 100, .active = true });
    var p = db.prepareAdvance(gpa, 1, &b) catch |err| {
        try std.testing.expectEqual(before, db.commitment());
        try std.testing.expect(db.get(.accounts, 1) == null);
        return err;
    };
    defer p.deinit();
    try db.commit(&p);
    const encoded = try db.checkpoint(gpa);
    defer gpa.free(encoded);
    var restored = try TestDb.restore(gpa, encoded, db.commitment().digest);
    defer restored.deinit();
}

test "allocation failures leave publication atomic and restore leak-free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, oomScenario, .{});
}
