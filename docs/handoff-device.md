# Machine 1 checkpoint — 14 November 2026

Branch: `device-inference`. This is a **device-setup checkpoint, not the integrated product**.
Ready implementation commit: `7ba437e17a6ce23832ad9f23f388afbcdf16a17e` (local; not pushed).
Initial device foundation: `d9efade7628da3eaece9c4471dfb284f533d7071`.
A following documentation-only commit records this SHA.

## Implemented

- Reproducible Voca Xcode project/scheme, local signing overrides, exact Meta DAT
  1.0.1 and LiteRT-LM 0.19.1 package resolution. Git LFS is required. Dynamic
  frameworks are embedded and found through `@executable_path/Frameworks`.
- Native Session setup, Review/Memory explanatory empty states, Meta registration
  callback routing, serialized photo request with timeout and cancellation.
  Photo observation time uses request time as an estimate, not a verified camera timestamp.
- Explicit assigned-band action: exact service + advertised name/manufacturer
  matching, GET_INFO identity/protocol/capability/max-frame validation, TX before
  commands, write-with-response, one outstanding command, sequence/opcode/length/
  status matching, 2-second timeout, no automatic retry, unknown-frame tolerance.
  Old connection callbacks are rejected. Tap mappings stay disabled until measured.
- Native Opus adapter and approximate capture timeline with wrap/gap/duplicate/
  restart handling. A consented 10-second sample uses on-device-only Apple speech
  recognition. Both mic-related streams stop at end; failures disconnect.
  Unknown speaker sample text is ephemeral, never approved memory.
- One native audio-session owner and explicit glasses-output confirmation. Native
  phrase diagnostic awaits full AVSpeechSynthesizer completion; interrupted or
  stale callbacks cannot finish another request. This is NOT Pipecat delivery.
- App-accessible generic model import, chunked SHA-256 verification, backup
  exclusion, persistent artifact index. Core-bound serialized LiteRT executor
  source is present but gated until the real Core package arrives.
- Generated semantic payload validation: known settings, bounded fields, 8–18
  words for cues, exact JSON field sets, source allowlists, no model-assigned IDs.

## Passing checks

- `swift test --scratch-path /tmp/voca-device-build`: **9 Swift Testing tests pass**.
  Identity matching, malformed frames/GET_INFO, unknown event handling, audio
  wrap/gap/restart/duplicates, outstanding-command matching, native synthetic Opus
  silence, cue/source/schema validation, scene/audit field rejection, bounded UI-operation timeout, duplicate-action suppression,
  and a late SDK callback not clearing a newer operation.
  These are **Mac fixtures**, not physical-band measurements.
- Signed Debug arm64 iPhone build, scheme `Voca`: **passes** with Xcode 27.2 /
  Swift 6.4.2. Command in README. Latest build log: `/tmp/voca-signed.log`.
- Unsigned arm64 iPhone Simulator build: **passes**. x86_64 excluded because the
  LiteRT SDK does not ship that slice. App launch confirmed after fixing runpath.
- Simulator Session screenshot inspected at normal and maximum Dynamic Type on
  iPhone 17e. Text wraps. This is limited rendering inspection; no complete
  keyboard, VoiceOver, zoom, scrolling, or error-flow interaction verification.
- `plutil -lint` for Info.plist/project: passes. Project generator compiles and
  preserves a locally selected signing team. `git diff --check`: passes.

## Real-device results

- Physical iPhone 18 Pro Max, iOS 27.2: wired, paired, Developer Mode enabled.
- User selected Personal Team and trusted its developer profile. A signed app
  was installed and successfully launched through devicectl.
- Camera capture passed: real JPEG received over documented Bluetooth Classic.
- User confirmed hearing the full native test phrase through the glasses.
- Embedded Pipecat startup passed on the phone; user confirmed the full Pipecat phrase through glasses and completed playback.
- Assigned band is 18; user is unsure which client owns its reported connection.
  No agent band scan/connection/capture was performed.
- No measured Gemma cold/warm latency, memory, thermal, locked-phone behavior,
  or combined Pipecat/Gemma runtime result exists yet.

## Machine 2 integration

No Core/content branch was available on origin at this checkpoint; only `main`.
No shared types were duplicated and no Machine 2-owned files were edited.

