# Voca — build plan

## Outcome

The wearer requests help, the glasses capture context, and the phone speaks a brief cue grounded in the wearer's own interests and available conversation. Explicit feedback changes which coaching strategy the app chooses next. Afterward, the wearer can review an evidenced strength, one improvement opportunity, and a short practice exercise.

The first complete demo must show:

1. A real glasses photo processed by E4B on the iPhone.
2. A contextually appropriate cue spoken through the glasses.
3. Assigned-band tap input and approved local personal memory; band audio transcription verified separately.
4. Genuine feedback persisted, changing the selected strategy's utility in a comparable context.
5. An evidence-linked audit and one practice exchange when transcript evidence is available.
6. E2B fallback, restart recovery, and clearly recorded device limitations.

## Vexo Open integration

VEXO OPEN KIT — event-band integration
Read https://github.com/VexoAI-Org/vexo-open-kit/blob/main/contract/contract.md and docs/speech.md before implementing; pin the inspected revision. Event firmware is fixed: no flashing, renumbering, or firmware hacking. Connect only to the assigned band number from its bag, never the first/nearest device or a name prefix. Require that number before any connection. Match service plus exact advertised identity/manufacturer band number before connecting, then verify GET_INFO. No scanning or connecting is authorized by these planning files alone.
Machine 1 owns the native CoreBluetooth client, packet parser, Opus decoding, transcription integration, and local approved-memory store. Machine 2 keeps Core hardware-independent and adds fixtures for unknown speaker, stale/gapped transcript, duplicate tap, and interrupted delivery. The event kit provides BLE audio/events, not automatic cloud transcripts or memory; OAuth/MCP is not required for this path.
Service: 254f0001-df82-4a9c-a2b5-563a0f6b2021. RX uses 0002; TX uses 0003 with the same suffix. Subscribe to TX before sending commands; use writes with response, one outstanding command, match sequence/opcode/length/status, and use the documented 2-second response timeout. Query GET_INFO, check protocol/capabilities/max_frame, and only then enable supported streams. Ignore unknown frame/event types safely. Never blindly retry non-idempotent commands.
A double tap opens the connection window when disconnected. Only one BLE client connects at once: close the laptop dashboard before the iPhone connects. While connected, EVENT frames expose single/double taps; validate detector timing before choosing gesture mappings. Start with single tap requesting a cue and an explicit Review action for audits; keep helpful/unhelpful feedback explicit and attached to a completed cue. Test whether single events precede double events to avoid duplicate actions.
Audio is Opus, 16 kHz mono, 20 ms packets; decode natively to PCM for the on-device speech pipeline. Track sequence wrap, gaps, stream restarts, and approximate capture timing separately from notification receipt time. Do not assume desktop Python decoder packages run on iOS. Microphone audio may include bystanders: explain capture, preserve the firmware's blue mic indicator, and never infer the wearer's identity from an undiarized transcript. Only attributable, approved speech becomes personal memory. No cloud speech fallback without explicit user choice.
First prove assigned-band discovery, GET_INFO and tap events; then capture a short consented audio sample and verify local decoding/transcription. Stop AUDIO and MIC_LEVEL when listening ends; both can activate the microphone. LED control is restricted while the mic indicator is active. Use the dashboard as a reference/test tool, not the deployed runtime. Band connection has no BLE encryption; disclose that boundary rather than claiming the entire system is encrypted.

## Runtime flow

```text
Glasses photo ──> scene facts ───────┐
Local store ───> approved memory ──┼─> frozen context
                 recent dialogue ──┤       │
User goal ─────────────────────────┘       v
                                  eligible strategies
                                           │
                                  contextual bandit
                                           │
                                  E4B phrases the cue
                                           │
                                  Pipecat → native TTS → glasses
                                           │
                                  explicit feedback
                                           │
                                  local policy update

Available transcript → deferred audit → short practice
```

## Pipecat voice layer

Embed Pipecat on the iPhone using the official Pipecat iOS project as an integration reference. Its embedded Python approach avoids a server, but its Apple Foundation Models provider must be replaced with a custom bridge to our existing `ModelGenerating` executor. Pin tested source revisions and package the required iOS-native Python dependencies. This bridge is implementation work, not an existing verified LiteRT integration.

