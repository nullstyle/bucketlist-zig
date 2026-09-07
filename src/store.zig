//! Native immutable blob storage and atomic checkpoint publication.
//! See docs/storage.md for ownership, durability, and collection contracts.
const std = @import("std");
const builtin = @import("builtin");

pub const Hash = [32]u8;
pub const Error = error{
    OutOfMemory,
    IoFailed,
    NotFound,
    TooLarge,
    CorruptBlob,
    CorruptManifest,
    NotRegularFile,
    UnsupportedPlatform,
    StoreBusy,
    InvalidPath,
    InvalidBucket,
    MergeMismatch,
};

/// The bucket hash format an operation verifies or produces. v2 carries the
/// profile's committed block target; see docs/format-v2.md. Traveling with
/// MergeLimits as the per-call policy bundle, it is a consensus property,
/// not a local resource limit.
pub const BucketFormat = union(enum) {
    v1,
    v2: struct { target_block_bytes: u32 },
};

/// Per-record workspace and total-work limits for native bucket reads/merges.
/// These are local resource policies, not part of the bucket hash encoding.
pub const MergeLimits = struct {
    max_key_bytes: u32 = 64 * 1024,
    max_value_bytes: u32 = 1024 * 1024,
    max_records: u64 = 1 << 32,
    max_bucket_bytes: u64 = 1 << 40,
    format: BucketFormat = .v1,
};

/// Slices borrow the cursor and are invalidated by its next/finish/deinit call.
/// A record is provisional until the cursor reaches verified EOF successfully.
pub const BucketRecord = struct {
    table: u32,
    key: []const u8,
    value: ?[]const u8,
};

/// A verified lookup distinguishes no record, deletion, and a live empty value.
/// A value allocation belongs to the allocator passed to lookupBucket.
pub const BucketLookup = union(enum) {
    absent,
    tombstone,
    value: []u8,

    pub fn deinit(self: *BucketLookup, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .value => |bytes| gpa.free(bytes),
            else => {},
        }
        self.* = .absent;
    }
};

/// Local read-index policy: not part of any hash or committed byte.
pub const ReadIndexOptions = struct {
    /// A new sampled span starts at least this many bytes after the previous
    /// one, so a warm point read streams at most roughly this many bytes.
    min_span_bytes: usize = 64 * 1024,
    /// Hard per-bucket bound; further records land in the last, wider span.
    max_samples: usize = 1 << 16,
    /// Retained bucket indexes; excess entries are evicted least-recently-used.
    max_buckets: usize = 512,
};

/// One sampled span start: records at `offset` begin with key `key`.
const Sample = struct {
    table: u32,
    offset: u64,
    key: []u8,
};

/// Immutable after construction. A warm lookup holds a reference; eviction
/// removes the entry from the map and frees it only once references drop.
const BucketIndex = struct {
    refs: std.atomic.Value(u32) = .init(1),
    newer: ?*BucketIndex = null,
    older: ?*BucketIndex = null,
    hash: Hash,
    size: u64,
    record_count: u64,
    samples: []Sample,

    fn order(_: void, a: Sample, b: Sample) bool {
        if (a.table != b.table) return a.table < b.table;
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

const ReadIndexCache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    options: ReadIndexOptions,
    map: std.HashMapUnmanaged(Hash, *BucketIndex, HashContext, std.hash_map.default_max_load_percentage) = .empty,
    newest: ?*BucketIndex = null,
    oldest: ?*BucketIndex = null,

    const HashContext = struct {
        pub fn hash(_: HashContext, key: Hash) u64 {
            return std.mem.readInt(u64, key[0..8], .little);
        }
        pub fn eql(_: HashContext, a: Hash, b: Hash) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    fn create(gpa: std.mem.Allocator, io: std.Io, options: ReadIndexOptions) Error!*ReadIndexCache {
        const self = gpa.create(ReadIndexCache) catch return error.OutOfMemory;
        self.* = .{ .gpa = gpa, .io = io, .options = .{
            .min_span_bytes = @max(1, options.min_span_bytes),
            .max_samples = @max(1, options.max_samples),
            .max_buckets = @max(1, options.max_buckets),
        } };
        return self;
    }

    fn destroy(self: *ReadIndexCache) void {
        var entry = self.oldest;
        while (entry) |index| {
            const next = index.newer;
            self.freeIndex(index);
            entry = next;
        }
        self.map.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn freeIndex(self: *ReadIndexCache, index: *BucketIndex) void {
        for (index.samples) |sample| self.gpa.free(sample.key);
        self.gpa.free(index.samples);
        self.gpa.destroy(index);
    }

    /// Caller must call release exactly once per acquired index.
    fn acquire(self: *ReadIndexCache, hash: Hash) ?*BucketIndex {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = self.map.get(hash) orelse return null;
        _ = index.refs.fetchAdd(1, .acq_rel);
        self.touch(index);
        return index;
    }

    fn release(self: *ReadIndexCache, index: *BucketIndex) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.releaseLocked(index);
    }

    fn releaseLocked(self: *ReadIndexCache, index: *BucketIndex) void {
        if (index.refs.fetchSub(1, .acq_rel) == 1) self.freeIndex(index);
    }

    fn unlink(self: *ReadIndexCache, index: *BucketIndex) void {
        if (index.newer) |above| above.older = index.older else self.newest = index.older;
        if (index.older) |below| below.newer = index.newer else self.oldest = index.newer;
        index.newer = null;
        index.older = null;
    }

    fn touch(self: *ReadIndexCache, index: *BucketIndex) void {
        if (self.newest == index) return;
        self.unlink(index);
        // Relink at the newest end.
        index.older = self.newest;
        if (self.newest) |above| above.newer = index;
        self.newest = index;
        if (self.oldest == null) self.oldest = index;
    }

    /// Takes ownership of `samples`; an empty or duplicate install frees them.
    /// Allocation failure is caller-visible: the read fails with OutOfMemory
    /// and may be retried, keeping every allocation failure observable.
    fn install(self: *ReadIndexCache, hash: Hash, size: u64, record_count: u64, samples: []Sample) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (samples.len == 0) {
            self.freeSamples(samples);
            return;
        }
        if (self.map.get(hash)) |existing| {
            // Keep the already-installed verified entry; drop the new samples.
            self.touch(existing);
            self.freeSamples(samples);
            return;
        }
        const index = self.gpa.create(BucketIndex) catch {
            self.freeSamples(samples);
            return error.OutOfMemory;
        };
        index.* = .{ .hash = hash, .size = size, .record_count = record_count, .samples = samples };
        self.map.put(self.gpa, hash, index) catch {
            self.gpa.destroy(index);
            self.freeSamples(samples);
            return error.OutOfMemory;
        };
        index.older = self.newest;
        if (self.newest) |above| above.newer = index;
        self.newest = index;
        if (self.oldest == null) self.oldest = index;
        while (self.map.count() > self.options.max_buckets) {
            const victim = self.oldest orelse break;
            std.debug.assert(self.map.remove(victim.hash));
            self.unlink(victim);
            self.releaseLocked(victim);
        }
    }

    fn freeSamples(self: *ReadIndexCache, samples: []Sample) void {
        for (samples) |sample| self.gpa.free(sample.key);
        self.gpa.free(samples);
    }
};

/// Owned bounded-memory scan. Do not copy; deinit closes its file and workspace.
/// Stop only after next returns null or finish succeeds to verify the hash,
/// order, framing, counts, and EOF. Deinit alone abandons verification.
pub const BucketCursor = struct {
    reader: BucketReader,
    record_count: u64,
    failure: ?Error = null,

    /// File/header metadata is provisional until verified EOF or finish.
    pub fn byteLength(self: *const BucketCursor) u64 {
        return self.reader.size;
    }

    pub fn recordCount(self: *const BucketCursor) u64 {
        return self.record_count;
    }

    pub fn deinit(self: *BucketCursor) void {
        self.reader.deinit();
        self.* = undefined;
    }

    pub fn next(self: *BucketCursor) Error!?BucketRecord {
        if (self.failure) |err| return err;
        self.reader.advance() catch |err| {
            self.failure = err;
            return err;
        };
        return self.reader.current;
    }

    /// Drain the unread suffix and authenticate the complete bucket.
    pub fn finish(self: *BucketCursor) Error!void {
        while (try self.next() != null) {}
    }
};

/// Scan cursor that additionally records read-index samples and installs
/// them exactly when verification reaches EOF. Record slices and verification
/// rules follow BucketCursor; with no read index enabled it behaves as
/// scanBucket. Index-bookkeeping allocation failures are observable errors.
pub const IndexedCursor = struct {
    cursor: BucketCursor,
    store: *Store,
    hash: Hash,
    total_records: u64,
    samples: std.ArrayList(Sample) = .empty,
    sampled_offset: u64 = 0,
    installed: bool = false,

    pub fn byteLength(self: *const IndexedCursor) u64 {
        return self.cursor.byteLength();
    }
    pub fn recordCount(self: *const IndexedCursor) u64 {
        return self.total_records;
    }
    pub fn deinit(self: *IndexedCursor) void {
        if (!self.installed) {
            for (self.samples.items) |sample| self.store.gpa.free(sample.key);
            self.samples.deinit(self.store.gpa);
        }
        self.cursor.deinit();
        self.* = undefined;
    }
    pub fn next(self: *IndexedCursor) Error!?BucketRecord {
        if (self.cursor.failure) |err| return err;
        const reader = &self.cursor.reader;
        const record_offset = reader.consumed;
        reader.advance() catch |err| {
            self.cursor.failure = err;
            return err;
        };
        const record = reader.current orelse {
            self.install() catch |err| {
                self.cursor.failure = err;
                return err;
            };
            return null;
        };
        if (self.store.read_index != null and self.samples.items.len < self.indexOptions().max_samples and
            (self.samples.items.len == 0 or record_offset - self.sampled_offset >= self.indexOptions().min_span_bytes))
        {
            const key_copy = self.store.gpa.dupe(u8, record.key) catch return error.OutOfMemory;
            errdefer self.store.gpa.free(key_copy);
            self.samples.append(self.store.gpa, .{ .table = record.table, .offset = record_offset, .key = key_copy }) catch return error.OutOfMemory;
            self.sampled_offset = record_offset;
        }
        return record;
    }
    /// Drain the unread suffix, authenticate the bucket, install the index.
    pub fn finish(self: *IndexedCursor) Error!void {
        while (try self.next() != null) {}
    }
    fn indexOptions(self: *const IndexedCursor) ReadIndexOptions {
        return self.store.read_index.?.options;
    }
    fn install(self: *IndexedCursor) Error!void {
        // Framed (compressed) blobs carry no stable uncompressed offsets on
        // disk; the index is only sound for plain blobs.
        if (self.cursor.reader.decomp != null) {
            for (self.samples.items) |sample| self.store.gpa.free(sample.key);
            self.samples.deinit(self.store.gpa);
            self.installed = true;
            return;
        }
        if (self.store.read_index) |cache| {
            // Ownership transfers on success; a failed install frees them.
            const owned = try self.samples.toOwnedSlice(self.store.gpa);
            self.installed = true;
            try cache.install(self.hash, self.cursor.reader.size, self.total_records, owned);
        } else {
            self.installed = true;
            for (self.samples.items) |sample| self.store.gpa.free(sample.key);
            self.samples.deinit(self.store.gpa);
        }
    }
};

const magic = "BKLSTOR1";
const compress_magic = "BKLZRAW1";
const compress_header_len = compress_magic.len + 8;

/// Decompress a framed payload (magic + u64be length + raw deflate).
/// Returns the uncompressed bytes; the caller frees.
fn inflateBytes(gpa: std.mem.Allocator, payload: []const u8, expected_len: usize) Error![]u8 {
    if (payload.len < compress_header_len - compress_magic.len) return error.CorruptBlob;
    const out = gpa.alloc(u8, expected_len) catch return error.OutOfMemory;
    errdefer gpa.free(out);
    var source: std.Io.Reader = .fixed(payload);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&source, .raw, &window);
    decomp.reader.readSliceAll(out) catch return error.CorruptBlob;
    if (decomp.reader.peekByte()) |_| return error.CorruptBlob else |_| {}
    return out;
}

