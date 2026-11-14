# Machine 2 handoff — Core and coaching content

## Ready changes

- Foundation-only Swift package at `Packages/VocaCore` with canonical public contracts, `ModelGenerating`, `VoiceCoordinating`, content models, and a serialized `CoachEngine` actor.
- `CoachEngine` freezes the canonical ten features and eligibility at selection; keys LinUCB history by model ID, artifact SHA-256, prompt version, and mode; persists pending decisions and cue/delivery/feedback atomically; enforces immutable terminal delivery; and replays corrected feedback in only the affected namespace.
- Evidence deletion API: `deleteEvidence(sourceID:)` (with `invalidateEvidence(sourceID:)` as a compatibility spelling). It removes complete affected episodes so transcript/memory text and their cue/reward derivations disappear from persisted history, replays remaining policy state, and blocks stale snapshots from reusing that source ID.
- Labelled synthetic fixtures in `VocaFixtures` cover unknown speaker, stale/gapped dialogue, duplicate tap IDs, and interrupted delivery.
- Compact coaching catalog and three simulated practice scenarios are in the owned `Resources/` directories. `CoachingContent.decode(cards:scenarios:)` checks unique IDs, HTTPS source links, and scenario principle references.

## Public integration signatures

```swift
public init(storeURL: URL) throws
public func selectCue(_ context: CueContext, explore: Bool,
                      excluding: Strategy? = nil) throws -> CueDecision?
public func recordDelivery(decisionID: UUID, cue: CueResult?,
                           status: DeliveryStatus) throws
public func applyFeedback(_ event: FeedbackEvent) throws
public func episodes() -> [Episode]
public func deleteEvidence(sourceID: String) throws
public func invalidateEvidence(sourceID: String) throws // compatibility alias
public static func features(for context: CueContext) -> [Double]
```

Actor calls are `await`ed by app clients. Construct one engine from the durable local store URL. `recordDelivery` requires the generated cue for `.completed`; failed and cancelled deliveries may pass `cue: nil`. Repeating the same terminal status and cue is idempotent; a conflicting terminal event throws. Feedback must match a completed cue and the frozen profile. Feedback corrections require a strictly greater revision. Do not implement feature derivation in the app.

`ModelResponse.validate(for:)` checks request ID, exact model profile, and nonempty output. `SpeechRequest`, `VoiceEvent`, `PracticeTurn`, and `VoiceCoordinating` are in `Contracts.swift`; Core intentionally has no audio, Pipecat, or hardware dependencies.

Bundle the JSON resources from `Resources/CoachingCards/coaching-cards.json` and `Resources/PracticeScenarios/practice-scenarios.json`. Practice partner instructions explicitly label the partner as simulated; scenario output must not be added to personal memory or real-person evidence.

## Verification

Run:

```sh
swift test --package-path Packages/VocaCore
```

The suite checks feature order, unavailable/disabled masks, no eligible action, alternative exclusion, the signed four-active-feature `+0.8` utility update, correction/replay, E4B/E2B and live/practice separation, persistence/relaunch, cue attribution, duplicate/conflicting delivery, feedback no-ops, evidence deletion, voice interruption fixtures, and resource references.

## Limitations

- Fresh dialogue uses an engineering threshold of 30 seconds and requires a nonempty utterance timestamp plus `speaker == "wearer"`; this is a Core policy convention, not a Vexo guarantee.
- Atomic JSON writes are local persistence, not encrypted storage. The app owner must protect the store and delete it with associated private data.
- No device, Vexo BLE, model inference, native speech, or Pipecat behavior was exercised here.
