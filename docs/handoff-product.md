# Machine 2 handoff — Core and coaching content

Ready implementation commit: `6307adacb297c3ed261c6554cee56fb174fbe182`.

## Ready changes

- Foundation-only Swift package at `Packages/VocaCore` with canonical public contracts, `ModelGenerating`, `VoiceCoordinating`, content models, and a serialized `CoachEngine` actor.
- `CoachEngine` freezes the canonical ten features and eligibility at selection; keys LinUCB history by model ID, artifact SHA-256, prompt version, and mode; persists pending decisions and cue/delivery/feedback atomically; enforces immutable terminal delivery; and replays corrected feedback in only the affected namespace.
- Evidence deletion API: `deleteEvidence(sourceID:)` (with `invalidateEvidence(sourceID:)` as a compatibility spelling). It removes complete affected episodes so transcript/memory text and their cue/reward derivations disappear from persisted history, replays remaining policy state, and blocks stale snapshots from reusing that source ID.
- Labelled synthetic fixtures in `VocaFixtures` cover unknown speaker, stale/gapped dialogue, duplicate tap IDs, and interrupted delivery.
- Nine original coaching cards cover all nine requested books, and three simulated practice scenarios are in the owned `Resources/` directories. The source links point to public author, publisher, or book listing pages. `CoachingContent.decode(cards:scenarios:)` checks unique IDs, HTTPS source links, and scenario principle references.
- Cue source validation accepts only share-approved memory IDs, available dialogue IDs, and the scene request ID. Fresh dialogue can be any nonempty attributed speaker; missing/unknown/undiarized speakers and missing timestamps are excluded. Repeated decision UUIDs are rejected before selection is persisted.
- Explain cues require a separate `knownPointSourceID` for wearer-entered `knownPoint`; Core makes `.explainClearly` ineligible without it and rejects completed cues that cite only the scene. This keeps typed wearer context from being attributed to the photo.

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

Actor calls are `await`ed by app clients. Construct one engine from the durable local store URL. After cue validation and before handing it to speech, persist it with `recordDelivery(decisionID:cue:status: .pending)`. This keeps the actual cue/sources with the frozen decision if the app exits during playback. On relaunch, mark unresolved pending delivery cancelled; passing `cue: nil` preserves the stored cue and cannot earn feedback. `.completed` requires a valid cue (provided then or already pending). Repeating the same pending cue or terminal status is idempotent; conflicting cue/terminal events throw. Feedback must match a completed cue and the frozen profile. Feedback corrections require a strictly greater revision. Do not implement feature derivation in the app.

`ModelResponse.validate(for:)` checks request ID, exact model profile, and nonempty output. `SpeechRequest`, `VoiceEvent`, `PracticeTurn`, and `VoiceCoordinating` are in `Contracts.swift`; Core intentionally has no audio, Pipecat, or hardware dependencies.

### Machine 1 migration for Explain cues

When constructing an Explain `CueContext`, assign a unique source ID to the wearer's typed point, for example `user-input:<decision UUID>`, and set `knownPointSourceID`. Include that ID in the generated cue's allowed source IDs and ask the model to cite it when using `knownPoint`. `recordDelivery` then verifies the cue contains the same citation. Without a point and source ID, Core returns no decision for Explain; do not fall back to citing the scene.

Bundle the JSON resources from `Resources/CoachingCards/coaching-cards.json` and `Resources/PracticeScenarios/practice-scenarios.json`. Practice partner instructions explicitly label the partner as simulated; scenario output must not be added to personal memory or real-person evidence.

## Verification

Run:

```sh
swift test --package-path Packages/VocaCore
```

**Verified:** `swift test --package-path Packages/VocaCore` passed: 13 tests, 0 failures. `git diff --check` passed. Tests include share-unapproved memory source rejection, attributed partner dialogue freshness, duplicate decision ID rejection, Explain point source attribution, pending cue persistence and cancellation recovery, signed four-active-feature `+0.8` update, delayed E4B feedback after E2B selection, correction replay across relaunch, live/practice separation, cue attribution, duplicate/conflicting delivery, feedback no-ops, evidence deletion, voice interruption fixtures, and resource references.

## Limitations

- Fresh dialogue uses an engineering threshold of 30 seconds and requires a nonempty utterance timestamp and an attributed speaker label. This is a Core policy convention, not a Vexo guarantee.
- Atomic JSON writes are local persistence, not encrypted storage. The app owner must protect the store and delete it with associated private data.
- No device, Vexo BLE, model inference, native speech, or Pipecat behavior was exercised here.
