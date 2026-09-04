//! Version-one canonical record codec. See docs/encoding.md for its byte contract.
const std = @import("std");

pub const EncodeError = error{ NoSpace, NonCanonical };
pub const DecodeError = error{InvalidEncoding};

/// Bounded raw bytes. Unused storage is zero; encoded order is length-first.
pub fn Bytes(comptime max: usize) type {
    if (max > std.math.maxInt(u32)) @compileError("Bytes bound must fit in u32");
    return struct {
        pub const bucketlist_bytes_bound = max;
        const Self = @This();

        len: u32 = 0,
        data: [max]u8 = @splat(0),

        pub fn init(bytes: []const u8) error{TooLong}!Self {
            if (bytes.len > max) return error.TooLong;
            var result: Self = .{};
            result.len = @intCast(bytes.len);
            @memcpy(result.data[0..bytes.len], bytes);
            return result;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len];
        }
    };
}

pub fn bytesBound(comptime T: type) ?usize {
    if (@typeInfo(T) != .@"struct") return null;
    if (!@hasDecl(T, "bucketlist_bytes_bound")) return null;
    const bound = T.bucketlist_bytes_bound;
    if (T != Bytes(bound)) @compileError("bucketlist_bytes_bound is reserved for bucketlist.Bytes");
    return bound;
}

fn integerBytes(comptime T: type) usize {
    const info = @typeInfo(T).int;
    return switch (info.bits) {
        8, 16, 32, 64 => info.bits / 8,
        else => @compileError("canonical integers must be i8/i16/i32/i64 or u8/u16/u32/u64"),
    };
}

fn maximumSize(comptime T: type) usize {
    if (bytesBound(T)) |bound| return 4 + bound;
    return switch (@typeInfo(T)) {
        .int => integerBytes(T),
        .bool => 1,
        .array => |info| blk: {
            if (info.sentinel_ptr != null) @compileError("canonical arrays cannot have a sentinel");
            if (info.len > std.math.maxInt(u32)) @compileError("canonical array length must fit in u32");
            break :blk info.len * maximumSize(info.child);
        },
        .@"struct" => |info| blk: {
            if (info.layout != .auto or info.is_tuple) @compileError("canonical structs must be ordinary named-field structs");
            var size: usize = 0;
            for (info.field_types, info.field_attrs) |Field, attrs| {
                if (attrs.@"comptime") @compileError("canonical structs cannot contain comptime fields");
                size += maximumSize(Field);
            }
            break :blk size;
        },
        .@"enum" => |info| blk: {
            if (info.mode != .exhaustive) @compileError("canonical enums must be exhaustive");
            if (@typeInfo(info.tag_type).int.signedness != .unsigned) @compileError("canonical enums require an unsigned fixed-width tag type");
            break :blk integerBytes(info.tag_type);
        },
        else => @compileError("unsupported canonical type: use integers, bools, arrays, structs, exhaustive enums or Bytes"),
    };
}

/// Allocation-free canonical encoding and strict whole-input decoding.
pub fn Codec(comptime T: type) type {
    const size = maximumSize(T);
    return struct {
        pub const max_size = size;

        pub fn encode(value: T, out: []u8) EncodeError![]const u8 {
            var writer: Writer = .{ .out = out };
            try encodeValue(T, value, &writer);
            return out[0..writer.position];
        }

        pub fn decode(bytes: []const u8) DecodeError!T {
            var reader: Reader = .{ .bytes = bytes };
            const result = try decodeValue(T, &reader);
            if (reader.position != bytes.len) return error.InvalidEncoding;
            return result;
        }
    };
}

