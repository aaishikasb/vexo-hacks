# Vexo device subtask handoff

## Scope and identity

Assigned band is **18**, per the user's final correction (18 supersedes the brief
10 report). The parent reports blue blinking and has instructed the user to enter
18 and use Voca's explicit Connect action. This subtask performed **no BLE scan,
connection, stream activation, or physical audio capture**.

Inspected Vexo Open Kit revision:
`1e4291e2fa4896b1f603d3d4f0b009c483425da0`, contract v1.1 and `docs/speech.md`.
Firmware remains unchanged. No cloud transcription dependencies were added.

## Changes

- Reject empty Opus AUDIO frames before decoding.
- Validate returned active-stream masks: EVENT and AUDIO must actually start;
  AUDIO and MIC_LEVEL must both be absent after listening stops. Failed STOP
  acknowledgement disconnects instead of claiming a verified mic shutdown.
- Allow listening only after GET_INFO and initial stream setup complete.
- Expose `BandClient.taps.observations`: bounded last 32 raw tap observations,
  each with `milliseconds`, `code`, `receivedAt`, and `duplicate`. Receipt order
  is retained across band clock wrap; duplicate events cannot invoke a second
  mapped single action. `tapMappingVerified` stays false until physical timing
  is measured. The contract does not specify whether single events precede a
  double, so no gesture delay/window was invented.
- Disconnect and critical-battery notices terminate the active listening flow.
- Fence audio/error/timer callbacks by listening generation; reject a new start
  while STOP is awaiting acknowledgement. Preserve final transcript callbacks
  for their original source only. Keep `sourceID`, approximate `utteredAt`,
  `isFinal`, and `hasGap` in the ephemeral listening state. Gaps clear timestamp
  validity and reset the native decoder. Speaker remains unknown; nothing is
  saved or promoted to personal memory.
- Preserve the actionable decoder/transcriber failure message during cleanup.

## Verification

- `swift test --scratch-path /tmp/voca-band-checks`: 14 fixture tests passed,
  including the parent's two new cue pipeline tests. Band additions cover exact
  assignment/manufacturer conflicts, empty audio rejection, START/STOP masks,
  bounded tap ordering, duplicates, and clock wrap. Existing Opus, response
  matching, and audio timeline checks also passed.
- Final assignment was restored to 18 after the full run; focused assignment
  rerun results are reported to the parent separately.
- `git diff --check`: passed.
- BandClient/BandListening iOS compilation must be included in the parent's next
  app build; root Swift fixtures do not compile CoreBluetooth/Speech services.

## Physical verification still needed

1. Close the laptop Bluetooth dashboard **and USB serial dashboard sessions**;
   unplug USB if it is currently connected to a data host. USB may own streams
   even while a BLE client is connected. Charging alone is not a BLE connection.
2. Enter 18, double-tap for blue blinking, then use Voca's explicit Connect.
   Verify exact advertised identity, GET_INFO number/protocol/capabilities/frame
   size, and EVENT acknowledgement. Log only nonpersonal metadata.
3. Display the bounded tap observations in the diagnostic UI. Perform spaced
   single and double taps; determine ordering and detector intervals before
   enabling a single-tap coaching mapping. Audits and ratings remain explicit.
4. Only after taps pass, obtain nearby people's consent for the short sample.
   Verify blue indicator, native iPhone Opus decoding and local speech assets,
   approximate timing/gap behavior, and both AUDIO/MIC_LEVEL stopped at finish.
   No cloud fallback, automatic speaker identity, or approved memory is implied.

No commit was created; changes are ready for the parent to integrate and commit.
