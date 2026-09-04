"""Compare compiler-reported interface shapes, ignoring anonymous type IDs."""
import argparse
import difflib
import pathlib
import re
import subprocess

p = argparse.ArgumentParser()
p.add_argument("executable")
p.add_argument("snapshot", type=pathlib.Path)
p.add_argument("--update", action="store_true")
args = p.parse_args()
result = subprocess.run([args.executable], capture_output=True, text=True, check=True)
actual = re.sub(r"__(struct|enum|union)_\d+", r"__\1_ANON", result.stdout + result.stderr)
if args.update:
    args.snapshot.parent.mkdir(parents=True, exist_ok=True)
    args.snapshot.write_text(actual)
else:
    expected = args.snapshot.read_text()
    if actual != expected:
        print("".join(difflib.unified_diff(expected.splitlines(True), actual.splitlines(True), fromfile=str(args.snapshot), tofile="current API")))
        raise SystemExit(1)
    print("[check-api] Experimental public interface matches snapshot")
