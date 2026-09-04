//! Stable structural schema identity, independent of Zig type and table names.
const std = @import("std");
const codec = @import("codec.zig");

pub const max_key_size = 1024;
pub const max_value_size = 1024 * 1024;
pub const max_namespace_size = 256;
pub const hash_domain = "BKL-SCHEMA-V1";

pub fn Table(comptime table_id: u32, comptime K: type, comptime V: type) type {
    if (codec.Codec(K).max_size > max_key_size) @compileError("table keys must encode in at most 1024 bytes");
    if (codec.Codec(V).max_size > max_value_size) @compileError("table values must encode in at most 1 MiB");
    return struct {
        pub const id = table_id;
        pub const Key = K;
        pub const Value = V;
    };
}

/// Validates a schema at compile time and provides its stable descriptor/hash.
pub fn Definition(comptime Schema: type) type {
    if (@typeInfo(Schema) != .@"struct") @compileError("Schema must be a struct declaring namespace, version, and tables");
    if (!@hasDecl(Schema, "namespace") or !@hasDecl(Schema, "version") or !@hasDecl(Schema, "tables"))
        @compileError("Schema must declare namespace, version, and tables");
    const namespace_bytes: []const u8 = Schema.namespace;
    if (namespace_bytes.len > max_namespace_size) @compileError("schema namespace must contain at most 256 bytes");
    const schema_version: u32 = Schema.version;
    const Tables = @TypeOf(Schema.tables);
    if (@typeInfo(Tables) != .@"struct" or @typeInfo(Tables).@"struct".is_tuple)
        @compileError("Schema.tables must be a named-field struct value of Table types");
    const names = std.meta.fieldNames(Tables);
    if (names.len > std.math.maxInt(u32)) @compileError("schema table count must fit in u32");
    for (names, 0..) |name, index| {
        const T = @field(Schema.tables, name);
        if (@TypeOf(T) != type or @typeInfo(T) != .@"struct") @compileError("Schema.tables fields must be Table types");
        if (!@hasDecl(T, "id") or !@hasDecl(T, "Key") or !@hasDecl(T, "Value"))
            @compileError("Schema.tables fields must be Table types");
        if (T != Table(T.id, T.Key, T.Value)) @compileError("Schema.tables fields must use bucketlist.Table");
        for (names[0..index]) |previous| {
            if (T.id == @field(Schema.tables, previous).id) @compileError("schema table IDs must be unique");
        }
    }
    const sorted_names = sortNames(Schema, names);
    return struct {
        pub const TableName = std.meta.FieldEnum(Tables);
        pub const namespace = namespace_bytes;
        pub const version = schema_version;
        pub const table_count = names.len;
        pub const descriptor_size = descriptorSize(Schema, sorted_names);

        pub fn table(comptime name: TableName) type {
            return @field(Schema.tables, @tagName(name));
        }

        pub fn encodeDescriptor(out: []u8) error{NoSpace}![]const u8 {
            if (out.len < descriptor_size) return error.NoSpace;
            var writer: BufferWriter = .{ .out = out };
            try writeDescriptor(Schema, sorted_names, &writer);
            return out[0..writer.position];
        }

        pub fn hash() [32]u8 {
            const result = comptime blk: {
                @setEvalBranchQuota(1_000_000);
                var writer: HashWriter = .{};
                writer.hasher.update(hash_domain);
                writeDescriptor(Schema, sorted_names, &writer) catch unreachable;
                break :blk writer.hasher.finalResult();
            };
            return result;
        }
    };
}

fn sortNames(comptime Schema: type, comptime names: []const [:0]const u8) [names.len][:0]const u8 {
    var result: [names.len][:0]const u8 = undefined;
    @memcpy(&result, names);
    for (0..result.len) |index| {
        var cursor = index;
        while (cursor > 0 and @field(Schema.tables, result[cursor]).id < @field(Schema.tables, result[cursor - 1]).id) : (cursor -= 1) {
            std.mem.swap([:0]const u8, &result[cursor], &result[cursor - 1]);
        }
    }
    return result;
}