fn compressBytes(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const framed = gpa.alloc(u8, compress_header_len + bytes.len + bytes.len / 64 + 128) catch return error.OutOfMemory;
    errdefer gpa.free(framed);
    @memcpy(framed[0..compress_magic.len], compress_magic);
    std.mem.writeInt(u64, framed[compress_magic.len..][0..8], @intCast(bytes.len), .big);
    var sink: std.Io.Writer = .fixed(framed[compress_header_len..]);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    // Fastest preset: write-path economics favors CPU over ratio.
    const fast = std.compress.flate.Compress.Options{ .good = 4, .nice = 8, .lazy = 0, .chain = 4 };
    var compressor = std.compress.flate.Compress.init(&sink, &window, .raw, fast) catch return error.IoFailed;
    compressor.writer.writeAll(bytes) catch return error.IoFailed;
    compressor.finish() catch return error.IoFailed;
    const written = compress_header_len + sink.end;
    if (gpa.realloc(framed, written)) |shrunk| return shrunk else |_| return framed[0..written];
}
const header_len = magic.len + 8 + 32;
const manifest_name = "manifest";
const PublishFault = enum {
    none,
    after_header_write,
    after_payload_write,
    after_file_sync,
    before_replace,
    after_replace,
    after_directory_sync,
    after_final_file_sync,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    blobs: std.Io.Dir,
    lock: std.Io.File,
    read_index: ?*ReadIndexCache = null,
    compress_writes: bool = false,

    /// Owns open directory and exclusive advisory lock handles. The allocator
    /// and Io must remain valid until deinit and support every calling thread.
    /// With thread-safe allocator/Io, immutable blob reads, puts, and merges may
    /// run concurrently on one Store. Do not mutate Store fields during use.
    /// Each cursor has one owner. Serialize publication/recovery decisions;
    /// collect and deinit require no active calls, cursors, or background jobs.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Error!Store {
        if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos)
            return error.UnsupportedPlatform;
        const root = try openPath(io, path);
        errdefer root.close(io);
        const lock = root.createFile(io, "LOCK", .{
            .exclusive = true,
            .read = true,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => root.openFile(io, "LOCK", .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |e| return mapIo(e),
            else => return mapIo(err),
        };
        errdefer lock.close(io);
        if ((lock.stat(io) catch return error.IoFailed).kind != .file)
            return error.NotRegularFile;
        try fullSync(io, lock);
        const blobs = root.createDirPathOpen(io, "blobs", .{
            .open_options = .{ .follow_symlinks = false, .iterate = true },
        }) catch return error.IoFailed;
        errdefer blobs.close(io);
        try syncDir(io, blobs);
        try syncDir(io, root);
        try fullSync(io, lock);
        return .{ .gpa = gpa, .io = io, .root = root, .blobs = blobs, .lock = lock };
    }

    pub fn deinit(self: *Store) void {
        if (self.read_index) |cache| cache.destroy();
        self.read_index = null;
        self.blobs.close(self.io);
        self.lock.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    /// Opt in to a local read index for `lookupBucketIndexed`. Call once after
    /// open, before concurrent use. Index memory comes from the Store
    /// allocator; entries hold verified blob shapes only, never record data.
    pub fn enableReadIndex(self: *Store, options: ReadIndexOptions) Error!void {
        if (self.read_index != null) return error.StoreBusy;
        self.read_index = try ReadIndexCache.create(self.gpa, self.io, options);
    }

    /// Opt future writes into transparent deflate framing: blob names keep
    /// hashing the canonical uncompressed bytes (a local policy, never a
    /// consensus input); reads autodetect the framing, so mixed and legacy
    /// stores remain readable. The read index is not installed for
    /// compressed blobs (span offsets lose meaning under decompression).
    pub fn enableCompression(self: *Store) void {
        self.compress_writes = true;
    }

    fn compressStaged(self: *Store, bytes: []const u8) Error![]u8 {
        return compressBytes(self.gpa, bytes);
    }

    /// SHA256(bytes) names immutable contents. Existing contents must verify;
    /// an existing corrupt file is an error, never silently overwritten.
    /// A successful return means the file and its directory entry are synced.
    pub fn putBlob(self: *Store, bytes: []const u8) Error!Hash {
        const hash = digest(bytes);
        const name = std.fmt.bytesToHex(hash, .lower);
        const stored: []const u8 = if (self.compress_writes) try self.compressStaged(bytes) else bytes;
        defer if (stored.len != bytes.len or stored.ptr != bytes.ptr) self.gpa.free(stored);
        // Shared buckets are common across checkpoints. Verify the immutable
        // file with bounded scratch before allocating/writing a temporary copy.
        const existing: ?std.Io.File = if (self.compress_writes)
            null // framed reuse is verified below by content comparison
        else
            openVerified(self.blobs, self.io, &name, hash, bytes.len) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
        if (self.compress_writes and try self.blobExists(&name)) {
            const plain = try self.readBlobPlain(self.gpa, &name, bytes.len);
            defer self.gpa.free(plain);
            if (!std.mem.eql(u8, plain, bytes)) return error.CorruptBlob;
            const kept = try openRegular(self.blobs, self.io, &name);
            defer kept.close(self.io);
            try fullSync(self.io, kept);
        } else if (existing) |file| {
            defer file.close(self.io);
            try fullSync(self.io, file);
        } else {
            var atomic = self.blobs.createFileAtomic(self.io, &name, .{}) catch return error.IoFailed;
            defer atomic.deinit(self.io);
            try writeBytes(self.io, atomic.file, stored);
            try fullSync(self.io, atomic.file);
            atomic.link(self.io) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    // A file can appear after the initial absence check. Keep
                    // no-replace publication and verify the winning file too.
                    const file = try openVerified(self.blobs, self.io, &name, hash, bytes.len);
                    defer file.close(self.io);
                    try fullSync(self.io, file);
                },
                else => return error.IoFailed,
            };
        }
        try syncDir(self.io, self.blobs);
        // A final full sync after the directory barrier flushes the renamed
        // entry's metadata through the drive cache on macOS too.
        const installed = try openRegular(self.blobs, self.io, &name);
        defer installed.close(self.io);
        try fullSync(self.io, installed);
        return hash;
    }

    /// Install canonical bucket bytes under their v2 block-hash name
    /// (docs/format-v2.md). Framing, order, counts, and length are validated
    /// while hashing; an existing file is re-verified under v2. Durability
    /// barriers match putBlob. The v2 target travels in limits.format.
    pub fn putBucketV2(self: *Store, bytes: []const u8, limits: MergeLimits) Error!Hash {
        const target = switch (limits.format) {
            .v2 => |v2| v2.target_block_bytes,
            .v1 => return error.InvalidBucket,
        };
        const hash = try v2BucketHash(bytes, target, limits);
        const name = std.fmt.bytesToHex(hash, .lower);
        if (try self.blobExists(&name)) {
            const plain = try self.readBlobPlain(self.gpa, &name, bytes.len);
            defer self.gpa.free(plain);
            if (!std.mem.eql(u8, plain, bytes)) return error.CorruptBlob;
            const file = try openRegular(self.blobs, self.io, &name);
            defer file.close(self.io);
            try fullSync(self.io, file);
            return hash;
        }
        const stored: []const u8 = if (self.compress_writes) try compressBytes(self.gpa, bytes) else bytes;
        defer if (stored.ptr != bytes.ptr) self.gpa.free(stored);
        var atomic = self.blobs.createFileAtomic(self.io, &name, .{}) catch return error.IoFailed;
        defer atomic.deinit(self.io);
        try writeBytes(self.io, atomic.file, stored);
        try fullSync(self.io, atomic.file);
        atomic.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const plain = try self.readBlobPlain(self.gpa, &name, bytes.len);
                defer self.gpa.free(plain);
                if (!std.mem.eql(u8, plain, bytes)) return error.CorruptBlob;
            },
            else => return error.IoFailed,
        };
        try syncDir(self.io, self.blobs);
        const installed = try openRegular(self.blobs, self.io, &name);
        defer installed.close(self.io);
        try fullSync(self.io, installed);
        return hash;
    }

    fn blobExists(self: *Store, name: []const u8) Error!bool {
        _ = self.blobs.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.IoFailed,
        };
        return true;
    }

    /// The caller owns the returned allocation. max_bytes is an inclusive
    /// bound, checked before allocation and again while reading.
    /// Read a blob's plain (uncompressed) bytes, inflating framed payloads.
    fn readBlobPlain(self: *Store, gpa: std.mem.Allocator, name: []const u8, max_bytes: usize) Error![]u8 {
        const raw = try readBounded(self.blobs, self.io, name, gpa, max_bytes + compress_header_len + max_bytes / 64 + 128);
        defer gpa.free(raw);
        if (raw.len >= compress_magic.len and std.mem.eql(u8, raw[0..compress_magic.len], compress_magic)) {
            if (raw.len < compress_header_len) return error.CorruptBlob;
            const expected = std.mem.readInt(u64, raw[compress_magic.len..][0..8], .big);
            if (expected > max_bytes) return error.TooLarge;
            return inflateBytes(gpa, raw[compress_header_len..], @intCast(expected));
        }
        if (raw.len > max_bytes) return error.TooLarge;
        return gpa.dupe(u8, raw) catch return error.OutOfMemory;
    }

    pub fn getBlob(self: *Store, gpa: std.mem.Allocator, hash: Hash, max_bytes: usize) Error![]u8 {
        const name = std.fmt.bytesToHex(hash, .lower);
        const bytes = try self.readBlobPlain(gpa, &name, max_bytes);
        errdefer gpa.free(bytes);
        if (!std.mem.eql(u8, &hash, &digest(bytes))) return error.CorruptBlob;
        return bytes;
    }

    /// The cursor owns a file handle and 2*max_key+max_value+8192 scratch bytes
    /// from the Store allocator. Its allocator and Io must outlive the cursor.
    /// Record slices are provisional until successful verified EOF.
    pub fn scanBucket(self: *Store, hash: Hash, limits: MergeLimits) Error!BucketCursor {
        var reader = try BucketReader.init(self, hash, limits);
        try reader.wireCompressed(self.gpa, limits);
        return .{ .reader = reader, .record_count = reader.remaining };
    }

    /// Verified scan that seeds the read index at EOF (see IndexedCursor).
    pub fn scanBucketIndexed(self: *Store, hash: Hash, limits: MergeLimits) Error!IndexedCursor {
        var cursor = try BucketReader.init(self, hash, limits);
        // The cursor struct below is the reader's final address; wire any
        // decompressor against it before moving in.
        var indexed: IndexedCursor = undefined;
        try cursor.wireCompressed(self.gpa, limits);
        indexed = .{ .cursor = .{ .reader = cursor, .record_count = cursor.remaining }, .store = self, .hash = hash, .total_records = cursor.remaining };
        return indexed;
    }

    /// Stream and verify the WHOLE bucket, even after finding the key. Runtime
    /// is O(bucket bytes); memory is cursor scratch plus at most one value copy.
    /// All failures free a captured value and return no unverified result.
    pub fn lookupBucket(self: *Store, gpa: std.mem.Allocator, hash: Hash, table: u32, key: []const u8, limits: MergeLimits) Error!BucketLookup {
        if (key.len > limits.max_key_bytes) return error.TooLarge;
        var cursor = try self.scanBucket(hash, limits);
        defer cursor.deinit();
        var result: BucketLookup = .absent;
        errdefer result.deinit(gpa);
        while (try cursor.next()) |record| {
            if (record.table != table or !std.mem.eql(u8, record.key, key)) continue;
            result.deinit(gpa);
            // Assign the union only after the allocation succeeds: this
            // compiler can set the tag before evaluating a failing payload
            // expression, which once left a .value tag over an undefined
            // pointer on x86_64 (freed by the errdefer below).
            result = if (record.value) |value| blk: {
                const copy = try gpa.dupe(u8, value);
                break :blk BucketLookup{ .value = copy };
            } else .tombstone;
        }
        return result;
    }

    /// Verified lookup through the optional read index. With an index and an
    /// unchanged file size, only the sampled span containing the key is read
    /// (no whole-blob hash: the blob was fully verified when its index was
    /// built, and immutable content-addressed names make that entry sound).
    /// A size change, missing index, or index-build allocation failure falls
    /// back to `lookupBucket`'s fully verified whole-bucket stream. Framing
    /// anomalies inside a span still fail closed.
    pub fn lookupBucketIndexed(self: *Store, gpa: std.mem.Allocator, hash: Hash, table: u32, key: []const u8, limits: MergeLimits) Error!BucketLookup {
        if (key.len > limits.max_key_bytes) return error.TooLarge;
        if (self.read_index) |cache| {
            if (cache.acquire(hash)) |index| {
                defer cache.release(index);
                const name = std.fmt.bytesToHex(hash, .lower);
                const file = try openRegular(self.blobs, self.io, &name);
                defer file.close(self.io);
                const size = (file.stat(self.io) catch return error.IoFailed).size;
                if (size == index.size) {
                    // Capture the index before release; the entry may be
                    // evicted and freed as soon as the lock is dropped, but
                    // `index` stays alive through our reference.
                    return self.lookupSpan(file, index, table, key, limits, gpa);
                }
                // The file no longer matches its verified shape. Distrust the
                // index entry and fall through to a full re-verification.
            }
        }
        return self.lookupIndexedCold(gpa, hash, table, key, limits);
    }

    /// Whole-bucket verified scan that opportunistically records span starts.
    /// Identical semantics to `lookupBucket`; index-build allocation failures
    /// only disable sampling, never the read or its verification.
    fn lookupIndexedCold(self: *Store, gpa: std.mem.Allocator, hash: Hash, table: u32, key: []const u8, limits: MergeLimits) Error!BucketLookup {
        var reader = try BucketReader.init(self, hash, limits);
        defer reader.deinit();
        try reader.wireCompressed(self.gpa, limits);
        const total_records = reader.remaining;
        const cache = self.read_index;
        const options = if (cache) |c| c.options else undefined;
        var samples: std.ArrayList(Sample) = .empty;
        errdefer {
            for (samples.items) |sample| self.gpa.free(sample.key);
            samples.deinit(self.gpa);
        }
        var sampled_offset: u64 = 0;
        var result: BucketLookup = .absent;
        errdefer result.deinit(gpa);
        while (true) {
            const record_offset = reader.consumed;
            try reader.advance();
            const record = reader.current orelse break;
            if (cache != null and samples.items.len < options.max_samples and
                (samples.items.len == 0 or record_offset - sampled_offset >= options.min_span_bytes))
            {
                const key_copy = self.gpa.dupe(u8, record.key) catch return error.OutOfMemory;
                errdefer self.gpa.free(key_copy);
                try samples.append(self.gpa, .{ .table = record.table, .offset = record_offset, .key = key_copy });
                sampled_offset = record_offset;
            }
            if (record.table == table and std.mem.eql(u8, record.key, key)) {
                result.deinit(gpa);
                result = if (record.value) |value| blk: {
                    const copy = try gpa.dupe(u8, value);
                    break :blk BucketLookup{ .value = copy };
                } else .tombstone;
            }
        }
        if (cache) |c| {
            const owned = try samples.toOwnedSlice(self.gpa);
            try c.install(hash, reader.size, total_records, owned);
        } else {
            samples.deinit(self.gpa);
        }
        return result;
    }

    /// Parse and search one indexed span with positional reads only. Every
    /// framing anomaly fails closed; order gives an early confirmed absence.
    fn lookupSpan(self: *Store, file: std.Io.File, index: *BucketIndex, table: u32, key: []const u8, limits: MergeLimits, gpa: std.mem.Allocator) Error!BucketLookup {
        const sampleBefore = struct {
            fn call(sample: Sample, want_table: u32, want_key: []const u8) bool {
                if (sample.table != want_table) return sample.table < want_table;
                return std.mem.order(u8, sample.key, want_key) != .gt;
            }
        }.call;
        // Last sample that does not sort after the target. Its span is the
        // only one that can contain the target: every record in span j sorts
        // in [samples[j], samples[j+1]), and samples[0] is the first record.
        var best: ?usize = null;
        var lo: usize = 0;
        var hi: usize = index.samples.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (sampleBefore(index.samples[mid], table, key)) {
                best = mid;
                lo = mid + 1;
            } else hi = mid;
        }
        const span = best orelse return .absent;
        const span_start = index.samples[span].offset;
        const span_end = if (span + 1 < index.samples.len) index.samples[span + 1].offset else index.size;
        if (span_start >= span_end or span_end > index.size) return error.InvalidBucket;
        const key_buffer = self.gpa.alloc(u8, limits.max_key_bytes) catch return error.OutOfMemory;
        defer self.gpa.free(key_buffer);
        const value_buffer = self.gpa.alloc(u8, limits.max_value_bytes) catch return error.OutOfMemory;
        defer self.gpa.free(value_buffer);
        var offset = span_start;
        while (offset < span_end) {
            var header: [8]u8 = undefined;
            try self.readSpan(file, &header, offset);
            offset += header.len;
            const record_table = std.mem.readInt(u32, header[0..4], .big);
            const key_len = std.mem.readInt(u32, header[4..8], .big);
            if (key_len > key_buffer.len) return error.TooLarge;
            const record_key = key_buffer[0..key_len];
            try self.readSpan(file, record_key, offset);
            offset += key_len;
            var tag: [1]u8 = undefined;
            try self.readSpan(file, &tag, offset);
            offset += tag.len;
            const value: []const u8 = switch (tag[0]) {
                0 => &.{},
                1 => value: {
                    var length: [4]u8 = undefined;
                    try self.readSpan(file, &length, offset);
                    offset += length.len;
                    const value_len = std.mem.readInt(u32, &length, .big);
                    if (value_len > value_buffer.len) return error.TooLarge;
                    const bytes = value_buffer[0..value_len];
                    try self.readSpan(file, bytes, offset);
                    offset += value_len;
                    break :value bytes;
                },
                else => return error.InvalidBucket,
            };
            const order: std.math.Order = if (record_table != table)
                (if (record_table < table) .lt else .gt)
            else
                std.mem.order(u8, record_key, key);
            switch (order) {
                .eq => {
                    if (tag[0] == 0) return .tombstone;
                    const copy = try gpa.dupe(u8, value);
                    return BucketLookup{ .value = copy };
                },
                .gt => return .absent,
                .lt => {},
            }
        }
        return .absent;
    }

    fn readSpan(self: *Store, file: std.Io.File, buffer: []u8, offset: u64) Error!void {
        if (buffer.len == 0) return;
        _ = file.readPositionalAll(self.io, buffer, offset) catch return error.IoFailed;
    }

    /// caller may drop tombstones only at a boundary with no older records.
    /// Two fully verified passes use bounded record workspace, independent of
    /// bucket size. The result is durable; no manifest is published here.
    pub fn mergeBuckets(self: *Store, older: Hash, newer: Hash, drop_tombstones: bool, limits: MergeLimits) Error!Hash {
        const first = try mergePass(self, older, newer, drop_tombstones, limits, null);
        var name: [64]u8 = @splat('0');
        // Atomic holds a borrowed destination slice. Fill it with the final
        // digest before link; no provisional destination is ever installed.
        var atomic = self.blobs.createFileAtomic(self.io, &name, .{}) catch return error.IoFailed;
        defer atomic.deinit(self.io);
        var buffer: [8192]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        var v2_hasher = switch (limits.format) {
            .v1 => undefined,
            .v2 => |v2| V2Hasher.init(v2.target_block_bytes),
        };
        var compressor_state: ?std.compress.flate.Compress = null;
        var compress_window: ?[]u8 = null;
        defer if (compress_window) |window| self.gpa.free(window);
        if (self.compress_writes) {
            // The framing header must flow through the same writer as the
            // compressed payload: a second writer restarts at offset zero
            // and would clobber it.
            var header: [compress_header_len]u8 = undefined;
            @memcpy(header[0..compress_magic.len], compress_magic);
            std.mem.writeInt(u64, header[compress_magic.len..][0..8], 0, .big); // length patched after hash known
            writer.interface.writeAll(&header) catch return error.IoFailed;
            const window = self.gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
            compress_window = window;
            const fast = std.compress.flate.Compress.Options{ .good = 4, .nice = 8, .lazy = 0, .chain = 4 };
            compressor_state = std.compress.flate.Compress.init(&writer.interface, window, .raw, fast) catch return error.IoFailed;
        }
        var output: MergeOutput = .{
            .writer = if (compressor_state) |*c| &c.writer else &writer.interface,
            .limit = limits.max_bucket_bytes,
            .v2 = if (limits.format == .v2) &v2_hasher else null,
        };
        try output.write(bucket_domain);
        var count_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &count_bytes, first.count, .big);
        try output.write(&count_bytes);
        const second = try mergePass(self, older, newer, drop_tombstones, limits, &output);
        if (second.count != first.count or second.size != first.size or output.size != first.size)
            return error.CorruptBlob;
        if (compressor_state) |*c| c.finish() catch return error.IoFailed;
        writer.interface.flush() catch return error.IoFailed;
        const hash = if (output.v2) |hasher| hasher.final() else output.hash.finalResult();
        if (compress_window != null) {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, first.size, .big);
            atomic.file.writePositionalAll(self.io, &length, compress_magic.len) catch return error.IoFailed;
        }
        name = std.fmt.bytesToHex(hash, .lower);
        try fullSync(self.io, atomic.file);
        atomic.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => try self.verifyInstalled(&name, hash, first.size, limits),
            else => return error.IoFailed,
        };
        try syncDir(self.io, self.blobs);
        const installed = try openRegular(self.blobs, self.io, &name);
        defer installed.close(self.io);
        try fullSync(self.io, installed);
        return hash;
    }

    /// Verify that merging two stored buckets yields exactly `expected`
    /// without writing anything: the same two bounded passes and record
    /// semantics as `mergeBuckets`, hashing the would-be output only.
    /// Reopen validation uses this when the pending output is already a
    /// durable blob; `error.MergeMismatch` rejects a forged pending hash.
    pub fn mergeBucketsVerify(self: *Store, older: Hash, newer: Hash, drop_tombstones: bool, limits: MergeLimits, expected: Hash) Error!void {
        const first = try mergePass(self, older, newer, drop_tombstones, limits, null);
        var v2_hasher = switch (limits.format) {
            .v1 => undefined,
            .v2 => |v2| V2Hasher.init(v2.target_block_bytes),
        };
        var sink: MergeOutput = .{
            .writer = null,
            .limit = limits.max_bucket_bytes,
            .v2 = if (limits.format == .v2) &v2_hasher else null,
        };
        // Hash the exact output byte stream, header included, exactly as
        // mergeBuckets writes it.
        try sink.write(bucket_domain);
        var count_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &count_bytes, first.count, .big);
        try sink.write(&count_bytes);
        const second = try mergePass(self, older, newer, drop_tombstones, limits, &sink);
        if (second.count != first.count or second.size != first.size or sink.size != first.size)
            return error.MergeMismatch;
        const actual = if (sink.v2) |hasher| hasher.final() else sink.hash.finalResult();
        if (!std.mem.eql(u8, &expected, &actual)) return error.MergeMismatch;
    }

    /// Verify an already-installed merge winner: streaming verification
    /// keeps the fixed-workspace bound for plain files; framed winners and
    /// size mismatches fall back to a full read, still failing closed.
    fn verifyInstalled(self: *Store, name: []const u8, hash: Hash, plain_size: u64, limits: MergeLimits) Error!void {
        if (verifyFile(self.blobs, self.io, name, hash, plain_size)) |_| {
            return;
        } else |verify_err| switch (verify_err) {
            error.CorruptBlob, error.CorruptManifest, error.TooLarge => {},
            else => return verify_err,
        }
        const plain = try self.readBlobPlain(self.gpa, name, @intCast(plain_size));
        defer self.gpa.free(plain);
        const actual = switch (limits.format) {
            .v1 => digest(plain),
            .v2 => |v2| try v2BucketHash(plain, v2.target_block_bytes, limits),
        };
        if (!std.mem.eql(u8, &actual, &hash)) return error.CorruptBlob;
    }

    /// Publish an opaque application manifest after putBlob has durably
    /// installed EVERY referenced blob. This layer cannot inspect references.
    /// After a post-rename error the new manifest may already be visible.
    /// An owner may publish alongside independent blob jobs, but must await
    /// every referenced output and serialize its own publication decisions.
    pub fn publish(self: *Store, manifest_bytes: []const u8) Error!void {
        return self.publishImpl(manifest_bytes, .none);
    }

    fn publishImpl(self: *Store, bytes: []const u8, fault: PublishFault) Error!void {
        try syncDir(self.io, self.blobs);
        var header: [header_len]u8 = undefined;
        @memcpy(header[0..magic.len], magic);
        std.mem.writeInt(u64, header[magic.len..][0..8], @intCast(bytes.len), .big);
        @memcpy(header[magic.len + 8 ..], &digest(bytes));
        var atomic = self.root.createFileAtomic(self.io, manifest_name, .{ .replace = true }) catch return error.IoFailed;
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        writer.interface.writeAll(&header) catch return error.IoFailed;
        if (fault == .after_header_write) return error.IoFailed;
        writer.interface.writeAll(bytes) catch return error.IoFailed;
        if (fault == .after_payload_write) return error.IoFailed;
        writer.interface.flush() catch return error.IoFailed;
        try fullSync(self.io, atomic.file);
        if (fault == .after_file_sync) return error.IoFailed;
        if (fault == .before_replace) return error.IoFailed;
        atomic.replace(self.io) catch return error.IoFailed;
        if (fault == .after_replace) return error.IoFailed;
        try syncDir(self.io, self.root);
        if (fault == .after_directory_sync) return error.IoFailed;
        const installed = try openRegular(self.root, self.io, manifest_name);
        defer installed.close(self.io);
        try fullSync(self.io, installed);
        if (fault == .after_final_file_sync) return error.IoFailed;
    }

    /// null means no checkpoint has been published. Malformed/truncated
    /// storage envelopes are errors, never treated as an absent checkpoint.
    pub fn readManifest(self: *Store, gpa: std.mem.Allocator, max_bytes: usize) Error!?[]u8 {
        const wrapped = readBounded(self.root, self.io, manifest_name, gpa, max_bytes +| header_len) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        defer gpa.free(wrapped);
        if (wrapped.len < header_len or !std.mem.eql(u8, wrapped[0..magic.len], magic))
            return error.CorruptManifest;
        const len = std.mem.readInt(u64, wrapped[magic.len..][0..8], .big);
        if (len > max_bytes) return error.TooLarge;
        if (len != wrapped.len - header_len) return error.CorruptManifest;
        const bytes = wrapped[header_len..];
        if (!std.mem.eql(u8, wrapped[magic.len + 8 .. header_len], &digest(bytes)))
            return error.CorruptManifest;
        return gpa.dupe(u8, bytes) catch return error.OutOfMemory;
    }

    /// Explicit reachability GC. Caller must include the current manifest,
    /// retained checkpoints, active readers, and pending publications' blobs.
    /// Only regular files with exactly 64 lowercase hex characters are removed.
    /// Unknown names, symlinks, directories, and atomic-write debris survive.
    /// Caller must quiesce all blob jobs/cursors before collecting.
    pub fn collect(self: *Store, reachable: []const Hash) Error!usize {
        var removed: usize = 0;
        var iter = self.blobs.iterate();
        while (iter.next(self.io) catch return error.IoFailed) |entry| {
            if (entry.kind != .file) continue;
            const hash = parseName(entry.name) orelse continue;
            var keep = false;
            for (reachable) |live| {
                if (std.mem.eql(u8, &hash, &live)) {
                    keep = true;
                    break;
                }
            }
            if (keep) continue;
            self.blobs.deleteFile(self.io, entry.name) catch return error.IoFailed;
            removed += 1;
        }
        if (removed != 0) {
            try syncDir(self.io, self.blobs);
            try fullSync(self.io, self.lock);
        }
        return removed;
    }
};

