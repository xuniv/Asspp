#!/usr/bin/env python3
"""Reject personal build metadata and signing assets before publishing Asspp."""

import hashlib
import json
import plistlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


# Public SAP resources from Lakr233/ApplePackage 2.0.3, read from the exact
# Package.resolved commit, Sources/ApplePackage/SAP/Resources. Updating that
# dependency requires reviewing these identities again; filenames alone do
# not distinguish public lookup tables from private enrollment models.
APPLE_PACKAGE_REVISION = "773583a29c6b1f1b0d0783d0a15d3ddafcd85eec"
APPLE_PACKAGE_TABLE_HASHES = {
    "f2-tables.bin": "f811dd378e1e8e05a9d3697111c4fb1d4afe2acdf81a1fcde69fe231bc975876",
    "word-tables.bin": "6eeffb5e403a54a3b51baa67cf0b7abc23271da404fef4cae9e06c9753833340",
    "carry-masks.bin": "f0396c6119faafecc811c33a61433faacbfb685d157f198da920183b240285d0",
    "byte-tables.bin": "a40bb580f1012b06b8b257926b76bb02ec98033f6399da2143c963d36dbe0aae",
}
PUBLIC_SAP_TABLES = {
    bundle + name: digest
    for bundle in (
        "Payload/Asspp.app/ApplePackage_ApplePackage.bundle/",
        "Asspp.app/Contents/Resources/ApplePackage_ApplePackage.bundle/Contents/Resources/",
    )
    for name, digest in APPLE_PACKAGE_TABLE_HASHES.items()
}


def check(archive):
    resolved = Path(__file__).resolve().parents[2] / "Asspp.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    apple_package = [pin for pin in json.loads(resolved.read_text())["pins"] if pin["identity"] == "applepackage"]
    if len(apple_package) != 1 or apple_package[0]["state"]["revision"] != APPLE_PACKAGE_REVISION:
        raise ValueError("public SAP table allowlist does not match the pinned ApplePackage revision")
    with tempfile.TemporaryDirectory(prefix="asspp-release-check-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(archive) as package:
            for item in package.infolist():
                path = Path(item.filename)
                content = None
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError("unsafe archive path")
                if path.suffix.lower() in {".mobileprovision", ".provisionprofile", ".p12", ".p8"}:
                    raise ValueError("archive contains provisioning or signing assets")
                if path.name in {"Developer.xcconfig", "rootCA-key.pem", "OfflineIdentity.plist"}:
                    raise ValueError("archive contains local developer configuration or a CA private key")
                if path.suffix.lower() in {
                    ".bin", ".snapshot", ".capture", ".sinf", ".supf", ".supp", ".sidb", ".sids"
                } or any(part in path.parts for part in ("UnfairPlayFixtures", "test-fixtures", "SC_Info", "ProcessedIPAs")):
                    expected_hash = PUBLIC_SAP_TABLES.get(item.filename)
                    if expected_hash is None or item.is_dir():
                        raise ValueError("archive contains an enrollment model, private license or smoke fixture")
                    content = package.read(item)
                    if hashlib.sha256(content).hexdigest() != expected_hash:
                        raise ValueError("public SAP table does not match its pinned identity")
                if not item.is_dir():
                    if content is None:
                        content = package.read(item)
                    if re.search(rb"/Users/(?!runner(?:admin)?/|Shared/)[A-Za-z0-9._-]+/", content):
                        raise ValueError("archive contains a personal home directory path")
            package.extractall(root)

        apps = list(root.glob("Asspp.app")) + list(root.glob("Payload/Asspp.app"))
        if len(apps) != 1:
            raise ValueError("expected one Asspp application")
        app = apps[0]
        info = app / "Contents/Info.plist" if (app / "Contents").exists() else app / "Info.plist"
        metadata = plistlib.loads(info.read_bytes())
        version_config = Path(__file__).resolve().parents[2] / "Configuration/Version.xcconfig"
        version = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", version_config.read_text(), re.MULTILINE).group(1)
        if metadata.get("CFBundleShortVersionString") != version:
            raise ValueError("application version does not match Version.xcconfig")
        if os.environ.get("GITHUB_REF_TYPE") == "tag" and os.environ.get("GITHUB_REF_NAME") != version:
            raise ValueError("release tag does not match the application version")
        if any(key in metadata for key in ("TeamIdentifier", "ApplicationIdentifierPrefix", "DeveloperName")):
            raise ValueError("application metadata contains a developer identity")

        signature = subprocess.run(
            ["codesign", "--display", "--verbose=4", str(app)], capture_output=True, text=True
        )
        for line in signature.stderr.splitlines():
            if line.startswith("TeamIdentifier=") and line != "TeamIdentifier=not set":
                raise ValueError("application contains a signing team")
            if line.startswith("Authority="):
                raise ValueError("application contains a developer signing certificate")
        if signature.returncode and "not signed at all" not in signature.stderr:
            raise ValueError("unable to inspect application signature")

        for certificate in app.rglob("*.pem"):
            if "-key" in certificate.stem:
                continue  # The local TLS server requires its bundled leaf key.
            result = subprocess.run(
                ["openssl", "x509", "-in", str(certificate), "-noout", "-subject", "-issuer"],
                capture_output=True, text=True,
            )
            if result.returncode or "@" in result.stdout or "/Users/" in result.stdout:
                raise ValueError("certificate contains personal metadata or cannot be inspected")
        print(f"{Path(archive).name}: release privacy checks passed")


if __name__ == "__main__":
    for argument in sys.argv[1:]:
        check(argument)
