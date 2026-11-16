#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
# Updated only after the shared client runtime passes its browser checks.
revision=78fa38dd41bb0e9878571c0072c7900afb3f8488
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/source"
curl --fail --location --retry 3 --silent --show-error \
  "https://codeload.github.com/xuniv/AssppWeb/tar.gz/$revision" -o "$work/source.tar.gz"
tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$work/source"
npm install --prefix "$work/js" --save-exact --ignore-scripts --no-audit --no-fund esbuild@0.25.12
ESBUILD="$work/js/node_modules/.bin/esbuild" bash "$work/source/runtime/build.sh" "$repo_root/StoreRuntime.bundle"