// This native module deliberately does not import the core's bucket source:
// both modules can coexist in one Zig graph. Literal fixtures below pin parity
// with bucket.zig's documented canonical format and independently known hash.
const bucket_domain = "bucketlist.bucket.v1\x00";
const empty_bucket = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x00";
const stream_buffer_len = 8192;

const StreamRecord = BucketRecord;

fn recordOrder(a: StreamRecord, b: StreamRecord) std.math.Order {
    if (a.table != b.table) return std.math.order(a.table, b.table);
    return std.mem.order(u8, a.key, b.key);
}

// v2 block hashing (docs/format-v2.md), intentionally duplicated from the
// core module so this store keeps no import edge; literal fixtures below pin
// parity with tools/v2-vectors.py and thereby the core implementation.
const v2_block_domain = "bucketlist.block.v2\x00";
const v2_node_domain = "bucketlist.blocknode.v2\x00";
const v2_empty_domain = "bucketlist.block.v2.empty\x00";
const v2_bucket_domain = "bucketlist.bucket.v2\x00";

const V2Tree = struct {
    const Node = struct { span: u64, hash: Hash };
    peaks: [64]Node = undefined,
    count: usize = 0,
    leaves: u64 = 0,

    fn append(self: *V2Tree, leaf: Hash) void {
        self.peaks[self.count] = .{ .span = 1, .hash = leaf };
        self.count += 1;
        self.leaves += 1;
        while (self.count >= 2) {
            const left = self.peaks[self.count - 2];
            const right = self.peaks[self.count - 1];
            if (left.span != right.span) break;
            self.peaks[self.count - 2] = .{ .span = left.span * 2, .hash = v2Combine(left.hash, right.hash) };
            self.count -= 1;
        }
    }
    fn root(self: *const V2Tree) Hash {
        var acc = self.peaks[0].hash;
        for (self.peaks[1..self.count]) |peak| acc = v2Combine(acc, peak.hash);
        return acc;
    }
};

