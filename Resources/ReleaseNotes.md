Run Apple authentication and Store downloads locally with the modern ipatool ARM64 runtime, including SAP, Anisette, Store AMD and KBSync. The sideloaded app needs no hosted authentication server or JIT entitlement. Public Apple images are packaged as verified compressed data to reduce first-run memory use.

Login, license acquisition, downloads and version lookups now share the same protocol engine. Sign in to existing accounts again once after upgrading. Preserve explicit authentication/license errors and accept legacy iOS packages that omit platform declarations.

The release includes Asspp.ipa and an English-only Asspp-AltStore.ipa for the gated AltStore source at https://xuniv.github.io/alt/source.json. Both are unsigned and must be signed when sideloading. OTA installation still requires installing the local CA profile and enabling full trust in iOS Settings.

Validation includes Chromium/WebKit interpreter checks, a native WKWebView smoke check, installer/certificate regressions, unsigned iOS/macOS builds and release privacy checks. Live account login and physical-device installation require device verification.
