#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/StoreRuntimeSmoke.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R "$root/StoreRuntime.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.asspp.runtime-check</string><key>CFBundleName</key><string>StoreRuntimeSmoke</string><key>CFBundleExecutable</key><string>StoreRuntimeSmoke</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
swiftc -parse-as-library -swift-version 5 \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntime.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeAssets.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeSockets.swift" \
    "$root/Resources/Tests/StoreRuntimeSmoke.swift" \
    -o "$app/Contents/MacOS/StoreRuntimeSmoke"
"$app/Contents/MacOS/StoreRuntimeSmoke"