For live cues, submit only the fully validated cue text to Pipecat's speech pipeline. Do not regenerate it or read structured JSON aloud. Keep microphone capture off unless the wearer explicitly starts a voice interaction. Use native iPhone speech synthesis initially, connected through a custom Pipecat TTS adapter; this retains the planned voice output without requiring the reference project's PocketTTS model.

For mock conversations, use native on-device Apple speech recognition → Pipecat turn/context handling → the same serialized Gemma executor → native speech synthesis → glasses. Verify speech assets and on-device recognition availability before starting. Band audio feeds the local transcription pipeline; approved memory is stored locally. Practice transcripts retain their own provenance and mode.

Swift owns a single audio session and playback path. Pipecat handles turn sequencing and interruption events. Verify glasses input/output routes separately; offer an explicitly labelled phone-microphone option if glasses capture fails. Stop speech on route loss instead of silently playing a private cue through the phone speaker.

The device owner implements `Voca/Voice/`, the embedded pipeline, and native bridge. Machine 2 supplies scenario/card data. Machine 1 owns prompt composition and review UI. Keep Python dependencies out of the Foundation-only Core package.

Bridge messages carry request ID, session generation, optional decision ID, and requested/actual model profile. Expose speech submission, cancellation, and playback started/completed/failed/cancelled events. For practice, forward final user transcripts and generation requests through the existing model interface. Publish concrete voice-service signatures in the device handoff note before product UI integration.

Only completion of the entire cue's native playback may set `DeliveryStatus.completed`; queued synthesis and Pipecat pipeline completion are insufficient. Interruptions cancel generation and playback, invalidate pending callbacks, and exclude unplayed assistant text from practice context. Model switching drains both inference and voice work before loading the fallback. Pipecat events do not create rewards: Core still requires explicit feedback on a completed delivery.

Use an explicit Session request button first. Connect a wearable trigger only when its supported event path is verified. Serialize photo captures and retain the capture timestamp. A photo can establish visible surroundings; it cannot establish a person's emotions or intentions.

The event band provides BLE microphone packets and events; Voca supplies transcription and approved-memory storage. Preserve source IDs, utterance times, speaker attribution, and coverage. Retrieval time is not utterance time. Start with a 30-second utterance-age threshold for fresh dialogue; unknown timestamps are not fresh. Without fresh dialogue, use an eligible scene opener or approved personal connection. Without conversation evidence, show “Waiting for transcript” for the audit.

## Workstreams

### Machine 1 — app, devices, inference, voice, and integration

Own all SwiftUI screens; Xcode/signing/dependencies; Meta capture; Vexo BLE/audio and local transcript/memory; LiteRT E4B/E2B; embedded Pipecat and native speech adapters; audit and practice orchestration; README and final submission. Follow the detailed build order in `voca-codex-prompt-you.txt`. Import Machine 2's Core package and resource data.

First prove the camera sample, then a fixed Pipecat phrase through glasses, then the E4B cue path. Connect Vexo and the policy, add feedback/review/memory screens, then spoken practice and fallback. Measure device behavior throughout.

### Machine 2 — Core and coaching content

Own the Foundation-only Core package, canonical contracts, policy, episode persistence/replay, fixtures/tests, coaching cards, and practice scenario data. Follow `voca-codex-prompt-friend.txt`. Publish contracts first, then policy/store, then content. No UI, networking, Pipecat installation, model runtime, or physical hardware is required.

## Shared interfaces

Machine 2 maintains `Packages/VocaCore/Sources/VocaCore/Contracts.swift`. All shared records are public, `Codable`, and `Sendable`, with public initializers. Use Foundation types only. IDs are UUID unless specified otherwise; timestamps are Date.

String-backed enums:

```text
Setting: cafe | shop | event | other
Goal: enter | deepen | explain
Strategy: followUp | personalConnection | explainClearly | reflectClarify | situationalOpener
SessionMode: live | practice
ModelID: gemma4E4B | gemma4E2B
DeliveryStatus: pending | completed | failed | cancelled
FeedbackVerdict: helpful | unhelpful | notTried | invalidEvidence
ModelJob: scene | cue | audit | practice
Coverage: complete | partial | unavailable
AuditStatus: ready | waitingForTranscript
```

