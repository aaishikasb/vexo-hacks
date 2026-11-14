# Voca

Native iPhone conversation companion in active development. **The complete
coaching loop is not yet integrated.** This checkpoint provides the signed-app
setup path, glasses camera client, assigned-band BLE transport, native audio
route test, consented on-device transcription sample, and verified model import.
Core policy, persistence, and coaching content are integrated. The first photo-to-cue
flow and explicit feedback controls are implemented. Review and Memory still show
empty states; memory editing, audits, and practice remain pending. The speech-only embedded Pipecat adapter passed its physical-phone test:
the user heard the phrase through the glasses and confirmed completed playback.

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

# Run after Machine 2's ready Core commit is integrated.
swift test --package-path Packages/VocaCore
```

The SDK has arm64 Simulator binaries; x86_64 Simulator is excluded. The new
Python packaging currently prepares only the physical iPhone extension; repeat
Simulator builds require adding and verifying the simulator cross-build first. Dependency
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
3. Select glasses as the iPhone audio output, then confirm that route in the app.
   “Speak native test phrase” is a **native audio diagnostic**, not Pipecat proof.
   User confirmed the complete native phrase through the glasses on November 14.
   Route changes interrupt speech; phone-speaker fallback is not allowed.
   For the next check, press “Start embedded Pipecat,” wait for ready, then
   “Speak test phrase through Pipecat.” Microphone capture remains off.
4. Enter the band number printed on its bag. Close the laptop dashboard and
   double-tap the band. Only pressing **Connect assigned band** starts scanning.
   Service and exact advertised identity/manufacturer number are checked before
   connecting; GET_INFO is verified before enabling EVENT. Firmware is unchanged.
5. Taps are diagnostic until single/double ordering is measured on the assigned
   band. Feedback is never inferred from a tap. BLE is **not encrypted**.
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

Machine 2’s reviewed branch through `60cc07d` is integrated by merge `8f63592`.
Canonical contracts are imported directly; no duplicate types exist.
Core’s ten tests pass. The Core-enabled LiteRT executor and cue flow build for
the physical iPhone. Cue decisions are persisted before generation; only full
native playback records completion and permits explicit feedback.

Fetch the official generic models using `python3 scripts/fetch_models.py`.
`config/models.json` pins repository revisions, sizes, and SHA-256 hashes.
Models live under ignored `.local/models/`. Transfer each file to Voca's
Documents directory with `devicectl device copy to`, then select that model and
use **Import staged official model**. Alternatively use the Files importer.
Load one model, start the glasses camera and embedded Pipecat, confirm the
output route, select Enter, and use **Request a spoken cue**. A model switch
cancels and awaits current cue work before releasing the old engine.

The pinned Pipecat reference includes its modified mobile fork. The app now
bundles its Python runtime and a custom speech-only FrameProcessor adapter;
Swift acknowledges full native playback before Pipecat reports completion.
Host checks: `PYTHONPATH=Voca/Voice/Python:.build/pipecat-ios/pipecat/src .build/pipecat-ios/.venv/bin/python -m unittest discover -s Tests/VoiceTests`.
No claim is made yet that Gemma produces cues, feedback trains policy, or
audits/practice work. See the handoff for physical Pipecat results.
No five-second latency, thermal, memory, locked-phone, route-loss, or long-term
learning measurements have been made.

See [device handoff](docs/handoff-device.md) for exact checks and blockers.

Large-model hash memory regression (Mac, using the downloaded E4B file):

```sh
swiftc -parse-as-library Voca/Inference/ModelArtifact.swift scripts/check_model_hash.swift -o /tmp/voca-hash-check
/tmp/voca-hash-check .local/models/gemma-4-E4B-it.litertlm 0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0
```

Physical E4B text check passed: load 11.18 s, first generation 3.41 s, second
2.00 s. Full photo-to-speech latency and thermal behavior remain unmeasured.
