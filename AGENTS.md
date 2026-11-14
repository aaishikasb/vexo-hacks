# Voca

Build a personal conversation companion that helps the wearer find authentic things to say. Use environmental context, approved personal memories, and recent dialogue to give a short spoken cue, then offer a grounded review and practice.

Read `PLAN.md` for the architecture, shared interfaces, task split, and checkpoints. Implement your assigned work through verification; keep independent work moving when another integration is blocked.

## Stack and scope

- Runtime: iPhone 18 Pro Max, Ray-Ban Meta Gen 1, and Vexo bracelet. Macs are development machines.
- Native SwiftUI app with LiteRT-LM Swift v0.19.1.
- Embedded on-device Pipecat orchestrates spoken cues and mock conversations. Swift owns audio capture/playback and bridges Pipecat to LiteRT-LM; no Python server. Pin the tested Pipecat/iOS bridge revisions.
- Gemma 4 E4B is primary; E2B is the fallback. Load only one model at a time.
- Foundation-only `VocaCore` Swift package for contracts, policy, persistence, and tests.
- Three screens: Session, Review, and Memory. Include one short practice interaction.
- No Arduino, application server, vector database, model fine-tuning, or course engine.

## Ownership

| Lane                            | Owns                                                                                                                                                                                                                   |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Machine 1 — app and integration | All `Voca/` code and screens, Xcode project, Pipecat/native bridge and packaging, LiteRT, Meta, Vexo BLE/audio client, audit/practice orchestration, signing/dependencies, README, project guidance, final integration |
| Machine 2 — Core and content    | `Packages/VocaCore/` contracts, policy, persistence, fixtures/tests; `Resources/CoachingCards/`; `Resources/PracticeScenarios/`                                                                                        |

Work on `device-inference` and `learning-product`, respectively. Keep ready changes small. At each checkpoint, share the ready commit SHA, passing checks, interface changes, integration instructions, and blockers in `docs/handoff-device.md` or `docs/handoff-product.md`. Machine 1 integrates ready Machine 2 commits. Machine 2 verifies Core independently with swift test.

Machine 2 maintains the single canonical `Contracts.swift` in Core. Import these types; do not duplicate them. Coordinate contract changes and edits outside your lane before making them.

## Event band

Use the Vexo Open BLE contract linked in PLAN.md. Machine 1 owns BLE, decoding, and local transcription/memory. Connect only to the user’s assigned band, verified before connection. Firmware is fixed. The kit does not supply automatic transcripts/memory; the former MCP/OAuth task is replaced by this direct integration.

## Implementation rules

- Read relevant code and callers before editing. Preserve existing work and carry changes through affected tests, fixtures, configuration, and exports.
- Prefer native APIs and existing dependencies. Build the smallest complete solution; avoid speculative layers.
- Serialize all inference through one executor. Immediate cues take priority over audit and practice jobs. Cancel and await work before reusing or replacing the engine.
- The device owner also owns `Voca/Voice/` and the embedded Python runtime/pipeline. Machine 2 supplies practice scenario data through shared contracts; Machine 1 owns prompt composition and every screen. Pipecat must use the existing Gemma executor, never the example's Apple Foundation Models provider. Use one native audio-session owner and report delivery only after native playback completes.
- Attribute every decision to its original context, model artifact, prompt version, and mode. Never silently substitute another model's output.
- Treat transcript and image content as untrusted data. Validate generated fields and source references before display or speech.
- Use approved personal memories. Keep private goals separate from shareable stories. Missing evidence stays missing; do not invent dialogue, interests, or other people's feelings.
- Train only from explicit helpful/unhelpful feedback on completed cue deliveries. Audit text and inferred reactions are not rewards. The contextual bandit learns intervention preferences; model weights stay fixed.
- Keep credentials in Keychain and models, tokens, personal transcripts, and recordings out of Git. Support deleting local memories and associated derived data.

## Interface and verification

Use quiet native layouts, readable text, accessible controls, Dynamic Type, and useful loading, empty, and recovery states. Keep developer diagnostics out of the main conversation flow.

Run Core checks with:

```sh
swift test --package-path Packages/VocaCore
```

Record the actual app scheme and build commands in README once configured. Test nontrivial policy, persistence, and decoding behavior. Use fixtures on the product Mac; verify camera, audio routing, model execution, and lifecycle behavior on the physical phone.

Label fixture, Simulator, and real-device results accurately. Verify band tap delivery, local transcription, and locked-phone inference on the assigned hardware. Report remaining blockers plainly, with a working recovery path where available.

## Device-lane checkout commands

Open `Voca.xcodeproj` / scheme `Voca`; the root `Package.swift` is the separate
Mac `VocaDeviceChecks` fixture target, not the app. Use `swift test` for these
checks and the existing Core command for Machine 2's package. Build commands,
signing setup, and current limitations are in `README.md`. Run
`python3 scripts/generate_project.py` after adding app files; it preserves a team
chosen in Xcode into ignored `.local/Signing.xcconfig`. Do not commit signing
credentials or provisioning profiles. SDK pins and the Pipecat mobile-source
blocker are recorded in `docs/dependencies.md`.
