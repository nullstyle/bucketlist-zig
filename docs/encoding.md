# Canonical schema and record encoding, version 1

This document fixes the byte contract implemented by `src/codec.zig` and
`src/schema.zig`. The BucketList container and its commitments are specified
in [format.md](format.md). These formats are independent of Stellar XDR.

All integers in the description below are big endian. Encodings contain no
alignment bytes, native struct padding, terminators, or implicit Unicode
normalization. A decoder consumes exactly one complete value and rejects any
trailing input. Allocation-free decoding returns owned bounded values.

## Application schemas

```zig
const bucketlist = @import("bucketlist");
const Schema = struct {
    pub const namespace = "example.directory";
    pub const version: u32 = 1;
    pub const tables = .{
        .accounts = bucketlist.Table(1, i16, struct {
            amount: u64,
            active: bool,
        }),
        .names = bucketlist.Table(2, bucketlist.Bytes(8), bool),
    };
};
```

Namespaces are raw byte strings of at most 256 bytes. Versions and table IDs
are unsigned 32-bit integers. Table IDs must be unique. A key's maximum
encoded size is 1024 bytes; a value's maximum is 1 MiB. These limits include
all length prefixes. Both are checked at compile time, alongside supported
types. Table ID zero is permitted. Empty namespaces, empty structs, and
zero-length fixed arrays are permitted; applications should use a meaningful
namespace to separate their commitments.

`Table(id, Key, Value)` declares one table. Internal `Definition(Schema)`
provides `TableName`, `table(comptime name)`, `hash()`, `descriptor_size`, and
`encodeDescriptor(out)`. Table names select the typed API but do not enter the
schema descriptor. Reordering or renaming tables leaves identity unchanged
when IDs and types remain unchanged.

## Record values

`Codec(T).max_size` gives an upper bound for the encoded value.
`Codec(T).encode(value, out)` returns the used slice of `out`, with errors
`NoSpace` or `NonCanonical`. `Codec(T).decode(bytes)` returns a value or
`InvalidEncoding`. Encoding errors may leave partially written output; callers
publish output only after success.

| Zig type | Canonical bytes |
| --- | --- |
| `u8`, `u16`, `u32`, `u64` | The integer in big endian at its declared width. |
| `i8`, `i16`, `i32`, `i64` | Its two's-complement bits with the sign bit flipped, in big endian. |
| `bool` | One byte: `00` for false or `01` for true. Other bytes are invalid. |
| `[N]T` | Exactly N consecutive encodings of T, without a count prefix. |
| Ordinary named-field struct | Its field encodings in declaration order, without a field count or names. |
| Exhaustive `enum(u8/u16/u32/u64)` | The declared numeric tag in big endian at the tag width. Unknown tags are invalid. |
| `Bytes(N)` | An unsigned 32-bit byte length followed by that many raw bytes. The length must be at most N. |

Struct field names, default values, and Zig type names do not affect encoding.
A renamed field with the same position and type has the same wire identity.
Developers must give enum variants stable explicit numeric values: Zig's
reflection exposes the resulting numeric tags but cannot distinguish a
written assignment from an inferred tag. Numeric values, rather than enum
names or declaration order, define identity.

Pointers, slices, floats, optionals, unions, nonexhaustive enums, signed enum
tags, unusual integer widths, tuples, sentinel arrays, packed/extern structs,
and comptime record fields are unsupported and produce compile errors. Plain
arrays can contain any supported type. They are not restricted to bytes.

`Bytes(N).init(bytes)` returns a bounded value or `TooLong`. `slice()` borrows
its active bytes and must not outlive that value. The value's backing storage
is initialized to zero beyond its active length. Decoding preserves this
invariant. Encoding rejects an out-of-bounds length or nonzero unused storage
as `NonCanonical`; unused storage is never serialized. Construct bounded
values with `init` instead of manually filling their representation.

## Key ordering