const Writer = struct {
    out: []u8,
    position: usize = 0,

    fn write(self: *Writer, bytes: []const u8) error{NoSpace}!void {
        if (bytes.len > self.out.len - self.position) return error.NoSpace;
        @memcpy(self.out[self.position..][0..bytes.len], bytes);
        self.position += bytes.len;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn take(self: *Reader, size: usize) DecodeError![]const u8 {
        if (size > self.bytes.len - self.position) return error.InvalidEncoding;
        const result = self.bytes[self.position..][0..size];
        self.position += size;
        return result;
    }
};

fn encodeInt(comptime T: type, value: T, writer: *Writer) EncodeError!void {
    const info = @typeInfo(T).int;
    const U = @Int(.unsigned, info.bits);
    var raw: U = @bitCast(value);
    if (info.signedness == .signed) raw ^= @as(U, 1) << (info.bits - 1);
    var encoded: [integerBytes(T)]u8 = undefined;
    std.mem.writeInt(U, &encoded, raw, .big);
    try writer.write(&encoded);
}

fn decodeInt(comptime T: type, reader: *Reader) DecodeError!T {
    const info = @typeInfo(T).int;
    const U = @Int(.unsigned, info.bits);
    const bytes = try reader.take(integerBytes(T));
    var raw = std.mem.readInt(U, bytes[0..comptime integerBytes(T)], .big);
    if (info.signedness == .signed) raw ^= @as(U, 1) << (info.bits - 1);
    return @bitCast(raw);
}

fn encodeValue(comptime T: type, value: T, writer: *Writer) EncodeError!void {
    if (comptime bytesBound(T)) |bound| {
        if (value.len > bound) return error.NonCanonical;
        for (value.data[value.len..]) |byte| if (byte != 0) return error.NonCanonical;
        try encodeInt(u32, value.len, writer);
        try writer.write(value.data[0..value.len]);
        return;
    }
    switch (@typeInfo(T)) {
        .int => try encodeInt(T, value, writer),
        .bool => try writer.write(&.{@intFromBool(value)}),
        .array => |info| for (value) |element| try encodeValue(info.child, element, writer),
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try encodeValue(Field, @field(value, name), writer),
        .@"enum" => |info| try encodeInt(info.tag_type, @backingInt(value), writer),
        else => unreachable,
    }
}

fn decodeValue(comptime T: type, reader: *Reader) DecodeError!T {
    if (comptime bytesBound(T)) |bound| {
        const len = try decodeInt(u32, reader);
        if (len > bound) return error.InvalidEncoding;
        return T.init(try reader.take(len)) catch return error.InvalidEncoding;
    }
    return switch (@typeInfo(T)) {
        .int => try decodeInt(T, reader),
        .bool => switch ((try reader.take(1))[0]) {
            0 => false,
            1 => true,
            else => error.InvalidEncoding,
        },
        .array => |info| blk: {
            var result: T = undefined;
            for (&result) |*element| element.* = try decodeValue(info.child, reader);
            break :blk result;
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, Field| @field(result, name) = try decodeValue(Field, reader);
            break :blk result;
        },
        .@"enum" => |info| blk: {
            const raw = try decodeInt(info.tag_type, reader);
            inline for (info.field_values) |field_value| if (raw == field_value) break :blk @fromBackingInt(@intCast(raw));
            return error.InvalidEncoding;
        },
        else => unreachable,
    };
}

test "literal record encodings and round trip" {
    const Color = enum(u16) { red = 2, green = 400 };
    const Record = struct { enabled: bool, number: i16, name: Bytes(8), color: Color, tail: [2]u8 };
    const value: Record = .{ .enabled = true, .number = -2, .name = try Bytes(8).init("cat"), .color = .green, .tail = .{ 0xab, 0xcd } };
    var buffer: [Codec(Record).max_size]u8 = undefined;
    const expected = [_]u8{ 1, 0x7f, 0xfe, 0, 0, 0, 3, 'c', 'a', 't', 1, 0x90, 0xab, 0xcd };
    try std.testing.expectEqualSlices(u8, &expected, try Codec(Record).encode(value, &buffer));
    try std.testing.expectEqualDeep(value, try Codec(Record).decode(&expected));
    try std.testing.expectError(error.NoSpace, Codec(Record).encode(value, buffer[0 .. expected.len - 1]));
}

test "strict malformed lengths booleans enums truncation and trailing bytes" {
    const Color = enum(u8) { red = 1, blue = 4 };
    try std.testing.expectError(error.InvalidEncoding, Codec(bool).decode(&.{2}));
    try std.testing.expectError(error.InvalidEncoding, Codec(Color).decode(&.{2}));
    try std.testing.expectError(error.InvalidEncoding, Codec(u16).decode(&.{1}));
    try std.testing.expectError(error.InvalidEncoding, Codec(u16).decode(&.{ 0, 1, 2 }));
    try std.testing.expectError(error.InvalidEncoding, Codec(Bytes(4)).decode(&.{ 0, 0, 0, 5, 1, 2, 3, 4, 5 }));
    try std.testing.expectError(error.InvalidEncoding, Codec(Bytes(4)).decode(&.{ 0, 0, 0, 3, 1, 2 }));
    try std.testing.expectError(error.InvalidEncoding, Codec(Bytes(4)).decode(&.{ 0, 0, 0, 0, 1 }));
    try std.testing.expectError(error.TooLong, Bytes(2).init("abc"));
}

test "bounded bytes canonical padding and length-first order" {
    var short = try Bytes(8).init("z");
    const long = try Bytes(8).init("aa");
    var left: [12]u8 = undefined;
    var right: [12]u8 = undefined;
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, try Codec(Bytes(8)).encode(short, &left), try Codec(Bytes(8)).encode(long, &right)));
    const decoded = try Codec(Bytes(8)).decode(&.{ 0, 0, 0, 1, 'z' });
    try std.testing.expectEqualSlices(u8, "z", decoded.slice());
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0)), decoded.data[1..]);
    short.data[2] = 1;
    try std.testing.expectError(error.NonCanonical, Codec(Bytes(8)).encode(short, &left));
    short.len = 9;
    try std.testing.expectError(error.NonCanonical, Codec(Bytes(8)).encode(short, &left));
}

test "integer encoding preserves signed and unsigned numeric order" {
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        const values = if (@typeInfo(T).int.signedness == .signed)
            [_]T{ std.math.minInt(T), -2, -1, 0, 1, std.math.maxInt(T) }
        else
            [_]T{ 0, 1, 2, 3, 4, std.math.maxInt(T) };
        var previous: [Codec(T).max_size]u8 = @splat(0);
        var current: [Codec(T).max_size]u8 = undefined;
        for (values, 0..) |value, index| {
            const encoded = try Codec(T).encode(value, &current);
            try std.testing.expectEqual(value, try Codec(T).decode(encoded));
            if (index != 0) try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, &previous, encoded));
            @memcpy(&previous, encoded);
        }
    }
    var bytes: [8]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, try Codec(i64).encode(std.math.minInt(i64), &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0x7f, 0xff }, try Codec(i16).encode(-1, &bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0 }, try Codec(i16).encode(0, &bytes));
}