fn v2Combine(left: Hash, right: Hash) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(v2_node_domain);
    h.update(&left);
    h.update(&right);
    return h.finalResult();
}

const V2Hasher = struct {
    target: u32,
    tree: V2Tree = .{},
    block: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
    block_index: u64 = 0,
    block_bytes: u64 = 0,
    record_count: u64 = 0,
    block_open: bool = false,

    fn init(target: u32) V2Hasher {
        return .{ .target = target };
    }
    fn record(self: *V2Hasher, table: u32, key: []const u8, value: ?[]const u8) void {
        if (!self.block_open) self.open();
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], table, .big);
        std.mem.writeInt(u32, header[4..8], @intCast(key.len), .big);
        self.block.update(&header);
        self.block.update(key);
        self.block.update(&[1]u8{if (value == null) 0 else 1});
        if (value) |bytes| {
            var length: [4]u8 = undefined;
            std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
            self.block.update(&length);
            self.block.update(bytes);
            self.block_bytes += 13 + key.len + bytes.len;
        } else self.block_bytes += 9 + key.len;
        self.record_count += 1;
        if (self.block_bytes >= self.target) self.close();
    }
    fn open(self: *V2Hasher) void {
        self.block = std.crypto.hash.sha2.Sha256.init(.{});
        self.block.update(v2_block_domain);
        var index: [8]u8 = undefined;
        std.mem.writeInt(u64, &index, self.block_index, .big);
        self.block.update(&index);
        self.block_bytes = 0;
        self.block_open = true;
    }
    fn close(self: *V2Hasher) void {
        var leaf: Hash = undefined;
        self.block.final(&leaf);
        self.tree.append(leaf);
        self.block_index += 1;
        self.block_open = false;
    }
    fn final(self: *V2Hasher) Hash {
        if (self.block_open) self.close();
        const block_count = self.tree.leaves;
        var root: Hash = undefined;
        if (block_count == 0) {
            std.crypto.hash.sha2.Sha256.hash(v2_empty_domain, &root, .{});
        } else root = self.tree.root();
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(v2_bucket_domain);
        var counts: [8]u8 = undefined;
        std.mem.writeInt(u64, &counts, self.record_count, .big);
        h.update(&counts);
        std.mem.writeInt(u64, &counts, block_count, .big);
        h.update(&counts);
        h.update(&root);
        return h.finalResult();
    }
};

/// Hash the canonical bucket bytes under v2 without trusting them: the
/// memory walk enforces framing, order, count, and exact length.
fn v2BucketHash(bytes: []const u8, target: u32, limits: MergeLimits) Error!Hash {
    if (bytes.len < empty_bucket.len or !std.mem.eql(u8, bytes[0..bucket_domain.len], bucket_domain)) return error.InvalidBucket;
    const count = std.mem.readInt(u64, bytes[bucket_domain.len..][0..8], .big);
    if (count > limits.max_records) return error.TooLarge;
    var hasher = V2Hasher.init(target);
    var position: usize = empty_bucket.len;
    var previous: ?StreamRecord = null;
    for (0..count) |_| {
        if (position + 9 > bytes.len) return error.InvalidBucket;
        const table = std.mem.readInt(u32, bytes[position..][0..4], .big);
        const key_len = std.mem.readInt(u32, bytes[position + 4 ..][0..4], .big);
        if (key_len > limits.max_key_bytes) return error.TooLarge;
        position += 8;
        if (position + key_len + 1 > bytes.len) return error.InvalidBucket;
        const key = bytes[position..][0..key_len];
        position += key_len;
        const tag = bytes[position];
        position += 1;
        const value: ?[]const u8 = switch (tag) {
            0 => null,
            1 => value: {
                if (position + 4 > bytes.len) return error.InvalidBucket;
                const value_len = std.mem.readInt(u32, bytes[position..][0..4], .big);
                if (value_len > limits.max_value_bytes) return error.TooLarge;
                position += 4;
                if (position + value_len > bytes.len) return error.InvalidBucket;
                const out = bytes[position..][0..value_len];
                position += value_len;
                break :value out;
            },
            else => return error.InvalidBucket,
        };
        const row: StreamRecord = .{ .table = table, .key = key, .value = value };
        if (previous) |p| if (recordOrder(p, row) != .lt) return error.InvalidBucket;
        previous = row;
        hasher.record(table, key, value);
    }
    if (position != bytes.len) return error.InvalidBucket;
    return hasher.final();
}

const BucketReader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    file: std.Io.File,
    reader: std.Io.File.Reader,
    scratch: []u8,
    key_buffer: []u8,
    previous_key: []u8,
    value_buffer: []u8,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    v2: ?V2Hasher = null,
    compressed: bool = false,
    decomp: ?std.compress.flate.Decompress = null,
    decomp_window: ?[]u8 = null,
    expected: Hash,
    size: u64,
    consumed: u64 = 0,
    remaining: u64 = 0,
    current: ?StreamRecord = null,
    finished: bool = false,

    fn init(store: *Store, expected: Hash, limits: MergeLimits) Error!BucketReader {
        const name = std.fmt.bytesToHex(expected, .lower);
        const file = try openRegular(store.blobs, store.io, &name);
        errdefer file.close(store.io);
        const size = (file.stat(store.io) catch return error.IoFailed).size;
        if (size > limits.max_bucket_bytes) return error.TooLarge;
        // A framed (compressed) blob may be smaller than the plain bucket
        // header; the sniff below distinguishes them.
        if (size < compress_header_len) return error.InvalidBucket;
        const key_len: usize = limits.max_key_bytes;
        const value_len: usize = limits.max_value_bytes;
        const keys_len = std.math.mul(usize, key_len, 2) catch return error.TooLarge;
        const records_len = std.math.add(usize, keys_len, value_len) catch return error.TooLarge;
        const scratch_len = std.math.add(usize, records_len, stream_buffer_len) catch return error.TooLarge;
        const scratch = store.gpa.alloc(u8, scratch_len) catch return error.OutOfMemory;
        errdefer store.gpa.free(scratch);
        var self: BucketReader = .{
            .io = store.io,
            .gpa = store.gpa,
            .file = file,
            .reader = file.reader(store.io, scratch[records_len..]),
            .scratch = scratch,
            .key_buffer = scratch[0..key_len],
            .previous_key = scratch[key_len..keys_len],
            .value_buffer = scratch[keys_len..records_len],
            .expected = expected,
            .size = size,
        };
        // Sniff the compression framing on the first 8 bytes before any
        // hashing: framed payloads decompress through a window; plain ones
        // hash those first bytes as the domain prefix.
        var prefix: [compress_magic.len]u8 = undefined;
        self.reader.interface.readSliceAll(&prefix) catch return error.IoFailed;
        var header: [empty_bucket.len]u8 = undefined;
        if (std.mem.eql(u8, &prefix, compress_magic)) {
            var length: [8]u8 = undefined;
            self.reader.interface.readSliceAll(&length) catch return error.IoFailed;
            const uncompressed = std.mem.readInt(u64, &length, .big);
            if (uncompressed > limits.max_bucket_bytes) return error.TooLarge;
            self.size = uncompressed;
            self.compressed = true;
            // The decompressor is wired up after this struct is moved into
            // place (see scanBucket): it must point at the final reader.
            return self;
        } else {
            @memcpy(header[0..prefix.len], &prefix);
            self.hash.update(&prefix);
            self.consumed += prefix.len;
            try self.read(header[prefix.len..]);
        }
        if (!std.mem.eql(u8, header[0..bucket_domain.len], bucket_domain)) return error.InvalidBucket;
        self.remaining = std.mem.readInt(u64, header[bucket_domain.len..][0..8], .big);
        if (self.remaining > limits.max_records) return error.TooLarge;
        if (self.remaining > (size - empty_bucket.len) / 9) return error.InvalidBucket;
        switch (limits.format) {
            .v1 => {},
            .v2 => |v2| self.v2 = V2Hasher.init(v2.target_block_bytes),
        }
        return self;
    }

    fn deinit(self: *BucketReader) void {
        self.file.close(self.io);
        if (self.decomp_window) |window| self.gpa.free(window);
        self.gpa.free(self.scratch);
        self.* = undefined;
    }

    /// Complete compressed setup once the reader lives at its final
    /// address: the decompressor must point at that instance's interface.
    fn wireCompressed(self: *BucketReader, gpa: std.mem.Allocator, limits: MergeLimits) Error!void {
        if (!self.compressed) return;
        const window = gpa.alloc(u8, std.compress.flate.max_window_len) catch return error.OutOfMemory;
        self.decomp = std.compress.flate.Decompress.init(&self.reader.interface, .raw, window);
        self.decomp_window = window;
        switch (limits.format) {
            .v1 => {},
            .v2 => |v2| self.v2 = V2Hasher.init(v2.target_block_bytes),
        }
        var header: [empty_bucket.len]u8 = undefined;
        try self.read(&header);
        if (!std.mem.eql(u8, header[0..bucket_domain.len], bucket_domain)) return error.InvalidBucket;
        self.remaining = std.mem.readInt(u64, header[bucket_domain.len..][0..8], .big);
        if (self.remaining > limits.max_records) return error.TooLarge;
    }

    fn readCompressedHeader(self: *BucketReader) Error!void {
        var header: [empty_bucket.len]u8 = undefined;
        try self.read(&header);
        if (!std.mem.eql(u8, header[0..bucket_domain.len], bucket_domain)) return error.InvalidBucket;
        self.remaining = std.mem.readInt(u64, header[bucket_domain.len..][0..8], .big);
    }

    fn read(self: *BucketReader, bytes: []u8) Error!void {
        if (bytes.len > self.size - self.consumed) return error.InvalidBucket;
        if (self.decomp != null) {
            self.decomp.?.reader.readSliceAll(bytes) catch |err| return switch (err) {
                error.EndOfStream => error.InvalidBucket,
                else => error.CorruptBlob,
            };
        } else {
            self.reader.interface.readSliceAll(bytes) catch |err| return switch (err) {
                error.EndOfStream => error.InvalidBucket,
                error.ReadFailed => error.IoFailed,
            };
        }
        self.hash.update(bytes);
        self.consumed += bytes.len;
    }

    fn integer(self: *BucketReader, comptime T: type) Error!T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.read(&bytes);
        return std.mem.readInt(T, &bytes, .big);
    }

    fn advance(self: *BucketReader) Error!void {
        if (self.remaining == 0) {
            self.current = null;
            if (self.finished) return;
            if (self.consumed != self.size) return error.InvalidBucket;
            const trailing = if (self.decomp != null)
                self.decomp.?.reader.peekByte()
            else
                self.reader.interface.peekByte();
            if (trailing) |_| {
                return error.InvalidBucket;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return error.IoFailed,
            }
            const actual = if (self.v2) |*v2| v2.final() else self.hash.finalResult();
            if (!std.mem.eql(u8, &self.expected, &actual)) return error.CorruptBlob;
            self.finished = true;
            return;
        }
        var previous: ?StreamRecord = null;
        if (self.current) |record| {
            std.mem.swap([]u8, &self.previous_key, &self.key_buffer);
            previous = .{ .table = record.table, .key = self.previous_key[0..record.key.len], .value = null };
        }
        const table = try self.integer(u32);
        const key_len = try self.integer(u32);
        if (key_len > self.key_buffer.len) return error.TooLarge;
        const key = self.key_buffer[0..key_len];
        try self.read(key);
        const tag = try self.integer(u8);
        const value: ?[]const u8 = switch (tag) {
            0 => null,
            1 => value: {
                const value_len = try self.integer(u32);
                if (value_len > self.value_buffer.len) return error.TooLarge;
                const bytes = self.value_buffer[0..value_len];
                try self.read(bytes);
                break :value bytes;
            },
            else => return error.InvalidBucket,
        };
        const record: StreamRecord = .{ .table = table, .key = key, .value = value };
        if (previous) |p| if (recordOrder(p, record) != .lt) return error.InvalidBucket;
        if (self.v2 != null) self.v2.?.record(table, key, value);
        self.current = record;
        self.remaining -= 1;
    }
};

