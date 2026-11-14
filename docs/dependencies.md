# Inspected dependencies — 14 November 2026

| Component | Exact revision | Verification |
| --- | --- | --- |
| LiteRT-LM Swift 0.19.1 | `7a03724cece417f1724c923b3d527b4319730841` | Resolved, linked in unsigned iPhone and arm64 Simulator builds. Model execution not yet tested. |
| Meta DAT iOS 1.0.1 | `0bd369298eef6a980ad0bdb6c8a5502f2c02a08c` | Resolved, camera integration compiles. Glasses compatibility not yet tested. |
| Meta sample main | `bbae597cd1c748cd29b9375a1624a8d75b1c9e14` | Inspected; use SDK framework interfaces as API authority. Sample and release API names can differ. |
| Vexo Open Kit | `1e4291e2fa4896b1f603d3d4f0b009c483425da0` | Read contract v1.1 and docs/speech.md. Native parser and synthetic Opus checks pass on Mac. No band connection performed. |
| Pipecat iOS reference | `6a204432df5cd533abb85e0577a7e79dccd93a04` | Architecture, runtime and packaging inspected; NOT packaged or runtime-tested. |
| Official Pipecat main | `1bc2e37b15566cd34bb6941a335ce09c3bbbab8c` | Inspected, NOT a tested mobile runtime pin. Required Apple adapters absent. |

## Pipecat packaging blocker

The iOS reference README requires a “modified pipecat/ checkout”. Its bot imports
`pipecat.services.apple.bridge`, `.llm`, `.stt`, `.tts`,
`pipecat.audio.vad.apple`, and `pipecat.transports.apple`. These are not in the
inspected official Pipecat main checkout, and the iOS reference does not include
or pin that modified checkout. The user does not have a separate copy.

Using the published pipeline classes is not yet a drop-in solution: importing
`frames` imports VAD, which imports `audio.utils`, which imports native numpy,
loudness, and Pipecat resamplers. These require a deliberate mobile dependency
split or iOS builds; desktop wheels must not be copied into the phone app.
The official reference's small dependency closure assumes its unpublished
modifications. No Foundation Models, PocketTTS, cloud, or server fallback is used.

Next implementation: obtain the matching mobile patch or implement and test a
mobile dependency split plus native bridge in a pinned fork, then cross-build
Python and pydantic-core, bundle/sign extensions, and connect Swift's existing
LiteRT executor and native playback. This remains implementation work, not a
completed integration. The native phrase button deliberately states that it does
not verify Pipecat or record a coaching delivery.

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
