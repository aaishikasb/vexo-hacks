# Simulator UI fixtures

Captured 14 November 2026 on iPhone 17e Simulator, iOS 27.2 (390-point width).
These compile the actual Session/Setup views and shared visual components with
no-op hardware/model dependencies. The completed cue is synthetic. No model,
camera, band, microphone, audio playback, or learning behavior is demonstrated.

- `session.png`: default dark Session, unavailable hardware.
- `setup.png`: setup sheet, top.
- `setup-bottom.png`: setup sheet, bottom with native audio output picker.
- `cue-feedback.png`: synthetic completed cue, all feedback choices.
- `accessibility3-rtl.png`: Accessibility3 size, RTL layout, bottom of Session.

Bottom views use a fixture-only default scroll anchor. They verify rendering at
the bottom of the scroll content, not actual gesture navigation or VoiceOver.
See ../ui-review.md for the review and remaining verification scope.

## Memory, Review, and Practice fixtures

Captured later on 14 November 2026 on the same iPhone 17e Simulator. These
compile the actual MemoryView, MemoryStore, AuditView, PracticeView, shared
components, and extracted Review layout/cue-card code. Model, speech, and
practice-session services are no-op stubs; all displayed personal material,
cue text, delivery status, and feedback are synthetic fixture content.

- `memory-empty.png`: empty approved-memory form.
- `memory-filled.png`: synthetic approved memory, full text and deletion action.
- `memory-accessibility3.png`: saved-memory/privacy section at Accessibility3.
- `audit-waiting.png`: no transcript, useful waiting state and evidence action.
- `audit-accessibility3.png`: large-text review action and privacy explanation.
- `review-history.png`: extracted actual Review layout with synthetic completed
  cue and Saved as helpful feedback.
- `practice.png`: initial practice screen with bundled scenario title, selected-output copy, status above the selector, and Start practice action (refreshed after device feedback).
- `practice-accessibility3.png`: full wrapping scenario title after fixing
  native Picker clipping at Accessibility3.

Large-text bottom/middle views use fixture-only default scroll anchors. No
gesture navigation, keyboard, VoiceOver, permission prompts, microphone, speech
recognition, model generation, audit quality, or hardware behavior was verified
by these screenshots. The fixture writes only synthetic data in its own sandbox.