const MergeOutput = struct {
    /// A null writer hashes and counts without producing bytes: two
    /// null-writer passes derive a merge's exact hash with no writes.
    /// v2 mode feeds each record to the block hasher for the name instead.
    writer: ?*std.Io.Writer,
    v2: ?*V2Hasher = null,
    hash: std.crypto.hash.sha2.Sha256 = .init(.{}),
    size: u64 = 0,
    limit: u64,

    fn write(self: *MergeOutput, bytes: []const u8) Error!void {
        if (bytes.len > self.limit - self.size) return error.TooLarge;
        if (self.writer) |writer| writer.writeAll(bytes) catch return error.IoFailed;
        self.hash.update(bytes);
        self.size += bytes.len;
    }

    fn record(self: *MergeOutput, row: StreamRecord) Error!void {
        if (self.v2) |hasher| hasher.record(row.table, row.key, row.value);
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], row.table, .big);
        std.mem.writeInt(u32, header[4..8], @intCast(row.key.len), .big);
        try self.write(&header);
        try self.write(row.key);
        if (row.value) |bytes| {
            try self.write(&.{1});
            std.mem.writeInt(u32, header[0..4], @intCast(bytes.len), .big);
            try self.write(header[0..4]);
            try self.write(bytes);
        } else try self.write(&.{0});
    }
};

const MergeSize = struct { count: u64 = 0, size: u64 = empty_bucket.len };

fn mergePass(store: *Store, older: Hash, newer: Hash, drop_tombstones: bool, limits: MergeLimits, output: ?*MergeOutput) Error!MergeSize {
    var old = try BucketReader.init(store, older, limits);
    defer old.deinit();
    try old.wireCompressed(store.gpa, limits);
    var new = try BucketReader.init(store, newer, limits);
    defer new.deinit();
    try new.wireCompressed(store.gpa, limits);
    try old.advance();
    try new.advance();
    var result: MergeSize = .{};
    while (old.current != null or new.current != null) {
        var take_old = false;
        var take_new = false;
        const selected: StreamRecord = if (old.current) |a| selected: {
            if (new.current) |b| {
                switch (recordOrder(a, b)) {
                    .lt => {
                        take_old = true;
                        break :selected a;
                    },
                    .eq => {
                        take_old = true;
                        take_new = true;
                        break :selected b;
                    },
                    .gt => {
                        take_new = true;
                        break :selected b;
                    },
                }
            }
            take_old = true;
            break :selected a;
        } else selected: {
            take_new = true;
            break :selected new.current.?;
        };
        if (!drop_tombstones or selected.value != null) {
            if (result.count == limits.max_records) return error.TooLarge;
            const size: u64 = 9 + @as(u64, selected.key.len) + if (selected.value) |v| 4 + @as(u64, v.len) else 0;
            if (size > limits.max_bucket_bytes - result.size) return error.TooLarge;
            result.size += size;
            result.count += 1;
            if (output) |dest| try dest.record(selected);
        }
        if (take_old) try old.advance();
        if (take_new) try new.advance();
    }
    return result;
}

/// Caller owns the returned verified handle. Hashing uses fixed stack scratch;
/// neither putBlob's reuse path nor collision verification allocates blob size.
fn openVerified(dir: std.Io.Dir, io: std.Io, name: []const u8, expected: Hash, expected_size: u64) Error!std.Io.File {
    const file = try openRegular(dir, io, name);
    errdefer file.close(io);
    if ((file.stat(io) catch return error.IoFailed).size != expected_size) return error.CorruptBlob;
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &.{});
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var remaining = expected_size;
    while (remaining != 0) {
        const n: usize = @intCast(@min(remaining, buffer.len));
        reader.interface.readSliceAll(buffer[0..n]) catch |err| return switch (err) {
            error.EndOfStream => error.CorruptBlob,
            error.ReadFailed => error.IoFailed,
        };
        hash.update(buffer[0..n]);
        remaining -= n;
    }
    var tail: [1]u8 = undefined;
    if (reader.interface.readSliceAll(&tail)) |_| return error.CorruptBlob else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return error.IoFailed,
    }
    if (!std.mem.eql(u8, &expected, &hash.finalResult())) return error.CorruptBlob;
    return file;
}

fn verifyFile(dir: std.Io.Dir, io: std.Io, name: []const u8, expected: Hash, expected_size: u64) Error!void {
    const file = try openVerified(dir, io, name, expected, expected_size);
    file.close(io);
}

fn digest(bytes: []const u8) Hash {
    var hash: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return hash;
}

fn parseName(name: []const u8) ?Hash {
    if (name.len != 64) return null;
    for (name) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return null;
    var hash: Hash = undefined;
    _ = std.fmt.hexToBytes(&hash, name) catch return null;
    return hash;
}

fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.WouldBlock => error.StoreBusy,
        else => error.IoFailed,
    };
}

fn openRegular(dir: std.Io.Dir, io: std.Io, name: []const u8) Error!std.Io.File {
    // Reject FIFOs/devices before read-only open, which can otherwise block.
    // The handle check below remains necessary. Callers must exclude hostile
    // concurrent directory-entry replacement; the precheck is not atomic.
    const before = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| return mapIo(err);
    if (before.kind == .sym_link) return error.IoFailed;
    if (before.kind != .file) return error.NotRegularFile;
    const file = dir.openFile(io, name, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| return mapIo(err);
    errdefer file.close(io);
    if ((file.stat(io) catch return error.IoFailed).kind != .file) return error.NotRegularFile;
    return file;
}

fn readBounded(dir: std.Io.Dir, io: std.Io, name: []const u8, gpa: std.mem.Allocator, max_bytes: usize) Error![]u8 {
    const file = try openRegular(dir, io, name);
    defer file.close(io);
    if ((file.stat(io) catch return error.IoFailed).size > max_bytes) return error.TooLarge;
    var reader = file.reader(io, &.{});
    // Reader limits are exclusive: reaching the limit before seeing EOF is
    // StreamTooLong. Allow one lookahead byte and enforce our inclusive API.
    const bytes = reader.interface.allocRemaining(gpa, .limited(max_bytes +| 1)) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.TooLarge,
        error.ReadFailed => error.IoFailed,
    };
    errdefer gpa.free(bytes);
    if (bytes.len > max_bytes) return error.TooLarge;
    return bytes;
}

fn writeBytes(io: std.Io, file: std.Io.File, bytes: []const u8) Error!void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.writeAll(bytes) catch return error.IoFailed;
    writer.interface.flush() catch return error.IoFailed;
}

fn fullSync(io: std.Io, file: std.Io.File) Error!void {
    file.sync(io) catch return error.IoFailed;
    if (comptime builtin.os.tag == .macos) {
        if (std.c.fcntl(file.handle, std.posix.F.FULLFSYNC) < 0) return error.IoFailed;
    }
}

fn syncDir(io: std.Io, dir: std.Io.Dir) Error!void {
    // Linux uses O_PATH for non-iterable directory handles; fsync on those
    // descriptors fails with EBADF. Request an iterable/readable handle even
    // when the caller only opened its directory for relative path access.
    const readable = dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false }) catch return error.IoFailed;
    defer readable.close(io);
    const file: std.Io.File = .{ .handle = readable.handle, .flags = .{ .nonblocking = false } };
    file.sync(io) catch return error.IoFailed;
}

/// Resolve each component separately so symlinked ancestors cannot redirect
/// a store. The caller still controls and trusts its cwd and ancestor dirs.
fn openPath(io: std.Io, path: []const u8) Error!std.Io.Dir {
    if (path.len == 0) return error.InvalidPath;
    var components = std.mem.splitScalar(u8, path, '/');
    var checked = components;
    while (checked.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
    var dir = std.Io.Dir.cwd().openDir(io, if (std.fs.path.isAbsolute(path)) "/" else ".", .{
        .follow_symlinks = false,
    }) catch return error.IoFailed;
    errdefer dir.close(io);
    while (components.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        const next = dir.createDirPathOpen(io, part, .{
            .open_options = .{ .follow_symlinks = false },
        }) catch return error.IoFailed;
        syncDir(io, dir) catch |err| {
            next.close(io);
            return err;
        };
        dir.close(io);
        dir = next;
    }
    return dir;
}

const testing = std.testing;

fn testStore(tmp: *testing.TmpDir) !Store {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &path);
    return Store.open(testing.allocator, testing.io, path[0..len]);
}

test "immutable blobs verify hashes, exact limits, corruption, and truncation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const empty_hash = try store.putBlob("");
    const empty = try store.getBlob(testing.allocator, empty_hash, 0);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    const hash = try store.putBlob("bucket data");
    try testing.expectEqual(hash, try store.putBlob("bucket data"));
    const bytes = try store.getBlob(testing.allocator, hash, 11);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("bucket data", bytes);
    try testing.expectError(error.TooLarge, store.getBlob(testing.allocator, hash, 10));
    try testing.expectError(error.NotFound, store.getBlob(testing.allocator, digest("absent"), 100));
    const name = std.fmt.bytesToHex(hash, .lower);
    const file = try store.blobs.createFile(testing.io, &name, .{});
    defer file.close(testing.io);
    try writeBytes(testing.io, file, "bucket datX");
    try testing.expectError(error.CorruptBlob, store.getBlob(testing.allocator, hash, 100));
    try testing.expectError(error.CorruptBlob, store.putBlob("bucket data"));
    try file.setLength(testing.io, 2);
    try testing.expectError(error.CorruptBlob, store.getBlob(testing.allocator, hash, 100));
}

test "large existing blob reuse creates no temporary copy or allocation and retains durability barriers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const bytes = try testing.allocator.alloc(u8, 1024 * 1024 + 17);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    const hash = try store.putBlob(bytes);
    const name = std.fmt.bytesToHex(hash, .lower);

    const Guard = struct {
        var creates: usize = 0;
        var syncs: usize = 0;
        var fail_sync: ?usize = null;

        fn create(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.CreateFileAtomicOptions) std.Io.Dir.CreateFileAtomicError!std.Io.File.Atomic {
            creates += 1;
            return error.AccessDenied;
        }
        fn sync(ctx: ?*anyopaque, file: std.Io.File) std.Io.File.SyncError!void {
            const index = syncs;
            syncs += 1;
            if (fail_sync == index) return error.InputOutput;
            return testing.io.vtable.fileSync(ctx, file);
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    store.gpa = failing.allocator();
    var vtable = testing.io.vtable.*;
    vtable.dirCreateFileAtomic = Guard.create;
    vtable.fileSync = Guard.sync;
    store.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    defer store.io = testing.io;
    // The original implementation attempted the denied temp creation before
    // discovering the existing file, then allocated the entire file to verify.
    try testing.expectEqual(hash, try store.putBlob(bytes));
    try testing.expectEqual(@as(usize, 0), Guard.creates);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 3), Guard.syncs);
    for (0..3) |failure| {
        Guard.syncs = 0;
        Guard.fail_sync = failure;
        try testing.expectError(error.IoFailed, store.putBlob(bytes));
        try testing.expectEqual(failure + 1, Guard.syncs);
    }
    Guard.fail_sync = null;
    Guard.syncs = 0;
    try testing.expectEqual(hash, try store.putBlob(bytes));
    try testing.expectEqual(@as(usize, 3), Guard.syncs);
    try testing.expectEqual(@as(usize, 0), Guard.creates);

    const file = try store.blobs.createFile(testing.io, &name, .{ .truncate = false });
    defer file.close(testing.io);
    const wrong: [1]u8 = .{bytes[bytes.len - 1] ^ 0xff};
    try file.writePositionalAll(testing.io, &wrong, bytes.len - 1);
    try testing.expectError(error.CorruptBlob, store.putBlob(bytes));
    try file.setLength(testing.io, bytes.len - 1);
    try testing.expectError(error.CorruptBlob, store.putBlob(bytes));
    try file.setLength(testing.io, bytes.len + 1);
    try testing.expectError(error.CorruptBlob, store.putBlob(bytes));
    try testing.expectEqual(@as(usize, 0), Guard.creates);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expect(!failing.has_induced_failure);
}

