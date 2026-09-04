#!/usr/bin/env python3
"""Independent v1 executable specification; never imports or executes Zig.

Generate fixtures with `mise exec -- python tools/reference.py` and verify with
`--check`. The dictionary-based model deliberately uses explicit lookahead and
full logical maps, unlike production merge cursors and immutable ownership.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import struct


ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMESPACE = "bucketlist.vectors"
VERSION = 1
ADVANCES = 128


def u16(value):
    return struct.pack(">H", value)


def u32(value):
    return struct.pack(">I", value)


def u64(value):
    return struct.pack(">Q", value)


def signed(value, bits):
    return (value + (1 << (bits - 1))).to_bytes(bits // 8, "big")


def digest(data):
    return hashlib.sha256(data).digest()


def schema_descriptor():
    # Table 1: key i16, value struct {balance:i64,active:bool}.
    # Table 2: key Bytes(8), value u64. Table declaration names are not encoded.
    return (u16(len(NAMESPACE)) + NAMESPACE.encode() + u32(VERSION) + u32(2)
            + u32(1) + bytes([2, 16, 5]) + u32(2) + bytes([2, 64, 3])
            + u32(2) + bytes([7]) + u32(8) + bytes([1, 64]))


SCHEMA_HASH = digest(b"BKL-SCHEMA-V1" + schema_descriptor())


def encode_bucket(rows):
    result = b"bucketlist.bucket.v1\0" + u64(len(rows))
    for (table, key), value in sorted(rows.items()):
        result += u32(table) + u32(len(key)) + key
        result += b"\0" if value is None else b"\1" + u32(len(value)) + value
    return result


def bucket_hash(rows):
    return digest(encode_bucket(rows))


def merge(older, newer, terminal):
    result = dict(older)
    result.update(newer)
    if terminal:
        result = {key: value for key, value in result.items() if value is not None}
    return result


def account(key, balance, active=True):
    return {"kind": "put_account", "account": key, "balance": balance, "active": active}


def delete_account(key):
    return {"kind": "delete_account", "account": key}


def name(key, owner):
    return {"kind": "put_name", "name_hex": key.hex(), "owner": owner}


def delete_name(key):
    return {"kind": "delete_name", "name_hex": key.hex()}


def operations(sequence):
    n = sequence
    match n % 10:
        case 0:
            return []
        case 1:
            return [account(-(n % 17), n * 100, n % 3 != 0), name(b"a\0" + bytes([n % 5]), n)]
        case 2:
            return [account(-((n - 1) % 17), -n, False), name(b"", 0)]
        case 3:
            return [delete_account(-((n - 2) % 17)), delete_name(b"a\0" + bytes([(n - 2) % 5]))]
        case 4:
            return [account(n % 17, 1), delete_account(n % 17), account(0, n)]
        case 5:
            return [account(0, n - 1), delete_name(b"missing")]
        case 6:
            return [name(b"a", n), name(b"a\0", n + 1), name(b"a\xff", n + 2)]
        case 7:
            return [account(-32768, -(1 << 63)), account(32767, (1 << 63) - 1, False), name(b"abcdefgh", (1 << 64) - 1)]
        case 8:
            return [delete_account(-32768), account(-32768, -(1 << 63)), delete_name(b"")]
        case 9:
            return [delete_account(32767), name(b"a", n), delete_account(0), account(0, n, False)]
    raise AssertionError("unreachable")


def encode_operations(ops):
    # Explicit call-order last-write wins, before comparison with the base map.
    rows = {}
    for op in ops:
        if op["kind"].endswith("account"):
            key = (1, signed(op["account"], 16))
            value = signed(op["balance"], 64) + bytes([op["active"]]) if op["kind"] == "put_account" else None
        else:
            raw_key = bytes.fromhex(op["name_hex"])
            key = (2, u32(len(raw_key)) + raw_key)
            value = u64(op["owner"]) if op["kind"] == "put_name" else None
        rows[key] = value
    return rows


class Model:
    def __init__(self, depth):
        self.depth = depth
        self.sequence = 0
        self.levels = [{"curr": {}, "snap": {}, "next": None} for _ in range(depth)]
        self.logical = {}
        self.profile = digest(b"bucketlist.profile.v1\0" + u32(depth) + u32(4))

    def advance(self, ops):
        n = self.sequence + 1
        rows = {key: value for key, value in encode_operations(ops).items()
                if self.logical.get(key) != value}
        for i in reversed(range(1, self.depth)):
            incoming_interval = 2 * 4 ** (i - 1)
            if n % incoming_interval:
                continue
            source, dest = self.levels[i - 1], self.levels[i]
            source["snap"], source["curr"] = source["curr"], {}
            if dest["next"] is not None:
                dest["curr"] = dest["next"]
            next_incoming = n + incoming_interval
            destination_will_spill = i != self.depth - 1 and next_incoming % (2 * 4 ** i) == 0
            older = {} if destination_will_spill else dest["curr"]
            dest["next"] = merge(older, source["snap"], i == self.depth - 1)
        self.levels[0]["curr"] = merge(self.levels[0]["curr"], rows, self.depth == 1)
        self.logical = merge(self.logical, rows, True)
        self.sequence = n
        visible = {}
        for level in self.levels:
            for role in ["curr", "snap"]:
                for key, value in level[role].items():
                    visible.setdefault(key, value)
        assert {key: value for key, value in visible.items() if value is not None} == self.logical
        return rows

    def hashes(self):
        level_hashes = [digest(b"bucketlist.level.v1\0" + u32(i) + bucket_hash(level["curr"]) + bucket_hash(level["snap"]))
                        for i, level in enumerate(self.levels)]
        root = digest(b"bucketlist.list.v1\0" + self.profile + b"".join(level_hashes))
        pending = b"".join(u32(i) + (b"\0" if level["next"] is None else b"\1" + bucket_hash(level["next"]))
                           for i, level in enumerate(self.levels))
        continuation = digest(b"bucketlist.continuation.v1\0" + self.profile + pending)
        database = digest(b"bucketlist.database.v1\0" + SCHEMA_HASH + self.profile
                          + u64(self.sequence) + root + continuation)
        return root, continuation, database


def corpus():
    frames = {}
    traces = []

    def remember(rows):
        encoded = encode_bucket(rows)
        h = digest(encoded).hex()
        frames[h] = encoded.hex()
        return h

    for depth in [1, 2, 3, 11]:
        model = Model(depth)
        steps = []
        history = bytearray()
        for n in range(ADVANCES + 1):
            batch = {} if n == 0 else model.advance(operations(n))
            root, continuation, database = model.hashes()
            history.extend(database)
            steps.append({
                "sequence": n,
                "batch": remember(batch),
                "root": root.hex(),
                "continuation": continuation.hex(),
                "database": database.hex(),
                "levels": [{role: remember(rows) if rows is not None else None
                            for role, rows in level.items()} for level in model.levels],
            })
        traces.append({"depth": depth, "profile": model.profile.hex(), "steps": steps,
                       "aggregate": digest(history).hex()})
    return {
        "format": "bucketlist-zig-independent-v1",
        "namespace": NAMESPACE,
        "version": VERSION,
        "schema_descriptor": schema_descriptor().hex(),
        "schema_hash": SCHEMA_HASH.hex(),
        "operations": [[]] + [operations(n) for n in range(1, ADVANCES + 1)],
        "buckets": [{"hash": h, "bytes": encoded} for h, encoded in sorted(frames.items())],
        "traces": traces,
    }


def zig_bytes(data):
    return '"' + ''.join(f"\\x{byte:02x}" for byte in data) + '"'


def zig_fixture(data):
    out = ["// Generated by tools/reference.py. Regenerate; do not edit manually.",
           "// zig fmt: off",
           "pub const Operation = struct { kind: enum { put_account, delete_account, put_name, delete_name }, account: i16 = 0, balance: i64 = 0, active: bool = false, name: []const u8 = \"\", owner: u64 = 0 };",
           "pub const Level = struct { curr: usize, snap: usize, next: ?usize };",
           "pub const Step = struct { sequence: u64, batch: usize, root: []const u8, continuation: []const u8, database: []const u8, levels: []const Level };",
           "pub const Trace = struct { depth: usize, profile: []const u8, aggregate: []const u8, steps: []const Step };",
           "pub const Frame = struct { hash: []const u8, bytes: []const u8 };",
           f'pub const namespace = "{NAMESPACE}";',
           f"pub const version: u32 = {VERSION};",
           f'pub const schema_hash = "{data["schema_hash"]}";',
           "pub const schema_descriptor = " + zig_bytes(bytes.fromhex(data["schema_descriptor"])) + ";",
           "pub const operations = [_][]const Operation{"]
    for ops in data["operations"]:
        out.append("    &.{")
        for op in ops:
            fields = [".kind = ." + op["kind"]]
            for key, value in op.items():
                if key == "kind":
                    continue
                if key == "name_hex":
                    fields.append(".name = " + zig_bytes(bytes.fromhex(value)))
                else:
                    fields.append("." + key + " = " + (str(value).lower() if isinstance(value, bool) else str(value)))
            out.append("        .{ " + ", ".join(fields) + " },")
        out.append("    },")
    out.append("};\npub const buckets = [_]Frame{")
    for frame in data["buckets"]:
        out.append(f'    .{{ .hash = "{frame["hash"]}", .bytes = {zig_bytes(bytes.fromhex(frame["bytes"]))} }},')
    out.append("};\npub const traces = [_]Trace{")
    indexes = {frame["hash"]: i for i, frame in enumerate(data["buckets"])}
    for trace in data["traces"]:
        out.append(f'    .{{ .depth = {trace["depth"]}, .profile = "{trace["profile"]}", .aggregate = "{trace["aggregate"]}", .steps = &.{{')
        for step in trace["steps"]:
            out.append(f'        .{{ .sequence = {step["sequence"]}, .batch = {indexes[step["batch"]]}, .root = "{step["root"]}", .continuation = "{step["continuation"]}", .database = "{step["database"]}", .levels = &.{{')
            for level in step["levels"]:
                out.append("            .{ " + ", ".join("." + role + " = " + ("null" if h is None else str(indexes[h])) for role, h in level.items()) + " },")
            out.append("        } },")
        out.append("    } },")
    out.append("};\n")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if checked-in fixtures differ")
    args = parser.parse_args()
    data = corpus()
    files = {
        ROOT / "vectors/reference.json": json.dumps(data, indent=2, ensure_ascii=True) + "\n",
        ROOT / "vectors/reference.zig": zig_fixture(data),
    }
    for path, content in files.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit(f"Reference fixture drift: {path.relative_to(ROOT)}; regenerate with tools/reference.py")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print(f"Reference fixtures {'verified' if args.check else 'generated'}: {len(data['buckets'])} buckets, "
          f"{len(data['traces'])} profiles, {ADVANCES} advances each")


if __name__ == "__main__":
    main()
