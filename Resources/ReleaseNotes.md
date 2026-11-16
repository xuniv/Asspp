Fix authentication startup failures in the client interpreter. Newly mapped guest memory is explicitly zero-filled, matching native Unicorn and preventing recycled data from corrupting FairPlay/ADI initialization. Repeated calls to the same host function now invoke its callback every time.

Reduce native asset-decoding memory by removing large intermediate arrays and redundant public-image copies. Keep the iOS interpreter attached to the active window, normalize bundle-path aliases, and cancel stale startup timers. Startup errors and retained logs now distinguish process termination, navigation and timeout stages without including account data.

Release checks include repeated ADI initialization, synthetic callback/memory regressions and a real iOS-simulator WKWebView run. Separate public-network checks exercise verified Apple TLS and SAP signing without an Apple account. Account login and physical-device installation still require device verification.

Asspp.ipa and the English-only Asspp-AltStore.ipa are unsigned. The AltStore source is https://xuniv.github.io/alt/source.json. OTA installation requires the local CA profile and full trust in iOS Settings.