Publish the ready commit to origin and send its SHA plus `docs/handoff-product.md`.
Machine 1 will inspect/cherry-pick it, regenerate the Xcode project (which adds the
local Core product and content resources), run Core tests, then compile the
Core-bound executor and finish product orchestration and UI.

The canonical v2 service API remains unchanged. Core also needs a confirmed API
for deleting evidence and associated derived episode/policy data before the
app exposes memory deletion; invalidating a reward alone does not erase private
text from persisted episode snapshots. Please include the concrete signature in
the product handoff. Do not implement hardware or voice dependencies in Core.

## Remaining blockers and work

1. Core/contracts/policy/store/content handoff absent. Approved memory store,
   full Session/Review/Memory flows, persisted decisions, eligible feedback,
   learning demonstration, audit, practice, and provenance integration remain.
2. Pipecat embedded startup now passes; native speech adapter is implemented.
   Canonical VoiceCoordinating, Gemma adapter, and
   practice orchestration still require completion. The earlier missing-fork
   diagnosis was incorrect; the pinned reference includes the mobile fork.
3. Gemma artifacts must be imported with known hashes. Executor cancellation,
   priority, warmup, E2B session switching, and attribution need Core-backed tests
   and real-device validation before enabling the coaching path. Currently load
   is manual; failed load does not create a startup retry loop.
4. Camera, native phrase, and Pipecat phrase passed. Only after explicit assigned-band authorization perform GET_INFO/tap
   timing checks, then consented decoding/transcription checks.
5. No demo video/submission claim should describe this checkpoint as a complete
   coaching product. Model weights remain fixed; no learning claim is verified.

### Camera investigation — November 14

User still reports waiting for device while wearing glasses. Real diagnostic
confirmed registered/connected/compatible/donned, but the early permission query
returned `MWDATCore.PermissionError.noDevice`. Camera startup now waits up to ten
seconds for SDK discovery and starts the session before checking permission, as
in the inspected Meta CameraAccess sample. Registration no longer overwrites an
active session's status. Stop invalidates discovery and permission callbacks.

After the change, a real-device check failed with `Session ended by device` and
SDK wear state `doffed`; no photo was returned. This is **not** a camera pass or
proof of the root cause. Signed Debug build passes; nine existing fixture tests
pass (they do not exercise Meta hardware). `scripts/check_camera.py DEVICE_ID`
is a DEBUG-only real-camera regression harness: it requires an unlocked phone
and consenting camera subject; copies only state metadata, not the captured
photo. Debug compilation conditions are now explicit in the project generator.
The harness deletes its previous local snapshot before each copy because
`devicectl copy` does not overwrite an existing destination. User subsequently confirmed briefly removing the glasses, so the `doffed`
state is not evidence of a wear-detection fault. Session termination still
requires a repeat with continuous wear.

### Camera verified on physical phone

The exact regression passed after selecting the documented Bluetooth Classic
transport in Info.plist: `external-accessory` background mode plus
`UISupportedExternalAccessoryProtocols = [com.meta.ar.wearable]`; removed Wi-Fi
Bonjour/local-network declarations. Added the Bluetooth peripheral background
mode specified by Meta. AutoDeviceSelector retained: a separate test with
SpecificDeviceSelector did not resolve the stall and was reverted.

Reference: https://github.com/meta/meta-wearables-dat-ios/issues/354 (Meta response,
October 22, 2026). The configured Wi-Fi path previously stalled at
`session=started, stream=waitingForDevice` even with connected/compatible/worn
glasses. After the transport change, `python3 scripts/check_camera.py DEVICE_ID`
returned `passed`, `stream=streaming`, `photoBytes=334852`, worn/connected/compatible.
The photo stayed in app memory; only state metadata was copied. Signed iPhone
Debug build passed and was installed. This proves a single real glasses photo,
not sustained streaming, locked-phone behavior, inference, or Pipecat delivery.

### Native speech confirmed

User confirmed hearing the complete fixed test phrase through the glasses on
November 14. This is a real-device, user-observed native synthesis/audio-route
pass. It does not verify Pipecat, model generation, interruptions, or locked-phone
playback. Next: package embedded Pipecat and route the same phrase through its
native playback adapter. The earlier missing-fork blocker was an inspection
error: the pinned reference includes its modified fork under `pipecat/`.

