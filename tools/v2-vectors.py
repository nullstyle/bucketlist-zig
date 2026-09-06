#!/usr/bin/env python3
"""Independent v2 block-format model (docs/format-v2.md).

Emits the literal vectors embedded in src/proofs.zig. hashlib only; shares
no code with the implementation. Regenerate there, never hand-edit.
"""
import hashlib


def u32(n):
    return n.to_bytes(4, "big")


def u64(n):
    return n.to_bytes(8, "big")


def sha(*parts):
    h = hashlib.sha256()
    for p in parts:
        h.update(p)
    return h.digest()


def frame(table, key, value):
    body = u32(table) + u32(len(key)) + key
    if value is None:
        return body + b"\x00", 9 + len(key)
    return body + b"\x01" + u32(len(value)) + value, 13 + len(key) + len(value)


def tree_root(leaves):
    peaks = []  # (span, hash), largest first, rightmost appended at the end
    for leaf in leaves:
        peaks.append((1, leaf))
        while len(peaks) >= 2 and peaks[-1][0] == peaks[-2][0]:
            (span, left), (_, right) = peaks[-2], peaks[-1]
            peaks[-2:] = [(span * 2, sha(b"bucketlist.blocknode.v2\x00", left, right))]
    acc = peaks[0][1]
    for _, h in peaks[1:]:
        acc = sha(b"bucketlist.blocknode.v2\x00", acc, h)
    return acc


def bucket_hash(records, target):
    block_hashes = []
    cur = b""
    cur_len = 0
    for record in records:
        framed, size = frame(*record)
        if cur_len == 0:
            cur = b""
        cur += framed
        cur_len += size
        if cur_len >= target:
            block_hashes.append(sha(b"bucketlist.block.v2\x00", u64(len(block_hashes)), cur))
            cur = b""
            cur_len = 0
    if cur_len > 0:
        # The final block may be shorter; close it after the stream ends.
        block_hashes.append(sha(b"bucketlist.block.v2\x00", u64(len(block_hashes)), cur))
        cur = b""
        cur_len = 0
    block_root = (
        sha(b"bucketlist.block.v2.empty\x00") if not block_hashes else tree_root(block_hashes)
    )
    return sha(
        b"bucketlist.bucket.v2\x00",
        u64(len(records)),
        u64(len(block_hashes)),
        block_root,
    )


def stream(count, parity, target):
    records = [
        (1, u32(2 * i + parity), u32(i)) for i in range(count)
    ]
    return bucket_hash(records, target)


def main():
    cases = [
        (0, 0, 128),
        (1, 0, 128),
        (7, 0, 128),
        (8, 0, 128),
        (100, 0, 128),
        (100, 1, 128),
        (100, 0, 21),
        (1000, 0, 65536),
    ]
    for count, parity, target in cases:
        print(f"stream({count}, {parity}, {target}): {stream(count, parity, target).hex()}")


if __name__ == "__main__":
    main()


def h32(hexstr):
    return bytes.fromhex(hexstr)


def chain_digest(schema_hex, profile_hex, seq, levels):
    """The v1-chain commitment recomputation: identical composition for v1 and
    v2 profiles given the profile hash. levels = [(curr, snap, next|None)]."""
    schema, profile = h32(schema_hex), h32(profile_hex)
    level_hashes = [
        sha(b"bucketlist.level.v1\x00", i.to_bytes(4, "big"), h32(c), h32(s))
        for i, (c, s, _) in enumerate(levels)
    ]
    list_root = sha(b"bucketlist.list.v1\x00", profile, *level_hashes)
    cont = hashlib.sha256()
    cont.update(b"bucketlist.continuation.v1\x00")
    cont.update(profile)
    for i, (_, _, nxt) in enumerate(levels):
        cont.update(i.to_bytes(4, "big"))
        cont.update(b"\x01" if nxt is not None else b"\x00")
        if nxt is not None:
            cont.update(h32(nxt))
    db = hashlib.sha256()
    db.update(b"bucketlist.database.v1\x00")
    db.update(schema)
    db.update(profile)
    db.update(seq.to_bytes(8, "big"))
    db.update(list_root)
    db.update(cont.digest())
    return db.digest()


def chain_cases():
    """Deterministic level fixtures for the Zig parity test."""
    import hashlib as _h

    def fake(seed):
        return _h.sha256(seed.to_bytes(4, "big")).hexdigest()

    case_a = [(fake(10 * i + 1), fake(10 * i + 2), None) for i in range(11)]
    case_b = [(fake(20 * i + 1), fake(20 * i + 2), fake(20 * i + 3) if i == 4 else None) for i in range(11)]
    schema = fake(900)
    profile = fake(901)
    for name, seq, levels in (("a", 5, case_a), ("b", 70, case_b)):
        print(f"chain {name}: {chain_digest(schema, profile, seq, levels).hex()}")


if __name__ == "__main__":
    main()
    chain_cases()
