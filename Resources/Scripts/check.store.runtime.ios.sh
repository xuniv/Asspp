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
selection="$(python3 - <<'PY'
import json,re,subprocess
try:
    listed=subprocess.run(['xcrun','simctl','list','--json'],capture_output=True,text=True,timeout=90)
except subprocess.TimeoutExpired:
    raise SystemExit('simulator-list-timeout')
if listed.returncode:
    raise SystemExit('simulator-list-failed')
inventory=json.loads(listed.stdout)
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
PY
)"
runtime="${selection%%$'\n'*}"
device_type="${selection#*$'\n'}"
device="$(python3 - "$device_type" "$runtime" <<'PY'
import subprocess,sys,uuid
try:
    created=subprocess.run(['xcrun','simctl','create','AssppRuntimeCheck',sys.argv[1],sys.argv[2]],capture_output=True,text=True,timeout=90)
except subprocess.TimeoutExpired:
    raise SystemExit('simulator-create-timeout')
if created.returncode:
    raise SystemExit('simulator-create-failed')
print(uuid.UUID(created.stdout.strip()))
PY
)"
echo "Booting $device_type with $runtime"
container="$(python3 - "$device" "$app" <<'PY'
import pathlib,re,subprocess,sys
device,app=sys.argv[1:]
class ReadinessFailure(Exception):
    def __init__(self,code,shutdown405=False):
        super().__init__(code)
        self.shutdown405=shutdown405
def command(phase,args,timeout):
    print('iOS simulator: '+phase, file=sys.stderr, flush=True)
    try:
        result=subprocess.run(['xcrun','simctl',*args],capture_output=True,text=True,timeout=timeout)
    except subprocess.TimeoutExpired:
        raise ReadinessFailure('simulator-'+phase+'-timeout') from None
    if result.returncode:
        shutdown405=bool(re.search(r'domain=com\.apple\.CoreSimulator\.SimError,\s*code=405\)',result.stderr)
                         and re.search(r'Unable to lookup in current state:\s*Shutdown(?:\s|$)',result.stderr))
        raise ReadinessFailure('simulator-'+phase+'-failed exit='+str(result.returncode),shutdown405)
    return result.stdout.strip()
try:
    for attempt in range(2):
        try:
            # This UUID was freshly created; do not overload CoreSimulator
            # with extra state-list queries between the successful commands.
            command('boot',['boot',device],240)
            # Never use -b: all boots must stay within this owned-device budget.
            command('bootstatus',['bootstatus',device],240)
            command('install',['install',device,app],300)
            container=command('container',['get_app_container',device,'example.asspp.runtime-check','data'],120)
            if not pathlib.Path(container).is_absolute():
                raise ReadinessFailure('simulator-container-invalid')
            print(container)
            break
        except ReadinessFailure as error:
            # One infra recovery only for the owned command's exact 405/Shutdown.
            # No native check, authentication call or other failure is retried.
            if attempt==0 and error.shutdown405:
                print(str(error)+'; simulator-shutdown-recovery-once',file=sys.stderr,flush=True)
                continue
            raise
except ReadinessFailure as error:
    raise SystemExit(str(error)) from None
PY
)"
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
        if process.poll() is not None:
            # Re-read after exit to catch the app's final atomic status write.
            status = result.read_text() if result.exists() else ''
            if status == 'passed':
                break
            raise SystemExit('iOS native Store runtime app exited before passing')
        time.sleep(0.5)
    else:
        raise SystemExit('iOS native Store runtime check timed out')
finally:
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)
    reader.join(timeout=5)
PY