### Band assignment update

User assigned band number is 18. User reports a connection but is unsure which
client owns it. This does not verify Voca discovery, GET_INFO, or tap events.
Close any dashboard/other client before a Voca test; no new band scan or
connection was performed during Pipecat packaging.

### Embedded Pipecat startup verified

Pinned iOS reference `6a204432df5cd533abb85e0577a7e79dccd93a04` supplies
modified Pipecat `1.8.2.dev304`. Packaged checksum-pinned Python 3.13.14 and
cross-compiled pydantic-core 2.46.5. Native extension frameworks are signed
inside Voca. No PocketTTS assets, Foundation Models, server, or microphone
capture is used. Custom `NativeSpeechAdapter` routes TTSSpeakFrame through
Swift NativeAudio, awaiting the whole-playback acknowledgement.

Signed physical-phone build/install passed. `--pipecat-check` on the actual
iPhone produced `ready=true`, `status=Embedded Pipecat ready`. Two host pipeline
tests passed against the real pinned fork (completion gating/stale and duplicate
acknowledgements; cancelled playback). This is a speech-only integration step,
not yet the canonical VoiceCoordinating service or Gemma/practice orchestration.
Simulator Python extension build is not prepared yet; previous Simulator results
predate this runtime addition. User confirmed hearing the full phrase through the glasses and seeing completed playback on November 14. This is a user-observed physical-device pass, not an acoustic recording or latency measurement.

### Pipecat speech checkpoint confirmed

Implementation commit: `fe80f8f`. User heard the fixed Voca phrase through the
glasses and confirmed “Pipecat speech playback completed.” The follow-up
recalled “Voca is ready to find your own words”; the configured phrase remains
“Voca is ready to help you find your own words.” No recording was made.
Next build-order step is the serialized Gemma photo-to-cue path, requiring the
canonical Core handoff and user-imported, hash-verified model artifacts.
Route-loss interruption and speech with concurrent Gemma remain unverified.

### Core and first cue flow integrated

Integrated Machine 2 ready SHAs `7156e47` and `4477d87` as local commits
`315d177` and `db614c6`. Core's 9 tests pass. Removed temporary canImport build
gates and corrected LiteRT actor calls. The signed app builds with scene
generation, validated 8–18-word cue generation, persisted Core selection,
Pipecat/native delivery, explicit feedback, and pending-episode recovery.
Current snapshot deliberately contains no memories or dialogue; no such
evidence is invented. Memory editing, audits, and practice remain outstanding.

Official generic E4B/E2B downloads have verified SHA-256 hashes recorded in
`config/models.json`; artifacts remain ignored. E4B is staged on the phone for
actual load/generation checks. No model inference pass is claimed at this point.

Band 18 connection and tap receipt were user-confirmed in Voca. Agent review
added START/STOP acknowledgement checks, empty-Opus rejection, bounded tap
history, and listening-generation cleanup. These compile in the integrated
iPhone build. Ordered single/double behavior, microphone sample, native iPhone
Opus and local transcription still require physical tests.

### Reviewed Machine 2 branch merge — 14 November 2026

Merged `learning-product` through `60cc07d` into `device-inference` at
`8f63592`, resolving the earlier cherry-picked Core files to Machine 2's reviewed
versions. This includes approved-memory source checks, attributed partner
freshness, duplicate decision rejection, and all nine coaching cards. Existing
uncommitted app work was preserved.

Validation against the integrated working tree: Core 10 tests passed; root
`swift test` 14 device fixtures passed. Regenerated the Xcode project and built
scheme `Voca` with `GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project Voca.xcodeproj
-scheme Voca -destination 'generic/platform=iOS' -derivedDataPath .build/iPhone
CODE_SIGNING_ALLOWED=NO build`: BUILD SUCCEEDED. This was an unsigned physical-iOS
target build, not a Simulator run or device runtime validation. No installation,
model execution, or wearable test was performed in this merge checkpoint.

### Published first cue integration

