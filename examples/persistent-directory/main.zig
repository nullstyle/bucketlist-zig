//! Run with an empty directory dedicated to this example:
//!   mise exec -- zig build run -- /absolute/path/to/scratch-store
//! Full References below are trusted because this process captured them from
//! successful saves. Reading a digest from untrusted storage is not certification.
const std = @import("std");
const bucketlist = @import("bucketlist");
const checkpoints = @import("bucketlist-checkpoints");
const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const Name = bucketlist.Bytes(32);
const Schema = struct {
    pub const namespace = "example.persistent.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, u64, struct { balance: u64 }),
        .names = bucketlist.Table(2, Name, u64),
    };
};
const Directory = bucketlist.Database(Schema);
const Checkpoints = checkpoints.Checkpoints(Directory);

// Example application metadata: preserve the exact canonical last command so
// a consensus adapter could restore its predecessor value, not merely a root.
const Command = struct {
    advance: u64,
    previous_database: Hash,
    account: u64,
    balance: u64,
    name: Name,
    remove_name: bool,
};
const CommandCodec = bucketlist.Codec(Command);
const limits: checkpoints.Limits = .{
    .max_checkpoint_bytes = 1024 * 1024,
    .max_metadata_bytes = CommandCodec.max_size,
};

fn next(db: *const Directory, balance: u64, remove_name: bool) Command {
    const commitment = db.commitment();
    return .{
        .advance = commitment.advance + 1,
        .previous_database = commitment.digest,
        .account = 7,
        .balance = balance,
        .name = Name.init("alice") catch unreachable,
        .remove_name = remove_name,
    };
}

fn apply(db: *Directory, gpa: Allocator, command: Command) !void {
    const previous = db.commitment();
    if (previous.advance == std.math.maxInt(u64) or command.advance != previous.advance + 1 or
        !std.mem.eql(u8, &command.previous_database, &previous.digest)) return error.InvalidPredecessor;
    var batch = try db.batch(gpa);
    defer batch.deinit();
    try batch.put(.accounts, command.account, .{ .balance = command.balance });
    if (command.remove_name) try batch.delete(.names, command.name) else try batch.put(.names, command.name, command.account);
    var prepared = try db.prepareAdvance(gpa, command.advance, &batch);
    defer prepared.deinit();
    try db.commit(&prepared);
}

fn expectSame(a: *const Directory, b: *const Directory) !void {
    if (!std.mem.eql(u8, &a.commitment().digest, &b.commitment().digest)) return error.ContinuationDiverged;
}

fn expectReference(a: checkpoints.Reference, b: checkpoints.Reference) !void {
    if (!std.mem.eql(u8, &a.manifest_hash, &b.manifest_hash) or
        !std.mem.eql(u8, &a.database_digest, &b.database_digest)) return error.WrongPublishedReference;
}

fn save(manager: *Checkpoints, db: *const Directory, command: Command) !checkpoints.Reference {
    var view = db.readView();
    defer view.deinit();
    var buffer: [CommandCodec.max_size]u8 = undefined;
    return manager.save(&view, try CommandCodec.encode(command, &buffer));
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: persistent-directory <empty-storage-directory>\n", .{});
        return error.MissingStoragePath;
    };
    if (args.next() != null) return error.UnexpectedArgument;
    const gpa = init.gpa;
    var uninterrupted = Directory.init(gpa);
    defer uninterrupted.deinit();
    const command1 = next(&uninterrupted, 100, false);
    try apply(&uninterrupted, gpa, command1);
    var command1_buffer: [CommandCodec.max_size]u8 = undefined;
    const command1_bytes = try CommandCodec.encode(command1, &command1_buffer);

    var command2: Command = undefined;
    const reference1 = first_publication: {
        var pinned = uninterrupted.readView();
        defer pinned.deinit();
        command2 = next(&uninterrupted, 175, true);
        try apply(&uninterrupted, gpa, command2);
        // Publication uses the pinned frontier even after the writer advances.
        var manager = try Checkpoints.open(gpa, init.io, path, limits);
        defer manager.deinit();
        if (try manager.current() != null) return error.StorageAlreadyInitialized;
        const reference = try manager.save(&pinned, command1_bytes);
        if (!std.mem.eql(u8, &reference.database_digest, &pinned.commitment().digest) or
            std.mem.eql(u8, &reference.database_digest, &uninterrupted.commitment().digest)) return error.PinnedFrontierChanged;
        try expectReference(reference, (try manager.current()) orelse return error.MissingPublishedReference);
        break :first_publication reference;
    };

    // The store is fully closed before reopening. The captured full Reference
    // authenticates both the database frontier and exact application metadata.
    var manager = try Checkpoints.open(gpa, init.io, path, limits);
    defer manager.deinit();
    try expectReference(reference1, (try manager.current()) orelse return error.MissingPublishedReference);
    var restored = try manager.load(gpa, reference1);
    defer restored.deinit();
    if (!std.mem.eql(u8, command1_bytes, restored.metadata)) return error.ApplicationMetadataChanged;
    const previous_command = try CommandCodec.decode(restored.metadata);
    if (previous_command.advance != 1 or restored.database.get(.accounts, 7).?.balance != 100 or
        restored.database.get(.names, previous_command.name).? != 7) return error.RestoredRecordsChanged;

    try apply(&restored.database, gpa, command2);
    try expectSame(&uninterrupted, &restored.database);
    const reference2 = try save(&manager, &restored.database, command2);
    const command3 = next(&uninterrupted, 250, false);
    try apply(&uninterrupted, gpa, command3);
    try apply(&restored.database, gpa, command3);
    try expectSame(&uninterrupted, &restored.database);
    const reference3 = try save(&manager, &restored.database, command3);
    try expectReference(reference3, (try manager.current()) orelse return error.MissingPublishedReference);
    if (std.mem.eql(u8, &reference2.manifest_hash, &reference3.manifest_hash)) return error.DistinctCheckpointsCollided;

    // Keep the old recovery point and current checkpoint. The intermediate
    // advance-2 checkpoint is intentionally absent from the retention set.
    const collected = try manager.collect(&.{reference1});
    if (collected == 0) return error.NoGarbageCollected;
    var retained = try manager.load(gpa, reference1);
    defer retained.deinit();
    if (!std.mem.eql(u8, retained.metadata, command1_bytes) or
        retained.database.get(.accounts, 7).?.balance != 100) return error.RetainedCheckpointChanged;
    var current = try manager.load(gpa, reference3);
    defer current.deinit();
    try expectSame(&uninterrupted, &current.database);
    if (current.database.get(.accounts, 7).?.balance != 250 or
        current.database.get(.names, command3.name).? != 7) return error.CurrentRecordsChanged;
    std.debug.print("[persistent-directory] restored advance 1, continued identically to 3, retained 1 and 3, collected {d} blobs\n", .{collected});
    std.debug.print("[persistent-directory] database={s} manifest={s}\n", .{
        std.fmt.bytesToHex(reference3.database_digest, .lower), std.fmt.bytesToHex(reference3.manifest_hash, .lower),
    });
}
