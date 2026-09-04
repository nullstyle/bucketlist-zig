"""Compile deliberately invalid consumers and require the intended diagnostic."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
cases = {
    "float": "unsupported",
    "pointer": "unsupported",
    "duplicate_table": "schema table IDs must be unique",
    "oversize_key": "table keys must encode in at most 1024 bytes",
}
with tempfile.TemporaryDirectory(prefix="bucketlist-rejections-") as tmp:
    for name, message in cases.items():
        result = subprocess.run([
            "zig", "build-obj", "--dep", "bucketlist",
            "-Mroot=" + str(root / "tests/rejections" / (name + ".zig")),
            "-Mbucketlist=" + str(root / "src/lib.zig"),
            "--cache-dir", tmp, "-fno-emit-bin",
        ], capture_output=True, text=True)
        if result.returncode == 0 or message.lower() not in result.stderr.lower():
            print(result.stderr)
            raise SystemExit(f"{name}: expected compile rejection containing {message!r}")
print(f"[schema-rejections] {len(cases)} malformed consumers rejected")