The first photo → Gemma scene/cue → Pipecat/native playback flow is wired in
`CuePipeline` and `CoachingSession`. Core selection is persisted before cue
generation, live exploration defaults off, and only successful native playback
acknowledged through Pipecat permits completed delivery and feedback. Cancelled
or failed playback cannot train the policy. Snapshots have no invented dialogue
or personal memories. Existing band diagnostics and microphone cleanup changes
are included because the integrated Session screen consumes them.

Fresh validation: Core 10 tests, device/cue 14 tests, Pipecat host 2 tests; all
passed. Regenerated project; unsigned generic-iOS Voca build succeeded. These
are host/build results: the full photo-to-Gemma-to-glasses loop, rendered UI,
and device interruption behavior remain to be verified on hardware.

### E4B device check passed

On the physical iPhone, generic E4B SHA-256
`0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0`
imported and loaded successfully. DEBUG check reported load 11.1769 s, first
validated text generation 3.4065 s, second 2.0031 s. These are text-only check
measurements, not photo-to-speech latency or sustained thermal results. Only E4B
was loaded; E2B is staged but not loaded/tested yet. Real photo-to-cue listening
check is pending user confirmation.

Import investigation found FileHandle read buffers accumulating in Foundation's
autorelease pool: the 3.66 GB E4B hash consumed ~3.68 GB peak footprint on Mac.
Draining the pool per chunk preserved the published digest and reduced measured
peak resident memory to 5,373,952 bytes. `scripts/check_model_hash.swift` asserts
matching SHA and a 256 MB peak-resident ceiling against a large supplied model.

A separate Voca crash identified a MainActor-inherited Speech authorization
callback executing on a background queue. Explicit Sendable callbacks and
start/cancellation fencing corrected it. The physical phone's --speech-check
returned passed=true after start/stop with no PCM or microphone capture. This
proves the callback path and on-device recognizer availability check, not actual
band transcription. Updated checks: 10 Core tests and 14 app/band fixtures pass;
signed integrated iPhone build passes.

### Photo inference crash diagnosis

Physical-device CPU vision failed with `Failed to allocate tensors`. Metal
vision with native constrained JSON then aborted in Rust `rust_oom` through
`llguidance` tokenizer creation (Voca crash report 12:23:01). Disabled native
response constraints, supplied the schema in the prompt, and retained strict
Swift JSON, semantic, source-ID, and profile validation before delivery.
Profile prompt version is now `voca-v2.2-metal-prompt-json`.

The signed recovery build installed successfully. Real-camera `--scene-check`
passed: 299,959-byte JPEG, five validated observations, 3.7541 seconds for scene
generation with E4B and Metal vision. App fixtures: 14 passed. This is scene-only
inference; complete photo-to-cue-to-glasses delivery remains pending user test.

### Explain source attribution and delayed-feedback checkpoint

Integrated Machine 2 through `8b190b2` (implementation/test commit `05802b5`)
with merge `2fc0023`. `CuePipeline` now assigns `user-input:<decision UUID>` to
nonempty wearer-entered points, supplies `knownPointSourceID` to Core, prompts
for the appropriate citation, and rejects Explain cues missing that citation
before speech. Photo-only citations cannot stand in for typed input.

Verified: 12 Core tests, including delayed E4B feedback after E2B selection and
corrected replay after relaunch; 15 device/pipeline tests, including two Explain
citation cases; unsigned generic-iOS Voca build succeeded. Device runtime and
spoken Explain behavior were not exercised in this checkpoint. Concurrent
local inference/diagnostic edits remain uncommitted.

### Repeated-photo and full-cue diagnostic

User reported native NOT_FOUND `No per layer embeddings found in inputs`.
This remains unreproduced in the expanded physical-device `--scene-check`:
first image, text-only request, repeated image, and the actual Core-backed
CuePipeline all passed on the same E4B engine (12-word validated cue). The check
uses a temporary episode store and never marks delivery complete or rewards it.
No photo/cue text is exported. This does not establish reliable interactive
playback. DEBUG inference failures now export only job kind, profile, byte
counts, timestamp, and native error to `Documents/inference-failure.json` to
identify the failing interactive stage without saving private request content.

### Metal allocation recovery and bounded runtime

