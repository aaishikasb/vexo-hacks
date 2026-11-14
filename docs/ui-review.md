# Native interface review

Scope: the six requested better-* skills, adapted to SwiftUI rather than copying
web-only ARIA/CSS rules. This is a source/design review; it is not a shipping
accessibility certification. Glasses are charging, so no glasses camera, audio,
or BLE interaction was performed for this review.

## Direction and brand evidence

The fourth supplied reference is the primary visual direction: a dark, open
session surface, a restrained central voice motif, a clear current state, and
recent content below. Keep the motif decorative; do not display “Listening” or
animate a microphone waveform when capture is off.

[Vexo’s official site](https://www.vexoai.com/) was inspected on 14 November 2026.
Its published site CSS includes neutral dark `#0A0A0A`/`#FAFAFA` theme values, and
its product markup includes Graphite `#1F2023` and Pearl `#E7E3DC`. These support
using near-black, graphite, and warm white here. The orange `#FB651E` in the
homepage belongs to the YC mark; it is not evidence of a Vexo orange brand
accent. Voca should retain its own name and should not imply it is the official
Vexo app. Do not import the site's commercial cloud/privacy claims into the
event-band implementation: its BLE connection remains unencrypted.

## Measured semantic palette

Calculated from declared opaque sRGB hex values using WCAG relative luminance
and `(Llighter + 0.05) / (Ldarker + 0.05)`. Values below are computed, not sampled
from a running screen. Parent implementation owns the centralized native color
tokens; individual components should consume semantic roles.

| Appearance | Foreground role / value | Background role / value | Ratio |
| --- | --- | --- | --- |
| Dark | Foreground `#FAFAFA` | Background `#0A0A0A` | 18.97:1 |
| Dark | Foreground `#FAFAFA` | Surface `#1F2023` | 15.61:1 |
| Dark | Secondary text `#B0B3BA` | Background `#0A0A0A` | 9.43:1 |
| Dark | Secondary text `#B0B3BA` | Surface `#1F2023` | 7.76:1 |
| Both | On-accent `#15171C` | Accent fill `#E7E3DC` | 14.02:1 |
| Light | Foreground `#15171C` | Background `#F5F5F2` | 16.42:1 |
| Light | Foreground `#15171C` | Surface `#FFFFFF` | 17.93:1 |
| Light | Secondary text `#50584F` | Background `#F5F5F2` | 6.75:1 |
| Light | Secondary text `#50584F` | Surface `#FFFFFF` | 7.37:1 |
| Dark | Accent `#E7E3DC` | Background `#0A0A0A` | 15.48:1 |
| Dark | Accent `#E7E3DC` | Surface `#1F2023` | 12.74:1 |

All listed text pairs exceed 4.5:1 (WCAG 1.4.3). Do not add opacity to secondary
text: that would create a different, unmeasured pair. A subtle surface against
the page is not a sufficient input boundary on its own; native input treatment
or a measured 3:1 boundary/focus treatment is still required where the boundary
identifies a control (1.4.11). A decorative waveform has no contrast threshold.

## Flow and copy recommendations

| Severity | Location | Before | Intended treatment | Why |
| --- | --- | --- | --- | --- |
| Medium | `Voca/App/VocaApp.swift` Session | Device diagnostics and startup buttons precede the cue | One Start session action, clear readiness summary, one Get a cue action; detailed controls in setup/settings | Layout: order by importance; reduce sequencing burden |
| Medium | `Voca/App/VocaApp.swift` Session | Pipecat, model artifact, and SHA labels dominate the main flow | Use “Voice”, “On-device model”, and model status in setup; retain hashes in diagnostics/import | Writing: use task language, preserve technical evidence where useful |
| Medium | `Voca/App/VocaApp.swift` band setup | Blank band field and separate low-level actions | Prefill assigned band 18, label Change band, validate exact identity before connecting | Writing: actionable setup; hardware identity requirement stays intact |
| Medium | `Voca/App/VocaApp.swift` cue result | Feedback sits after a long diagnostic form | Full cue text followed immediately by delivery state and Helpful / Unhelpful / Not tried | Layout: group related information; only completed playback permits feedback |
| Medium | `Voca/App/VocaApp.swift` unavailable state | Several controls disabled independently | State the missing dependency and give one recovery action | Writing: errors and unavailable states explain the next step |
| Low | Shared native components | Default form hierarchy only | Native semantic type roles, restrained surfaces, system SF Symbols | Typography/UI: one coherent system without new font dependencies |

Suggested main copy: “Find your own words.” Ready instruction: “Tap band 18 or
request a cue here.” Only show that instruction after tap mapping is enabled and
required devices are ready. While glasses are unavailable: “Connect your glasses
to capture a scene and hear a cue.” Do not pretend a hardware-dependent action
succeeded. Useful goals: “Start a conversation”, “Go deeper”, “Explain a point”,
while preserving Core's canonical enum values. Explain has a visible field label;
Deepen states that attributable dialogue is required.

## Native verification checklist

- Use native Button, Picker, Toggle, TextField, Sheet and TabView semantics.
- Give icon-only toolbar actions an action-based accessibility label. Hide only
  decorative waveform artwork from VoiceOver; expose the textual state beside it.
- Use text plus an icon for readiness, failure and delivery; never color alone
  (1.4.1). Announce meaningful completion/errors without repeated noisy updates.
- Use Dynamic Type styles; permit full cue/error wrapping and scrolling. Avoid
  fixed text heights, `.minimumScaleFactor` as a clipping workaround, and hidden
  truncation. Check accessibility text sizes and the narrowest supported width
  (1.4.4/1.4.10 analogues).
- Use leading/trailing alignment and native layout direction. Let goal controls
  and feedback actions stack at larger text sizes rather than squeeze labels.
- Prefer at least 44-point touch targets; this is a native usability target, not
  the WCAG CSS-pixel minimum. Do not overlap expanded hit areas.
- Keep movement absent or gate it on `accessibilityReduceMotion`; the decorative
  motif can remain static. A spinner must be paired with status and cancellation.
- Keep microphone capture off by default. Starting a session must not imply
  consent to record bystanders or enable band AUDIO/MIC_LEVEL streams.
- Route confirmation and tap-detector calibration remain explicit. A setup flow
  cannot infer either from pairing or a generic “connected” state.

## Simulator fixture rendering

A temporary simulator app compiled the actual Session/Setup SwiftUI source and
shared visual components, with no-op hardware/model dependencies and one synthetic
completed cue. iPhone 17e Simulator, iOS 27.2, 390-point width. It neither loaded
Gemma nor connected glasses/band, captured audio, or changed policy rewards.

- Default dark Session: hero, readiness, goal and primary action fit without text
  truncation. The original toolbar wordmark truncated; native inline navigation
  title fixed it and was re-rendered.
- Synthetic completed cue: full cue and all three feedback controls fit in the
  bottom content render; feedback correctly changes from a row to a column.
- Setup top/bottom: full assigned-band field, calibration disclosure, privacy copy
  and final actions are present. Updated captures include idle-state copy and the
  native route picker.
- Accessibility3 with RTL: layout mirrors and body/hero wrap. Found native menu
  Picker label vertical clipping. The implementation owner replaced it with a
  wrapping native Menu label; re-render confirmed both lines fully visible.
- Bottom captures used a fixture-only default scroll anchor. CUA could not access
  Simulator, so gesture scrolling, control activation and keyboard behavior were
  not verified by these screenshots.

Evidence: [Simulator fixture captures](ui-preview/README.md). The temporary
rendering harness remains outside Git at `/tmp/voca-ui-preview` for reproduction.
All images are fixtures, not a real-device or full dependency build.

Not verified: VoiceOver order/names/announcements, external-keyboard navigation,
Switch Control, maximum Dynamic Type, localized translations, physical tap timing,
locked-device behavior or camera/audio startup. Contrast above remains a declared
opaque-token calculation, not a composited pixel audit.
