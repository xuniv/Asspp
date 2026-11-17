#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'The native arm64 iOS simulator check requires an Apple Silicon runner.' >&2
  exit 1
fi
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
native="$root/NativeRuntime/AssppStoreRuntime.xcframework/ios-arm64-simulator"
test -f "$native/libAssppStoreRuntime.a"
test -f "$native/Headers/AssppStoreRuntime.h"
mkdir -p "$app"
cp -R "$root/StoreRuntime.bundle" "$app/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>example.asspp.runtime-check</string><key>CFBundleName</key><string>StoreRuntimeSmoke</string><key>CFBundleExecutable</key><string>StoreRuntimeSmoke</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSRequiresIPhoneOS</key><true/><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/><key>UISceneConfigurations</key><dict><key>UIWindowSceneSessionRoleApplication</key><array><dict><key>UISceneConfigurationName</key><string>RuntimeCheck</string><key>UISceneDelegateClassName</key><string>StoreRuntimeSmoke.StoreRuntimeSmokeSceneDelegate</string></dict></array></dict></dict><key>UILaunchScreen</key><dict/></dict></plist>
PLIST
simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDKROOT="$simulator_sdk" xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
    "$root/Asspp/Backend/AppStore/StoreDiagnostics.swift" \
    -target "arm64-apple-ios17.0-simulator" -sdk "$simulator_sdk" \
    -import-objc-header "$native/Headers/AssppStoreRuntime.h" \
    "$root/Asspp/Backend/StoreRuntime/StoreRuntime.swift" \
    "$root/Resources/Tests/StoreRuntimeSmoke.swift" \
    -Xlinker -force_load -Xlinker "$native/libAssppStoreRuntime.a" \
    -Xlinker -export_dynamic -lresolv -lz -framework Security -framework CoreFoundation \
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
container="$(xcrun simctl get_app_container "$device" example.asspp.runtime-check data)"
result_file="$container/Documents/runtime-smoke-result.txt"
rm -f "$result_file"
echo 'Starting the native Store runtime checks'
python3 - "$device" "$result_file" <<'PY'
import pathlib,subprocess,sys,threading,time
result = pathlib.Path(sys.argv[2])
process = subprocess.Popen(['xcrun','simctl','launch','--terminate-running-process','--console',sys.argv[1],'example.asspp.runtime-check'], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
def report():
    for line in process.stdout:
        print(line,end='',flush=True)
reader = threading.Thread(target=report,daemon=True)
reader.start()
started = time.monotonic()
previous = ''
try:
    while time.monotonic()-started < 720:
        status = result.read_text() if result.exists() else ''
        if status != previous:
            print('iOS check status: '+status,flush=True)
            previous = status
        if status == 'passed':
            break
        if status.startswith('failed:'):
            raise SystemExit('iOS native Store runtime check failed: '+status)
        if not status and process.poll() is not None and time.monotonic()-started > 45:
            raise SystemExit('iOS check app exited before its scene started')
        time.sleep(0.5)
    else:
        raise SystemExit('iOS native Store runtime check timed out')
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    reader.join(timeout=5)
PY