test "putBlob verifies a race winner after initial absence with bounded memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const bytes = try manyRecords(testing.allocator, 10000, 0);
    defer testing.allocator.free(bytes);
    const hash = try store.putBlob(bytes);
    const name = std.fmt.bytesToHex(hash, .lower);
    const Guard = struct {
        var hidden = false;
        fn statFile(ctx: ?*anyopaque, dir: std.Io.Dir, path: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            if (!hidden) {
                hidden = true;
                return error.FileNotFound;
            }
            return testing.io.vtable.dirStatFile(ctx, dir, path, options);
        }
    };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    store.gpa = failing.allocator();
    var vtable = testing.io.vtable.*;
    vtable.dirStatFile = Guard.statFile;
    store.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    defer store.io = testing.io;
    // Hide the first observation: by link time an immutable file is present,
    // exercising PathAlreadyExists without a nondeterministic racing thread.
    try testing.expectEqual(hash, try store.putBlob(bytes));
    try testing.expect(Guard.hidden);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    const file = try store.blobs.createFile(testing.io, &name, .{ .truncate = false });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "X", 0);
    Guard.hidden = false;
    try testing.expectError(error.CorruptBlob, store.putBlob(bytes));
    try testing.expect(Guard.hidden);
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectError(error.CorruptBlob, store.getBlob(testing.allocator, hash, bytes.len));
    try testing.expect(!failing.has_induced_failure);
}

test "atomic manifest failure before replace preserves old frontier and reopen reads it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    try testing.expectEqual(@as(?[]u8, null), try store.readManifest(testing.allocator, 100));
    _ = try store.putBlob("first bucket");
    try store.publish("checkpoint one");
    _ = try store.putBlob("second bucket");
    try testing.expectError(error.IoFailed, store.publishImpl("checkpoint two", .before_replace));
    store.deinit();
    store = try testStore(&tmp);
    defer store.deinit();
    const old = (try store.readManifest(testing.allocator, 14)).?;
    defer testing.allocator.free(old);
    try testing.expectEqualStrings("checkpoint one", old);
    try testing.expectError(error.TooLarge, store.readManifest(testing.allocator, 13));
    try store.publish("checkpoint two");
    const next = (try store.readManifest(testing.allocator, 14)).?;
    defer testing.allocator.free(next);
    try testing.expectEqualStrings("checkpoint two", next);
}

test "manifest publication fault matrix recovers the frontier at every boundary" {
    const points = [_]PublishFault{
        .after_header_write,
        .after_payload_write,
        .after_file_sync,
        .before_replace,
        .after_replace,
        .after_directory_sync,
        .after_final_file_sync,
    };
    const old_bytes = "old referenced bucket";
    const new_bytes = "new referenced bucket";
    const old_hash = digest(old_bytes);
    const new_hash = digest(new_bytes);
    for (points) |point| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        {
            var store = try testStore(&tmp);
            defer store.deinit();
            try testing.expectEqual(old_hash, try store.putBlob(old_bytes));
            try store.publish(&old_hash);
            try testing.expectEqual(new_hash, try store.putBlob(new_bytes));
            try testing.expectError(error.IoFailed, store.publishImpl(&new_hash, point));
        }
        var restored = try testStore(&tmp);
        defer restored.deinit();
        const frontier = (try restored.readManifest(testing.allocator, 32)).?;
        defer testing.allocator.free(frontier);
        const replaced = switch (point) {
            .after_replace, .after_directory_sync, .after_final_file_sync => true,
            else => false,
        };
        try testing.expectEqualSlices(u8, if (replaced) &new_hash else &old_hash, frontier);
        const referenced_hash = frontier[0..32].*;
        const referenced = try restored.getBlob(testing.allocator, referenced_hash, 100);
        defer testing.allocator.free(referenced);
        try testing.expectEqualStrings(if (replaced) new_bytes else old_bytes, referenced);
        // Both complete blobs survive every boundary, including the new blob
        // that is still unreferenced when publication failed before replace.
        const old = try restored.getBlob(testing.allocator, old_hash, 100);
        defer testing.allocator.free(old);
        const new = try restored.getBlob(testing.allocator, new_hash, 100);
        defer testing.allocator.free(new);
        try testing.expectEqualStrings(old_bytes, old);
        try testing.expectEqualStrings(new_bytes, new);
    }
}

test "manifest corruption and truncation fail closed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    try store.publish("frontier");
    const file = try store.root.createFile(testing.io, manifest_name, .{ .truncate = false });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "X", header_len);
    try testing.expectError(error.CorruptManifest, store.readManifest(testing.allocator, 100));
    try file.writePositionalAll(testing.io, "f", header_len);
    const restored = (try store.readManifest(testing.allocator, 100)).?;
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("frontier", restored);
    var wrong_len: [8]u8 = undefined;
    std.mem.writeInt(u64, &wrong_len, 7, .big);
    try file.writePositionalAll(testing.io, &wrong_len, magic.len);
    try testing.expectError(error.CorruptManifest, store.readManifest(testing.allocator, 100));
    try writeBytes(testing.io, file, "X");
    try testing.expectError(error.CorruptManifest, store.readManifest(testing.allocator, 100));
    try file.setLength(testing.io, 4);
    try testing.expectError(error.CorruptManifest, store.readManifest(testing.allocator, 100));
}

test "collection retains explicit live blobs and ignores noncanonical files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const live = try store.putBlob("live");
    const dead = try store.putBlob("dead");
    const debris = try store.blobs.createFile(testing.io, "temp", .{});
    debris.close(testing.io);
    try testing.expectEqual(@as(usize, 1), try store.collect(&.{live}));
    const bytes = try store.getBlob(testing.allocator, live, 4);
    defer testing.allocator.free(bytes);
    try testing.expectError(error.NotFound, store.getBlob(testing.allocator, dead, 4));
    const surviving = try store.blobs.openFile(testing.io, "temp", .{});
    surviving.close(testing.io);
    try testing.expectEqual(@as(usize, 0), try store.collect(&.{live}));
}

test "symlinked blobs and store directories are rejected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const name = std.fmt.bytesToHex(digest("target"), .lower);
    try store.blobs.symLink(testing.io, "../manifest", &name, .{});
    try testing.expectError(error.IoFailed, store.getBlob(testing.allocator, digest("target"), 100));
    try testing.expectError(error.IoFailed, store.putBlob("target"));
    try testing.expectEqual(@as(usize, 0), try store.collect(&.{}));
    try store.root.symLink(testing.io, "blobs", "alias", .{ .is_directory = true });
    var root_path: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &root_path);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/alias", .{root_path[0..len]});
    defer testing.allocator.free(path);
    try testing.expectError(error.IoFailed, Store.open(testing.allocator, testing.io, path));
}

test "exclusive store lock and parent traversal rejection" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    try testing.expectError(error.StoreBusy, testStore(&tmp));
    try testing.expectError(error.InvalidPath, Store.open(testing.allocator, testing.io, "../outside"));
}

const fixture_old = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x03" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01a\x01\x00\x00\x00\x03old" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01b\x01\x00\x00\x00\x03old" ++
    "\x00\x00\x00\x02\x00\x00\x00\x01a\x01\x00\x00\x00\x05other";
const fixture_new = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x03" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01a\x00" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01b\x01\x00\x00\x00\x03new" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01c\x01\x00\x00\x00\x00";
const fixture_merged = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x04" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01a\x00" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01b\x01\x00\x00\x00\x03new" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01c\x01\x00\x00\x00\x00" ++
    "\x00\x00\x00\x02\x00\x00\x00\x01a\x01\x00\x00\x00\x05other";
const fixture_terminal = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x03" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01b\x01\x00\x00\x00\x03new" ++
    "\x00\x00\x00\x01\x00\x00\x00\x01c\x01\x00\x00\x00\x00" ++
    "\x00\x00\x00\x02\x00\x00\x00\x01a\x01\x00\x00\x00\x05other";

test "verified bucket lookup distinguishes absent, tombstone, empty, and table identity" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const hash = try store.putBlob(fixture_merged);
    var absent = try store.lookupBucket(testing.allocator, hash, 1, "missing", .{});
    defer absent.deinit(testing.allocator);
    try testing.expect(absent == .absent);
    var tombstone = try store.lookupBucket(testing.allocator, hash, 1, "a", .{});
    defer tombstone.deinit(testing.allocator);
    try testing.expect(tombstone == .tombstone);
    var empty = try store.lookupBucket(testing.allocator, hash, 1, "c", .{});
    defer empty.deinit(testing.allocator);
    try testing.expect(empty == .value);
    try testing.expectEqualStrings("", empty.value);
    var value = try store.lookupBucket(testing.allocator, hash, 1, "b", .{});
    defer value.deinit(testing.allocator);
    try testing.expectEqualStrings("new", value.value);
    var other = try store.lookupBucket(testing.allocator, hash, 2, "a", .{});
    defer other.deinit(testing.allocator);
    try testing.expectEqualStrings("other", other.value);

    var cursor = try store.scanBucket(hash, .{});
    defer cursor.deinit();
    try testing.expectEqual(@as(u64, fixture_merged.len), cursor.byteLength());
    try testing.expectEqual(@as(u64, 4), cursor.recordCount());
    const first = (try cursor.next()).?;
    try testing.expectEqual(@as(u32, 1), first.table);
    try testing.expectEqualStrings("a", first.key);
    try testing.expect(first.value == null);
    const second = (try cursor.next()).?;
    try testing.expectEqualStrings("b", second.key);
    try testing.expectEqualStrings("new", second.value.?);
    try cursor.finish();
    try testing.expectEqual(@as(u64, 4), cursor.recordCount());
    try testing.expect(try cursor.next() == null);
    try cursor.finish();
    var empty_cursor = try store.scanBucket(try store.putBlob(empty_bucket), .{});
    defer empty_cursor.deinit();
    try testing.expect(try empty_cursor.next() == null);
}

test "lookup and scan reject corrupt tails after an early matching record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const hash = try store.putBlob(fixture_old);
    const name = std.fmt.bytesToHex(hash, .lower);
    const file = try store.blobs.openFile(testing.io, &name, .{ .mode = .read_write });
    try file.writePositionalAll(testing.io, "X", fixture_old.len - 1);
    file.close(testing.io);
    try testing.expectError(error.CorruptBlob, store.lookupBucket(testing.allocator, hash, 1, "a", .{}));
    try testing.expectError(error.CorruptBlob, store.lookupBucket(testing.allocator, hash, 99, "absent", .{}));
    var cursor = try store.scanBucket(hash, .{});
    defer cursor.deinit();
    // Streaming records are only provisional; successful early parsing cannot
    // certify the unread tail. An error stays sticky until cursor destruction.
    try testing.expectEqualStrings("old", (try cursor.next()).?.value.?);
    try testing.expectError(error.CorruptBlob, cursor.finish());
    try testing.expectError(error.CorruptBlob, cursor.next());
    try testing.expectError(error.CorruptBlob, cursor.finish());

    const trailing = try store.putBlob(fixture_new ++ "x");
    try testing.expectError(error.InvalidBucket, store.lookupBucket(testing.allocator, trailing, 1, "a", .{}));
    const bounded = try store.putBlob(fixture_new);
    try testing.expectError(error.TooLarge, store.lookupBucket(testing.allocator, bounded, 1, "a", .{ .max_value_bytes = 2 }));
    try testing.expectError(error.TooLarge, store.lookupBucket(testing.allocator, bounded, 1, "long", .{ .max_key_bytes = 1 }));
}

fn drainBucket(store: *Store, hash: Hash, limits: MergeLimits) Error!void {
    var cursor = try store.scanBucket(hash, limits);
    defer cursor.deinit();
    try cursor.finish();
}

test "public bucket scans enforce canonical framing and declared resource bounds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const duplicate = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x02" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00";
    const unordered = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x02" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01b\x00" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00";
    const invalid_tag = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\x00\x00\x00\x00\x02";
    for ([_][]const u8{ duplicate, unordered, invalid_tag, fixture_new[0 .. fixture_new.len - 1], empty_bucket ++ "x", "bad domain" }) |bytes| {
        try testing.expectError(error.InvalidBucket, drainBucket(&store, try store.putBlob(bytes), .{}));
    }
    const huge_count = bucket_domain ++ "\xff\xff\xff\xff\xff\xff\xff\xff";
    try testing.expectError(error.TooLarge, drainBucket(&store, try store.putBlob(huge_count), .{}));
    const huge_key = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\xff\xff\xff\xff\x00";
    try testing.expectError(error.TooLarge, drainBucket(&store, try store.putBlob(huge_key), .{}));
    const huge_value = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\x00\x00\x00\x00\x01\xff\xff\xff\xff";
    try testing.expectError(error.TooLarge, drainBucket(&store, try store.putBlob(huge_value), .{}));
    const hash = try store.putBlob(fixture_new);
    try testing.expectError(error.TooLarge, drainBucket(&store, hash, .{ .max_records = 2 }));
    try testing.expectError(error.TooLarge, drainBucket(&store, hash, .{ .max_bucket_bytes = fixture_new.len - 1 }));
    try drainBucket(&store, hash, .{ .max_key_bytes = 1, .max_value_bytes = 3, .max_records = 3, .max_bucket_bytes = fixture_new.len });
}

