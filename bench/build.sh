#!/bin/sh
# Compiles the other implementations. Needs a C compiler, cargo, go, and npm,
# and the location of yyjson's source as $1. Binaries go in $2.
set -eu
yyjson=$1
bin=$2
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$bin"

cc -O3 -flto -I"$yyjson/src" "$here/compare/c/main.c" "$yyjson/src/yyjson.c" -o "$bin/yyjson"
(cd "$here/compare/rust" && CARGO_TARGET_DIR="$bin/rust-target" RUSTFLAGS="-C target-cpu=native" cargo build --release --quiet)
cp "$bin/rust-target/release/bench-json-patch" "$bin/rust"
(cd "$here/compare/go" && go mod tidy && go build -o "$bin/go" .)
(cd "$here/compare/node" && npm install --silent)