Keys compare first by numeric table ID, then by unsigned lexicographic order
of the canonical key bytes. Integer encodings preserve numeric order across
the whole signed or unsigned range. Composite keys compare their consecutive
encoded fields; this is byte ordering, not a general language comparator.

Bounded strings compare **length first**, then by their bytes. For example,
`Bytes(8).init("z")` encodes as `000000017a` and sorts before `"aa"`, encoded
as `000000026161`. Fixed byte arrays have ordinary unsigned lexicographic
order. There is no locale, text case folding, or Unicode normalization.

## Structural schema descriptor

The descriptor consists of:

1. `namespace_length:u16` and `namespace:bytes[namespace_length]`.
2. `application_schema_version:u32`.
3. `table_count:u32`.
4. For each table, sorted by ascending numeric table ID:
   `table_id:u32`, the key type descriptor, then the value type descriptor.

Type descriptors recursively use this prefix grammar. Each numeric width is
measured in bits; lengths and counts are unsigned.

| Type | Descriptor |
| --- | --- |
| Unsigned integer | `01 || width:u8` |
| Signed integer | `02 || width:u8` |
| Boolean | `03` |
| Fixed array | `04 || element_count:u32 || element_type` |
| Struct | `05 || field_count:u32 || field_type[0] || ...` in declaration order |
| Enum | `06 || tag_width:u8 || tag_count:u32 || tag[0] || ...` |
| Bounded bytes | `07 || maximum_length:u32` |

Enum tags are sorted by unsigned numeric value, and each uses the enum's
fixed tag width. Variant names and declaration order are absent. Struct field
names and default values are absent. Distinct wire types retain distinct
descriptors even when particular values have identical bytes; for example,
`Bytes(8)` differs from a struct containing a `u32` and `[8]u8`.

Schema identity is exactly:

```text
SHA256(ASCII("BKL-SCHEMA-V1") || descriptor)
```

The ASCII domain is 13 bytes, with no NUL or separate length. The domain
versions this descriptor grammar; the application version is a separate
field. Changes to namespace, application version, table IDs, field layouts,
bounds, or numeric enum tags change schema identity. Such changes need an
application database epoch; automatic migrations are outside this format.

## Literal vectors

Codec vectors:

| Type and value | Hex bytes |
| --- | --- |
| `i16` minimum (-32768) | `0000` |
| `i16` -1 | `7fff` |
| `i16` 0 | `8000` |
| `i16` maximum (32767) | `ffff` |
| `i64` minimum | `0000000000000000` |
| `Bytes(8)` empty | `00000000` |
| `Bytes(8)` "cat" | `00000003636174` |
| `enum(u16) { red = 2, green = 400 }`, green | `0190` |
| Struct `{bool, i16, Bytes(8), enum(u16), [2]u8}`, values `{true, -2, "cat", green, {0xab, 0xcd}}` | `017ffe000000036361740190abcd` |

For namespace `"test"`, application version 1, and tables
`Table(1, i16, struct { amount: u64, active: bool })` and
`Table(2, Bytes(8), bool)`, the complete descriptor is:

```text
0004746573740000000100000002000000010210050000000201400300000002070000000803
```

Its schema hash is:

```text
6328c9fd03834da00fe2f79e3eb271420dbe9707fab449565e2b52fd8335f7b7
```

The literal hash was independently calculated with Python `hashlib.sha256`
from `b"BKL-SCHEMA-V1" + bytes.fromhex(descriptor_hex)`. The tests pin the
literal bytes and hash, including declaration-reorder invariance. The enum
descriptor for tags `{400, 2}` at width 16 is `06100000000200020190`.

Negative vectors rejected by whole-input decoding include boolean `02`,
unknown tag `02` for `enum(u8) { red = 1, blue = 4 }`, truncated `u16` input
`01`, trailing `u16` input `000102`, bounded length overflow
`000000050102030405` for `Bytes(4)`, truncated `Bytes(4)` input
`000000030102`, and trailing empty bounded bytes `0000000001`.
