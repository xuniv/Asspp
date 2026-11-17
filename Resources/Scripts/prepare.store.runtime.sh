#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
# Pin reviewed native runtime sources; public assets retain their independent hashes.
revision=081f107df9669f0efa47581b46a98c062ae1b892
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source_root="${ASSPP_NATIVE_SOURCE:-}"
if [[ -z "$source_root" ]]; then
  source_root="$work/source"
  mkdir -p "$source_root"
  curl --fail --location --retry 3 --silent --show-error \
    "https://codeload.github.com/xuniv/AssppWeb/tar.gz/$revision" -o "$work/source.tar.gz"
  tar -xzf "$work/source.tar.gz" --strip-components=1 -C "$source_root"
fi
for tool in go cmake xcrun python3 git; do command -v "$tool" >/dev/null; done
mkdir -p "$repo_root/NativeRuntime" "$repo_root/StoreRuntime.bundle"
git init -q "$work/ipatool"
git -C "$work/ipatool" fetch -q --depth 1 https://github.com/majd/ipatool.git b352566155a667d8aaeabaa7ecec4966080f92ab
git -C "$work/ipatool" checkout -q --detach FETCH_HEAD
git init -q "$work/unfairplay"
git -C "$work/unfairplay" fetch -q --depth 1 https://github.com/DrWhax/unfairplay.git d7503082a59e3dcfdd3ea7a70434dcecaaaf07df
git -C "$work/unfairplay" checkout -q --detach FETCH_HEAD
export UNFAIRPLAY_SOURCE="$work/unfairplay"
export ASSPP_UNFAIRPLAY_FIXTURES=1
for target in ${ASSPP_NATIVE_TARGETS:-ios-arm64 ios-simulator-arm64 macos-arm64 macos-amd64}; do
  export IPATOOL_SOURCE="$work/ipatool"
  export ASSPP_NATIVE_WORK="$work/build-$target"
  if [[ "$target" == ios-arm64 ]]; then export ASSPP_NATIVE_SKIP_ASSETS=0; else export ASSPP_NATIVE_SKIP_ASSETS=1; fi
  bash "$source_root/runtime/native/build.sh" "$work/output-$target" "$target"
done
framework="$repo_root/NativeRuntime/AssppStoreRuntime.xcframework"
if [[ -d "$framework" ]]; then rm -rf "$framework"; fi
framework_args=(-library "$work/output-ios-arm64/libAssppStoreRuntime.a" -headers "$work/output-ios-arm64/include"
  -library "$work/output-ios-simulator-arm64/libAssppStoreRuntime.a" -headers "$work/output-ios-simulator-arm64/include")
if [[ -f "$work/output-macos-arm64/libAssppStoreRuntime.a" && -f "$work/output-macos-amd64/libAssppStoreRuntime.a" ]]; then
  mkdir -p "$work/output-macos"
  xcrun lipo -create "$work/output-macos-arm64/libAssppStoreRuntime.a" "$work/output-macos-amd64/libAssppStoreRuntime.a" -output "$work/output-macos/libAssppStoreRuntime.a"
  framework_args+=(-library "$work/output-macos/libAssppStoreRuntime.a" -headers "$work/output-macos-arm64/include")
fi
xcodebuild -create-xcframework "${framework_args[@]}" -output "$framework"
test -f "$work/output-ios-arm64/test-fixtures/input.ipa"
rm -rf "$repo_root/NativeRuntime/test-fixtures"
cp -R "$work/output-ios-arm64/test-fixtures" "$repo_root/NativeRuntime/test-fixtures"
cp -R "$work/output-ios-arm64/assets" "$repo_root/StoreRuntime.bundle/"
cp -R "$work/output-ios-arm64/licenses" "$repo_root/StoreRuntime.bundle/"
cp "$work/output-ios-arm64/upstream-revision.txt" "$repo_root/StoreRuntime.bundle/"
# Discard obsolete generated WebContent resources when upgrading an existing checkout.
rm -f "$repo_root/StoreRuntime.bundle/runtime.wasm" "$repo_root/StoreRuntime.bundle/store-runtime.js" "$repo_root/StoreRuntime.bundle/index.html"
printf '%s\n' "$revision" > "$repo_root/NativeRuntime/source-revision.txt"
