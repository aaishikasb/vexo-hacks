# Inspected dependencies — 14 November 2026

| Component | Exact revision | Verification |
| --- | --- | --- |
| LiteRT-LM Swift 0.19.1 | `7a03724cece417f1724c923b3d527b4319730841` | Resolved, linked in unsigned iPhone and arm64 Simulator builds. Model execution not yet tested. |
| Meta DAT iOS 1.0.1 | `0bd369298eef6a980ad0bdb6c8a5502f2c02a08c` | Physical camera capture passed; SDK reports compatible. |
| Meta sample main | `bbae597cd1c748cd29b9375a1624a8d75b1c9e14` | Inspected; use SDK framework interfaces as API authority. Sample and release API names can differ. |
| Vexo Open Kit | `1e4291e2fa4896b1f603d3d4f0b009c483425da0` | Read contract v1.1 and docs/speech.md. Native parser and synthetic Opus checks pass on Mac. No band connection performed. |
| Pipecat iOS reference | `6a204432df5cd533abb85e0577a7e79dccd93a04` | Packaged Python 3.13.14 and native pydantic-core 2.46.5; embedded Pipecat startup passed on iPhone. Audible Pipecat phrase pending. |
| Official Pipecat main | `1bc2e37b15566cd34bb6941a335ce09c3bbbab8c` | Inspected, NOT a tested mobile runtime pin. Required Apple adapters absent. |

## Pipecat packaging status

Correction: the pinned iOS reference **does contain** its modified Pipecat source
under `pipecat/`, including the Apple adapters and mobile dependency split. The
earlier inspection incorrectly treated official upstream main as the only source.
The vendored fork's `FORK.md` records upstream base
`1f8a513dd79c31f54bbd5b197fa26aefe242deca` and version `1.8.2.dev304`;
the containing reference commit pins the modifications. No additional private
checkout is required. Runtime packaging and Voca’s speech-only native adapter are implemented.
Embedded startup passed on the physical phone. Gemma and full conversation
adapters remain pending.

## Native Opus

Apple AVAudioConverter supports Opus on the development Mac. The synthetic
20 ms silence regression produces a shortened initial buffer due to decoder
priming, then 320 PCM frames at 16 kHz. The adapter preserves actual frame count.
Capture time remains approximate and separate from notification receipt time.
Gaps reset decoder state and invalidate transcript timing; they are not silently
filled with invented speech. Physical iPhone decoding and transcription remain
unverified.

## References

- https://developers.google.com/edge/litert-lm/swift
- https://developers.google.com/edge/litert-lm/models/gemma-4
- https://github.com/facebook/meta-wearables-dat-ios/tree/1.0.1
- https://github.com/VexoAI-Org/vexo-open-kit/tree/1e4291e2fa4896b1f603d3d4f0b009c483425da0
- https://github.com/pipecat-ai/pipecat-build-ios/tree/6a204432df5cd533abb85e0577a7e79dccd93a04
- https://developer.apple.com/documentation/avfaudio/avaudioconverter

Meta camera transport: this Personal Team build uses the documented Bluetooth
Classic path (`com.meta.ar.wearable` external accessory protocol), not Wi-Fi.
See Meta's October 22 response in https://github.com/meta/meta-wearables-dat-ios/issues/354.
The Wi-Fi-declared configuration reproduced `waitingForDevice`; Classic delivered
an actual JPEG on the physical phone. Do not reintroduce Bonjour/local-network
keys without intentionally changing and revalidating the transport.
