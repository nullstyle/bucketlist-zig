//! Native typed database whose resident state contains hashes, not bucket data.
//! One owner serializes operations; parallel merges require thread-safe gpa/Io.
const std = @import("std");
const lib = @import("bucketlist");
const storage = @import("bucketlist-store");
const frontiers = @import("frontier.zig");
const Allocator = std.mem.Allocator;
const Hash = storage.Hash;
pub const Commitment = lib.Commitment;
pub const Reference = struct { manifest_hash: Hash, database_digest: Hash };
const bucket_domain = "bucketlist.bucket.v1\x00";
const manifest_domain = "bucketlist.disk-frontier.v1\x00";
const catalog_domain = "bucketlist.disk-current.v1\x00";
const Record = storage.BucketRecord;

pub fn Database(comptime Schema: type) type {
    return DatabaseWithDepth(Schema, 11);
}

pub fn DatabaseWithDepth(comptime S: type, comptime depth: usize) type {
    const Def = lib.Definition(S);
    const Name = Def.TableName;
    const Frontier = frontiers.Frontier(depth);
    return struct {
        const Self = @This();
        pub const Schema = S;
        pub const TableName = Name;
        pub const schema_hash = Def.hash();
        pub const Options = struct {
            merge_workers: usize = 2,
            max_batch_bytes: usize = 8 * 1024 * 1024,
            max_batch_changes: usize = 65536,
            max_metadata_bytes: usize = 64 * 1024,
            max_bucket_bytes: u64 = 1 << 40,
            max_bucket_records: u64 = 1 << 32,
            max_read_views: usize = 64,
            /// Bucket hash format for every blob this database writes and
            /// verifies; null keeps v1 flat hashing (docs/format-v2.md).
            format: ?storage.BucketFormat = null,
            /// Transparent deflate framing for written blobs; names keep
            /// hashing the uncompressed bytes (local policy only).
            compression: bool = false,
            /// Blob durability policy (storage.Durability). The default
            /// `.per_blob` syncs every blob individually before its write
            /// returns; `.pre_publish` defers blob syncs to one batched
            /// barrier at each commit's catalog publication. Local policy,
            /// never committed bytes.
            durability: storage.Durability = .per_blob,
            /// Local read index for point reads: after one fully verified
            /// bucket pass, warm lookups read only the sampled span instead
            /// of rehashing the whole blob. `null` keeps per-read whole-bucket
            /// verification. This is a local policy, never committed bytes.
            read_index: ?storage.ReadIndexOptions = .{},
            /// An external trust anchor also detects local catalog rollback.
            expected: ?Reference = null,
        };
        gpa: Allocator,
        io: std.Io,
        store: storage.Store,
        options: Options,
        frontier: Frontier = .init(),
        current_reference: Reference = undefined,
        current_metadata: []u8,
        prepared_open: bool = false,
        poisoned: bool = false,
        views: ?*ReadView = null,
        view_count: usize = 0,

        /// Allocator and Io must support all configured merge worker threads.
        /// Fully authenticates every retained bucket and pending merge on open.
        pub fn open(gpa: Allocator, io: std.Io, path: []const u8, options: Options) !*Self {
            if (options.merge_workers == 0 or options.merge_workers > 31 or
                options.max_batch_changes == 0 or options.max_batch_changes > 100000000 or
                options.max_metadata_bytes > @min(std.math.maxInt(u32), std.math.maxInt(usize) - (manifest_domain.len + 32 + 32 + 8 + depth * 97 + 4))) return error.InvalidOptions;
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .gpa = gpa, .io = io, .store = try storage.Store.open(gpa, io, path), .options = options, .current_metadata = &.{} };
            errdefer self.store.deinit();
            if (options.read_index) |read_index| try self.store.enableReadIndex(read_index);
            if (options.compression) self.store.enableCompression();
            self.store.setDurability(options.durability);
            if (self.v2Target()) |target| self.frontier = Frontier.initProfile(lib.proofs.profileHash(@intCast(depth), target), lib.proofs.emptyBucketHash());
            const catalog = try self.store.readManifest(gpa, catalog_domain.len + 64);
            defer if (catalog) |bytes| gpa.free(bytes);
            if (catalog) |bytes| {
                var reader: Reader = .{ .bytes = bytes };
                if (!std.mem.eql(u8, try reader.take(catalog_domain.len), catalog_domain)) return error.InvalidManifest;
                const ref: Reference = .{ .manifest_hash = try reader.hash(), .database_digest = try reader.hash() };
                try reader.end();
                if (options.expected) |expected| if (!std.meta.eql(ref, expected)) return error.CommitmentMismatch;
                var loaded = try self.load(ref);
                errdefer loaded.deinit(gpa);
                try self.validate(&loaded.frontier);
                self.frontier = loaded.frontier;
                self.current_metadata = loaded.metadata;
                self.current_reference = ref;
            } else {
                if (options.expected != null) return error.CommitmentMismatch;
                const genesis = try self.encodeManifest(&self.frontier, "");
                defer gpa.free(genesis);
                var genesis_hash: Hash = undefined;
                std.crypto.hash.sha2.Sha256.hash(genesis, &genesis_hash, .{});
                try self.requireGenesisOnly(genesis_hash);
                const empty_bytes = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x00";
                if (self.v2Target() != null) {
                    _ = try self.store.putBucketV2(empty_bytes, self.mergeLimits());
                } else {
                    _ = try self.store.putBlob(empty_bytes);
                }
                const ref: Reference = .{ .manifest_hash = try self.store.putBlob(genesis), .database_digest = self.commitment().digest };
                try self.publish(ref);
                self.current_reference = ref;
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.prepared_open and self.view_count == 0);
            self.gpa.free(self.current_metadata);
            self.store.deinit();
            const gpa = self.gpa;
            self.* = undefined;
            gpa.destroy(self);
        }

        pub fn commitment(self: *const Self) Commitment {
            return commitmentFor(&self.frontier);
        }

        fn commitmentFor(state: *const Frontier) Commitment {
            const c = state.commitment(schema_hash);
            return .{ .advance = c.advance, .bucket_list_root = c.bucket_list_root, .continuation_hash = c.continuation_hash, .digest = c.digest };
        }

        pub fn reference(self: *const Self) Reference {
            return self.current_reference;
        }

        /// Borrowed until the next successful commit or deinit.
        pub fn metadata(self: *const Self) []const u8 {
            return self.current_metadata;
        }

        pub fn get(self: *Self, comptime name: Name, key: Def.table(name).Key) !?Def.table(name).Value {
            return self.getFrom(&self.frontier, name, key);
        }

        fn getFrom(self: *Self, state: *const Frontier, comptime name: Name, key: Def.table(name).Key) !?Def.table(name).Value {
            const T = Def.table(name);
            var buf: [lib.Codec(T.Key).max_size]u8 = undefined;
            const bytes = try lib.Codec(T.Key).encode(key, &buf);
            var found = try self.lookup(state, T.id, bytes);
            defer found.deinit(self.gpa);
            return switch (found) {
                .value => |v| try lib.Codec(T.Value).decode(v),
                else => null,
            };
        }

        fn lookup(self: *Self, state: *const Frontier, table: u32, key: []const u8) !storage.BucketLookup {
            for (state.levels) |level| {
                for ([_]Hash{ level.curr, level.snap }) |hash| {
                    var found = try self.store.lookupBucketIndexed(self.gpa, hash, table, key, self.mergeLimits());
                    if (found != .absent) return found;
                    found.deinit(self.gpa);
                }
            }
            return .absent;
        }

        /// Independent owned batch. Calls replace the final value of each key.
        /// Fixed default limits bound staging before a host accepts ownership.
        pub const Batch = struct {
            const Identity = struct { table: u32, key: []const u8 };
            const Context = struct {
                pub fn hash(_: @This(), k: Identity) u64 {
                    return std.hash.Wyhash.hash(k.table, k.key);
                }
                pub fn eql(_: @This(), a: Identity, b: Identity) bool {
                    return a.table == b.table and std.mem.eql(u8, a.key, b.key);
                }
            };
            const Index = std.HashMapUnmanaged(Identity, usize, Context, std.hash_map.default_max_load_percentage);
            gpa: Allocator,
            changes: std.ArrayList(Record) = .empty,
            index: Index = .empty,
            byte_count: usize = 0,
            max_bytes: usize = 8 * 1024 * 1024,
            max_changes: usize = 65536,

            pub fn init(gpa: Allocator) Batch {
                return .{ .gpa = gpa };
            }
            pub fn initBounded(gpa: Allocator, max_bytes: usize, max_changes: usize) Batch {
                return .{ .gpa = gpa, .max_bytes = max_bytes, .max_changes = @min(max_changes, 100000000) };
            }
            pub fn deinit(self: *Batch) void {
                self.index.deinit(self.gpa);
                for (self.changes.items) |row| {
                    self.gpa.free(row.key);
                    if (row.value) |v| self.gpa.free(v);
                }
                self.changes.deinit(self.gpa);
                self.* = .init(self.gpa);
            }
            pub fn checkLimits(self: *const Batch, options: Options) !void {
                if (self.byte_count > options.max_batch_bytes or self.changes.items.len > options.max_batch_changes) return error.BatchTooLarge;
            }
            pub fn put(self: *Batch, comptime name: Name, key: Def.table(name).Key, value: Def.table(name).Value) !void {
                const T = Def.table(name);
                const k = try encodeAlloc(T.Key, self.gpa, key);
                errdefer self.gpa.free(k);
                const v = try encodeAlloc(T.Value, self.gpa, value);
                errdefer self.gpa.free(v);
                try self.replace(.{ .table = T.id, .key = k, .value = v });
            }
            pub fn delete(self: *Batch, comptime name: Name, key: Def.table(name).Key) !void {
                const k = try encodeAlloc(Def.table(name).Key, self.gpa, key);
                errdefer self.gpa.free(k);
                try self.replace(.{ .table = Def.table(name).id, .key = k, .value = null });
            }
            fn replace(self: *Batch, row: Record) !void {
                const identity: Identity = .{ .table = row.table, .key = row.key };
                const size = rowSize(row);
                if (self.index.get(identity)) |i| {
                    const old = &self.changes.items[i];
                    const retained = self.byte_count - rowSize(old.*);
                    if (size > self.max_bytes -| retained) return error.BatchTooLarge;
                    self.byte_count = retained + size;
                    self.gpa.free(row.key);
                    if (old.value) |v| self.gpa.free(v);
                    old.value = row.value;
                    return;
                }
                if (self.changes.items.len >= self.max_changes or size > self.max_bytes -| self.byte_count) return error.BatchTooLarge;
                try self.changes.ensureUnusedCapacity(self.gpa, 1);
                try self.index.ensureUnusedCapacity(self.gpa, 1);
                self.index.putAssumeCapacityNoClobber(identity, self.changes.items.len);
                self.changes.appendAssumeCapacity(row);
                self.byte_count += size;
            }
        };

        pub const Prepared = struct {
            owner: *Self,
            state: ?Frontier,
            meta: []u8,
            ref: Reference,
            pub fn commitment(self: *const Prepared) Commitment {
                return commitmentFor(&self.state.?);
            }
            pub fn deinit(self: *Prepared) void {
                if (self.state != null) {
                    self.owner.gpa.free(self.meta);
                    self.owner.prepared_open = false;
                    self.state = null;
                }
            }
            /// Atomic durable publication precedes visibility. A publication
            /// error poisons the owner: reopen to discover the durable outcome.
            pub fn commit(self: *Prepared) !void {
                const owner = self.owner;
                if (owner.poisoned) return error.Poisoned;
                const state = self.state orelse return error.ClosedPrepared;
                owner.publish(self.ref) catch |err| {
                    owner.poisoned = true;
                    return err;
                };
                owner.gpa.free(owner.current_metadata);
                owner.current_metadata = self.meta;
                owner.current_reference = self.ref;
                owner.frontier = state;
                owner.prepared_open = false;
                self.state = null;
            }
        };

        /// Produces durable immutable files but leaves the live catalog intact.
        /// Batch is borrowed for this call; retry/abort never consumes it.
        pub fn prepare(self: *Self, next: u64, batch: *Batch, meta: []const u8) !Prepared {
            if (self.poisoned) return error.Poisoned;
            if (self.prepared_open) return error.PreparedActive;
            if (self.frontier.seq == std.math.maxInt(u64)) return error.SequenceExhausted;
            if (next != self.frontier.seq + 1) return error.WrongAdvance;
            try batch.checkLimits(self.options);
            if (meta.len > self.options.max_metadata_bytes) return error.MetadataTooLarge;
            const owned_meta = try self.gpa.dupe(u8, meta);
            errdefer self.gpa.free(owned_meta);
            var rows = try self.normalize(batch.changes.items);
            defer rows.deinit(self.gpa);
            const fresh = try encodeBucket(self.gpa, rows.items);
            defer self.gpa.free(fresh);
            const hash = if (self.v2Target() != null)
                try self.store.putBucketV2(fresh, self.mergeLimits())
            else
                try self.store.putBlob(fresh);
            const plan = try self.frontier.plan(next, hash);
            var results: [depth]Hash = undefined;
            try self.runMerges(plan.merges(), results[0..plan.count]);
            const state = try plan.finish(results[0..plan.count]);
            const ref = try self.writeManifest(&state, meta);
            self.prepared_open = true;
            return .{ .owner = self, .state = state, .meta = owned_meta, .ref = ref };
        }

        /// Merge-joins sorted changes with each visible bucket once. Decisions
        /// use youngest-first precedence, including tombstones, and remain
        /// private until every scanned file reaches its authenticated EOF.
        fn normalize(self: *Self, changes: []const Record) !std.ArrayList(Record) {
            var rows: std.ArrayList(Record) = .empty;
            errdefer rows.deinit(self.gpa);
            try rows.appendSlice(self.gpa, changes);
            std.mem.sort(Record, rows.items, {}, less);
            const Decision = enum { unresolved, keep, omit };
            const decisions = try self.gpa.alloc(Decision, rows.items.len);
            defer self.gpa.free(decisions);
            @memset(decisions, .unresolved);
            var remaining = rows.items.len;
            levels: for (self.frontier.levels) |level| {
                for ([_]Hash{ level.curr, level.snap }) |hash| {
                    if (remaining == 0) break :levels;
                    var cursor = try self.store.scanBucket(hash, self.mergeLimits());
                    defer cursor.deinit();
                    var index: usize = 0;
                    while (try cursor.next()) |old| {
                        while (index < rows.items.len and
                            (decisions[index] != .unresolved or less({}, rows.items[index], old))) : (index += 1)
                        {}
                        if (index == rows.items.len) {
                            try cursor.finish();
                            break;
                        }
                        const row = rows.items[index];
                        if (less({}, old, row)) continue;
                        const changed = if (row.value) |value|
                            if (old.value) |previous| !std.mem.eql(u8, value, previous) else true
                        else
                            old.value != null;
                        decisions[index] = if (changed) .keep else .omit;
                        remaining -= 1;
                        index += 1;
                    }
                }
            }
            var count: usize = 0;
            for (rows.items, decisions) |row, decision| {
                if (decision == .keep or (decision == .unresolved and row.value != null)) {
                    rows.items[count] = row;
                    count += 1;
                }
            }
            rows.items.len = count;
            return rows;
        }

        const Work = struct {
            store: *storage.Store,
            limits: storage.MergeLimits,
            job: frontiers.Merge,
            result: Hash = undefined,
            failure: ?anyerror = null,
            fn run(work: *Work) void {
                work.result = work.store.mergeBuckets(work.job.older, work.job.newer, work.job.drop_tombstones, work.limits) catch |err| {
                    work.failure = err;
                    return;
                };
            }
        };
        fn runMerges(self: *Self, jobs: []const frontiers.Merge, results: []Hash) !void {
            var work: [depth]Work = undefined;
            var threads: [depth]std.Thread = undefined;
            var start: usize = 0;
            while (start < jobs.len) {
                const count = @min(self.options.merge_workers, jobs.len - start);
                for (0..count) |i| work[i] = .{ .store = &self.store, .limits = self.mergeLimits(), .job = jobs[start + i] };
                if (count == 1) {
                    Work.run(&work[0]);
                } else {
                    var spawned: usize = 0;
                    while (spawned < count) : (spawned += 1) {
                        threads[spawned] = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Work.run, .{&work[spawned]}) catch |err| {
                            for (threads[0..spawned]) |thread| thread.join();
                            return err;
                        };
                    }
                    for (threads[0..count]) |thread| thread.join();
                }
                for (work[0..count], 0..) |job, i| {
                    if (job.failure) |err| return err;
                    results[start + i] = job.result;
                }
                start += count;
            }
        }

        fn v2Target(self: *const Self) ?u32 {
            return switch (self.options.format orelse .v1) {
                .v1 => null,
                .v2 => |v2| v2.target_block_bytes,
            };
        }

        fn mergeLimits(self: *const Self) storage.MergeLimits {
            comptime var max_key: u32 = 0;
            comptime var max_value: u32 = 0;
            inline for (comptime std.meta.fieldNames(@TypeOf(S.tables))) |name| {
                const T = @field(S.tables, name);
                max_key = @max(max_key, lib.Codec(T.Key).max_size);
                max_value = @max(max_value, lib.Codec(T.Value).max_size);
            }
            return .{ .max_key_bytes = max_key, .max_value_bytes = max_value, .max_records = self.options.max_bucket_records, .max_bucket_bytes = self.options.max_bucket_bytes, .format = self.options.format orelse .v1 };
        }

        fn validateRecord(row: Record) !void {
            inline for (comptime std.meta.fieldNames(@TypeOf(S.tables))) |name| {
                const T = @field(S.tables, name);
                if (row.table == T.id) {
                    _ = lib.Codec(T.Key).decode(row.key) catch return error.InvalidRecord;
                    if (row.value) |v| _ = lib.Codec(T.Value).decode(v) catch return error.InvalidRecord;
                    return;
                }
            }
            return error.InvalidRecord;
        }

        fn validate(self: *Self, state: *const Frontier) !void {
            try state.validateShape();
            var seen: [depth * 3]Hash = undefined;
            var count: usize = 0;
            for (state.levels) |level| {
                for ([_]?Hash{ level.curr, level.snap, level.next }) |maybe_hash| {
                    const hash = maybe_hash orelse continue;
                    var duplicate = false;
                    for (seen[0..count]) |previous| if (std.mem.eql(u8, &previous, &hash)) {
                        duplicate = true;
                        break;
                    };
                    if (duplicate) continue;
                    seen[count] = hash;
                    count += 1;
                    var cursor = try self.store.scanBucketIndexed(hash, self.mergeLimits());
                    defer cursor.deinit();
                    while (try cursor.next()) |row| {
                        try validateRecord(row);
                        if (row.value == null and std.mem.eql(u8, &hash, &state.levels[depth - 1].curr)) return error.InvalidTopology;
                    }
                }
            }
            // The pending output is already a durable blob; re-derive its
            // hash from the authenticated inputs without rewriting it.
            for (0..depth) |i| if (state.pendingJob(i)) |job| {
                self.store.mergeBucketsVerify(job.older, job.newer, job.drop_tombstones, self.mergeLimits(), state.levels[i].next.?) catch |err| switch (err) {
                    error.MergeMismatch => return error.InvalidTopology,
                    else => return err,
                };
            };
        }

        const Loaded = struct {
            frontier: Frontier,
            metadata: []u8,
            fn deinit(self: *Loaded, gpa: Allocator) void {
                gpa.free(self.metadata);
            }
        };
        fn manifestLimit(self: *const Self) usize {
            return manifest_domain.len + 32 + 32 + 8 + depth * 97 + 4 + self.options.max_metadata_bytes;
        }
        fn requireGenesisOnly(self: *Self, genesis_hash: Hash) !void {
            var iterator = self.store.blobs.iterate();
            while (iterator.next(self.io) catch return error.IoFailed) |entry| {
                if (entry.name.len != 64) continue;
                var canonical = true;
                for (entry.name) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
                    canonical = false;
                    break;
                };
                if (!canonical) continue;
                var hash: Hash = undefined;
                _ = std.fmt.hexToBytes(&hash, entry.name) catch unreachable;
                if (!std.mem.eql(u8, &hash, &self.frontier.empty) and !std.mem.eql(u8, &hash, &genesis_hash)) return error.MissingManifest;
            }
        }
        fn writeManifest(self: *Self, state: *const Frontier, meta: []const u8) !Reference {
            const bytes = try self.encodeManifest(state, meta);
            defer self.gpa.free(bytes);
            return .{ .manifest_hash = try self.store.putBlob(bytes), .database_digest = state.commitment(schema_hash).digest };
        }
        fn encodeManifest(self: *Self, state: *const Frontier, meta: []const u8) ![]u8 {
            var bytes: std.ArrayList(u8) = .empty;
            errdefer bytes.deinit(self.gpa);
            try bytes.appendSlice(self.gpa, manifest_domain);
            try bytes.appendSlice(self.gpa, &schema_hash);
            try bytes.appendSlice(self.gpa, &state.profile_hash);
            try appendInt(u64, &bytes, self.gpa, state.seq);
            for (state.levels) |level| {
                try bytes.appendSlice(self.gpa, &level.curr);
                try bytes.appendSlice(self.gpa, &level.snap);
                try bytes.append(self.gpa, @intFromBool(level.next != null));
                if (level.next) |hash| try bytes.appendSlice(self.gpa, &hash);
            }
            try appendInt(u32, &bytes, self.gpa, @intCast(meta.len));
            try bytes.appendSlice(self.gpa, meta);
            return bytes.toOwnedSlice(self.gpa);
        }
        fn load(self: *Self, ref: Reference) !Loaded {
            const bytes = try self.store.getBlob(self.gpa, ref.manifest_hash, self.manifestLimit());
            defer self.gpa.free(bytes);
            var reader: Reader = .{ .bytes = bytes };
            if (!std.mem.eql(u8, try reader.take(manifest_domain.len), manifest_domain)) return error.InvalidManifest;
            if (!std.mem.eql(u8, try reader.take(32), &schema_hash)) return error.SchemaMismatch;
            var state: Frontier = if (self.v2Target()) |target|
                Frontier.initProfile(lib.proofs.profileHash(@intCast(depth), target), lib.proofs.emptyBucketHash())
            else
                .init();
            if (!std.mem.eql(u8, try reader.take(32), &state.profile_hash)) return error.ProfileMismatch;
            state.seq = try reader.int(u64);
            for (&state.levels) |*level| {
                level.curr = try reader.hash();
                level.snap = try reader.hash();
                const tag = try reader.int(u8);
                level.next = switch (tag) {
                    0 => null,
                    1 => try reader.hash(),
                    else => return error.InvalidManifest,
                };
            }
            const meta_len = try reader.int(u32);
            if (meta_len > self.options.max_metadata_bytes) return error.MetadataTooLarge;
            const meta = try reader.take(meta_len);
            try reader.end();
            if (!std.mem.eql(u8, &state.commitment(schema_hash).digest, &ref.database_digest)) return error.CommitmentMismatch;
            return .{ .frontier = state, .metadata = try self.gpa.dupe(u8, meta) };
        }
        fn publish(self: *Self, ref: Reference) !void {
            var payload: [catalog_domain.len + 64]u8 = undefined;
            @memcpy(payload[0..catalog_domain.len], catalog_domain);
            @memcpy(payload[catalog_domain.len..][0..32], &ref.manifest_hash);
            @memcpy(payload[catalog_domain.len + 32 ..], &ref.database_digest);
            try self.store.publish(&payload);
        }

        /// Pins this exact frontier against collection. Owner must outlive it.
        /// View acquisition/release and reads are serialized with owner calls.
        pub fn readView(self: *Self) !*ReadView {
            if (self.view_count >= self.options.max_read_views) return error.TooManyViews;
            const view = try self.gpa.create(ReadView);
            view.* = .{ .owner = self, .state = self.frontier, .ref = self.current_reference, .next = self.views };
            self.views = view;
            self.view_count += 1;
            return view;
        }
        pub const ReadView = struct {
            owner: *Self,
            state: Frontier,
            ref: Reference,
            next: ?*ReadView,
            pub fn commitment(self: *const ReadView) Commitment {
                return commitmentFor(&self.state);
            }
            pub fn reference(self: *const ReadView) Reference {
                return self.ref;
            }
            pub fn get(self: *ReadView, comptime name: Name, key: Def.table(name).Key) !?Def.table(name).Value {
                return self.owner.getFrom(&self.state, name, key);
            }
            /// Prove one key's visible state at this pinned view, verifiable
            /// against `self.commitment().digest`.
            pub fn prove(self: *ReadView, comptime name: Name, key: Def.table(name).Key, gpa: Allocator) !ProofBundle {
                return self.owner.proveState(&self.state, name, key, gpa);
            }
            pub fn deinit(self: *ReadView) void {
                const owner = self.owner;
                var link = &owner.views;
                while (link.*.? != self) link = &link.*.?.next;
                link.* = self.next;
                owner.view_count -= 1;
                owner.gpa.destroy(self);
            }
        };

        /// A generated visible-state proof plus every allocation it owns.
        pub const ProofBundle = struct {
            proof: lib.proofs.VisibleProof,
            levels: []lib.proofs.ChainLevel,
            blocks: [][]u8,
            steps: [][]const lib.proofs.BlockPath.Step,
            gpa: Allocator,
            pub fn deinit(self: *ProofBundle) void {
                self.gpa.free(self.proof.key);
                for (self.blocks) |block| self.gpa.free(block);
                self.gpa.free(self.blocks);
                for (self.steps) |list| self.gpa.free(list);
                self.gpa.free(self.steps);
                self.gpa.free(self.proof.younger);
                self.gpa.free(self.levels);
            }
        };

        const ScannedBucket = struct {
            present: bool,
            block: []u8,
            block_index: u64,
            block_count: u64,
            record_count: u64,
            leaves: []lib.proofs.Hash,
            bracketed: bool,
        };

        /// Stream one bucket under the read index, re-deriving block bytes,
        /// leaf hashes, and the block that contains or brackets the key.
        fn scanForProof(self: *Self, gpa: Allocator, hash: Hash, table: u32, key: []const u8) !ScannedBucket {
            const target: u32 = self.v2Target().?;
            var cursor = try self.store.scanBucketIndexed(hash, self.mergeLimits());
            defer cursor.deinit();
            var leaves: std.ArrayList(lib.proofs.Hash) = .empty;
            errdefer leaves.deinit(gpa);
            var block: std.ArrayList(u8) = .empty;
            errdefer block.deinit(gpa);
            var block_size: u64 = 0;
            var block_index: u64 = 0;
            var record_count: u64 = 0;
            var present = false;
            var bracketed = false;
            var chosen: ?struct { index: u64, bytes: []u8, leaves_at_close: usize } = null;
            while (true) {
                const record = try cursor.next() orelse break;
                // Re-frame into the current block buffer.
                var header: [8]u8 = undefined;
                std.mem.writeInt(u32, header[0..4], record.table, .big);
                std.mem.writeInt(u32, header[4..8], @intCast(record.key.len), .big);
                try block.appendSlice(gpa, &header);
                try block.appendSlice(gpa, record.key);
                try block.append(gpa, @intFromBool(record.value != null));
                if (record.value) |value| {
                    var length: [4]u8 = undefined;
                    std.mem.writeInt(u32, &length, @intCast(value.len), .big);
                    try block.appendSlice(gpa, &length);
                    try block.appendSlice(gpa, value);
                    block_size += 13 + record.key.len + value.len;
                } else block_size += 9 + record.key.len;
                record_count += 1;
                const order: std.math.Order = if (record.table != table)
                    (if (record.table < table) .lt else .gt)
                else
                    std.mem.order(u8, record.key, key);
                if (order == .eq) present = true;
                if (block_size >= target) {
                    // Close this block: hash it over the re-framed bytes.
                    const leaf = lib.proofs.blockHash(block_index, block.items);
                    try leaves.append(gpa, leaf);
                    if (present and chosen == null) {
                        chosen = .{ .index = block_index, .bytes = try gpa.dupe(u8, block.items), .leaves_at_close = leaves.items.len };
                    }
                    if (!present and !bracketed and order == .gt) {
                        bracketed = true;
                        chosen = .{ .index = block_index, .bytes = try gpa.dupe(u8, block.items), .leaves_at_close = leaves.items.len };
                    }
                    block.clearRetainingCapacity();
                    block_size = 0;
                    block_index += 1;
                }
            }
            if (block.items.len > 0) {
                const leaf = lib.proofs.blockHash(block_index, block.items);
                try leaves.append(gpa, leaf);
                if (chosen == null) {
                    chosen = .{ .index = block_index, .bytes = try gpa.dupe(u8, block.items), .leaves_at_close = leaves.items.len };
                }
            } else if (chosen == null) {
                return error.NoBracketingBlock;
            }
            block.deinit(gpa);
            const picked = chosen.?;
            return .{
                .present = present,
                .block = picked.bytes,
                .block_index = picked.index,
                .block_count = block_index + @intFromBool(block.items.len > 0),
                .record_count = record_count,
                .leaves = try leaves.toOwnedSlice(gpa),
                .bracketed = bracketed or present,
            };
        }

        /// Generate the youngest-wins visible-state proof for one key from
        /// the current frontier. Requires a v2 profile.
        pub fn prove(self: *Self, comptime name: Name, key: Def.table(name).Key, gpa: Allocator) !ProofBundle {
            return self.proveState(&self.frontier, name, key, gpa);
        }

        /// Generation against any authenticated frontier state: the live
        /// frontier, a pinned read view, or a loaded retained reference.
        /// Soundness needs only the state's bucket bytes (every scanned
        /// bucket is fully re-verified during generation) and the caller's
        /// trusted digest for the returned proof.
        fn proveState(self: *Self, state: *const Frontier, comptime name: Name, key: Def.table(name).Key, gpa: Allocator) !ProofBundle {
            const target = self.v2Target() orelse return error.ProfileMismatch;
            _ = target;
            const T = Def.table(name);
            var buf: [lib.Codec(T.Key).max_size]u8 = undefined;
            const key_bytes = try lib.Codec(T.Key).encode(key, &buf);
            var blocks: std.ArrayList([]u8) = .empty;
            errdefer {
                for (blocks.items) |b| gpa.free(b);
                blocks.deinit(gpa);
            }
            var steps: std.ArrayList([]const lib.proofs.BlockPath.Step) = .empty;
            errdefer {
                for (steps.items) |list| gpa.free(list);
                steps.deinit(gpa);
            }
            var placements: std.ArrayList(lib.proofs.SlotPlacement) = .empty;
            errdefer placements.deinit(gpa);
            var scanned_leaves: std.ArrayList([]lib.proofs.Hash) = .empty;
            errdefer {
                for (scanned_leaves.items) |list| gpa.free(list);
                scanned_leaves.deinit(gpa);
            }
            var deciding: ?lib.proofs.SlotPlacement = null;
            var deciding_value: ?[]const u8 = null;
            _ = &deciding_value;
            var deciding_present = false;
            generate: for (state.levels, 0..) |level, level_index| {
                for ([_]struct { hash: Hash, snapshot: bool }{
                    .{ .hash = level.curr, .snapshot = false },
                    .{ .hash = level.snap, .snapshot = true },
                }) |slot| {
                    if (std.mem.eql(u8, &slot.hash, &state.empty)) continue;
                    const scanned = try self.scanForProof(gpa, slot.hash, T.id, key_bytes);
                    defer gpa.free(scanned.leaves);
                    const path = try lib.proofs.blockPath(gpa, scanned.leaves, @intCast(scanned.block_index));
                    const placement: lib.proofs.SlotPlacement = .{
                        .slot_level = level_index,
                        .slot_snapshot = slot.snapshot,
                        .bucket = .{
                            .block = scanned.block,
                            .block_index = scanned.block_index,
                            .block_count = scanned.block_count,
                            .record_count = scanned.record_count,
                            .path = path,
                        },
                    };
                    try blocks.append(gpa, scanned.block);
                    try steps.append(gpa, path.steps);
                    if (scanned.present) {
                        deciding = placement;
                        deciding_present = true;
                        deciding_value = valueInBlock(scanned.block, T.id, key_bytes);
                        break :generate;
                    }
                    try placements.append(gpa, placement);
                    deciding = placement;
                }
            }
            const final_placement = deciding orelse return error.KeyNotFound;
            if (!deciding_present) {
                // The oldest non-empty bucket decides absence; drop its
                // duplicated absence entry from the younger list.
                if (placements.items.len > 0 and placements.items[placements.items.len - 1].slot_level == final_placement.slot_level and placements.items[placements.items.len - 1].slot_snapshot == final_placement.slot_snapshot) {
                    _ = placements.pop();
                }
            }
            const levels = try gpa.alloc(lib.proofs.ChainLevel, depth);
            errdefer gpa.free(levels);
            for (state.levels, 0..) |level, i| {
                levels[i] = .{ .curr = level.curr, .snap = level.snap, .next = level.next };
            }
            return .{
                .proof = .{
                    .table = T.id,
                    .key = try gpa.dupe(u8, key_bytes),
                    .value = deciding_value,
                    .absent = !deciding_present,
                    .younger = try placements.toOwnedSlice(gpa),
                    .deciding = final_placement,
                    .schema_hash = schema_hash,
                    .profile_hash = state.profile_hash,
                    .advance = state.seq,
                    .levels = levels,
                },
                .levels = levels,
                .blocks = try blocks.toOwnedSlice(gpa),
                .steps = try steps.toOwnedSlice(gpa),
                .gpa = gpa,
            };
        }

        /// Prove one key's visible state at a RETAINED checkpoint reference.
        /// The reference's manifest is loaded and digest-checked; generation
        /// then re-verifies every bucket it touches, so the proof is sound
        /// against `reference.database_digest`. The caller must keep the
        /// reference retained against collection.
        pub fn proveReference(self: *Self, ref: Reference, comptime name: Name, key: Def.table(name).Key, gpa: Allocator) !ProofBundle {
            if (self.poisoned) return error.Poisoned;
            var loaded = try self.load(ref);
            defer loaded.deinit(self.gpa);
            return self.proveState(&loaded.frontier, name, key, gpa);
        }

        /// Every allocation a generated range proof owns; record bytes are
        /// borrowed from `blocks` through `proof.entries`.
        pub const RangeBundle = struct {
            proof: lib.proofs.RangeProof,
            levels: []lib.proofs.ChainLevel,
            runs: []lib.proofs.RangeRun,
            blocks: [][]u8,
            steps: [][]const lib.proofs.BlockPath.Step,
            gpa: Allocator,

            pub fn deinit(self: *RangeBundle) void {
                self.gpa.free(self.proof.start);
                self.gpa.free(self.proof.end);
                self.gpa.free(self.proof.entries);
                for (self.blocks) |block| self.gpa.free(block);
                self.gpa.free(self.blocks);
                for (self.steps) |list| self.gpa.free(list);
                self.gpa.free(self.steps);
                for (self.runs) |run| self.gpa.free(run.blocks);
                self.gpa.free(self.runs);
                self.gpa.free(self.levels);
            }
        };

        /// Per-block metadata from a bucket's first verified pass: whether
        /// the block holds an in-range record, ends before (table, start),
        /// or starts at/after (table, end).
        const RunMeta = struct { hit: bool, prefix: bool, suffix: bool };

        /// Choose the covering run [from, to] a range proof must include
        /// (see lib.proofs.verifyRange's completeness rules): the inner
        /// blocks plus one bracket on each unbounded side, or for a bucket
        /// with no in-range records the last prefix block through the first
        /// block starting at/after end (a mixed block needs one more).
        fn selectRun(meta: []const RunMeta) struct { from: usize, to: usize } {
            const count = meta.len;
            var first: ?usize = null;
            var last: usize = 0;
            for (meta, 0..) |m, index| {
                if (!m.hit) continue;
                if (first == null) first = index;
                last = index;
            }
            if (first) |inner| {
                return .{
                    .from = if (inner > 0) inner - 1 else 0,
                    .to = if (last + 1 < count) last + 1 else count - 1,
                };
            }
            var anchor: ?usize = null;
            for (meta, 0..) |m, index| {
                if (m.prefix) anchor = index;
            }
            const from = anchor orelse 0;
            if (anchor == null) {
                // No block ends before start: block zero is mixed or the
                // whole bucket starts at/after end.
                if (count > 1 and !meta[0].suffix) return .{ .from = 0, .to = 1 };
                return .{ .from = 0, .to = 0 };
            }
            if (from + 1 < count and !meta[from + 1].suffix and from + 2 < count)
                return .{ .from = from, .to = from + 2 };
            return .{ .from = from, .to = @min(from + 1, count - 1) };
        }

        /// Generate the visible-range proof for one table over encoded key
        /// interval [start, end) from the current frontier (youngest-wins
        /// across every non-empty slot). Requires a v2 profile.
        pub fn proveRange(self: *Self, comptime name: Name, start: Def.table(name).Key, end: Def.table(name).Key, gpa: Allocator) !RangeBundle {
            return self.proveRangeState(&self.frontier, name, start, end, gpa);
        }

        fn proveRangeState(self: *Self, state: *const Frontier, comptime name: Name, start_key: Def.table(name).Key, end_key: Def.table(name).Key, gpa: Allocator) !RangeBundle {
            const target = self.v2Target() orelse return error.ProfileMismatch;
            const T = Def.table(name);
            var start_buf: [lib.Codec(T.Key).max_size]u8 = undefined;
            var end_buf: [lib.Codec(T.Key).max_size]u8 = undefined;
            const start = try lib.Codec(T.Key).encode(start_key, &start_buf);
            const end = try lib.Codec(T.Key).encode(end_key, &end_buf);
            if (std.mem.order(u8, start, end) != .lt) return error.InvalidRange;

            var runs: std.ArrayList(lib.proofs.RangeRun) = .empty;
            errdefer {
                for (runs.items) |run| gpa.free(run.blocks);
                runs.deinit(gpa);
            }
            var blocks: std.ArrayList([]u8) = .empty;
            errdefer {
                for (blocks.items) |block| gpa.free(block);
                blocks.deinit(gpa);
            }
            var steps: std.ArrayList([]const lib.proofs.BlockPath.Step) = .empty;
            errdefer {
                for (steps.items) |list| gpa.free(list);
                steps.deinit(gpa);
            }
            var entries: std.ArrayList(lib.proofs.RangeEntry) = .empty;
            errdefer entries.deinit(gpa);
            var decided: std.StringHashMapUnmanaged(void) = .empty;
            defer decided.deinit(gpa);

            for (state.levels, 0..) |level, level_index| {
                for ([_]struct { hash: Hash, snapshot: bool }{
                    .{ .hash = level.curr, .snapshot = false },
                    .{ .hash = level.snap, .snapshot = true },
                }) |slot| {
                    if (std.mem.eql(u8, &slot.hash, &state.empty)) continue;
                    var run = try self.rangeRunForSlot(gpa, slot.hash, T.id, start, end, target, &blocks, &steps);
                    errdefer gpa.free(run.blocks);
                    run.slot_level = level_index;
                    run.slot_snapshot = slot.snapshot;
                    // Youngest-wins: this slot decides every in-range key it
                    // holds that no younger slot has decided yet.
                    for (run.blocks) |*range_block| {
                        var position: usize = 0;
                        const bytes = range_block.block;
                        while (position + 8 <= bytes.len) {
                            const record_table = std.mem.readInt(u32, bytes[position..][0..4], .big);
                            const key_len = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .big);
                            if (position + 8 + key_len + 1 > bytes.len) return error.InvalidBucket;
                            const record_key = bytes[position + 8 ..][0..key_len];
                            position += 8 + key_len;
                            const tag = bytes[position];
                            position += 1;
                            var value: ?[]const u8 = null;
                            if (tag == 1) {
                                if (position + 4 > bytes.len) return error.InvalidBucket;
                                const value_len = std.mem.readInt(u32, bytes[position..][0..4], .big);
                                if (position + 4 + value_len > bytes.len) return error.InvalidBucket;
                                value = bytes[position + 4 ..][0..value_len];
                                position += 4 + value_len;
                            } else if (tag != 0) return error.InvalidBucket;
                            if (record_table != T.id) continue;
                            if (std.mem.order(u8, record_key, start) == .lt) continue;
                            if (std.mem.order(u8, record_key, end) != .lt) break;
                            const seen = (try decided.getOrPut(gpa, record_key)).found_existing;
                            if (!seen and value != null) try entries.append(gpa, .{ .key = record_key, .value = value.? });
                        }
                    }
                    try runs.append(gpa, run);
                }
            }
            std.mem.sort(lib.proofs.RangeEntry, entries.items, {}, struct {
                fn less(_: void, a: lib.proofs.RangeEntry, b: lib.proofs.RangeEntry) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.less);
            const levels = try gpa.alloc(lib.proofs.ChainLevel, depth);
            errdefer gpa.free(levels);
            for (state.levels, 0..) |level, i| {
                levels[i] = .{ .curr = level.curr, .snap = level.snap, .next = level.next };
            }
            const owned_runs = try runs.toOwnedSlice(gpa);
            errdefer gpa.free(owned_runs);
            return .{
                .proof = .{
                    .table = T.id,
                    .start = try gpa.dupe(u8, start),
                    .end = try gpa.dupe(u8, end),
                    .entries = try entries.toOwnedSlice(gpa),
                    .runs = owned_runs,
                    .schema_hash = schema_hash,
                    .profile_hash = state.profile_hash,
                    .advance = state.seq,
                    .levels = levels,
                },
                .levels = levels,
                .runs = owned_runs,
                .blocks = try blocks.toOwnedSlice(gpa),
                .steps = try steps.toOwnedSlice(gpa),
                .gpa = gpa,
            };
        }

        /// Two verified passes over one slot's bucket: the first derives
        /// per-block metadata and the covering run, the second retains only
        /// the run's block bytes and every leaf; paths are computed after
        /// the tree is complete. Block bytes are appended to `blocks` and
        /// step slices to `steps`; the returned run borrows both.
        fn rangeRunForSlot(self: *Self, gpa: Allocator, hash: Hash, table: u32, start: []const u8, end: []const u8, target: u32, blocks: *std.ArrayList([]u8), steps: *std.ArrayList([]const lib.proofs.BlockPath.Step)) !lib.proofs.RangeRun {
            var meta: std.ArrayList(RunMeta) = .empty;
            defer meta.deinit(gpa);
            var record_count: u64 = 0;
            {
                var cursor = try self.store.scanBucketIndexed(hash, self.mergeLimits());
                defer cursor.deinit();
                var block_size: u64 = 0;
                var hit = false;
                var last_below_start = false;
                var first_at_or_after_end = false;
                var seen = false;
                while (try cursor.next()) |record| {
                    if (!seen) {
                        seen = true;
                        first_at_or_after_end = record.table > table or (record.table == table and std.mem.order(u8, record.key, end) != .lt);
                    }
                    if (record.table == table and std.mem.order(u8, record.key, start) != .lt and std.mem.order(u8, record.key, end) == .lt) hit = true;
                    last_below_start = record.table < table or (record.table == table and std.mem.order(u8, record.key, start) == .lt);
                    block_size += 9 + record.key.len + if (record.value) |value| 4 + value.len else 0;
                    record_count += 1;
                    if (block_size >= target) {
                        try meta.append(gpa, .{ .hit = hit, .prefix = last_below_start, .suffix = first_at_or_after_end });
                        block_size = 0;
                        hit = false;
                        seen = false;
                    }
                }
                if (seen) try meta.append(gpa, .{ .hit = hit, .prefix = last_below_start, .suffix = first_at_or_after_end });
            }
            const selection = selectRun(meta.items);
            var run_blocks: std.ArrayList(lib.proofs.RangeBlock) = .empty;
            errdefer run_blocks.deinit(gpa);
            {
                var cursor = try self.store.scanBucketIndexed(hash, self.mergeLimits());
                defer cursor.deinit();
                var leaves: std.ArrayList(lib.proofs.Hash) = .empty;
                defer leaves.deinit(gpa);
                var block: std.ArrayList(u8) = .empty;
                defer block.deinit(gpa);
                var kept: std.ArrayList(u64) = .empty;
                defer kept.deinit(gpa);
                var block_size: u64 = 0;
                var block_index: u64 = 0;
                while (try cursor.next()) |record| {
                    var header: [8]u8 = undefined;
                    std.mem.writeInt(u32, header[0..4], record.table, .big);
                    std.mem.writeInt(u32, header[4..8], @intCast(record.key.len), .big);
                    try block.appendSlice(gpa, &header);
                    try block.appendSlice(gpa, record.key);
                    try block.append(gpa, @intFromBool(record.value != null));
                    if (record.value) |value| {
                        var length: [4]u8 = undefined;
                        std.mem.writeInt(u32, &length, @intCast(value.len), .big);
                        try block.appendSlice(gpa, &length);
                        try block.appendSlice(gpa, value);
                        block_size += 13 + record.key.len + value.len;
                    } else block_size += 9 + record.key.len;
                    if (block_size >= target) {
                        try leaves.append(gpa, lib.proofs.blockHash(block_index, block.items));
                        if (block_index >= selection.from and block_index <= selection.to) {
                            try blocks.append(gpa, try gpa.dupe(u8, block.items));
                            try kept.append(gpa, block_index);
                        }
                        block.clearRetainingCapacity();
                        block_size = 0;
                        block_index += 1;
                    }
                }
                if (block.items.len > 0) {
                    try leaves.append(gpa, lib.proofs.blockHash(block_index, block.items));
                    if (block_index >= selection.from and block_index <= selection.to) {
                        try blocks.append(gpa, try gpa.dupe(u8, block.items));
                        try kept.append(gpa, block_index);
                    }
                }
                // Paths need the complete tree; compute them only now.
                const first_kept = blocks.items.len - kept.items.len;
                for (kept.items, 0..) |index, i| {
                    const path = try lib.proofs.blockPath(gpa, leaves.items, @intCast(index));
                    try steps.append(gpa, path.steps);
                    try run_blocks.append(gpa, .{ .block = blocks.items[first_kept + i], .block_index = index, .path = path });
                }
            }
            return .{
                .slot_level = 0,
                .slot_snapshot = false,
                .block_count = meta.items.len,
                .record_count = record_count,
                .blocks = try run_blocks.toOwnedSlice(gpa),
            };
        }

        /// Requires quiescent readers. Retains current, pinned views, and each
        /// explicit reference; authenticates all roots before deleting anything.
        pub fn collect(self: *Self, retained: []const Reference) !usize {
            if (self.poisoned) return error.Poisoned;
            if (self.prepared_open) return error.PreparedActive;
            var reachable: std.ArrayList(Hash) = .empty;
            defer reachable.deinit(self.gpa);
            try self.retainReference(self.current_reference, &reachable);
            var view = self.views;
            while (view) |v| : (view = v.next) try self.retainReference(v.ref, &reachable);
            for (retained) |ref| try self.retainReference(ref, &reachable);
            return self.store.collect(reachable.items);
        }
        fn retainReference(self: *Self, ref: Reference, reachable: *std.ArrayList(Hash)) !void {
            var loaded = try self.load(ref);
            defer loaded.deinit(self.gpa);
            try self.validate(&loaded.frontier);
            try reachable.append(self.gpa, ref.manifest_hash);
            for (loaded.frontier.levels) |level| {
                try reachable.append(self.gpa, level.curr);
                try reachable.append(self.gpa, level.snap);
                if (level.next) |hash| try reachable.append(self.gpa, hash);
            }
        }
    };
}

