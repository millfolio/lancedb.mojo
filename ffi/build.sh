#!/bin/bash
#
# Build liblancedbmojo.dylib — the LanceDB FFI shim for lancedb.mojo (mirrors
# zlib.mojo/src/ffi/build.sh, but the shim is a Rust cdylib over the `lancedb`
# crate). cargo builds ffi/ in release, then we install the cdylib into
# $CONDA_PREFIX/lib (the canonical location _find_lib() resolves) and keep a
# build/ copy for bare checkouts. Idempotent-ish: cargo skips unchanged crates.
# Run via `pixi run ffi`.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../ffi
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT/build"

if [ "$(uname)" = "Darwin" ]; then EXT="dylib"; else EXT="so"; fi
ARTIFACT="$SCRIPT_DIR/target/release/liblancedbmojo.$EXT"
TARGET="$BUILD_DIR/liblancedbmojo.$EXT"

echo "building liblancedbmojo.$EXT (cargo release — first build pulls lancedb+arrow, slow)..."
( cd "$SCRIPT_DIR" && cargo build --release )

mkdir -p "$BUILD_DIR"
cp "$ARTIFACT" "$TARGET"

# Make the dylib relocatable so consumers find it via @loader_path regardless of
# cwd, and self-id under @rpath (matches package_headgate.sh's shim handling).
if [ "$(uname)" = "Darwin" ]; then
    install_name_tool -id "@rpath/liblancedbmojo.$EXT" "$TARGET" 2>/dev/null || true
    codesign --force --sign - "$TARGET" 2>/dev/null || true
fi

if [ -n "${CONDA_PREFIX:-}" ]; then
    mkdir -p "$CONDA_PREFIX/lib"
    cp "$TARGET" "$CONDA_PREFIX/lib/liblancedbmojo.$EXT"
    echo "installed: $CONDA_PREFIX/lib/liblancedbmojo.$EXT"
fi
echo "built: $TARGET"
