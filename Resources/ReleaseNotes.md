Reduce client interpreter memory pressure that could terminate WebContent on an iPhone or reload a browser tab.

Public Apple images now stream through bounded 64 KiB reads directly into the hash-verifying Go loader. The app transfers the runtime binary in bounded chunks too. Reuse Go/JS staging buffers, release callback registrations when guests close, and collect external JS references at operation boundaries. Keep guest callbacks delivered exactly once when a shared-page write must retry an instruction. Guest code pages use exact-content sharing with copy-on-write isolation as soon as each guest loads, before preparing sibling guests. Heap growth and per-guest translation buffers are bounded. SAP no longer crosses into JavaScript merely to count every instruction.

Tests now measure peak WebContent RSS as well as WASM linear memory, and cover cross-guest host/CPU write isolation, zero-filled recycled RAM, repeated ADI initialization and actual SAP signing. The optional public-network probe exercises full Anisette provisioning without an Apple ID and discards all generated proofs and state. Real account login and physical-device installation still require device verification.

Asspp.ipa and the English-only Asspp-AltStore.ipa are unsigned. The AltStore source is https://xuniv.github.io/alt/source.json. Existing OTA installation certificate trust requirements are unchanged.
