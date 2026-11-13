## Changes

Apple's authentication route can return an empty or HTML edge response before credentials are checked. The old native authenticator treated these as final errors. OTA installation also opened its link without first checking root-CA trust, while the certificate download URL could still be a startup placeholder. The fixes below address those paths while retaining normal TLS validation.

- Retry transient Apple authentication responses up to eight times, rotating the bag, legacy, and native endpoints with fresh SAP signatures. Honor bounded Retry-After delays and preserve real credential errors and 2FA challenges.
- Preserve storefront and pod routing during account renewal. Keep sensitive Apple messages, cookies, tokens, and redirect URLs out of authentication logs.
- Fix OTA installation links so only the HTTPS manifest URL carries the local server port.
- Use the IPA's actual build version in install manifests and remove stale Xcode target version overrides so release metadata follows `Version.xcconfig`.
- Serve an actual CA configuration profile with the correct MIME type, wait for the certificate server to start, and check system certificate trust and local HTTPS connectivity before opening an install link. Installation servers now bind only to loopback.
- Add a separate Import IPA page. Import XML/binary-plist iOS IPAs without an Apple account, install on this iPhone/iPad or a connected device on macOS, and delete files manually. Imported IPAs remain unchanged, expire after 24 hours, and are removed on restart. Storage is capped at 8 GiB.
- Remove the scheduled upstream signed-build workflow and the unused third-party signing-tool setup. Remaining workflows build, check, and publish unsigned packages without personal signing metadata.

## Certificate setup on iOS

1. In Asspp, choose **Settings > Install Certificate** (also available in the installation sheet).
2. In iOS **Settings > General > VPN & Device Management**, install the **Asspp Local Installation** profile. Replace an older Asspp certificate profile if one is already installed.
3. In **Settings > General > About > Certificate Trust Settings**, enable full trust for **Asspp Local Installation CA**.
4. Return to Asspp and choose **Retry Installation**. Allow local network access. If your DNS/VPN blocks private-address DNS results, allow `app.localhost.qaq.wiki` to resolve to `127.0.0.1`.

Installing the profile alone does not enable full trust. TLS certificate verification remains enabled; the app does not bypass iOS trust settings.

## Artifacts

`Asspp.ipa` is unsigned and must be signed using your own preferred installation method before running Asspp. That application signature is separate from the local HTTPS CA above. IPAs imported into Asspp also need valid signing and any required App Store license; this release does not resign or decrypt them.

Automated checks cover protocol classification, URL allowlists, CA profile contents, bundled certificate validity/hostname/key matching, builds, and artifact privacy. Live Apple-account authentication and physical-device OTA installation are not verified by CI.