/// Borrow the claimed value slice from inside a re-framed block copy.
fn valueInBlock(block: []const u8, table: u32, key: []const u8) ?[]const u8 {
    var position: usize = 0;
    while (position + 8 <= block.len) {
        const record_table = std.mem.readInt(u32, block[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, block[position + 4 ..][0..4], .big);
        if (position + 8 + key_len + 1 > block.len) return null;
        const record_key = block[position + 8 ..][0..key_len];
        position += 8 + key_len;
        const tag = block[position];
        position += 1;
        if (tag == 1) {
            const value_len = std.mem.readInt(u32, block[position..][0..4], .big);
            position += 4;
            if (position + value_len > block.len) return null;
            const value = block[position..][0..value_len];
            position += value_len;
            if (record_table == table and std.mem.eql(u8, record_key, key)) return value;
        } else if (record_table == table and std.mem.eql(u8, record_key, key)) return null;
    }
    return null;
}

fn rowSize(row: Record) usize {
    return 9 + row.key.len + if (row.value) |v| 4 + v.len else @as(usize, 0);
}
fn less(_: void, a: Record, b: Record) bool {
    return if (a.table != b.table) a.table < b.table else std.mem.order(u8, a.key, b.key) == .lt;
}
fn encodeAlloc(comptime T: type, gpa: Allocator, value: T) ![]u8 {
    const bytes = try gpa.alloc(u8, lib.Codec(T).max_size);
    errdefer gpa.free(bytes);
    const encoded = try lib.Codec(T).encode(value, bytes);
    return try gpa.realloc(bytes, encoded.len);
}
fn appendInt(comptime T: type, bytes: *std.ArrayList(u8), gpa: Allocator, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    try bytes.appendSlice(gpa, &buf);
}
fn encodeBucket(gpa: Allocator, rows: []const Record) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var length: usize = bucket_domain.len + 8;
    for (rows) |row| length = try std.math.add(usize, length, rowSize(row));
    try bytes.ensureTotalCapacityPrecise(gpa, length);
    try bytes.appendSlice(gpa, bucket_domain);
    try appendInt(u64, &bytes, gpa, @intCast(rows.len));
    for (rows) |row| {
        try appendInt(u32, &bytes, gpa, row.table);
        try appendInt(u32, &bytes, gpa, @intCast(row.key.len));
        try bytes.appendSlice(gpa, row.key);
        try bytes.append(gpa, @intFromBool(row.value != null));
        if (row.value) |value| {
            try appendInt(u32, &bytes, gpa, @intCast(value.len));
            try bytes.appendSlice(gpa, value);
        }
    }
    return bytes.toOwnedSlice(gpa);
}
const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.position) return error.InvalidManifest;
        const out = self.bytes[self.position..][0..len];
        self.position += len;
        return out;
    }
    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }
    fn hash(self: *Reader) !Hash {
        return (try self.take(32))[0..32].*;
    }
    fn end(self: *Reader) !void {
        if (self.position != self.bytes.len) return error.InvalidManifest;
    }
};
