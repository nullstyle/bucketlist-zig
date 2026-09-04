const std = @import("std");
const bucketlist = @import("bucketlist");
const Schema = struct {
    pub const namespace = "example.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, u64, struct { balance: u64 }),
        .names = bucketlist.Table(2, bucketlist.Bytes(32), u64),
    };
};
const Directory = bucketlist.Database(Schema);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var db = Directory.init(gpa);
    defer db.deinit();
    var batch = try db.batch(gpa);
    defer batch.deinit();
    try batch.put(.accounts, 7, .{ .balance = 100 });
    try batch.put(.names, try bucketlist.Bytes(32).init("alice"), 7);
    var advance = try db.prepareAdvance(gpa, 1, &batch);
    defer advance.deinit();
    try db.commit(&advance);
    const bytes = try db.checkpoint(gpa);
    defer gpa.free(bytes);
    var restored = try Directory.restore(gpa, bytes, db.commitment().digest);
    defer restored.deinit();
    if (restored.get(.accounts, 7).?.balance != 100) return error.WrongBalance;
    std.debug.print("[directory] advance={d} commitment={s} checkpoint={d} bytes\n", .{
        db.commitment().advance, std.fmt.bytesToHex(db.commitment().digest, .lower), bytes.len,
    });
}
