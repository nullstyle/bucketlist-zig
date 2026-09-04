//! Native checkpoint publication over a caller-supplied portable Database.
//! Own one dedicated Store namespace. The complete Reference is the trust
//! anchor: a database digest alone does not authenticate application metadata.
const std = @import("std");
const storage = @import("bucketlist-store");
const Allocator = std.mem.Allocator;
const Hash = [32]u8;

pub const Reference = struct {
    manifest_hash: Hash,
    database_digest: Hash,
};

pub const Limits = struct {
    max_checkpoint_bytes: usize = 1024 * 1024 * 1024,
    max_metadata_bytes: usize = 64 * 1024,
};

pub const Error = storage.Error || error{
    InvalidCheckpoint,
    InvalidReference,
    InvalidCatalog,
    InvalidLimits,
    Poisoned,
    CommitmentMismatch,
};

const portable_magic = "bucketlist.checkpoint.v1\x00";
const portable_header_len = portable_magic.len + 32 + 32 + 8;
const manifest_magic = "bucketlist.native-checkpoint.v1\x00";
const catalog_magic = "bucketlist.checkpoint-frontier.v1\x00";
const catalog_len = catalog_magic.len + 64;
const max_levels = 31;
const manifest_overhead = manifest_magic.len + 32 + 8 + portable_header_len + 1 + max_levels * (40 + 40 + 1 + 40);

