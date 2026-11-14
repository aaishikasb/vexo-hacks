# Voca

Native iPhone conversation companion in active development. **The complete
coaching loop is not yet integrated.** This checkpoint provides the signed-app
setup path, glasses camera client, assigned-band BLE transport, native audio
route test, consented on-device transcription sample, and verified model import.
Review and Memory currently show honest empty/setup states. Core, coaching
content, Pipecat voice orchestration, audits, practice, and learned feedback
integration remain pending.

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

The SDK has arm64 Simulator binaries; x86_64 Simulator is excluded. Dependency
versions and exact inspected revisions are in [docs/dependencies.md](docs/dependencies.md)
and the Xcode workspace's committed `Package.resolved`.

## Device setup and boundaries

1. Connect/unlock the iPhone, trust this Mac, enable Developer Mode. Actual check
   on 14 November: iPhone 18 Pro Max, iOS 27.2, paired, wired, Developer Mode enabled.
2. Connect glasses through Meta AI using the app. Camera permission opens Meta AI;
   start the camera and request a photo. Already-granted permission is reused;
   startup reports its stage and times out with a retry path. Photos remain in app memory. The supplied
   Meta AI/glasses/DAT versions are user-reported baselines; compatibility with
   resolved iOS DAT 1.0.1 still needs a real capture test.
3. Select glasses as the iPhone audio output, then confirm that route in the app.
   “Speak native test phrase” is a **native audio diagnostic**, not Pipecat proof.
   Route changes interrupt speech; phone-speaker fallback is not allowed.
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
   hashed in chunks, and excluded from backup and Git. Model execution controls
   become available only once Core is integrated. No automatic model startup
   retries are used. A user-selected fallback remains possible after load failure.

## Integration status

Machine 2 owns `Packages/VocaCore` and coaching resources. No duplicate shared
contracts were created. `LiteRTExecutor.swift` imports Core conditionally so
independent device setup can build while that package is absent; **its Core-bound
implementation is not yet compiled or verified**. Remove this temporary boundary
once the real package and product integration are ready.

The Pipecat reference needs missing modified mobile modules; details and recovery
work are in the dependency note. Nothing in this checkpoint claims that Pipecat
launches, Gemma produces cues, feedback trains policy, or audits/practice work.
No five-second latency, thermal, memory, locked-phone, route-loss, or long-term
learning measurements have been made.

See [device handoff](docs/handoff-device.md) for exact checks and blockers.
