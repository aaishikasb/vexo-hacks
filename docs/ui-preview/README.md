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
