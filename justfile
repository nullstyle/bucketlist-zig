# Check the installed compiler against this repo's mise pin.
doctor:
    #!/usr/bin/env sh
    set -eu
    want="$(mise current zig)"
    have="$(mise exec -- zig version)"
    test "$want" = "$have" || { echo "Zig mismatch: wanted $want, got $have"; exit 1; }
    echo "Zig: $have"
    mise exec -- just --version

# Unit/property/fixture tests, storage tests, and two-table example.
test:
    mise exec -- zig build test --summary all

fmt:
    mise exec -- zig fmt build.zig build.zig.zon src tests tools/*.zig examples/directory examples/persistent-directory

fmt-check:
    mise exec -- zig fmt --check build.zig build.zig.zon src tests tools/*.zig examples/directory examples/persistent-directory

vectors:
    mise exec -- zig build vectors

vectors-check:
    mise exec -- zig build vectors-check

wasm-diff:
    mise exec -- zig build wasm-diff

example-smoke:
    mise exec -- zig build example-smoke

persistent-example-smoke:
    mise exec -- zig build persistent-example-smoke

slcp-smoke:
    mise exec -- bash tools/slcp-smoke.sh

ci-lint:
    mise exec -- actionlint .github/workflows/*.yml

package-preflight:
    mise exec -- python3 tools/package-preflight.py

# Optional: execute native Linux checks in a disposable Docker container.
linux-check:
    bash tools/linux-check.sh

# Optional: execute original pinned Core scheduling functions in isolated shims.
core-oracle:
    mise exec -- python3 tools/check-core-oracle.py

preflight: doctor fmt-check ci-lint vectors-check test wasm-diff
    mise exec -- zig build test -Doptimize=ReleaseSafe --summary all
    mise exec -- zig build check -Dtarget=x86_64-linux --summary all
    mise exec -- python3 tools/package-preflight.py
