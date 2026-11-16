#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
work="$(mktemp -d)"
device=""
cleanup() {
  if [ -n "$device" ]; then
    python3 - "$device" <<'PY'
import subprocess,sys
for action in ['shutdown','delete']:
    try:
        subprocess.run(['xcrun','simctl',action,sys.argv[1]],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
    except subprocess.TimeoutExpired:
        print('Simulator cleanup exceeded its time limit',flush=True)
PY
  fi
  rm -rf "$work"
}
trap cleanup EXIT
app="$work/StoreRuntimeSmoke.app"
mkdir -p "$app"
cp -R "$root/StoreRuntime.bundle" "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.asspp.runtime-check</string><key>CFBundleName</key><string>StoreRuntimeSmoke</string><key>CFBundleExecutable</key><string>StoreRuntimeSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$simulator_sdk" xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
    "$root/Asspp/Backend/AppStore/StoreDiagnostics.swift" \
    -target "$(uname -m)-apple-ios17.0-simulator" -sdk "$simulator_sdk" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntime.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeAssets.swift" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntimeSockets.swift" \
    "$root/Resources/Tests/StoreRuntimeSmoke.swift" \
    -o "$app/StoreRuntimeSmoke"
codesign --force --sign - "$app"
selection="$(xcrun simctl list --json | python3 -c '
import json,re,sys
inventory=json.load(sys.stdin)
types={item["identifier"] for item in inventory["devicetypes"]}
for device in ["com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max","com.apple.CoreSimulator.SimDeviceType.iPhone-16"]:
    choices=[r for r in inventory["runtimes"] if r.get("isAvailable")
             and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
             and device in types
             and device in {d["identifier"] if isinstance(d,dict) else d for d in r.get("supportedDeviceTypes",[])}]
    if choices:
        print(max(choices,key=lambda r:tuple(map(int,re.findall(r"\d+",r["version"]))))["identifier"])
        print(device)
        break
else:
    raise SystemExit("No compatible iPhone simulator runtime is installed")
')"
runtime="${selection%%$'\n'*}"
device_type="${selection#*$'\n'}"
device="$(xcrun simctl create AssppRuntimeCheck "$device_type" "$runtime")"
echo "Booting $device_type with $runtime"
xcrun simctl boot "$device"
python3 - "$device" <<'PY'
import subprocess,sys
subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=240)
PY
xcrun simctl install "$device" "$app"
echo 'Starting the bundled WKWebView checks'
python3 - "$device" <<'PY'
import subprocess,sys,threading
process = subprocess.Popen(['xcrun','simctl','launch','--terminate-running-process','--console-pty',sys.argv[1],'example.asspp.runtime-check'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
lines = []
def report():
    for line in process.stdout:
        print(line,end='',flush=True)
        lines.append(line)
reader = threading.Thread(target=report,daemon=True)
reader.start()
try:
    process.wait(timeout=720)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait()
    reader.join(timeout=5)
    raise SystemExit('iOS WKWebView runtime check timed out')
reader.join(timeout=5)
if 'Asspp runtime checks passed' not in ''.join(lines):
    raise SystemExit('iOS WKWebView runtime check failed')
PY