test "bucket lookup allocation failures release cursor and captured value" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const hash = try store.putBlob(fixture_old);
    for (0..2) |index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        store.gpa = failing.allocator();
        try testing.expectError(error.OutOfMemory, store.lookupBucket(failing.allocator(), hash, 1, "a", .{}));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    store.gpa = testing.allocator;
}

test "streaming merge matches canonical core fixture and newest/tombstone semantics" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const core_literal = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x07\x00\x00\x00\x01k\x01\x00\x00\x00\x01v";
    const empty = try store.putBlob(empty_bucket);
    var known: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&known, "7076a8bba14bcc34e17a8a22d54a16d13b09247075da48782dac74352f01ac12");
    try testing.expectEqual(known, empty);
    _ = try std.fmt.hexToBytes(&known, "f0c97d1ffee7489cfcb47d1eba0918147cd67b220cbb5db08b045de3118ab940");
    const single = try store.putBlob(core_literal);
    try testing.expectEqual(known, single);
    try testing.expectEqual(single, try store.mergeBuckets(empty, single, false, .{}));
    try testing.expectEqual(empty, try store.mergeBuckets(empty, empty, true, .{}));
    const old = try store.putBlob(fixture_old);
    const new = try store.putBlob(fixture_new);
    try testing.expectError(error.TooLarge, store.mergeBuckets(old, new, false, .{ .max_records = 3 }));
    try testing.expectError(error.TooLarge, store.mergeBuckets(old, new, false, .{ .max_bucket_bytes = @max(fixture_old.len, fixture_new.len) }));
    const merged = try store.mergeBuckets(old, new, false, .{});
    try testing.expectEqual(digest(fixture_merged), merged);
    const bytes = try store.getBlob(testing.allocator, merged, fixture_merged.len);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings(fixture_merged, bytes);
    try testing.expectEqual(merged, try store.mergeBuckets(old, new, false, .{}));
    const terminal = try store.mergeBuckets(old, new, true, .{});
    try testing.expectEqual(digest(fixture_terminal), terminal);
    // Reversing precedence is observably different, including resurrection.
    try testing.expect(!std.mem.eql(u8, &merged, &(try store.mergeBuckets(new, old, false, .{}))));
}

test "streaming merge rejects corrupt content, malformed frames, order, and hostile lengths" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const empty = try store.putBlob(empty_bucket);
    const old = try store.putBlob(fixture_old);
    const old_name = std.fmt.bytesToHex(old, .lower);
    const file = try store.blobs.createFile(testing.io, &old_name, .{ .truncate = false });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "X", fixture_old.len - 1);
    try testing.expectError(error.CorruptBlob, store.mergeBuckets(old, empty, false, .{}));
    try testing.expectError(error.CorruptBlob, store.mergeBuckets(empty, old, false, .{}));
    const dup = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x02" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00";
    try testing.expectError(error.InvalidBucket, store.mergeBuckets(try store.putBlob(dup), empty, false, .{}));
    const unordered = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x02" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01b\x00" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01a\x00";
    try testing.expectError(error.InvalidBucket, store.mergeBuckets(try store.putBlob(unordered), empty, false, .{}));
    const enormous_key = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\xff\xff\xff\xff\x00";
    try testing.expectError(error.TooLarge, store.mergeBuckets(try store.putBlob(enormous_key), empty, false, .{}));
    const enormous_value = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\x00\x00\x00\x00\x01\xff\xff\xff\xff";
    try testing.expectError(error.TooLarge, store.mergeBuckets(try store.putBlob(enormous_value), empty, false, .{}));
    const invalid_tag = bucket_domain ++ "\x00\x00\x00\x00\x00\x00\x00\x01" ++
        "\x00\x00\x00\x01\x00\x00\x00\x00\x02";
    try testing.expectError(error.InvalidBucket, store.mergeBuckets(try store.putBlob(invalid_tag), empty, false, .{}));
    try testing.expectError(error.InvalidBucket, store.mergeBuckets(try store.putBlob(empty_bucket ++ "x"), empty, false, .{}));
    try testing.expectError(error.InvalidBucket, store.mergeBuckets(try store.putBlob(fixture_new[0 .. fixture_new.len - 1]), empty, false, .{}));
    try testing.expectError(error.TooLarge, store.mergeBuckets(empty, empty, false, .{ .max_bucket_bytes = 1 }));
    const new = try store.putBlob(fixture_new);
    try testing.expectError(error.TooLarge, store.mergeBuckets(new, empty, false, .{ .max_records = 2 }));
    try testing.expectError(error.TooLarge, store.mergeBuckets(new, empty, false, .{ .max_value_bytes = 2 }));
}

fn manyRecords(gpa: std.mem.Allocator, count: u32, parity: u32) ![]u8 {
    const bytes = try gpa.alloc(u8, empty_bucket.len + @as(usize, count) * 21);
    @memcpy(bytes[0..bucket_domain.len], bucket_domain);
    std.mem.writeInt(u64, bytes[bucket_domain.len..][0..8], count, .big);
    var pos: usize = empty_bucket.len;
    for (0..count) |i| {
        const key: u32 = @as(u32, @intCast(i)) * 2 + parity;
        std.mem.writeInt(u32, bytes[pos..][0..4], 1, .big);
        std.mem.writeInt(u32, bytes[pos + 4 ..][0..4], 4, .big);
        std.mem.writeInt(u32, bytes[pos + 8 ..][0..4], key, .big);
        bytes[pos + 12] = 1;
        std.mem.writeInt(u32, bytes[pos + 13 ..][0..4], 4, .big);
        std.mem.writeInt(u32, bytes[pos + 17 ..][0..4], key, .big);
        pos += 21;
    }
    return bytes;
}

test "public scans and verified lookup keep fixed workspace across large buckets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const bytes = try manyRecords(testing.allocator, 100000, 0);
    defer testing.allocator.free(bytes);
    const hash = try store.putBlob(bytes);
    var workspace: [8300]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&workspace);
    store.gpa = fixed.allocator();
    const limits: MergeLimits = .{ .max_key_bytes = 4, .max_value_bytes = 4 };
    {
        var cursor = try store.scanBucket(hash, limits);
        defer cursor.deinit();
        var count: usize = 0;
        while (try cursor.next()) |record| {
            const expected: u32 = @intCast(count * 2);
            try testing.expectEqual(expected, std.mem.readInt(u32, record.key[0..4], .big));
            try testing.expectEqual(expected, std.mem.readInt(u32, record.value.?[0..4], .big));
            count += 1;
        }
        try testing.expectEqual(@as(usize, 100000), count);
    }
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
    var value = try store.lookupBucket(testing.allocator, hash, 1, "\x00\x00\x00\x00", limits);
    defer value.deinit(testing.allocator);
    try testing.expectEqualStrings("\x00\x00\x00\x00", value.value);
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
    var absent = try store.lookupBucket(testing.allocator, hash, 1, "\xff\xff\xff\xff", limits);
    defer absent.deinit(testing.allocator);
    try testing.expect(absent == .absent);
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "read index answers warm lookups from one span after a fully verified pass" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const bytes = try manyRecords(testing.allocator, 10000, 0);
    defer testing.allocator.free(bytes);
    const hash = try store.putBlob(bytes);
    const limits: MergeLimits = .{ .max_key_bytes = 4, .max_value_bytes = 4 };
    try store.enableReadIndex(.{ .min_span_bytes = 128 });

    var cold_key: [4]u8 = undefined;
    std.mem.writeInt(u32, &cold_key, 5000, .big);
    var cold = try store.lookupBucketIndexed(testing.allocator, hash, 1, &cold_key, limits);
    defer cold.deinit(testing.allocator);
    try testing.expectEqualStrings(&cold_key, cold.value);

    // Warm lookups must stay byte-exact across present and both absent
    // classes, and read only a span instead of the whole blob.
    const Guard = struct {
        var read_bytes: usize = 0;
        fn read(ctx: ?*anyopaque, file: std.Io.File, buffers: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
            const n = try testing.io.vtable.fileReadPositional(ctx, file, buffers, offset);
            read_bytes += n;
            return n;
        }
    };
    var vtable = testing.io.vtable.*;
    vtable.fileReadPositional = Guard.read;
    store.io = .{ .userdata = testing.io.userdata, .vtable = &vtable };
    defer store.io = testing.io;
    defer Guard.read_bytes = 0;
    for (0..10000) |i| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i * 2), .big);
        var found = try store.lookupBucketIndexed(testing.allocator, hash, 1, &key, limits);
        defer found.deinit(testing.allocator);
        try testing.expectEqualStrings(&key, found.value);
    }
    for (0..10000) |i| {
        var key: [4]u8 = undefined;
        std.mem.writeInt(u32, &key, @intCast(i * 2 + 1), .big);
        var found = try store.lookupBucketIndexed(testing.allocator, hash, 1, &key, limits);
        defer found.deinit(testing.allocator);
        try testing.expect(found == .absent);
    }
    var beyond: [4]u8 = undefined;
    std.mem.writeInt(u32, &beyond, 40000, .big);
    var absent = try store.lookupBucketIndexed(testing.allocator, hash, 1, &beyond, limits);
    defer absent.deinit(testing.allocator);
    try testing.expect(absent == .absent);
    // Each warm lookup streamed only its span (a 128-byte span holds at
    // most seven 21-byte records); the whole-bucket path would read the
    // 210,025-byte blob on every one of these 20,001 lookups.
    const lookups = 2 * 10000 + 1;
    try testing.expect(Guard.read_bytes / lookups < 512);
}

test "read index re-verifies after size changes and reads only the probed span" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const bytes = try manyRecords(testing.allocator, 10000, 0);
    defer testing.allocator.free(bytes);
    const hash = try store.putBlob(bytes);
    const name = std.fmt.bytesToHex(hash, .lower);
    const limits: MergeLimits = .{ .max_key_bytes = 4, .max_value_bytes = 4 };
    try store.enableReadIndex(.{ .min_span_bytes = 2048 });
    var probe: [4]u8 = undefined;
    std.mem.writeInt(u32, &probe, 0, .big);
    var warm = try store.lookupBucketIndexed(testing.allocator, hash, 1, &probe, limits);
    defer warm.deinit(testing.allocator);
    try testing.expectEqualStrings(&probe, warm.value);

    // A same-size flip in a record far after the probe target is outside the
    // probed span: the warm read still answers from verified span bytes.
    const file = try store.blobs.openFile(testing.io, &name, .{ .mode = .read_write });
    defer file.close(testing.io);
    const far_offset = bytes.len - 4;
    try file.writePositionalAll(testing.io, "X", far_offset);
    var again = try store.lookupBucketIndexed(testing.allocator, hash, 1, &probe, limits);
    defer again.deinit(testing.allocator);
    try testing.expectEqualStrings(&probe, again.value);

    // Truncation changes the file size: the entry is distrusted and the
    // fallback re-verification fails closed (truncated framing here).
    try file.setLength(testing.io, bytes.len - 1);
    try testing.expectError(error.InvalidBucket, store.lookupBucketIndexed(testing.allocator, hash, 1, &probe, limits));
    // Appending changes the size as well; re-verification rejects it too.
    try file.setLength(testing.io, bytes.len + 1);
    try testing.expectError(error.InvalidBucket, store.lookupBucketIndexed(testing.allocator, hash, 1, &probe, limits));
    try testing.expectError(error.InvalidBucket, store.lookupBucket(testing.allocator, hash, 1, &probe, limits));
}

test "read index eviction re-verifies and allocation failure only skips sampling" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const even = try manyRecords(testing.allocator, 4000, 0);
    defer testing.allocator.free(even);
    const odd = try manyRecords(testing.allocator, 4000, 1);
    defer testing.allocator.free(odd);
    const a = try store.putBlob(even);
    const b = try store.putBlob(odd);
    const limits: MergeLimits = .{ .max_key_bytes = 4, .max_value_bytes = 4 };
    try store.enableReadIndex(.{ .min_span_bytes = 1024, .max_buckets = 1 });
    var key: [4]u8 = undefined;
    for (0..4) |round| {
        const hash = if (round % 2 == 0) a else b;
        const shift: u32 = if (round % 2 == 0) 0 else 1;
        std.mem.writeInt(u32, &key, 2 * 1998 + shift, .big);
        var found = try store.lookupBucketIndexed(testing.allocator, hash, 1, &key, limits);
        defer found.deinit(testing.allocator);
        try testing.expectEqualStrings(&key, found.value);
    }
    // Index-bookkeeping allocation failure is observable as OutOfMemory,
    // leaks nothing, and a retry succeeds once memory is available again.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    store.gpa = failing.allocator();
    std.mem.writeInt(u32, &key, 4, .big);
    try testing.expectError(error.OutOfMemory, store.lookupBucketIndexed(testing.allocator, a, 1, &key, limits));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    store.gpa = testing.allocator;
    store.gpa = testing.allocator;
    store.read_index.?.destroy();
    store.read_index = null;
    try store.enableReadIndex(.{ .min_span_bytes = 1024 });
    std.mem.writeInt(u32, &key, 4, .big);
    var restored = try store.lookupBucketIndexed(testing.allocator, a, 1, &key, limits);
    defer restored.deinit(testing.allocator);
    try testing.expectEqualStrings(&key, restored.value);
}