Canonical records:

```text
ModelProfile
  modelID: ModelID, artifactSHA256: String, promptVersion: String
Evidence
  sourceID: String, text: String, speaker: String?, utteredAt: Date?, shareApproved: Bool
MemorySnapshot
  approvedMemories: [Evidence], dialogue: [Evidence], fetchedAt: Date, coverage: Coverage
SceneFacts
  requestID: UUID, observedAt: Date, setting: Setting, observations: [String], uncertain: Bool
CueContext
  decisionID: UUID, requestedAt: Date, scene: SceneFacts, goal: Goal, mode: SessionMode,
  profile: ModelProfile, snapshot: MemorySnapshot, knownPoint: String?, disabledStrategies: [Strategy]
CueDecision
  context: CueContext, features: [Double], eligibleActions: [Strategy], selectedAction: Strategy,
  utilities: [String: Double], policyVersion: String, usedExploration: Bool
CueResult
  decisionID: UUID, actualProfile: ModelProfile, strategy: Strategy, text: String, sourceIDs: [String]
Episode
  decision: CueDecision, cue: CueResult?, delivery: DeliveryStatus, feedback: FeedbackEvent?
FeedbackEvent
  id: UUID, decisionID: UUID, verdict: FeedbackVerdict, revision: Int, recordedAt: Date
AuditReport
  decisionID: UUID, generationProfile: ModelProfile?, status: AuditStatus,
  strength: String?, opportunity: String?, exercise: String?, sourceIDs: [String], principleID: String?
ModelRequest
  requestID: UUID, decisionID: UUID?, kind: ModelJob, requestedProfile: ModelProfile,
  prompt: String, imageJPEG: Data?, maxOutputTokens: Int, responseSchemaJSON: String?
ModelResponse
  requestID: UUID, actualProfile: ModelProfile, text: String
```

Shared service signatures:

```swift
public protocol ModelGenerating: Sendable {
    func activeProfile() async throws -> ModelProfile
    func generate(_ request: ModelRequest) async throws -> ModelResponse
}

// Public API of the product lane's serialized CoachEngine actor:
init(storeURL: URL) throws
func selectCue(_ context: CueContext, explore: Bool,
               excluding: Strategy?) async throws -> CueDecision?
func recordDelivery(decisionID: UUID, cue: CueResult?,
                    status: DeliveryStatus) async throws
func applyFeedback(_ event: FeedbackEvent) async throws
func episodes() async throws -> [Episode]
```

The app assigns identifiers, timestamps, and profiles; the model generates semantic fields. Validate decoded output, length, allowed evidence references, and requested/actual profile equality. Scene observations may use capture-scoped evidence IDs. Core derives and freezes the feature vector; app code must not duplicate that logic. Machine 1 owns Review/Memory view integration.

## Voice and content contracts

VOICE CONTRACT v2 — Machine 2 declares these Foundation-only types; Machine 1 implements the service.
VoiceEventKind = started | completed | failed | cancelled (String-backed).
SpeechRequest: requestID:UUID, sessionID:UUID, generation:Int, decisionID:UUID?, profile:ModelProfile, mode:SessionMode, text:String.
VoiceEvent: requestID:UUID, sessionID:UUID, generation:Int, kind:VoiceEventKind, occurredAt:Date, errorMessage:String?.
PracticeTurn: id:UUID, sessionID:UUID, generation:Int, text:String, utteredAt:Date, isFinal:Bool.
All records public Codable/Sendable with public initializers.
VoiceCoordinating: Sendable
  speak(_ request:SpeechRequest) async throws -> AsyncThrowingStream<VoiceEvent, Error>
  cancel(sessionID:UUID) async
  startPractice(sessionID:UUID, generation:Int) async throws -> AsyncThrowingStream<PracticeTurn, Error>
  stopPractice(sessionID:UUID) async

speak returns immediately with an event stream after accepting the request. A request produces at most one terminal event; stream end without a terminal event is failure. Cancellation stops active/pending speech and generation for the session and awaits quiescence. The app increments generation after cancellation/restart and rejects stale callbacks. Cancelling the consuming task must cancel the underlying request. startPractice supplies recognition events, not auto-generated model responses; Machine 1's coordinator sends final turns to the serialized Gemma executor and sends validated responses back through speak. stopPractice stops capture and cancels session work. PracticeTurn IDs identify utterances; duplicate finals must not trigger duplicate generations.

