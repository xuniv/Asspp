#!/bin/bash
set -euo pipefail
xcode_path=$(python3 - <<'PY'
import glob, plistlib, re
from pathlib import Path
choices = []
for path in glob.glob('/Applications/Xcode*.app'):
    if any(marker in path.lower() for marker in ('beta', '_rc')):
        continue
    with (Path(path) / 'Contents/Info.plist').open('rb') as stream:
        version = plistlib.load(stream)['CFBundleShortVersionString']
    choices.append((tuple(int(n) for n in re.findall(r'\d+', version)), path))
if not choices:
    raise SystemExit('No non-beta Xcode is installed')
print(max(choices)[1])
PY
)
sudo xcode-select -s "$xcode_path"
xcodebuild -version