test "v2 buckets verify under the block format and match the independent model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    try store.enableReadIndex(.{ .min_span_bytes = 128 });
    const bytes = try manyRecords(testing.allocator, 100, 0);
    defer testing.allocator.free(bytes);
    const limits: MergeLimits = .{
        .max_key_bytes = 4,
        .max_value_bytes = 4,
        .format = .{ .v2 = .{ .target_block_bytes = 128 } },
    };
    // Literal from tools/v2-vectors.py over the manyRecords fixture shape
    // (table 1, key u32be(2i), value u32be(2i)) at target 128, plus the
    // empty-bucket constant.
    const hash = try store.putBucketV2(bytes, limits);
    var expected: Hash = undefined;
    _ = try std.fmt.hexToBytes(&expected, "11b18af417064d1f7ea26dc9d462b2d80696b76be501cb92cbeb5b3b4c6a926a");
    try testing.expectEqualSlices(u8, &expected, &hash);
    try testing.expectEqual(hash, try store.putBucketV2(bytes, limits));
    const empty = try store.putBucketV2(empty_bucket, limits);
    _ = try std.fmt.hexToBytes(&expected, "013dce769819e34e82bcbccd3d2d3f24dfbddd1d99f3f2647a99465105d78952");
    try testing.expectEqualSlices(u8, &expected, &empty);

    // Streaming scans, verified lookups, and the read index all operate on
    // the v2-named blob; the flat v1 interpretation of the same name fails.
    var cursor = try store.scanBucket(hash, limits);
    defer cursor.deinit();
    try cursor.finish();
    try testing.expectEqual(@as(u64, 100), cursor.recordCount());
    var key: [4]u8 = undefined;
    std.mem.writeInt(u32, &key, 198, .big);
    var found = try store.lookupBucketIndexed(testing.allocator, hash, 1, &key, limits);
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings(&key, found.value);
    std.mem.writeInt(u32, &key, 199, .big);
    var absent = try store.lookupBucketIndexed(testing.allocator, hash, 1, &key, limits);
    defer absent.deinit(testing.allocator);
    try testing.expect(absent == .absent);
    {
        var flat = try store.scanBucket(hash, .{ .max_key_bytes = 4, .max_value_bytes = 4 });
        defer flat.deinit();
        try testing.expectError(error.CorruptBlob, flat.finish());
    }

    // A value-byte flip (framing and order intact) breaks the block digest.
    const name = std.fmt.bytesToHex(hash, .lower);
    const file = try store.blobs.openFile(testing.io, &name, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "X", bytes.len - 1);
    {
        var flipped = try store.scanBucket(hash, limits);
        defer flipped.deinit();
        try testing.expectError(error.CorruptBlob, flipped.finish());
    }
}

test "v2 merges produce block-hashed outputs and verify without writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const even = try manyRecords(testing.allocator, 100, 0);
    defer testing.allocator.free(even);
    const odd = try manyRecords(testing.allocator, 100, 1);
    defer testing.allocator.free(odd);
    const limits: MergeLimits = .{
        .max_key_bytes = 4,
        .max_value_bytes = 4,
        .format = .{ .v2 = .{ .target_block_bytes = 128 } },
    };
    const older = try store.putBucketV2(even, limits);
    const newer = try store.putBucketV2(odd, limits);
    const merged = try store.mergeBuckets(older, newer, false, limits);
    // Independent literal: the merged stream (keys 0..199, value == key)
    // under target 128, from tools/v2-vectors.py.
    var expected: Hash = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2edc9550776d4138b5dc846f5230052740037a5c30ac3808344239327b7804b6");
    try testing.expectEqualSlices(u8, &expected, &merged);
    // Write-free verification accepts the true output and rejects a forgery.
    try store.mergeBucketsVerify(older, newer, false, limits, merged);
    try testing.expectError(error.MergeMismatch, store.mergeBucketsVerify(older, newer, false, limits, older));
    var drain = try store.scanBucket(merged, limits);
    defer drain.deinit();
    try drain.finish();
    try testing.expectEqual(@as(u64, 200), drain.recordCount());
    // The v1 interpretation of the v2-named output fails closed.
    var flat = try store.scanBucket(merged, .{ .max_key_bytes = 4, .max_value_bytes = 4 });
    defer flat.deinit();
    try testing.expectError(error.CorruptBlob, flat.finish());
}

test "compressed blobs keep content addressing over plain bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    store.enableCompression();
    const payload = try manyRecords(testing.allocator, 1000, 0);
    defer testing.allocator.free(payload);
    // Plain and compressed writers agree on the name and content.
    const hash = try store.putBlob(payload);
    const name = std.fmt.bytesToHex(hash, .lower);
    try testing.expectEqual(@as(Hash, digest(payload)), hash);
    const stat = try store.blobs.statFile(testing.io, &name, .{ .follow_symlinks = false });
    try testing.expect(stat.size < payload.len); // framed and actually smaller
    const read_back = try store.getBlob(testing.allocator, hash, payload.len);
    defer testing.allocator.free(read_back);
    try testing.expectEqualSlices(u8, payload, read_back);
    // Streaming scans, v2 hashing, and merges work through the framing.
    const limits: MergeLimits = .{
        .max_key_bytes = 4,
        .max_value_bytes = 4,
        .format = .{ .v2 = .{ .target_block_bytes = 128 } },
    };
    const v2 = try store.putBucketV2(payload, limits);
    var cursor = try store.scanBucket(v2, limits);
    defer cursor.deinit();
    try cursor.finish();
    try testing.expectEqual(@as(u64, 1000), cursor.recordCount());
    const odd = try manyRecords(testing.allocator, 1000, 1);
    defer testing.allocator.free(odd);
    const other = try store.putBucketV2(odd, limits);
    const merged = try store.mergeBuckets(v2, other, false, limits);
    var drain = try store.scanBucket(merged, limits);
    defer drain.deinit();
    try drain.finish();
    try testing.expectEqual(@as(u64, 2000), drain.recordCount());
    // A legacy (unframed) blob written before the opt-in stays readable.
    {
        var legacy_tmp = testing.tmpDir(.{});
        defer legacy_tmp.cleanup();
        var legacy = try testStore(&legacy_tmp);
        defer legacy.deinit();
        const legacy_hash = try legacy.putBlob(payload);
        try testing.expectEqual(hash, legacy_hash);
        const legacy_read = try store.getBlob(testing.allocator, legacy_hash, payload.len);
        defer testing.allocator.free(legacy_read);
        try testing.expectEqualSlices(u8, payload, legacy_read);
    }
    // Corrupt the compressed payload: verification must fail closed.
    const file = try store.blobs.openFile(testing.io, &name, .{ .mode = .read_write });
    defer file.close(testing.io);
    try file.writePositionalAll(testing.io, "X", stat.size / 2);
    try testing.expectError(error.CorruptBlob, store.getBlob(testing.allocator, hash, payload.len));
}

test "one store supports concurrent immutable puts merges and independent cursors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const old = try store.putBlob(fixture_old);
    const new = try store.putBlob(fixture_new);
    const expected = digest(fixture_merged);
    var start: std.atomic.Value(bool) = .init(false);
    const Job = struct {
        store: *Store,
        old: Hash,
        new: Hash,
        expected: Hash,
        start: *std.atomic.Value(bool),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.work() catch |err| {
                self.failure = err;
            };
        }

        fn work(self: *@This()) !void {
            for (0..4) |_| {
                try testing.expectEqual(self.expected, try self.store.mergeBuckets(self.old, self.new, false, .{ .max_key_bytes = 1, .max_value_bytes = 5 }));
                try testing.expectEqual(self.expected, try self.store.putBlob(fixture_merged));
                var value = try self.store.lookupBucket(testing.allocator, self.expected, 1, "b", .{ .max_key_bytes = 1, .max_value_bytes = 5 });
                defer value.deinit(testing.allocator);
                try testing.expectEqualStrings("new", value.value);
                var cursor = try self.store.scanBucket(self.expected, .{ .max_key_bytes = 1, .max_value_bytes = 5 });
                defer cursor.deinit();
                try cursor.finish();
                try testing.expectEqual(@as(u64, 4), cursor.recordCount());
            }
        }
    };
    var jobs: [4]Job = @splat(.{ .store = &store, .old = old, .new = new, .expected = expected, .start = &start });
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    {
        // Release already-spawned threads even if a later spawn fails.
        defer {
            start.store(true, .release);
            for (threads[0..started]) |thread| thread.join();
        }
        for (&jobs, &threads) |*job, *thread| {
            thread.* = try std.Thread.spawn(.{}, Job.run, .{job});
            started += 1;
        }
        start.store(true, .release);
    }
    for (jobs) |job| if (job.failure) |err| return err;
    try drainBucket(&store, expected, .{});
}

test "streaming merge uses fixed workspace for many records and existing large output" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const old_bytes = try manyRecords(testing.allocator, 10000, 0);
    defer testing.allocator.free(old_bytes);
    const new_bytes = try manyRecords(testing.allocator, 10000, 1);
    defer testing.allocator.free(new_bytes);
    const old = try store.putBlob(old_bytes);
    const new = try store.putBlob(new_bytes);
    var workspace: [17000]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&workspace);
    store.gpa = fixed.allocator();
    const limits: MergeLimits = .{ .max_key_bytes = 4, .max_value_bytes = 4 };
    const merged = try store.mergeBuckets(old, new, false, limits);
    // Exercise the existing-file verification branch under the same bound.
    try testing.expectEqual(merged, try store.mergeBuckets(old, new, false, limits));
    const bytes = try store.getBlob(testing.allocator, merged, empty_bucket.len + 20000 * 21);
    defer testing.allocator.free(bytes);
    try testing.expectEqual(@as(u64, 20000), std.mem.readInt(u64, bytes[bucket_domain.len..][0..8], .big));
    for (0..20000) |i| {
        const pos = empty_bucket.len + i * 21;
        try testing.expectEqual(@as(u32, @intCast(i)), std.mem.readInt(u32, bytes[pos + 8 ..][0..4], .big));
        try testing.expectEqual(@as(u32, @intCast(i)), std.mem.readInt(u32, bytes[pos + 17 ..][0..4], .big));
    }
    try testing.expectEqual(@as(usize, 0), fixed.end_index);
}

test "streaming merge workspace OOM does not install partial output or leak" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    const old = try store.putBlob(fixture_old);
    const new = try store.putBlob(fixture_new);
    for (0..4) |failure| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = failure });
        store.gpa = failing.allocator();
        try testing.expectError(error.OutOfMemory, store.mergeBuckets(old, new, false, .{}));
        try testing.expectError(error.NotFound, store.getBlob(testing.allocator, digest(fixture_merged), 1000));
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
    store.gpa = testing.allocator;
    try testing.expectEqual(digest(fixture_merged), try store.mergeBuckets(old, new, false, .{}));
}

fn makeTestFifo(dir: std.Io.Dir, name: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(testing.io, &path_buf);
    var fifo_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&fifo_buf, "{s}/{s}", .{ path_buf[0..len], name }, 0);
    if (comptime builtin.os.tag == .linux) {
        if (std.os.linux.errno(std.os.linux.mknod(path.ptr, std.os.linux.S.IFIFO | 0o600, 0)) != .SUCCESS)
            return error.FifoCreationFailed;
    } else if (comptime builtin.os.tag == .macos) {
        const C = struct {
            extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
        };
        if (C.mkfifo(path.ptr, 0o600) != 0) return error.FifoCreationFailed;
    } else return error.SkipZigTest;
}

test "FIFO reads reject before opening with a timeout-safe regression guard" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try testStore(&tmp);
    defer store.deinit();
    try makeTestFifo(store.root, manifest_name);
    const Guard = struct {
        underlying: std.Io,
        opened: bool = false,
        fn statFile(ctx: ?*anyopaque, dir: std.Io.Dir, name: []const u8, options: std.Io.Dir.StatFileOptions) std.Io.Dir.StatFileError!std.Io.File.Stat {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.underlying.vtable.dirStatFile(self.underlying.userdata, dir, name, options);
        }
        fn openFile(ctx: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!std.Io.File {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.opened = true;
            return error.AccessDenied; // Would block on the real FIFO.
        }
    };
    var guard: Guard = .{ .underlying = testing.io };
    var vtable = testing.io.vtable.*;
    vtable.dirStatFile = Guard.statFile;
    vtable.dirOpenFile = Guard.openFile;
    const guarded_io: std.Io = .{ .userdata = &guard, .vtable = &vtable };
    // If the precheck regresses, this assertion fails immediately before the
    // real-backend calls below; a broken implementation cannot hang this test.
    try testing.expectError(error.NotRegularFile, openRegular(store.root, guarded_io, manifest_name));
    try testing.expect(!guard.opened);
    try testing.expectError(error.NotRegularFile, store.readManifest(testing.allocator, 100));
    const hash = digest("FIFO blob");
    const name = std.fmt.bytesToHex(hash, .lower);
    try makeTestFifo(store.blobs, &name);
    try testing.expectError(error.NotRegularFile, store.getBlob(testing.allocator, hash, 100));
    try testing.expectError(error.NotRegularFile, store.putBlob("FIFO blob"));
}
