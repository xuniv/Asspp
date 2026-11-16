#!/usr/bin/env python3
"""Make the English-only source package required by xuniv/alt's existing gate."""
import pathlib
import plistlib
import re
import shutil
import stat
import sys
import zipfile

source, destination = map(pathlib.Path, sys.argv[1:])
english = re.compile(r'^(?:en(?:[-_][A-Za-z0-9]+)*|English|Base)\.lproj$', re.I)
with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
    for entry in sorted(original.infolist(), key=lambda item: item.filename):
        if any(part.endswith('.lproj') and not english.fullmatch(part) for part in entry.filename.split('/')):
            continue
        target = zipfile.ZipInfo(entry.filename, (1980, 1, 1, 0, 0, 0))
        target.create_system = 3
        mode = (entry.external_attr >> 16) & 0o777
        target.external_attr = ((stat.S_IFDIR | 0o755) if entry.is_dir() else (stat.S_IFREG | (0o755 if mode & 0o111 else 0o644))) << 16
        target.compress_type = zipfile.ZIP_DEFLATED
        if entry.filename.endswith('/Info.plist') and entry.file_size <= 4 * 1024 * 1024:
            data = original.read(entry)
            value = plistlib.loads(data)
            if 'CFBundleLocalizations' in value:
                value['CFBundleLocalizations'] = [language for language in value['CFBundleLocalizations'] if english.fullmatch(language + '.lproj')]
                data = plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=False)
            output.writestr(target, data)
        else:
            with original.open(entry) as reader, output.open(target, 'w') as writer:
                shutil.copyfileobj(reader, writer, length=1024 * 1024)