fn descriptorSize(comptime Schema: type, comptime names: anytype) usize {
    var size: usize = 2 + Schema.namespace.len + 4 + 4;
    for (names) |name| {
        const T = @field(Schema.tables, name);
        size += 4 + typeDescriptorSize(T.Key) + typeDescriptorSize(T.Value);
    }
    return size;
}

fn typeDescriptorSize(comptime T: type) usize {
    if (codec.bytesBound(T) != null) return 5;
    return switch (@typeInfo(T)) {
        .int => 2,
        .bool => 1,
        .array => |info| 5 + typeDescriptorSize(info.child),
        .@"struct" => |info| blk: {
            var size: usize = 5;
            for (info.field_types) |Field| size += typeDescriptorSize(Field);
            break :blk size;
        },
        .@"enum" => |info| 6 + info.field_values.len * (@typeInfo(info.tag_type).int.bits / 8),
        else => unreachable,
    };
}

const BufferWriter = struct {
    out: []u8,
    position: usize = 0,

    fn write(self: *BufferWriter, bytes: []const u8) error{NoSpace}!void {
        if (bytes.len > self.out.len - self.position) return error.NoSpace;
        @memcpy(self.out[self.position..][0..bytes.len], bytes);
        self.position += bytes.len;
    }
};

const HashWriter = struct {
    hasher: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn write(self: *HashWriter, bytes: []const u8) error{NoSpace}!void {
        self.hasher.update(bytes);
    }
};

fn writeUnsigned(comptime T: type, value: T, writer: anytype) error{NoSpace}!void {
    var buffer: [@bitSizeOf(T) / 8]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try writer.write(&buffer);
}

fn writeDescriptor(comptime Schema: type, comptime names: anytype, writer: anytype) error{NoSpace}!void {
    try writeUnsigned(u16, Schema.namespace.len, writer);
    try writer.write(Schema.namespace);
    try writeUnsigned(u32, Schema.version, writer);
    try writeUnsigned(u32, names.len, writer);
    inline for (names) |name| {
        const T = @field(Schema.tables, name);
        try writeUnsigned(u32, T.id, writer);
        try writeTypeDescriptor(T.Key, writer);
        try writeTypeDescriptor(T.Value, writer);
    }
}

fn sortedEnumTags(comptime T: type) [@typeInfo(T).@"enum".field_values.len]@typeInfo(T).@"enum".tag_type {
    const info = @typeInfo(T).@"enum";
    var tags: [info.field_values.len]info.tag_type = undefined;
    for (info.field_values, 0..) |value, index| tags[index] = value;
    std.mem.sort(info.tag_type, &tags, {}, std.sort.asc(info.tag_type));
    return tags;
}

fn writeTypeDescriptor(comptime T: type, writer: anytype) error{NoSpace}!void {
    if (comptime codec.bytesBound(T)) |bound| {
        try writer.write(&.{7});
        try writeUnsigned(u32, bound, writer);
        return;
    }
    switch (@typeInfo(T)) {
        .int => |info| try writer.write(&.{ if (info.signedness == .unsigned) 1 else 2, info.bits }),
        .bool => try writer.write(&.{3}),
        .array => |info| {
            try writer.write(&.{4});
            try writeUnsigned(u32, info.len, writer);
            try writeTypeDescriptor(info.child, writer);
        },
        .@"struct" => |info| {
            try writer.write(&.{5});
            try writeUnsigned(u32, info.field_types.len, writer);
            inline for (info.field_types) |Field| try writeTypeDescriptor(Field, writer);
        },
        .@"enum" => |info| {
            try writer.write(&.{ 6, @typeInfo(info.tag_type).int.bits });
            const tags = comptime sortedEnumTags(T);
            try writeUnsigned(u32, tags.len, writer);
            for (tags) |tag| try writeUnsigned(info.tag_type, tag, writer);
        },
        else => unreachable,
    }
}

