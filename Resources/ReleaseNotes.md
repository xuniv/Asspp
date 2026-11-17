Run Apple authentication and Store operations in a bundled native interpreter instead of Go/WASM inside WKWebView. The native runtime uses ahead-of-time compiled Go and a C interpreter; no JIT, jailbreak entitlement, hosted signer or remote executable is required. Keep the current ipatool protocol, verified public Apple certificates and account state in Keychain.

Remove WebContent startup, public-image base64 IPC and the browser guest bridge from the app. Preserve explicit authentication/2FA/license errors and existing installation certificate trust requirements. Native SAP, repeated ADI and Store-framework checks gate publication.

Asspp.ipa and the English-only Asspp-AltStore.ipa are unsigned. The AltStore source is https://xuniv.github.io/alt/source.json.