Only native playback of the entire cue produces completed. For cue requests, Machine 1 maps accepted terminal events to CoachEngine.recordDelivery using the matching decision ID and actual CueResult. A cancelled, partial, failed, or merely synthesized cue cannot earn a reward. Interrupted practice text stays out of completed assistant context. Pipecat never supplies reward values. Machine 2 tests these attribution rules using synthetic events; no Pipecat dependency enters Core.

COACHING CONTENT CONTRACT
Machine 2 publishes coaching-cards.json and practice-scenarios.json in its owned resource directories plus public Core decoding types. CoachingCard: id:String, title:String, principle:String, exercise:String, bookTitle:String, sourceURL:String. PracticeScenario: id:String, title:String, setting:Setting, goal:Goal, openingLine:String, partnerInstructions:String, principleIDs:[String]. Machine 1 bundles and consumes these resources. Scenario dialogue is labelled simulated and cannot become a personal memory or evidence about a real person.


## Learning loop

Use a disjoint LinUCB contextual bandit. Its action is the coaching strategy; the language model phrases the chosen intervention. This is immediate preference learning, with fixed model weights.

Canonical feature order:

```text
[1, cafe, shop, event, other, enter, deepen, explain,
 approvedStoryAvailable, freshDialogueAvailable]
```

Setting and goal are one-hot. Mask unsupported and disabled actions before selection:

| Strategy           | Required evidence                         |
| ------------------ | ----------------------------------------- |
| followUp           | Fresh dialogue                            |
| personalConnection | Relevant approved personal material       |
| explainClearly     | Known point or project to explain         |
| reflectClarify     | Fresh dialogue                            |
| situationalOpener  | Useful scene evidence and an opening goal |

Return no decision when nothing is eligible. An explicit request for another strategy excludes the previous action when an alternative exists.

For each action, initialize `P = identity(10)` and `b = zeros(10)`. Keep separate state for `(modelID, artifactSHA256, promptVersion, mode)`.

```text
theta = P * b
utility = transpose(x) * theta

Default live selection: highest utility, with deterministic goal-appropriate ties.
Opt-in exploration: highest utility + 0.5 * sqrt(transpose(x) * P * x).
```

Ask: “Did that help you say what you wanted, in your own voice?”

- Completed delivery + helpful: reward `+1`.
- Completed delivery + unhelpful: reward `-1`.
- Missing feedback, not tried, invalid evidence, or incomplete delivery: no update.

Playback completion records delivery; it is not evidence of usefulness. For the selected action only:

```text
v = P * x
P = P - outer(v, v) / (1 + transpose(x) * v)
b = b + reward * x
```

Persist the decision before generation, then its actual cue, sources, delivery, and canonical feedback. Duplicate or stale revisions cannot train twice. Corrected feedback replaces the previous verdict and rebuilds the affected policy from valid episodes. Evidence deletion removes invalid associated learning. Use atomic persistence and retain the last valid store on failure.

Delayed feedback always updates its original decision/profile, even after a model switch. Approved memory is shared across models; learned policies are separate. New audit/practice jobs use the currently active model and record their own generation profile.

The demo should show the same frozen context before and after real feedback, with the selected action's utility changing. Keep scripted/replayed examples visibly labelled. A score change demonstrates learning mechanics; longer-term conversational improvement requires later evaluation.

## Audits and coaching content

Produce one observed strength, one tentative opportunity tied to the wearer's goal, and one brief exercise. Link each observation to attributable transcript evidence. Do not turn missing evidence into a performance judgment or use generated praise as a reward.

Create a small set of original coaching cards informed by: The Communication Book, The Art of Witty Banter, How to Listen with Intention, Thanks for the Feedback, The Decision Book, Show Your Work!, Radical Candor, Read People Like a Book, and The Well-Spoken Thesaurus. Verify author/publisher descriptions for attributed ideas; do not invent quotations or imply full-book ingestion. Prioritize listening, authentic personal connections, and clear explanations. Keep humor optional and avoid claims of mind-reading.