Retrieved user failure: E4B text cue, 1,395 prompt bytes, no image, native
`Failed to allocate id<MTLBuffer>`. The expanded device check now starts Pipecat,
then runs repeated vision/text and three actual Core-backed Enter/Explain cue
requests. At context 2,048 with unbounded default visual tokens it reproduced
a later scene allocation failure with Metal currentAllocatedSize 3,451,060,224
bytes. Native errors now release conversation/engine/profile, fail queued jobs,
and require explicit reload or E2B selection rather than reuse failed state.

Set context to 2,048 and the SDK experimental visual-token budget to 280 before
engine initialization. Profile namespace `voca-v2.4-metal-context2048-vision280`.
This bounded configuration passed the same physical-device sequence with
Pipecat ready: real JPEG 406,287 bytes, five valid observations, first scene
3.6821 s, final valid cue 12 words. Signed build and 15 host fixture tests pass.
This is a provisional mitigation: intermittent reliability, sustained memory,
and full interactive speech delivery remain unproven. No automatic fallback,
cloud inference, microphone capture, or reward was introduced by these checks.

### Genuine feedback survives relaunch and changes utility

Physical iPhone: user confirmed complete Enter cue through glasses and applied
Helpful ratings in the UI. Relaunched Voca with devicectl --terminate-existing;
all four stored episodes were identical before/after, including feedback IDs,
verdicts, and revisions. No feedback was fabricated by the agent.

Host verification using the canonical Core implementation on disposable copies
of that real post-relaunch store: removing only the latest Helpful event gave
situationalOpener utility 0.75; retaining it gave 0.8571428571428574 for the exact
original feature vector/profile/mode. Probe decisions and the counterfactual
never touched the phone. Earlier actual decisions recorded utility 0 then 0.75
in matching contexts. Only one strategy was eligible, so this demonstrates
utility learning and persistence, not a change in choice among multiple arms.
Model weights remain fixed; long-term benefit remains unproven.

Reproducible checker: compile canonical Core sources plus
`scripts/check_feedback_replay.swift` and pass before/after exported store paths.
It asserts episode equality and positive utility change, creates only temporary
probe stores, and removes those stores on completion. Private exports were
removed after verification; no personal scene/cue text was added to Git.

### Complete-response execution and verified E2B fallback

Switched the native adapter from stream callbacks to `Conversation.sendMessage`:
Voca needs a whole validated result, and this API returns after the native call
rather than a terminal stream callback that precedes callback-state release.
The callback overlap was a suspected cause, not proven as the sole SDK defect.
Cancellation still calls native cancel; the executor awaits request return before
reuse/reload. Native failures still release the engine and require explicit reload.

E2B was staged but not imported. Imported it on the physical phone and verified
SHA-256 `181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c`.
Load now imports an official staged selected artifact through the existing hash
check if needed. Load errors have their own DEBUG diagnostic; checksum and
missing-artifact errors have distinct recovery text.

E2B initially echoed JSON schema keys instead of scene facts. Put schema metadata
before task instructions and explicitly request an instance with actual values.
Profile prompt version is `voca-v2.6-complete-json-instance`. Strict decoding,
field/type/source/length validation remain; decoding errors now become readable
validation failures. A regression test rejects wrong scene and cue field types.

Final physical checks, Pipecat loaded and one model engine at a time:
- E4B: repeated image/text plus 10 full cue pipelines, 10 validated/0 rejected,
  no native failure; first scene 3.74299 seconds.
- E2B: same sequence, 10 validated/0 rejected, no native failure; first scene
  1.51957 seconds. Both pipelines include an Explain case with explicit knownPoint.
- Signed iPhone build passes; 16 host device fixtures pass.

These bounded runs support the fix but do not prove sustained/thermal reliability.
No speech playback or reward is fabricated by the harness. E2B glasses playback,
physical cancellation with the new complete-response path, and switching under
active load remain separate checks. Existing personal feedback stays in its old
profile namespace. Concurrent Machine 2 Core/test/doc changes were preserved.

### E2B glasses playback confirmed

User confirmed the complete E2B cue played through the glasses after starting
the camera, confirming glasses audio output, and requesting Enter. This verifies
the physical fallback photo → E2B → Pipecat/native playback path on build
`e50c472`, in addition to the two ten-cue device generation runs. Long-duration
stability, cancellation under load, and active-work model switching remain
unverified. No feedback verdict was inferred from successful playback.

