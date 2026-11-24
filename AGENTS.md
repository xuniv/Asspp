# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Note**: `CLAUDE.md` is a symlink to `AGENTS.md`. Edit `AGENTS.md` directly.

## Project Overview

Asspp is a multi-account App Store management app (iOS + macOS) for searching, downloading, and installing IPA files. It uses an Xcode workspace (`Asspp.xcworkspace`) with SPM dependencies including [ApplePackage](https://github.com/Lakr233/ApplePackage), the core library for App Store API communication, IPA handling, and signature injection.

Bundle ID: `wiki.qaq.Asspp`. Deployment targets: iOS 17.0, macOS 15.0. Supports iPhone, iPad, and Mac (native, not Catalyst). No test targets exist.

## Build Commands

```bash
# Build for iOS (device)
xcodebuild -workspace Asspp.xcworkspace -scheme Asspp -configuration Debug -destination 'generic/platform=iOS' build | xcbeautify

# Build for macOS
xcodebuild -workspace Asspp.xcworkspace -scheme Asspp -configuration Debug -destination 'platform=macOS' build | xcbeautify

# Build for iOS simulator
xcodebuild -workspace Asspp.xcworkspace -scheme Asspp -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 16' build | xcbeautify

# CI release build (iOS IPA, unsigned)
./Resources/Scripts/compile.release.mobile.ci.sh "$(pwd)" "$(pwd)/Asspp.ipa"

# CI release build (macOS zip)
./Resources/Scripts/compile.release.osx.sh "$(pwd)" "$(pwd)/Asspp.zip"
```

**Important**: Always use `Asspp.xcworkspace` (not `.xcodeproj`) because the workspace manages SPM package resolution. Always pipe xcodebuild output through `xcbeautify` to reduce output verbosity and save tokens.

## Code Signing Setup

`Configuration/Developer.xcconfig` is gitignored and must exist for builds. It provides code signing settings:

```
DEVELOPMENT_TEAM = <your team ID>
CODE_SIGN_STYLE = Automatic
CODE_SIGN_IDENTITY = Apple Development
```

A build phase script errors if this file is missing. The CI scripts generate a no-signing version automatically.

## Build Configuration

xcconfig hierarchy: `Debug.xcconfig`/`Release.xcconfig` → `Base.xcconfig` → `Version.xcconfig`, plus `Developer.xcconfig` for signing. Version numbers are in `Configuration/Version.xcconfig` (single source of truth).

## Architecture

### App Entry Point

`Asspp/App/main.swift` — initializes logging (`LogManagerHandler`), configures `ApplePackage` device identifier, sets up `Digger` download manager (max 3 concurrent), and starts the OTA installer on iOS. On iOS 26+, the main view switches to `NewMainView` (new `Tab` API); otherwise `MainView` is used.

### Backend Layer (`Asspp/Backend/`)

- **AppStore/**: `AppStore` singleton manages accounts and device identifier. `AuthenticationService` handles auth using the bundled client Store runtime; `AddAccountView` retains the authenticator across verification-code attempts. `AppPackage`/`AppPackageArchive`/`UserAccount` are model wrappers around ApplePackage types.
- **Downloader/**: `Downloads` singleton manages download queue via `Digger`. `PackageManifest` tracks per-download state and IPA signature injection. Downloads persist to `Documents/Asspp/Packages/`.
- **Installer/**: iOS-only Vapor HTTPS server serving IPA files for OTA installation via `itms-services://` protocol. Uses TLS certs from `Certificates/localhost.qaq.wiki/` bundle.
- **DeviceCTL/**: macOS-only device management via `devicectl` CLI. `DeviceManager` handles app installation to connected iOS devices.
- **LogManager.swift**: Thread-safe log singleton feeding `Settings/LogView`.

### Interface Layer (`Asspp/Interface/`)

SwiftUI views organized by feature: Account, Search, Download, Installed (macOS only), Setting, Welcome. `MainView` uses `NavigationSplitView` sidebar on macOS and `TabView` on iOS.

### Key Patterns

- **Observation**: `AppStore`, `Downloads`, `Installer`, `DeviceManager`, `PackageManifest` all use `@Observable` (not legacy `ObservableObject`).
- **Persistence**: Custom `@PublishedPersist` / `@Persist` property wrappers (in `Extension/PublishedPersist.swift`) back properties to file storage (`Documents/Config/`) or Keychain. Accounts stored in Keychain; downloads and settings use file storage.
- **Platform branching**: Heavy use of `#if os(macOS)` / `#if os(iOS)` / `#if canImport(UIKit)` for platform-specific code paths.
- **Singletons**: `AppStore.this`, `Downloads.this` are `@MainActor` singletons.
- **Localization**: English + Simplified Chinese (zh-Hans) via `.xcstrings` format in `Asspp/App/`.

## Dependencies (SPM via Xcode)

- **ApplePackage** (remote) — App Store protocol, IPA handling
- **Vapor** — HTTPS server for iOS OTA installation
- **Digger** — Download manager with progress/speed tracking
- **Kingfisher** — Async image loading
- **ColorfulX** — Gradient animations (welcome screen)
- **KeychainAccess** — Keychain storage for accounts
- **AnyCodable** — Type-erased Codable values
- **ButtonKit** — Async button actions
- **swift-log** — Structured logging (`logger` global)

## Swift Code Style

- **Indentation**: 4 spaces. Opening brace on same line.
- **Naming**: PascalCase for types, camelCase for properties/methods. PascalCase filenames for types, `+` prefix for extension files.
- **Structure**: Early returns, guard statements for unwrapping, single responsibility per extension.
- **Modern Swift**: `@Observable` macro, `async/await`, `@MainActor`, opaque `some` types.
- **Memory**: `weak`/`unowned` references to break cycles, capture lists in closures.

## Fork protocol and installation rules

- `StoreAuthenticator` and `ModernStore` use the shared client-side ipatool runtime pinned by `Resources/Scripts/prepare.store.runtime.sh`. Keep login, license acquisition, downloads and version operations on this engine; do not restore the legacy ApplePackage transport.
- The bundled native Go/C library runs an ARM64 TCI interpreter on a serialized background queue, without native JIT, jailbreak entitlements, remote scripts or a hosted authentication service. Go opens approved Apple hosts/443 and verifies TLS with its pinned public Mozilla/Apple roots. Keep the stable C bridging header, input/output limits, panic recovery and sanitized diagnostic codes. The OTA installer's separate system/device trust checks remain mandatory.
- Runtime provisioning/account records belong in Keychain only. The disk cache contains only size/hash-verified public Apple images. Package public images at build time as compressed data; never extract large restore images in an iOS WebContent process.
- Read the shared runtime's README before changing the pinned protocol or guest bridge. Retain local state across 2FA, preserve explicit credential/token/license errors and previous storefront/pod values.
- Authentication logs may include fixed runtime diagnostic codes, numeric HTTP status and attempt counts only. Never retain account messages, credentials, cookies, signatures, or redirect queries.
- OTA URLs use `InstallationProtocol.installLink`: the port belongs only in the HTTPS manifest URL. System certificate verification must remain enabled; never add trust-all delegates, custom root anchors to bypass device trust, or ATS-wide exceptions.
- The CA endpoint serves a DER-root `.mobileconfig` with `application/x-apple-aspen-config`; `Installer.certificateURL()` waits for server readiness. Bind both local servers to loopback. Tools lets iOS choose the legacy domain or a per-installation offline identity for `asspp.localhost`. The offline CA signing key is ephemeral and the leaf identity stays in backup-excluded app support. The profile must contain public certificates only; never embed a root private key or personal signing identity.
- Imported IPA files stay separate from downloaded packages/accounts. Stream/copy files without modification, validate only bounded main-app plist metadata, purge imports on restart and after 24 hours, and enforce the 8 GiB cap.
- Run `bash Resources/Scripts/check.authentication-installer.sh` along with download checks. CI is manual only and checks an exact source SHA and configured version before starting one Apple Silicon iOS build. It builds device/simulator libraries once and publishes the same checked IPA artifacts. Mac packages remain an explicit local build option; never restore automatic push, PR, tag or polling builds. Preserve release privacy checks before any artifact publication.

### UnfairPlay

- The portable UnfairPlay engine shares the existing Store Go archive and operation gate. Never link a second Go runtime or use WebContent for native IPA processing. Keep the source pin and licenses in the shared runtime.
- Enrollment models are private Keychain records. Import individual valid models separately from selected registry validation; v1 needs explicit solo selection and macOS SINF conversion uses v2. Never try unrelated enrollments after a crypto failure.
- Downloaded/imported originals remain unchanged. Processed copies live in a private, backup-excluded library until deleted. Interrupted staging is removed at launch. Verification retains no plaintext output artifact. Use fixed errors and safe count/coverage reports, excluding model/key hashes, selectors and upstream private diagnostics.
- Decrypted outputs require subsequent signing. Known account/license stripping does not guarantee complete anonymization. Mac setup, collection, recovery and signing are excluded.
- Synthetic smoke fixtures are generated only for the test application under `NativeRuntime/test-fixtures`. Never package them into the production bundle; release privacy checks reject model/license files and fixture directories.

### Shared runtime build and checks

The generated root `StoreRuntime.bundle` contains compressed public images under `assets`; `NativeRuntime/AssppStoreRuntime.xcframework` supplies static iOS device, iOS simulator and universal macOS slices. Prepare both with `bash Resources/Scripts/prepare.store.runtime.sh`. Xcode force-loads the selected static archive and exports the Unicorn symbols required by its native loader. Run `bash Resources/Scripts/check.store.runtime.sh` on macOS and `bash Resources/Scripts/check.store.runtime.ios.sh` for the iOS simulator: they execute callback/zero-memory regressions and actual SAP, repeated ADI and Store-framework guests through the native C ABI without an Apple account. Release publication requires the iOS simulator check. Swift must never decompress public images or persist account state outside Keychain; retain only safe startup-stage diagnostics.

`Asspp-AltStore.ipa` is a separate English-only copy made by `prepare.alt.ipa.py`, to satisfy xuniv/alt's existing gate. The normal Asspp IPA retains its localizations. Both packages must pass release privacy checks. Alt publication must use alt's existing hash-pinned ingest gate; never bypass its denylist, withdrawal records or signing checks.
