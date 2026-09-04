"""Build/test an extracted package and standalone consumer without siblings."""
import pathlib
import re
import shutil
import subprocess
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
manifest = (root / "build.zig.zon").read_text()
path_block = re.search(r"\.paths\s*=\s*\.\{([^}]+)\}", manifest).group(1)
paths = re.findall(r'"([^"]+)"', path_block)
ignored = shutil.ignore_patterns(".zig-cache", "zig-out", "zig-pkg", "__pycache__")
with tempfile.TemporaryDirectory(prefix="bucketlist-package-") as scratch:
    # Native stores deliberately reject symlinked path components. macOS's
    # temporary path commonly starts with /var, a symlink to /private/var.
    scratch = pathlib.Path(scratch).resolve()
    staging = scratch / "staging"
    staging.mkdir()
    for name in paths:
        source, dest = root / name, staging / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, dest, ignore=ignored)
        else:
            shutil.copy2(source, dest)
    archive = scratch / "bucketlist.tar.gz"
    with tarfile.open(archive, "w:gz") as tar:
        for entry in sorted(staging.iterdir()):
            tar.add(entry, arcname=entry.name)
    extracted = scratch / "extracted"
    with tarfile.open(archive) as tar:
        tar.extractall(extracted, filter="data")
    subprocess.run(["zig", "build", "test", "-Doptimize=ReleaseSafe", "--summary", "all"], cwd=extracted, check=True)
    subprocess.run(["zig", "build", "run", "--build-file", "examples/directory/build.zig"], cwd=extracted, check=True)
    subprocess.run(
        ["zig", "build", "run", "--build-file", "examples/persistent-directory/build.zig", "--", str(scratch / "native-store")],
        cwd=extracted, check=True,
    )
    package_hash = subprocess.check_output(["zig", "fetch", str(archive)], cwd=scratch, text=True).strip()
    print(f"[package-preflight] clean extracted tests + standalone consumer passed; {package_hash}")