### E4B remains primary: actual native-failure recovery verified

User reported E4B still failed after complete-response changes. Latest native
log confirmed status 5 / NOT_FOUND / `No per-layer embeddings found in inputs`
at llm_litert_compiled_model_executor.cc:770. Thus streaming callback overlap was
not established as the root cause and complete-response alone was insufficient.
Expanded the harness: warm E2B, switch in-process to E4B, capture a new glasses
photo per cue. This reproduced a native failure at the first full pipeline;
fresh-process E4B with changing photos separately passed ten cues.

Added one bounded E4B-native-error recovery: after the failed request unwinds,
release its conversation and engine, initialize the same verified artifact and
config, and retry the same unspoken request under its original profile once.
Cancellation suppresses the retry. Only one native engine is retained. After
that retry fails, the app visibly loads E2B and creates a NEW cue pipeline and
Core decision; failed E4B episodes stay failed and E2B results carry E2B profile.
The delivered cue explicitly displays its model. No validation failures trigger
this native recovery/fallback and no reward is inferred.

Physical regression: `--scene-check --switch-from-e2b`, Pipecat loaded,
10 fresh-photo cue pipelines, 10 validated, zero rejected, **engineRecoveries=1**,
nativeSequencePassed=true. This exercised recovery from a real native error,
not a synthetic injection, and completed all jobs on E4B without E2B fallback.
First scene 4.09967 s; recovery/reload latency was not separately measured.
Signed app build and 16 host fixtures passed. E4B left loaded for the user.

This is app-level recovery, not proof the underlying SDK defect is removed.
Double-failure automatic E2B fallback and cancellation during reload still need
physical verification; recovery adds a model reload to request latency.


### Local voice tuning — 2026-11-14

Working-tree change; no ready commit created. SpeechUtterance.swift now prefers
installed US English Premium, then Enhanced voices, with system US English as
fallback. Rate is 0.94 times Apple's default; pitch and validated text remain
unchanged. NativeAudio uses this configuration through the existing Pipecat
adapter; no contract changes, cloud provider, credentials, or dependencies.
Project source membership regenerated; Mac fixture target includes the helper.

Checks: `swift test --filter speech` passed both Mac tests (fallback, text/pitch,
rate, language filtering and available quality selection). Unsigned generic iOS
build passed using the README command. The installed inventory test exercises
higher quality selection only when that quality is available on the test host.
Download an Enhanced/Premium US English voice in iPhone accessibility settings
before evaluating. New pacing and voice selection have not been auditioned or
installed on the physical phone; warmth and glasses playback remain unverified.

Physical installation follow-up: signed device build passed, installed over Voca
on the connected iPhone 18 Pro Max, and launched successfully with devicectl.
User listening check remains pending; use Setup → Advanced controls → Audio
route check, confirm glasses, start embedded Pipecat, then speak its test phrase.


### Guided interface and band cue gating — 2026-11-14

Replaced the diagnostics-first landing screen with native Session/Review/Memory
tabs, graphite/pearl semantic colors, accessible wrapping controls, cue feedback,
a guidance orb, and reduced-motion-aware device connection transitions. Setup
coordinates existing model/Pipecat services and assigned-band connection, with
explicit band switching and private audio confirmation. Existing voice tuning
is included in the integrated build. No shared contracts changed.

Single-tap cue mapping defaults off. New pure Foundation calibration and trigger
helpers observe event ordering, debounce duplicates, suppress double taps, and
check readiness at delivery. Eight regression tests cover this behavior.

Checks: signed physical-device build passed; all 26 host fixture tests passed;
git diff --check passed. Actual SwiftUI rendered with stub dependencies on
iPhone 17e Simulator at default and Accessibility3 RTL sizes; fixed wordmark
and goal-label clipping. See ui-review.md and ui-preview/README.md. Installed
and launched the integrated app on the paired iPhone without starting hardware
checks. Glasses were charging and were not used.

Remaining: physical tap calibration/tap-to-cue regression, VoiceOver and keyboard
interaction, maximum Dynamic Type, and voice audition. Audits and Memory editing
remain unfinished. Simulator fixture screenshots do not demonstrate hardware
or inference. E4B SDK recovery limitations remain as documented above.