const LiteralSchema = struct {
    pub const namespace = "test";
    pub const version = 1;
    pub const tables = .{
        .names = Table(2, codec.Bytes(8), bool),
        .accounts = Table(1, i16, struct { amount: u64, active: bool }),
    };
};

test "literal descriptor binds sorted IDs and structural field types" {
    const D = Definition(LiteralSchema);
    const expected = [_]u8{
        0, 4, 't', 'e', 's', 't', // namespace
        0, 0, 0, 1, // version
        0, 0, 0, 2, // table count
        0, 0, 0, 1, 2, 16, // table 1, signed 16-bit key
        5, 0, 0, 0, 2, 1, 64, 3, // struct {u64, bool}
        0, 0, 0, 2, 7, 0, 0, 0, 8, 3, // table 2, Bytes(8), bool
    };
    var buffer: [D.descriptor_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &expected, try D.encodeDescriptor(&buffer));
    try std.testing.expectError(error.NoSpace, D.encodeDescriptor(buffer[0 .. buffer.len - 1]));
    try std.testing.expect(D.table(.names).Key == codec.Bytes(8));
    // Independent Python hashlib SHA256 over the documented literal preimage.
    const expected_hash = [_]u8{ 0x63, 0x28, 0xc9, 0xfd, 0x03, 0x83, 0x4d, 0xa0, 0x0f, 0xe2, 0xf7, 0x9e, 0x3e, 0xb2, 0x71, 0x42, 0x0d, 0xbe, 0x97, 0x07, 0xfa, 0xb4, 0x49, 0x56, 0x5e, 0x2b, 0x52, 0xfd, 0x83, 0x35, 0xf7, 0xb7 };
    try std.testing.expectEqualSlices(u8, &expected_hash, &D.hash());
}

test "schema identity ignores table and type names but binds namespace version and layout" {
    const Reordered = struct {
        pub const namespace = LiteralSchema.namespace;
        pub const version = LiteralSchema.version;
        pub const tables = .{
            .renamed = Table(1, i16, struct { renamed_amount: u64, renamed_active: bool }),
            .directory = Table(2, codec.Bytes(8), bool),
        };
    };
    const NamespaceChange = struct {
        pub const namespace = "other";
        pub const version = LiteralSchema.version;
        pub const tables = LiteralSchema.tables;
    };
    const VersionChange = struct {
        pub const namespace = LiteralSchema.namespace;
        pub const version = 2;
        pub const tables = LiteralSchema.tables;
    };
    const LayoutChange = struct {
        pub const namespace = LiteralSchema.namespace;
        pub const version = LiteralSchema.version;
        pub const tables = .{
            .accounts = Table(1, i16, struct { active: bool, amount: u64 }),
            .names = Table(2, codec.Bytes(8), bool),
        };
    };
    try std.testing.expectEqualSlices(u8, &Definition(LiteralSchema).hash(), &Definition(Reordered).hash());
    try std.testing.expect(!std.mem.eql(u8, &Definition(LiteralSchema).hash(), &Definition(NamespaceChange).hash()));
    try std.testing.expect(!std.mem.eql(u8, &Definition(LiteralSchema).hash(), &Definition(VersionChange).hash()));
    try std.testing.expect(!std.mem.eql(u8, &Definition(LiteralSchema).hash(), &Definition(LayoutChange).hash()));
}

test "enum descriptors bind numeric tags independent of tag names and order" {
    const A = enum(u16) { late = 400, early = 2 };
    const B = enum(u16) { renamed_early = 2, renamed_late = 400 };
    var left: [typeDescriptorSize(A)]u8 = undefined;
    var right: [typeDescriptorSize(B)]u8 = undefined;
    var lw: BufferWriter = .{ .out = &left };
    var rw: BufferWriter = .{ .out = &right };
    try writeTypeDescriptor(A, &lw);
    try writeTypeDescriptor(B, &rw);
    try std.testing.expectEqualSlices(u8, &.{ 6, 16, 0, 0, 0, 2, 0, 2, 1, 0x90 }, &left);
    try std.testing.expectEqualSlices(u8, &left, &right);
}
