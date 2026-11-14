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
- Camera capture/Meta compatibility: user granted Always Allow, but startup remained in Working without a photo. Recovery build installed: checks existing permission, retains the selector, reports registration/compatibility/session state, and bounds UI wait to 25 seconds and stream startup to 15 seconds. Awaiting retest; camera checkpoint has NOT passed.
- No assigned band number or scan authorization was provided; **no agent band
  scan/connection/capture was performed**.
- No measured Gemma cold/warm latency, memory, thermal, locked-phone behavior,
  glasses playback, or combined Pipecat/Gemma runtime result exists yet.

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
2. Pipecat iOS reference requires modified Apple bridge modules that are not in
   the official main checkout. User has no copy. See `dependencies.md` for
   inspected revisions and native dependency chain. Runtime packaging and custom
   Gemma/native-TTS adapters are **not implemented or tested**. No alternate
   server, cloud, or Foundation Models path was substituted.
3. Gemma artifacts must be imported with known hashes. Executor cancellation,
   priority, warmup, E2B session switching, and attribution need Core-backed tests
   and real-device validation before enabling the coaching path. Currently load
   is manual; failed load does not create a startup retry loop.
4. Await real camera result, then native phrase route proof, then Pipecat speech
   proof. Only after explicit assigned-band authorization perform GET_INFO/tap
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
