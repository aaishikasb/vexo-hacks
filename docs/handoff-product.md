# Machine 2 handoff — Core and coaching content

Ready implementation commit: `3eff1e3e7124d2ffc0c98fab2206c515f0960abd`.

## Ready changes

- Foundation-only Swift package at `Packages/VocaCore` with canonical public contracts, `ModelGenerating`, `VoiceCoordinating`, content models, and a serialized `CoachEngine` actor.
- `CoachEngine` freezes the canonical ten features and eligibility at selection; keys LinUCB history by model ID, artifact SHA-256, prompt version, and mode; persists pending decisions and cue/delivery/feedback atomically; enforces immutable terminal delivery; and replays corrected feedback in only the affected namespace.
- Evidence deletion API: `deleteEvidence(sourceID:)` (with `invalidateEvidence(sourceID:)` as a compatibility spelling). It removes complete affected episodes so transcript/memory text and their cue/reward derivations disappear from persisted history, replays remaining policy state, and blocks stale snapshots from reusing that source ID.
- Labelled synthetic fixtures in `VocaFixtures` cover unknown speaker, stale/gapped dialogue, duplicate tap IDs, and interrupted delivery.
- Nine original coaching cards cover all nine requested books, and three simulated practice scenarios are in the owned `Resources/` directories. The source links point to public author, publisher, or book listing pages. `CoachingContent.decode(cards:scenarios:)` checks unique IDs, HTTPS source links, scenario principle references, and the `SIMULATED PARTNER:` prefix on every scenario.
- Cue source validation accepts only share-approved memory IDs, available dialogue IDs, and the scene request ID. Fresh dialogue can be any nonempty attributed speaker; missing/unknown/undiarized speakers and missing timestamps are excluded. Repeated decision UUIDs are rejected before selection is persisted.
- Explain cues require a separate `knownPointSourceID` for wearer-entered `knownPoint`; Core makes `.explainClearly` ineligible without it and rejects completed cues that cite only the scene. This keeps typed wearer context from being attributed to the photo.
- `AuditReportValidator.validate(_:decisionID:dialogue:knownPrincipleIDs:)` accepts ready reports only with bounded nonempty claims, a generation profile, known principle ID, and source IDs from attributable wearer speech. Waiting-for-transcript reports must contain no claims or source IDs.

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
public static func validate(_ report: AuditReport, decisionID: UUID,
                            dialogue: [Evidence], knownPrincipleIDs: Set<String>) throws -> AuditReport
```

Actor calls are `await`ed by app clients. Construct one engine from the durable local store URL. After cue validation and before handing it to speech, persist it with `recordDelivery(decisionID:cue:status: .pending)`. This keeps the actual cue/sources with the frozen decision if the app exits during playback. On relaunch, mark unresolved pending delivery cancelled; passing `cue: nil` preserves the stored cue and cannot earn feedback. `.completed` requires a valid cue (provided then or already pending). Repeating the same pending cue or terminal status is idempotent; conflicting cue/terminal events throw. Feedback must match a completed cue and the frozen profile. Feedback corrections require a strictly greater revision. Do not implement feature derivation in the app.

`ModelResponse.validate(for:)` checks request ID, exact model profile, and nonempty output. `SpeechRequest`, `VoiceEvent`, `PracticeTurn`, and `VoiceCoordinating` are in `Contracts.swift`; Core intentionally has no audio, Pipecat, or hardware dependencies.

### Machine 1 migration for Explain cues

When constructing an Explain `CueContext`, assign a unique source ID to the wearer's typed point, for example `user-input:<decision UUID>`, and set `knownPointSourceID`. Include that ID in the generated cue's allowed source IDs and ask the model to cite it when using `knownPoint`. `recordDelivery` then verifies the cue contains the same citation. Without a point and source ID, Core returns no decision for Explain; do not fall back to citing the scene.

Bundle the JSON resources from `Resources/CoachingCards/coaching-cards.json` and `Resources/PracticeScenarios/practice-scenarios.json`. Practice partner instructions explicitly label the partner as simulated; scenario output must not be added to personal memory or real-person evidence.

Before displaying an audit, pass only the current live session's dialogue to `AuditReportValidator`. If no wearer-attributed source is available, provide a `.waitingForTranscript` report with empty claims, sources, and principle ID. The content decoder rejects any practice scenario without its simulated-partner label.

## Verification

Run:

```sh
swift test --package-path Packages/VocaCore
```

**Verified:** `swift test --package-path Packages/VocaCore` passed: 14 tests, 0 failures. `git diff --check` passed. Tests include share-unapproved memory source rejection, attributed partner dialogue freshness, duplicate decision ID rejection, Explain point source attribution, pending cue persistence and cancellation recovery, signed four-active-feature `+0.8` update, delayed E4B feedback after E2B selection, correction replay across relaunch, ready/waiting audit evidence validation, simulated scenario label validation, live/practice separation, cue attribution, duplicate/conflicting delivery, feedback no-ops, evidence deletion, voice interruption fixtures, and resource references.

## Limitations

- Fresh dialogue uses an engineering threshold of 30 seconds and requires a nonempty utterance timestamp and an attributed speaker label. This is a Core policy convention, not a Vexo guarantee.
- Atomic JSON writes are local persistence, not encrypted storage. The app owner must protect the store and delete it with associated private data.
- No device, Vexo BLE, model inference, native speech, or Pipecat behavior was exercised here.

## Device-lane merge verification

The integration fix checks terminal delivery before handling pending updates.
Late pending callbacks (with or without a cue) now throw
`conflictingTerminalDelivery` for cancelled, failed, and completed episodes;
the regression verifies unchanged in-memory and relaunched state, while exact
terminal retries remain idempotent. `CoachingSession` now persists the validated
cue as pending before invoking speech.

Verified on the integrated working tree: 15 Core tests, 15 device/pipeline tests,
and the unsigned generic-iOS Voca build passed. No hardware playback or
interruption test was performed for this merge.
