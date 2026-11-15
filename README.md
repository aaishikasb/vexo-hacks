# Voca

Voca is a native iPhone conversation companion that helps the wearer find
something authentic to say. It combines a glasses photo, fresh on-device dialogue,
and explicitly approved personal memories into a short spoken cue, then offers
feedback, grounded review, and spoken practice.

Built for iPhone 18 Pro Max, Ray-Ban Meta Gen 1, and an assigned Vexo bracelet.
SwiftUI owns the interface and native audio; LiteRT-LM runs Gemma 4 E4B (with E2B
fallback), embedded Pipecat coordinates speech, and the Foundation-only
`VocaCore` package owns shared contracts, policy, and persistence. There is no
application server or cloud transcription fallback. Only one model runs at a time.

The `docs/` directory contains local-only working notes and verification artifacts.
It is intentionally ignored by Git; references to it below require that local directory.

## Current capabilities

- **Session:** photo-to-cue generation, fresh dialogue context, spoken delivery,
  calibrated single-tap requests, and explicit feedback on completed cues.
- **Review:** cue history, evidence-grounded conversation reviews, and a spoken
  practice partner with custom topics, pause/resume, and topic changes.
- **Memory:** approved personal details and a persistent queue of short band
  transcript suggestions that require individual approval or dismissal.

These flows are implemented, but complete band tap → fresh dialogue → model →
glasses playback still needs an uninterrupted physical-device verification.
Recorded checks include glasses capture and speech, repeated model generation,
feedback persistence, and synthetic practice prompts; they do not establish
long-session reliability or coaching effectiveness. See the
[device handoff](docs/handoff-device.md) for dated evidence and remaining checks.

## Open and build

Open **Voca.xcodeproj**, choose the **Voca** scheme. Opening the root
`Package.swift` instead shows `VocaDeviceChecks`, a Mac fixture-test package that
cannot be installed as the iPhone app.

Requires full Xcode (tested: 27.2, Swift 6.4.2), Git LFS, and an Apple development
team. Select the app target → Signing & Capabilities → Team. Local team settings
may be kept in ignored `.local/Signing.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

```sh
# Install uv and rustup; ensure uv, rustup and cargo are on PATH.
# One-time Rust toolchain setup:
rustup toolchain install stable --profile minimal
# Prepare pinned iPhone Python and native Pipecat dependency (no models).
python3 scripts/setup_pipecat.py

# Regenerate source membership; preserves an existing signing selection locally.
python3 scripts/generate_project.py

# Do not download LiteRT repository model fixtures through Git LFS.
GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project Voca.xcodeproj -scheme Voca \
  -destination 'generic/platform=iOS' -derivedDataPath .build/iPhone \
  CODE_SIGNING_ALLOWED=NO build

# Signed device build (use the connected iPhone's identifier).
GIT_LFS_SKIP_SMUDGE=1 xcodebuild -project Voca.xcodeproj -scheme Voca \
  -destination 'id=YOUR_DEVICE_ID' -derivedDataPath .build/Device \
  -allowProvisioningUpdates build

# Native Mac fixture checks; no devices, recordings, models, or network needed.
swift test

