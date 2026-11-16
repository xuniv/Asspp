#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d)"
device=""
cleanup() {
  if [ -n "$device" ]; then xcrun simctl delete "$device" >/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
app="$work/StoreRuntimeSmoke.app"
mkdir -p "$app"
cp -R "$root/StoreRuntime.bundle" "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.asspp.runtime-check</string><key>CFBundleName</key><string>StoreRuntimeSmoke</string><key>CFBundleExecutable</key><string>StoreRuntimeSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntime.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeAssets.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeSockets.swift" \
    "$root/Resources/Tests/StoreRuntimeSmoke.swift" \
    -o "$app/StoreRuntimeSmoke"
codesign --force --sign - "$app"
runtime="$(xcrun simctl list runtimes --json | python3 -c 'import json,sys; print(next(r["identifier"] for r in reversed(json.load(sys.stdin)["runtimes"]) if r.get("isAvailable") and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")))')"
device="$(xcrun simctl create AssppRuntimeCheck com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$runtime")"
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "$app"
python3 - "$device" <<'PY'
import subprocess,sys
result = subprocess.run(['xcrun','simctl','launch','--terminate-running-process','--console-pty',sys.argv[1],'example.asspp.runtime-check'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=480)
print(result.stdout)
if 'Asspp runtime checks passed' not in result.stdout:
    raise SystemExit('iOS WKWebView runtime check failed')
PY
