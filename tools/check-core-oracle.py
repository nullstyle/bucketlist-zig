#!/usr/bin/env python3
"""Compile pinned Core schedule bodies in a symbolic adapter; compare fixtures.

This is an opt-in source oracle, not a full stellar-core build. All Git access
is read-only. Extracted code, its license, compiler output and binaries remain
inside a temporary directory and are removed after the check.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
REVISION = "100cc3816c59357df488b17972aa5e2846ead831"
SOURCE = "src/bucket/BucketListBase.cpp"
FUNCTIONS = [
    ("BucketListBase", "shouldMergeWithEmptyCurr"),
    ("BucketListBase", "levelSize"),
    ("BucketListBase", "levelHalf"),
    ("BucketListBase", "levelShouldSpill"),
    ("BucketListBase", "keepTombstoneEntries"),
    ("BucketLevel", "snap"),
    ("BucketLevel", "prepare"),
    ("BucketListBase", "addBatchInternal"),
]


def git_read(core, path):
    return subprocess.check_output(["git", "-C", str(core), "show", f"{REVISION}:{path}"], text=True)


def extract(source, cls, method):
    # Preserve exact source bytes, including comments. Mask strings/comments
    # only in a same-length scratch copy used to locate the matching closing }.
    marker = re.search(r"^" + cls + r"<BucketT>::" + method + r"\(", source, re.MULTILINE)
    if marker is None:
        raise RuntimeError(f"Pinned Core function not found: {cls}::{method}")
    start = source.rfind("template <typename BucketT>", 0, marker.start())
    if start < 0:
        raise RuntimeError("Template prefix missing")
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'',
                    lambda match: " " * len(match.group()), source)
    brace = masked.index("{", marker.end())
    depth = 0
    for pos in range(brace, len(masked)):
        depth += (masked[pos] == "{") - (masked[pos] == "}")
        if depth == 0:
            return source[start:pos + 1]
    raise RuntimeError("Unbalanced source")


def rows_from_frame(encoded):
    data = bytes.fromhex(encoded)
    tag = b"bucketlist.bucket.v1\0"
    assert data.startswith(tag)
    pos = len(tag)

    def take(count):
        nonlocal pos
        result = data[pos:pos + count]
        assert len(result) == count
        pos += count
        return result

    count = int.from_bytes(take(8), "big")
    rows = {}
    for _ in range(count):
        table = take(4)
        key = take(int.from_bytes(take(4), "big"))
        present = take(1)
        assert present in [b"\0", b"\1"]
        value = take(int.from_bytes(take(4), "big")).hex() if present == b"\1" else None
        rows[(table + key).hex()] = value
    assert pos == len(data)
    return rows


def check_geometry(binary, depth):
    output = subprocess.check_output([str(binary), str(depth), "geometry"], text=True)
    checks = 0
    for line in output.splitlines():
        level, n, size, half, spill, empty = map(int, line.split())
        assert size == 4 ** (level + 1)
        assert half == size // 2
        assert bool(spill) == (level < depth - 1 and n % half == 0)
        expected_empty = False
        if level != 0 and level != depth - 1:
            incoming = 2 * 4 ** (level - 1)
            start = n // incoming * incoming
            expected_empty = (start + incoming) % half == 0
        assert bool(empty) == expected_empty
        checks += 1
    return checks


def check_trace(binary, trace, frames):
    input_lines = []
    for step in trace["steps"][1:]:
        rows = frames[step["batch"]]
        input_lines.append(f'{step["sequence"]} {len(rows)}')
        input_lines.extend(f'{key} {value if value is not None else "-"}' for key, value in sorted(rows.items()))
    result = subprocess.run([str(binary), str(trace["depth"])], input="\n".join(input_lines) + "\n",
                            text=True, stdout=subprocess.PIPE, check=True)
    actual = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        sequence, index = map(int, fields[:2])
        role, count = fields[2], int(fields[3])
        assert len(fields) == 4 + max(count, 0) * 2
        rows = None if count == -1 else {fields[i]: None if fields[i + 1] == "-" else fields[i + 1]
                                      for i in range(4, len(fields), 2)}
        actual[(sequence, index, role)] = rows
    checks = 0
    for step in trace["steps"]:
        for index, level in enumerate(step["levels"]):
            for role, letter in [("curr", "c"), ("snap", "s"), ("next", "n")]:
                expected = None if level[role] is None else frames[level[role]]
                key = (step["sequence"], index, letter)
                if actual.pop(key) != expected:
                    raise AssertionError(f'Core schedule mismatch: depth={trace["depth"]} seq={key[0]} level={index} role={role}')
                checks += 1
    assert not actual
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core", type=pathlib.Path, default=ROOT.parent / "stellar-core",
                        help="Read-only Git repository containing the pinned Core objects")
    args = parser.parse_args()
    source = git_read(args.core, SOURCE)
    notice = "\n".join(source.splitlines()[:4]) + "\n\n"
    extracted = notice + "\n\n".join(extract(source, cls, method) for cls, method in FUNCTIONS) + "\n"
    data = json.loads((ROOT / "vectors/reference.json").read_text())
    frames = {frame["hash"]: rows_from_frame(frame["bytes"]) for frame in data["buckets"]}
    with tempfile.TemporaryDirectory(prefix="bucketlist-core-oracle-") as temp:
        temp = pathlib.Path(temp)
        (temp / "core_schedule_extracted.hpp").write_text(extracted)
        (temp / "LICENSE-APACHE.txt").write_text(git_read(args.core, "LICENSE-APACHE.txt"))
        binary = temp / "core-schedule-oracle"
        command = ["mise", "exec", "--", "zig", "c++", "-std=c++17", "-O1",
                   "-I", str(temp), str(ROOT / "tools/core_schedule_oracle.cpp"), "-o", str(binary)]
        subprocess.run(command, cwd=ROOT, check=True)
        geometry_checks = 0
        bucket_checks = 0
        for trace in data["traces"]:
            geometry_checks += check_geometry(binary, trace["depth"])
            bucket_checks += check_trace(binary, trace, frames)
    print(f"Pinned Core schedule oracle passed: {len(FUNCTIONS)} verbatim functions, "
          f"{geometry_checks} geometry cases, {bucket_checks} exact bucket-map comparisons; revision {REVISION}")


if __name__ == "__main__":
    main()
