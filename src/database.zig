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
            const Identity = struct { table: u32, key: []const u8 };
            const IdentityContext = struct {
                pub fn hash(_: @This(), identity: Identity) u64 {
                    return std.hash.Wyhash.hash(identity.table, identity.key);
                }
                pub fn eql(_: @This(), a: Identity, b: Identity) bool {
                    return a.table == b.table and std.mem.eql(u8, a.key, b.key);
                }
            };
            const IdentityIndex = std.HashMapUnmanaged(Identity, usize, IdentityContext, std.hash_map.default_max_load_percentage);
            // HashMap capacities are u32 powers of two. Refuse an impossible
            // next growth before its internal capacity arithmetic can overflow.
            const max_index_entries = (((@as(u64, 1) << 31) - 1) * std.hash_map.default_max_load_percentage) / 100;

            owner: *Self,
            gpa: Allocator,
            token: u64,
            base: Hash,
            changes: std.ArrayList(bucket.Record) = .empty,
            // Keys borrow the independently owned allocations in changes;
            // growing the records array cannot invalidate these slices.
            index: IdentityIndex = .empty,
            sealed: bool = false,

            pub fn deinit(self: *Batch) void {
                self.index.deinit(self.gpa);
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
                const identity: Identity = .{ .table = record.table, .key = record.key };
                if (self.index.get(identity)) |position| {
                    const old = &self.changes.items[position];
                    // Retain the original key allocation, which the index
                    // borrows. Only the final value or deletion changes.
                    self.gpa.free(record.key);
                    if (old.value) |value| self.gpa.free(value);
                    old.value = record.value;
                    return;
                }
                if (self.index.count() >= max_index_entries) return error.OutOfMemory;
                // All fallible reservations precede the logical insertion.
                // OOM may grow capacity but leaves every staged record intact.
                try self.changes.ensureUnusedCapacity(self.gpa, 1);
                try self.index.ensureUnusedCapacity(self.gpa, 1);
                self.index.putAssumeCapacityNoClobber(identity, self.changes.items.len);
                self.changes.appendAssumeCapacity(record);
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
            /// Allocation-free serialization layout. Frame slices borrow this
            /// pinned view and become invalid when it is deinitialized.
            pub fn checkpointLayout(self: *const ReadView) CheckpointLayout {
                return layoutFrom(&self.engine);
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
        const checkpoint_header_len = checkpoint_magic.len + 32 + 32 + 8;
        pub const CheckpointSlot = enum { current, snapshot, pending };

        /// Advanced serialization interface. The fixed header is owned by
        /// value; canonical frame slices borrow the ReadView that supplied it.
        pub const CheckpointLayout = struct {
            pub const level_count = depth;
            pub const header_len = checkpoint_header_len;
            pub const Level = struct {
                curr: []const u8,
                snap: []const u8,
                next: ?[]const u8,
            };
            header: [header_len]u8,
            levels: [depth]Level,

            pub fn encodedSize(self: *const CheckpointLayout) error{InvalidCheckpoint}!usize {
                var total: usize = header_len;
                for (self.levels) |level| {
                    try accountFrame(&total, level.curr.len);
                    try accountFrame(&total, level.snap.len);
                    try accountBytes(&total, 1);
                    if (level.next) |bytes| try accountFrame(&total, bytes.len);
                }
                return total;
            }
        };

        fn layoutFrom(engine: *const Engine) CheckpointLayout {
            var layout: CheckpointLayout = undefined;
            @memcpy(layout.header[0..checkpoint_magic.len], checkpoint_magic);
            @memcpy(layout.header[checkpoint_magic.len..][0..32], &schema_hash);
            @memcpy(layout.header[checkpoint_magic.len + 32 ..][0..32], &Engine.profileHash());
            std.mem.writeInt(u64, layout.header[checkpoint_magic.len + 64 ..][0..8], engine.seq, .big);
            for (engine.levels, &layout.levels) |level, *dest| dest.* = .{
                .curr = level.curr.bytes(),
                .snap = level.snap.bytes(),
                .next = if (level.next) |pending| pending.bytes() else null,
            };
            return layout;
        }

        fn accountBytes(total: *usize, count: usize) error{InvalidCheckpoint}!void {
            if (count > max_checkpoint_bytes - total.*) return error.InvalidCheckpoint;
            total.* += count;
        }

        fn accountFrame(total: *usize, count: usize) error{InvalidCheckpoint}!void {
            try accountBytes(total, 8);
            try accountBytes(total, count);
        }

        pub fn checkpoint(self: *const Self, gpa: Allocator) ![]u8 {
            return encodeCheckpoint(&self.engine, gpa);
        }

        fn encodeCheckpoint(engine: *const Engine, gpa: Allocator) ![]u8 {
            const layout = layoutFrom(engine);
            const out = try gpa.alloc(u8, try layout.encodedSize());
            @memcpy(out[0..checkpoint_header_len], &layout.header);
            var pos: usize = checkpoint_header_len;
            for (layout.levels) |level| {
                writeFrame(out, &pos, level.curr);
                writeFrame(out, &pos, level.snap);
                out[pos] = @intFromBool(level.next != null);
                pos += 1;
                if (level.next) |bytes| writeFrame(out, &pos, bytes);
            }
            std.debug.assert(pos == out.len);
            return out;
        }

        fn writeFrame(out: []u8, pos: *usize, bytes: []const u8) void {
            std.mem.writeInt(u64, out[pos.*..][0..8], bytes.len, .big);
            pos.* += 8;
            @memcpy(out[pos.*..][0..bytes.len], bytes);
            pos.* += bytes.len;
        }

        /// `expected` must come from a trusted local frontier or application
        /// certificate. A digest read from the same untrusted file is not trust.
        pub fn restore(gpa: Allocator, bytes: []const u8, expected: Hash) !Self {
            if (bytes.len > max_checkpoint_bytes) return error.InvalidCheckpoint;
            var source: SliceSource = .{ .cursor = .{ .bytes = bytes } };
            const header = try source.cursor.take(checkpoint_header_len);
            var self = try restoreFrom(gpa, header, &source, expected);
            errdefer self.deinit();
            if (source.cursor.pos != bytes.len) return error.InvalidCheckpoint;
            return self;
        }

        /// Restore from borrowed frames, requested youngest level first in
        /// current/snapshot/pending order. source.bucket(level, slot) returns
        /// !?[]const u8 valid until the next call. Only pending may be null.
        /// The source owns its buffers and cleanup, including on error. This
        /// method copies each frame before asking for another, checks the exact
        /// header, canonical schema, size, topology and complete trusted digest.
        /// Source errors propagate; no partial Database is returned.
        pub fn restoreFrom(gpa: Allocator, header: []const u8, source: anytype, expected: Hash) !Self {
            if (header.len != checkpoint_header_len) return error.InvalidCheckpoint;
            var cursor: Cursor = .{ .bytes = header };
            if (!std.mem.eql(u8, try cursor.take(checkpoint_magic.len), checkpoint_magic) or
                !std.mem.eql(u8, try cursor.take(32), &schema_hash) or
                !std.mem.eql(u8, try cursor.take(32), &Engine.profileHash())) return error.InvalidCheckpoint;
            var self = Self.init(gpa);
            errdefer self.deinit();
            self.engine.seq = std.mem.readInt(u64, (try cursor.take(8))[0..8], .big);
            var total: usize = checkpoint_header_len;
            for (&self.engine.levels, 0..) |*level, i| {
                const curr = (try source.bucket(i, .current)) orelse return error.InvalidCheckpoint;
                try accountFrame(&total, curr.len);
                level.curr = try decodeTypedBucket(gpa, curr);
                const snap = (try source.bucket(i, .snapshot)) orelse return error.InvalidCheckpoint;
                try accountFrame(&total, snap.len);
                level.snap = try decodeTypedBucket(gpa, snap);
                try accountBytes(&total, 1);
                if (try source.bucket(i, .pending)) |pending| {
                    try accountFrame(&total, pending.len);
                    level.next = try decodeTypedBucket(gpa, pending);
                }
            }
            try self.engine.validate();
            if (!std.mem.eql(u8, &self.commitment().digest, &expected)) return error.CommitmentMismatch;
            return self;
        }

        const SliceSource = struct {
            cursor: Cursor,
            pub fn bucket(self: *@This(), _: usize, slot: CheckpointSlot) !?[]const u8 {
                if (slot == .pending) switch ((try self.cursor.take(1))[0]) {
                    0 => return null,
                    1 => {},
                    else => return error.InvalidCheckpoint,
                };
                const n = std.mem.readInt(u64, (try self.cursor.take(8))[0..8], .big);
                if (n > self.cursor.bytes.len - self.cursor.pos) return error.InvalidCheckpoint;
                return try self.cursor.take(@intCast(n));
            }
        };

        fn decodeTypedBucket(gpa: Allocator, bytes: []const u8) !bucket.Bucket {
            var b = try bucket.Bucket.decode(gpa, bytes);
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

const StagingSchema = struct {
    pub const namespace = "test.staging";
    pub const version: u32 = 1;
    pub const tables = .{
        .left = schema.Table(1, u64, u64),
        .right = schema.Table(2, u64, u64),
    };
};
const StagingDb = Database(StagingSchema);

test "large indexed batches preserve final calls and table identity across input orders" {
    const gpa = std.testing.allocator;
    const count = 2048;
    var actual = StagingDb.init(gpa);
    defer actual.deinit();
    var expected = StagingDb.init(gpa);
    defer expected.deinit();
    var changes = try actual.batch(gpa);
    defer changes.deinit();
    var final_only = try expected.batch(gpa);
    defer final_only.deinit();
    for (0..count) |i| {
        try changes.put(.left, i, i);
        try changes.put(.right, i, 10000 + i);
    }
    for (0..count) |j| {
        const i = count - j - 1;
        try changes.delete(.left, i);
        if (i % 3 != 0) try changes.put(.left, i, 30000 + i);
        try changes.put(.right, i, 40000 + i);
        if (i % 5 == 0) try changes.delete(.right, i) else try changes.put(.right, i, 50000 + i);
    }
    try std.testing.expectEqual(@as(usize, count * 2), changes.changes.items.len);
    for (0..count) |i| {
        if (i % 3 != 0) try final_only.put(.left, i, 30000 + i);
        if (i % 5 != 0) try final_only.put(.right, i, 50000 + i);
    }
    var prepared = try actual.prepareAdvance(gpa, 1, &changes);
    defer prepared.deinit();
    var reference = try expected.prepareAdvance(gpa, 1, &final_only);
    defer reference.deinit();
    try std.testing.expectEqual(reference.commitment(), prepared.commitment());
    try actual.commit(&prepared);
    for (0..count) |i| {
        const left: ?u64 = if (i % 3 == 0) null else 30000 + i;
        const right: ?u64 = if (i % 5 == 0) null else 50000 + i;
        try std.testing.expectEqual(left, actual.get(.left, i));
        try std.testing.expectEqual(right, actual.get(.right, i));
    }
}

const StagingOperation = struct { table: enum { left, right }, key: u64, value: ?u64 };

fn stageOperation(batch: *StagingDb.Batch, op: StagingOperation) !void {
    switch (op.table) {
        .left => if (op.value) |value| try batch.put(.left, op.key, value) else try batch.delete(.left, op.key),
        .right => if (op.value) |value| try batch.put(.right, op.key, value) else try batch.delete(.right, op.key),
    }
}

fn expectStagedRecords(expected: []const bucket.Record, actual: []const bucket.Record) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |a, b| {
        try std.testing.expectEqual(a.table, b.table);
        try std.testing.expectEqualSlices(u8, a.key, b.key);
        if (a.value) |value| {
            try std.testing.expect(b.value != null);
            try std.testing.expectEqualSlices(u8, value, b.value.?);
        } else try std.testing.expect(b.value == null);
    }
}

fn stagingFailureScenario(fail_index: usize) !struct { allocations: usize, failed: bool } {
    const gpa = std.testing.allocator;
    // Force growth to allocate: whether a backing allocator can remap in place
    // depends on its prior layout and must not change the failure-site census.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index, .resize_fail_index = 0 });
    {
        var actual = StagingDb.init(gpa);
        defer actual.deinit();
        var expected = StagingDb.init(gpa);
        defer expected.deinit();
        var changes = try actual.batch(failing.allocator());
        defer changes.deinit();
        var reference = try expected.batch(gpa);
        defer reference.deinit();
        const initial = actual.commitment();
        // Twenty-eight distinct identities force four index capacities, then
        // overwrite, delete, and recreate a subset with the same encoded keys.
        var operations: [48]StagingOperation = undefined;
        for (0..14) |i| {
            operations[2 * i] = .{ .table = .left, .key = i, .value = 100 + i };
            operations[2 * i + 1] = .{ .table = .right, .key = i, .value = 200 + i };
        }
        for (0..5) |i| {
            operations[28 + 4 * i] = .{ .table = .left, .key = i, .value = 300 + i };
            operations[28 + 4 * i + 1] = .{ .table = .left, .key = i, .value = null };
            operations[28 + 4 * i + 2] = .{ .table = .left, .key = i, .value = 500 + i };
            operations[28 + 4 * i + 3] = .{ .table = .right, .key = i, .value = null };
        }
        for (operations) |op| {
            stageOperation(&changes, op) catch |err| {
                if (err != error.OutOfMemory) return err;
                try std.testing.expectEqual(initial, actual.commitment());
                try expectStagedRecords(reference.changes.items, changes.changes.items);
                // Restore allocator availability and retry on the SAME batch.
                // This catches partially inserted indexes and dangling borrowed
                // keys that cleanup-only allocation-failure tests cannot see.
                failing.fail_index = std.math.maxInt(usize);
                try stageOperation(&changes, op);
            };
            try stageOperation(&reference, op);
        }
        try expectStagedRecords(reference.changes.items, changes.changes.items);
        var prepared = try actual.prepareAdvance(gpa, 1, &changes);
        defer prepared.deinit();
        var baseline = try expected.prepareAdvance(gpa, 1, &reference);
        defer baseline.deinit();
        try std.testing.expectEqual(baseline.commitment(), prepared.commitment());
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    return .{ .allocations = failing.alloc_index, .failed = failing.has_induced_failure };
}

test "every staging allocation failure preserves records and permits retry" {
    const baseline = try stagingFailureScenario(std.math.maxInt(usize));
    try std.testing.expect(!baseline.failed);
    for (0..baseline.allocations) |failure| {
        const result = try stagingFailureScenario(failure);
        try std.testing.expect(result.failed);
    }
}