## Model fallback and recovery

Start with E4B. Offer E2B for measured load, memory, thermal, or latency problems. Switch at a session boundary: stop requests, cancel and await work, release the engine and conversations, discard unfinished derived context, load/warm the fallback, and resume. Preserve approved memory and completed episodes. Record the actual artifact and prompt version on every result.

After repeated load failures, allow fallback selection on the next launch. A model switch does not resolve missing permissions, unavailable transcripts, or app suspension. Never send a stale cue after a cancelled request or model switch.

## Hourly checkpoints

| Time        | Machine 1                                         | Machine 2                                  | Shared evidence                      |
| ----------- | ------------------------------------------------- | ------------------------------------------ | ------------------------------------ |
| 09:00–10:00 | App, SDKs, signing, embedded runtime              | Contracts by 09:15; package fixtures/tests | App builds; Core tests independently |
| 10:00–11:00 | Fixed Pipecat speech, then photo/E4B/glasses loop | Policy, persistence, attribution tests     | Device loop and numeric updates      |
| 11:00–12:00 | Vexo, shared context, all UI scaffolds            | Coaching/scenario data and fixtures        | First integrated policy/cue path     |
| 12:00–13:00 | Feedback/review/memory integration                | Revision/replay/relaunch checks            | Genuine feedback persists            |
| 13:00–14:00 | Audit, spoken practice, E2B switch                | Review evidence and fix Core defects       | Interruption and fallback tested     |
| 14:00–15:00 | Device recovery and integration tests             | Focused regression checks                  | Feature freeze                       |
| 15:00–16:00 | Sustained device rehearsal                        | Verify learning demo attribution           | Measured operating limits            |
| 16:00–17:00 | Video, README, submission assets                  | Final Core/content checks                  | Assets ready                         |
| 17:00–17:30 | Final build and submission                        | Handoff support                            | Submit with buffer until 18:00       |

Account for 09:30 kickoff and 12:30 lunch. Exchange ready SHAs and checks at checkpoints. These are targets; report blockers and actual results honestly.

## Verification and finish line

- Core: feature order, masks, no eligible action, alternative exclusion, signed updates, ignored feedback, duplicate/stale revisions, corrections, persistence, delayed E4B feedback during E2B use, and live/practice separation. Numeric check: one signed reward with four active features gives the selected action same-context utility `+0.8` or `-0.8`.
- Device: actual model identity, camera permissions, capture serialization, TTS route/completion, cancellation, model switching, network loss, transcript freshness, lock/background behavior, and repeated use. Treat a five-second request-to-speech target as a measurement goal, not a claim.
- Product: realistic and empty data, missing transcript, decoding failure, large text, VoiceOver labels, memory deletion, and feedback correction.
- Voice: embedded runtime launches on device; fixed speech and Gemma responses reach glasses; practice recognition is on-device; interruptions cannot mark partial cues completed; stale callbacks cannot update new sessions; route loss stops private playback; E2B switching leaves no queued E4B speech. Measure combined runtime/model memory and thermal behavior. Reassess checkpoint timing if native packaging blocks integration; do not silently substitute a server or different LLM.
- Delivery: passing Core tests, reproducible app build, measured demo, handoff notes, README setup commands, and explicit unresolved limitations.

## Primary references

- [LiteRT-LM Swift](https://developers.google.com/edge/litert-lm/swift) and [Gemma 4 model guide](https://developers.google.com/edge/litert-lm/models/gemma-4)
- [Meta iOS integration](https://wearables.developer.meta.com/docs/develop/dat/build-integration-ios/) and [camera capture](https://wearables.developer.meta.com/docs/develop/dat/camera-capture/)
- [Vexo Open BLE contract](https://github.com/VexoAI-Org/vexo-open-kit/blob/main/contract/contract.md)
- [Pipecat iOS reference](https://github.com/pipecat-ai/pipecat-build-ios) and [embedded architecture](https://github.com/pipecat-ai/pipecat-build-ios/blob/main/docs/architecture.md)

Use current official SDK documentation for integration details. The kit’s Deepgram examples are cloud transcription; our selected on-device transcription path needs separate verification. Test taps and locked-phone behavior on hardware.