# Canonical Core policy, persistence, validation, and content checks.
swift test --package-path Packages/VocaCore
```

Speech remains local: embedded Pipecat sends validated text to Apple speech
synthesis. Voca prefers an installed Premium US English voice, then Enhanced,
and otherwise uses the system US English voice. Delivery uses a slightly slower
rate with the voice's natural pitch. For better quality, download a US English
Enhanced or Premium voice in iPhone Settings → Accessibility → Read & Speak →
Voices (Spoken Content on older iOS versions). No API key is needed. Voice
availability and perceived warmth must be checked through the glasses on iPhone.

The SDK has arm64 Simulator binaries; x86_64 Simulator is excluded. The new
Python packaging currently prepares only the physical iPhone extension; repeat
full-app Simulator builds require adding and verifying the simulator cross-build first.
The isolated [UI fixtures](docs/ui-preview/README.md) use stubbed hardware/model
services and do not verify the embedded runtime. Dependency
versions and exact inspected revisions are in [docs/dependencies.md](docs/dependencies.md)
and the Xcode workspace's committed `Package.resolved`.

## Device setup and boundaries

1. Connect/unlock the iPhone, trust this Mac, enable Developer Mode. Actual check
   on 14 November: iPhone 18 Pro Max, iOS 27.2, paired, wired, Developer Mode enabled.
2. Connect glasses through Meta AI using the app. Camera permission opens Meta AI;
   start the camera and request a photo. Already-granted permission is reused;
   startup reports its stage and times out with a retry path. Photos remain in app memory. The supplied
   Meta AI/glasses/DAT versions are user-reported baselines; compatibility with
   resolved iOS DAT 1.0.1 passed a real capture test using Bluetooth Classic.
3. Select the connected Ray-Ban Meta glasses as the iPhone audio output; Voca recognizes them automatically. Other outputs ask for approval once and are remembered by their route identity.
   “Speak native test phrase” is a **native audio diagnostic**, not Pipecat proof.
   User confirmed the complete native phrase through the glasses on November 14.
   Route changes interrupt live cue speech; automatic phone-speaker fallback is not allowed. Practice separately uses the output explicitly selected at its start.
   For the next check, press “Start embedded Pipecat,” wait for ready, then
   “Speak test phrase through Pipecat.” Microphone capture remains off.
4. Enter the band number printed on its bag. Close the laptop dashboard and
   double-tap the disconnected band to open its connection window. Voca automatically reconnects to the saved assigned identity; Settings also offers **Connect assigned band**.
   Service and exact advertised identity/manufacturer number are checked before
   connecting; GET_INFO is verified before enabling EVENT. Firmware is unchanged.
5. Complete **Settings → Set up single-tap cues** on the assigned band before
   using single taps for cues. Double taps start memory listening; calibration
   gestures do not. Feedback is never inferred from a tap. BLE is **not encrypted**.
6. For a 10-second transcription sample, obtain everyone's consent. Preserve the
   band's blue microphone indicator. Both AUDIO and MIC_LEVEL are stopped when
   listening ends; errors disconnect if STOP cannot be acknowledged. Recognition
   requires on-device availability and never uses a cloud fallback. Speaker is
   unknown; sample text is not saved or promoted to approved personal memory.
7. Import a generic E4B/E2B `.litertlm` file through Files with its independently
   verified SHA-256. Artifacts are copied into Application Support/Voca/Models,
   hashed in chunks, and excluded from backup and Git. Model execution uses the integrated Core interfaces. No automatic model startup
   retries are used. A user-selected fallback remains possible after load failure.

## Integration status

Core policy, persistence, canonical contracts, and coaching content are integrated.
The Core-enabled LiteRT executor and cue flow have recorded physical-iPhone builds. Cue decisions are persisted before generation; only full
native playback records completion and permits explicit feedback.

Fetch the official generic models using `python3 scripts/fetch_models.py`.
`config/models.json` pins repository revisions, sizes, and SHA-256 hashes.
Models live under ignored `.local/models/`. Transfer each file to Voca's
Documents directory with `devicectl device copy to`, then select that model and
use **Import staged official model**. Alternatively use the Files importer.
The app prepares one model, the glasses camera and embedded Pipecat automatically.
Select your audio output, approve it once if it is not recognized as the connected
glasses, choose a goal, and use **Get cue**. A model switch
cancels and awaits current cue work before releasing the old engine.

The pinned Pipecat reference includes its modified mobile fork. The app now
bundles its Python runtime and native speech/transcription adapters;
Swift acknowledges full native playback before Pipecat reports completion.
Host checks: `PYTHONPATH=Voca/Voice/Python:.build/pipecat-ios/pipecat/src .build/pipecat-ios/.venv/bin/python -m unittest discover -s Tests/VoiceTests`.
The complete-response LiteRT adapter passed ten repeated photo/cue pipelines each
with E4B and E2B on the phone while Pipecat was loaded, with all cues validated.
Context is capped at 2,048 and visual tokens at 280. Native errors release the
engine. E4B remains primary: a native failure gets one fresh-E4B-engine retry;
if that also fails, the app visibly loads E2B and creates a separately attributed
cue decision. Loading a staged official
artifact imports it with SHA-256 verification automatically. These bounded runs
do not establish long-duration or thermal reliability.
Feedback persistence and utility changes have been checked as described below.
Practice has synthetic on-device model checks; live microphone turn-taking and
full audit/practice interaction still need device verification. A five-second
request-to-speech target, sustained thermal/memory behavior, locked-phone use,
route-loss recovery, and long-term learning benefits are not established.

See [device handoff](docs/handoff-device.md) for exact checks and blockers.

Large-model hash memory regression (Mac, using the downloaded E4B file):

```sh
swiftc -parse-as-library Voca/Inference/ModelArtifact.swift scripts/check_model_hash.swift -o /tmp/voca-hash-check
/tmp/voca-hash-check .local/models/gemma-4-E4B-it.litertlm 0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0
```

Physical E4B text check passed: load 11.18 s, first generation 3.41 s, second
2.00 s. Full photo-to-speech latency and thermal behavior remain unmeasured.

Feedback replay verification (use private before/after app-store exports, never
commit them):

```sh
swiftc -parse-as-library Packages/VocaCore/Sources/VocaCore/*.swift scripts/check_feedback_replay.swift -o /tmp/voca-feedback-check
/tmp/voca-feedback-check /private/path/before.json /private/path/after-relaunch.json
```

Physical-device feedback persisted across relaunch. Canonical Core replay on
copies showed the latest genuine Helpful rating increasing the same-context
strategy utility from 0.75 to 0.8571. Only one strategy was eligible in this check;
it does not demonstrate a changed selection among competing strategies.


### Guided session interface

Opening Voca starts embedded Pipecat, loads E4B when no model is active, and
reconnects the saved glasses and assigned band (18 by default). Settings keeps
connection diagnostics and the audio output picker. Connected Ray-Ban Meta
outputs are recognized using the selected Bluetooth route and the SDK’s connected
device name (or the standard Ray-Ban Meta name). Other outputs ask once; approval
is stored by exact output UID and survives reconnect/relaunch. A changed output
still interrupts speech already in progress, even if the destination was approved.
Practice preserves cue-output approvals.

Get cue uses the current foreground, device, audio, memory and guidance state;
there is no separate session-enable flag to become stale after backgrounding.
It waits for any prior shutdown to finish. Unavailable cue history is retried,
and remaining blockers appear on Session instead of opening Settings. Guidance
readiness in Settings includes cue-history availability.

Complete **Settings → Set up single-tap cues** once. Calibration is saved for the
verified band number and firmware; reconnect resets event history and restores
only the measured timing. **Recalibrate taps** replaces it only after a new complete
check. Cancelling an unfinished recalibration restores the previous saved check.
Older builds did not persist calibration, so their measurements cannot be restored.
Double tap starts memory listening directly; calibration gestures never start
listening. Pending single cues remain suppressed by double taps and lost readiness.
Completed cues show explicit feedback in Session and Review. Optional wording
preferences and approved alternative phrasings guide later cue prompts. These
are style preferences, not personal-memory evidence or model fine-tuning; only
explicit eligible feedback updates the strategy policy.

Memory saves only explicitly approved personal details. Review → Review this
conversation accepts an explicitly confirmed real excerpt with speaker identity;
unknown times stay unknown. Audits wait without wearer evidence, otherwise cite
source IDs and provide one strength, tentative opportunity, and exercise. Deleting
an entry removes dependent reviews/history/learning with retry after interrupted
writes. Historical excerpts never become fresh live dialogue just because saved.

Review → Start spoken practice offers three starting situations (meetup entry,
project explanation, and deeper follow-up) plus an optional custom topic or
situation. “Make it your own” can ask for an interview, a project story, or a
particular conversational style; the partner generates a matching opening.
Change direction aloud or edit “Direction for the next reply” during practice.

The optional **Situation brief** records audience, relationship, topic, and a
private practice goal (240 characters each). **What I’m keeping in mind** shows
session-only context; quoted spoken corrections replace older entries, and notes
can be removed. Up to six fields persist beyond the recent transcript window.
Retained spoken notes preserve the entire original user turn, its ID/time, and
extraction model profile. Pause keeps this state; ending practice clears it.
Nothing here becomes an approved personal memory or survives closing practice.

The microphone opens automatically after completed partner playback. **Thinking
time → Adaptive** allows 3–8 seconds based on observed recognition-update gaps
and whether the current turn is brief or unfinished. **More time** waits eight
seconds; **Finish manually** disables the pause timer. These modes still respect
the capture limit and native recognition finals. Only a final transcript is sent
to the model. Finish sends the turn sooner. Each capture is capped at 55
seconds / 2,000 accepted characters. Recognition requires on-device assets; there
is no cloud fallback. A missing final transcript pauses progress with a Speak
retry; partial words are never silently submitted. Pause turns the microphone
off; Resume reopens it. Interrupt cancels and awaits the previous reply before
listening. The microphone stays off during partner speech: hands-free talk-over
and calibrated acoustic silence detection are not implemented.

The partner is prompted to invite an example, story, reason, or elaboration, one
question at a time. Brief answers invite one example unless the user declines;
detailed turns prompt a reflection without another question by default. These
are conversational heuristics, not assessments of emotion or ability.
Validated replies cannot exceed 45 words. Prompts retain up to
12 recent complete messages within 12,000 characters, plus the editable direction
(up to 500 characters). Only fully played partner replies enter context. Practice
is session-only, separate from personal memories and coaching rewards. Glasses
are not required; practice uses the selected output and the phone microphone.
Backgrounding, ending practice, and audio-route interruptions stop capture.

Checks: `swift test --filter practice` and `python3 scripts/check_live_practice.py`.
Debug launch argument `--practice-model-check` runs three synthetic Gemma E4B
cases on the phone and writes `Documents/practice-model-check.json`; it does not
record audio or add personal history. See
[the live practice verification](docs/ui-preview/live-practice-verification.md)
for measured device results and remaining checks.

The shared waveform and connection glow use red accents. Motion respects Reduce Motion.
The waveform and rotating idle headline animate
only while Session is visible in an active app; reduced motion keeps them static.

See [UI review](docs/ui-review.md) and [Simulator fixtures](docs/ui-preview/README.md).

## Continuous band memory suggestions

Double-tap the connected assigned band, or use **Start listening** in Memory.
There is no repeated in-app listening modal; inline guidance reminds the wearer
to get everyone’s consent. iOS speech permission still applies. Listening resumes
when that assigned band reconnects; **Stop listening** disables it even while the
band is disconnected. Changing the assigned band clears the preference.
Practice pauses band listening and resumes it after practice closes.

The on-device path is band Opus → native PCM → Apple on-device English speech
recognition → durable unapproved suggestions plus embedded Pipecat transcription
frames. Suggestions are saved before waiting for Pipecat acknowledgement, so a
voice-pipeline failure does not erase already captured useful details.
Pipecat's transcription worker is separate from speech playback, so a cue does
not block incoming transcript segments. Recognition renews every 10 seconds,
with up to three seconds of bounded audio buffering during finalization.
Unavailable speech assets, queue overload, decoding and persistence failures
stop capture or visibly report missing segments; there is no cloud fallback.

Only short, exact excerpts about names, interests, work/projects and follow-ups
are proposed, using local NaturalLanguage name tagging and conservative English
rules. This does not require Gemma, summarize conversations, identify the wearer,
or guarantee that every important fact is found. Full transcripts are transient;
raw audio is never written to disk. Suggestions never become approved memories
automatically. Separately, up to four final, gap-free excerpts (500 characters
each, at most 30 seconds old) provide temporary live cue context. A tap finalizes
the current speech window before freezing the cue input. Used excerpts are saved
with that cue for Review, with unknown speaker and `shareApproved == false`.
Missing timestamps, partial results, and audio gaps cannot authorize a live
follow-up. Voca's own playback is excluded from capture context. The cue must
cite dialogue and remains subject to evidence validation and actual native
playback completion. Context that expires during generation is not spoken.

Listening pauses and clears temporary context when the app backgrounds. It can
resume in the foreground when the assigned band and speech pipeline are ready;
Stop listening disables resumption. This is foreground conversation assistance,
not an assertion of reliable locked-phone inference.

Swipe right (or **Approve memory**) to confirm a detail is accurate and yours to
share; swipe left (or **Discard suggestion**) to delete it. Approval keeps the
source ID, capture session, excerpt, gap flag and extraction version. The original
speaker stays unknown in provenance. The approved note has no invented wearer
utterance timestamp. Existing cue/source deletion also removes this provenance.

Memory shows the entire unapproved queue, with separate approval/discard for each
detail. It survives app relaunch. Incomplete recognition can retain an exact useful
excerpt marked as uncertain with an unknown utterance time; it is never sent as
a finalized Pipecat turn. Long speech is split only at sentence/explicit clause
boundaries, never by arbitrary truncation. Pending suggestions are capped at 100
without silently evicting earlier items.
They are stored separately from approved memories, excluded from backup, and
protected until the first unlock after restart to support pending writes. This
storage protection does not imply that background capture remains active. Approved-memory files retain complete file
protection. Discarding all suggestions first stops and drains capture.

The app stops capture on backgrounding. Continuous foreground recognition,
reconnection, gaps, and long-session battery use still require physical band/iPhone
verification before claiming uninterrupted capture. The Bluetooth link remains
unencrypted. Native swipe/VoiceOver behavior also needs device verification.

## Verification and known limits

Recorded reliability checks (2026-11-14): cue prompts now limit evidence to the
selected strategy, preserve canonical source IDs, and retry invalid structured
output at most twice. Malformed JSON and unsupported citations never reach
speech. E4B is readiness-tested before showing Ready; exhausted native or
validation failures can switch to separately attributed E2B output.

The latest live-dialogue handoff records 86 app host tests and 17 Core tests
passing, plus gesture-routing and cue-readiness checks. These are recorded
checkpoint results; rerun the commands above for the current working tree. Physical synthetic stress passed
30 E4B cues and 16 E2B cues before a concurrent app install interrupted that run.
Repeated E4B reload after E2B still has a native model-mapping failure; use E2B,
or restart before retrying E4B. Extended Virtual Addressing cannot be signed
with the current Personal Team and is not enabled. Details, measurements, and
reproduction commands: [device handoff](docs/handoff-device.md). Glasses and
speech were intentionally excluded from this stress test.

Final isolated fallback run: E2B passed all 30 synthetic cases, cancellation,
and post-cancellation generation. Median/max generation: 0.75/1.28 s. E4B's
30-case pass and this E2B pass are separate runs; E4B reload remains unresolved.
