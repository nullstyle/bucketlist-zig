//! Bounded asynchronous publication, then authenticated disk recovery.
const std = @import("std");
const bucketlist = @import("bucketlist");
const native = @import("bucketlist-disk");
const Name = bucketlist.Bytes(32);
const Schema = struct {
    pub const namespace = "example.disk.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, u64, struct { balance: u64 }),
        .names = bucketlist.Table(2, Name, u64),
    };
};
const Host = native.Host(Schema);

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.ExpectedEmptyStorePath;
    if (args.next() != null) return error.UnexpectedArgument;
    const host = try Host.create(init.gpa, init.io, path, .{ .capacity = 2, .disk = .{ .max_metadata_bytes = 64 } });
    var host_open = true;
    defer if (host_open) host.deinit();
    if (host.status().durable != 0) return error.ExpectedEmptyStore;
    // Pause only to make the capacity demonstration deterministic. Production
    // admission usually leaves the worker running and handles Backpressure.
    host.pause();
    for (1..3) |seq| {
        var batch = Host.Batch.init(init.gpa);
        defer batch.deinit();
        try batch.put(.accounts, 7, .{ .balance = seq * 100 });
        try batch.put(.names, try Name.init("alice"), 7);
        try host.trySubmit(seq, &batch, &.{@intCast(seq)});
    }
    var overflow = Host.Batch.init(init.gpa);
    defer overflow.deinit();
    if (host.trySubmit(3, &overflow, "")) |_| return error.ExpectedBackpressure else |err| {
        if (err != error.Backpressure) return err;
    }
    host.resumeProcessing();
    try host.wait(2);
    var snapshot = try host.snapshot(init.gpa);
    defer snapshot.deinit();
    host.deinit();
    host_open = false;
    const db = try native.Database(Schema).open(init.gpa, init.io, path, .{ .expected = snapshot.reference });
    defer db.deinit();
    if (!std.meta.eql(db.commitment(), snapshot.commitment) or
        (try db.get(.accounts, 7)).?.balance != 200 or
        (try db.get(.names, try Name.init("alice"))).? != 7 or
        !std.mem.eql(u8, db.metadata(), &.{2})) return error.RecoveryMismatch;
    _ = try db.collect(&.{});
    std.debug.print("disk directory: bounded publication and authenticated recovery at advance {d}\n", .{db.commitment().advance});
}