/// Owns only persistence, not the live Database or its application policy.
/// All methods are synchronous and must be serialized. Historical views may
/// be saved deliberately: the caller chooses the published frontier.
pub fn Checkpoints(comptime Db: type) type {
    return struct {
        const Self = @This();
        gpa: Allocator,
        store: storage.Store,
        limits: Limits,
        poisoned: bool = false,

        pub fn open(gpa: Allocator, io: std.Io, path: []const u8, limits: Limits) Error!Self {
            if (limits.max_checkpoint_bytes == 0 or limits.max_checkpoint_bytes > Db.max_checkpoint_bytes or
                limits.max_metadata_bytes > std.math.maxInt(usize) - manifest_overhead)
                return error.InvalidLimits;
            var self: Self = .{ .gpa = gpa, .store = try storage.Store.open(gpa, io, path), .limits = limits };
            errdefer self.deinit();
            _ = try self.current();
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.store.deinit();
            self.* = undefined;
        }

        fn check(self: *const Self) Error!void {
            if (self.poisoned) return error.Poisoned;
        }

        /// This is the local selected frontier, not an external certificate.
        /// A publication error requires close/reopen before further use.
        pub fn current(self: *Self) Error!?Reference {
            try self.check();
            const bytes = (try self.store.readManifest(self.gpa, catalog_len)) orelse return null;
            defer self.gpa.free(bytes);
            if (bytes.len != catalog_len or !std.mem.eql(u8, bytes[0..catalog_magic.len], catalog_magic))
                return error.InvalidCatalog;
            return .{
                .manifest_hash = bytes[catalog_magic.len..][0..32].*,
                .database_digest = bytes[catalog_magic.len + 32 ..][0..32].*,
            };
        }

        /// The view remains caller-owned throughout. This convenience path
        /// allocates its full portable checkpoint, then stores each bucket by
        /// hash and publishes a small immutable manifest reference.
        pub fn save(self: *Self, view: *const Db.ReadView, metadata: []const u8) Error!Reference {
            return self.saveImpl(view, metadata, false);
        }

        fn saveImpl(self: *Self, view: *const Db.ReadView, metadata: []const u8, fail_after_publish: bool) Error!Reference {
            try self.check();
            if (metadata.len > self.limits.max_metadata_bytes) return error.TooLarge;
            const portable = view.checkpoint(self.gpa) catch |err| return mapCheckpointError(err);
            defer self.gpa.free(portable);
            if (portable.len > self.limits.max_checkpoint_bytes) return error.TooLarge;
            var cursor: Cursor = .{ .bytes = portable };
            const header = try cursor.take(portable_header_len);
            if (!std.mem.eql(u8, header[0..portable_magic.len], portable_magic)) return error.InvalidCheckpoint;
            const database_digest = view.commitment().digest;
            var manifest: std.ArrayList(u8) = .empty;
            defer manifest.deinit(self.gpa);
            try manifest.appendSlice(self.gpa, manifest_magic);
            try manifest.appendSlice(self.gpa, &database_digest);
            try appendU64(self.gpa, &manifest, metadata.len);
            try manifest.appendSlice(self.gpa, metadata);
            try manifest.appendSlice(self.gpa, header);
            const levels_at = manifest.items.len;
            try manifest.append(self.gpa, 0);
            var levels: u8 = 0;
            while (cursor.pos != portable.len) {
                if (levels == max_levels) return error.InvalidCheckpoint;
                try self.saveBucket(&cursor, &manifest);
                try self.saveBucket(&cursor, &manifest);
                const present = (try cursor.take(1))[0];
                if (present > 1) return error.InvalidCheckpoint;
                try manifest.append(self.gpa, present);
                if (present == 1) try self.saveBucket(&cursor, &manifest);
                levels += 1;
            }
            if (levels == 0) return error.InvalidCheckpoint;
            manifest.items[levels_at] = levels;
            const reference: Reference = .{
                .manifest_hash = try self.store.putBlob(manifest.items),
                .database_digest = database_digest,
            };
            var catalog: [catalog_len]u8 = undefined;
            @memcpy(catalog[0..catalog_magic.len], catalog_magic);
            @memcpy(catalog[catalog_magic.len..][0..32], &reference.manifest_hash);
            @memcpy(catalog[catalog_magic.len + 32 ..][0..32], &reference.database_digest);
            self.store.publish(&catalog) catch |err| {
                self.poisoned = true;
                return err;
            };
            // Simulates an ambiguous error after durable replacement without
            // exposing fault controls in the public interface.
            if (fail_after_publish) {
                self.poisoned = true;
                return error.IoFailed;
            }
            return reference;
        }

        fn saveBucket(self: *Self, cursor: *Cursor, manifest: *std.ArrayList(u8)) Error!void {
            const len = try cursor.integer(u64);
            if (len > cursor.bytes.len - cursor.pos) return error.InvalidCheckpoint;
            const bytes = try cursor.take(@intCast(len));
            const hash = try self.store.putBlob(bytes);
            try appendU64(self.gpa, manifest, len);
            try manifest.appendSlice(self.gpa, &hash);
        }

        pub const Restored = struct {
            database: Db,
            metadata: []u8,
            gpa: Allocator,

            pub fn deinit(self: *Restored) void {
                self.database.deinit();
                self.gpa.free(self.metadata);
                self.* = undefined;
            }
        };

        /// Trust the whole reference independently for external checkpoints.
        /// Every blob is verified, then portable Db.restore checks schema,
        /// schedule, typed canonicality and the trusted database digest.
        pub fn load(self: *Self, gpa: Allocator, reference: Reference) Error!Restored {
            try self.check();
            return self.loadInternal(gpa, reference, null);
        }

        fn loadInternal(self: *Self, gpa: Allocator, reference: Reference, reachable: ?*std.ArrayList(Hash)) Error!Restored {
            const manifest = try self.store.getBlob(gpa, reference.manifest_hash, self.limits.max_metadata_bytes + manifest_overhead);
            defer gpa.free(manifest);
            var cursor: Cursor = .{ .bytes = manifest };
            if (!std.mem.eql(u8, try cursor.take(manifest_magic.len), manifest_magic)) return error.InvalidCheckpoint;
            if (!std.mem.eql(u8, try cursor.take(32), &reference.database_digest)) return error.CommitmentMismatch;
            const metadata_len = try cursor.integer(u64);
            if (metadata_len > self.limits.max_metadata_bytes) return error.TooLarge;
            const metadata = try cursor.take(@intCast(metadata_len));
            const header = try cursor.take(portable_header_len);
            if (!std.mem.eql(u8, header[0..portable_magic.len], portable_magic)) return error.InvalidCheckpoint;
            const levels = (try cursor.take(1))[0];
            if (levels == 0 or levels > max_levels) return error.InvalidCheckpoint;
            var portable: std.ArrayList(u8) = .empty;
            defer portable.deinit(gpa);
            try self.appendPortable(gpa, &portable, header);
            for (0..levels) |_| {
                try self.loadBucket(gpa, &cursor, &portable, reachable);
                try self.loadBucket(gpa, &cursor, &portable, reachable);
                const present = (try cursor.take(1))[0];
                if (present > 1) return error.InvalidCheckpoint;
                try self.appendPortable(gpa, &portable, &.{present});
                if (present == 1) try self.loadBucket(gpa, &cursor, &portable, reachable);
            }
            if (cursor.pos != manifest.len) return error.InvalidCheckpoint;
            var database = Db.restore(gpa, portable.items, reference.database_digest) catch |err| return mapCheckpointError(err);
            errdefer database.deinit();
            const owned_metadata = try gpa.dupe(u8, metadata);
            errdefer gpa.free(owned_metadata);
            if (reachable) |list| try appendUnique(gpa, list, reference.manifest_hash);
            return .{ .database = database, .metadata = owned_metadata, .gpa = gpa };
        }

        fn appendPortable(self: *Self, gpa: Allocator, portable: *std.ArrayList(u8), bytes: []const u8) Error!void {
            if (bytes.len > self.limits.max_checkpoint_bytes - portable.items.len) return error.TooLarge;
            try portable.appendSlice(gpa, bytes);
        }

        fn loadBucket(self: *Self, gpa: Allocator, cursor: *Cursor, portable: *std.ArrayList(u8), reachable: ?*std.ArrayList(Hash)) Error!void {
            const len = try cursor.integer(u64);
            const hash = (try cursor.take(32))[0..32].*;
            const available = self.limits.max_checkpoint_bytes - portable.items.len;
            if (available < 8 or len > available - 8) return error.TooLarge;
            const bytes = try self.store.getBlob(gpa, hash, @intCast(len));
            defer gpa.free(bytes);
            if (bytes.len != len) return error.InvalidCheckpoint;
            try appendU64(gpa, portable, len);
            try self.appendPortable(gpa, portable, bytes);
            if (reachable) |list| try appendUnique(gpa, list, hash);
        }

        /// Preserves the selected current checkpoint automatically, plus every
        /// caller-retained reference. Fully validates ALL roots before deleting
        /// anything. External readers/pending work must retain their references.
        /// Use a dedicated manager directory: unrelated raw blobs are collected.
        pub fn collect(self: *Self, retained: []const Reference) Error!usize {
            try self.check();
            var reachable: std.ArrayList(Hash) = .empty;
            defer reachable.deinit(self.gpa);
            if (try self.current()) |reference| {
                var restored = try self.loadInternal(self.gpa, reference, &reachable);
                restored.deinit();
            }
            for (retained) |reference| {
                var restored = try self.loadInternal(self.gpa, reference, &reachable);
                restored.deinit();
            }
            return self.store.collect(reachable.items);
        }

        test "checkpoints: ambiguous publication poisons every operation until reopen" {
            const gpa = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const path = path_buf[0..path_len];
            var db = Db.init(gpa);
            defer db.deinit();
            var view = db.readView();
            defer view.deinit();
            {
                var manager = try Self.open(gpa, std.testing.io, path, .{});
                defer manager.deinit();
                const old = try manager.save(&view, "old");
                try std.testing.expectError(error.IoFailed, manager.saveImpl(&view, "new", true));
                try std.testing.expectError(error.Poisoned, manager.current());
                try std.testing.expectError(error.Poisoned, manager.save(&view, "later"));
                try std.testing.expectError(error.Poisoned, manager.load(gpa, old));
                try std.testing.expectError(error.Poisoned, manager.collect(&.{old}));
            }
            var reopened = try Self.open(gpa, std.testing.io, path, .{});
            defer reopened.deinit();
            var restored = try reopened.load(gpa, (try reopened.current()).?);
            defer restored.deinit();
            try std.testing.expectEqualStrings("new", restored.metadata);
        }

        test "checkpoints: actual catalog publication failure poisons until reopen" {
            const gpa = std.testing.allocator;
            const io = std.testing.io;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPath(io, &path_buf);
            const path = path_buf[0..path_len];
            var db = Db.init(gpa);
            defer db.deinit();
            var view = db.readView();
            defer view.deinit();
            const Guard = struct {
                var catalog_attempts: usize = 0;
                var blob_creates: usize = 0;

                fn create(ctx: ?*anyopaque, dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
                    if (std.mem.eql(u8, name, "manifest")) {
                        catalog_attempts += 1;
                        return error.AccessDenied;
                    }
                    blob_creates += 1;
                    return std.testing.io.vtable.dirCreateFileAtomic(ctx, dir, name, options);
                }
            };
            Guard.catalog_attempts = 0;
            Guard.blob_creates = 0;
            var vtable = io.vtable.*;
            vtable.dirCreateFileAtomic = Guard.create;
            const old = blk: {
                var manager = try Self.open(gpa, io, path, .{});
                defer manager.deinit();
                const old = try manager.save(&view, "old");
                manager.store.io = .{ .userdata = io.userdata, .vtable = &vtable };
                defer manager.store.io = io;
                try std.testing.expectError(error.IoFailed, manager.save(&view, "new"));
                try std.testing.expectEqual(@as(usize, 1), Guard.catalog_attempts);
                try std.testing.expect(Guard.blob_creates >= 1);
                try std.testing.expectError(error.Poisoned, manager.current());
                try std.testing.expectError(error.Poisoned, manager.save(&view, "later"));
                try std.testing.expectError(error.Poisoned, manager.load(gpa, old));
                try std.testing.expectError(error.Poisoned, manager.collect(&.{old}));
                break :blk old;
            };
            var reopened = try Self.open(gpa, io, path, .{});
            defer reopened.deinit();
            try std.testing.expectEqual(old, (try reopened.current()).?);
            var restored = try reopened.load(gpa, old);
            defer restored.deinit();
            try std.testing.expectEqualStrings("old", restored.metadata);
        }

        fn saveUnderAllocationFailure(gpa: Allocator, manager: *Self, view: *const Db.ReadView, old: Reference) !void {
            // checkAllAllocationFailures measures a successful call first;
            // select the old frontier afresh before every injected attempt.
            try std.testing.expectEqual(old, try manager.save(view, "old"));
            const original = manager.gpa;
            manager.gpa = gpa;
            defer manager.gpa = original;
            const saved = manager.save(view, "new allocation-tested metadata") catch |err| {
                // Validation uses the ordinary allocator so the deliberately
                // exhausted save allocator cannot hide a changed frontier.
                manager.gpa = original;
                try std.testing.expectEqual(old, (try manager.current()).?);
                var restored = try manager.load(original, old);
                defer restored.deinit();
                try std.testing.expectEqualStrings("old", restored.metadata);
                return err;
            };
            manager.gpa = original;
            try std.testing.expectEqual(saved, (try manager.current()).?);
            var restored = try manager.load(original, saved);
            defer restored.deinit();
            try std.testing.expectEqualStrings("new allocation-tested metadata", restored.metadata);
        }

        test "checkpoints: all save allocations fail before publication without poisoning" {
            const gpa = std.testing.allocator;
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            var manager = try Self.open(gpa, std.testing.io, path_buf[0..path_len], .{});
            defer manager.deinit();
            var db = Db.init(gpa);
            defer db.deinit();
            var view = db.readView();
            defer view.deinit();
            const old = try manager.save(&view, "old");
            try std.testing.checkAllAllocationFailures(gpa, saveUnderAllocationFailure, .{ &manager, &view, old });
        }
    };
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    fn take(self: *Cursor, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.pos) return error.InvalidCheckpoint;
        const result = self.bytes[self.pos..][0..count];
        self.pos += count;
        return result;
    }
    fn integer(self: *Cursor, comptime T: type) Error!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }
};

fn appendU64(gpa: Allocator, bytes: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .big);
    try bytes.appendSlice(gpa, &encoded);
}

fn appendUnique(gpa: Allocator, hashes: *std.ArrayList(Hash), hash: Hash) Allocator.Error!void {
    for (hashes.items) |previous| if (std.mem.eql(u8, &previous, &hash)) return;
    try hashes.append(gpa, hash);
}

fn mapCheckpointError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CommitmentMismatch => error.CommitmentMismatch,
        else => error.InvalidCheckpoint,
    };
}
