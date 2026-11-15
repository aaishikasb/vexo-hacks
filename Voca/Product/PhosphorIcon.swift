import SwiftUI

/// Bundled Phosphor artwork. Template rendering inherits each control's semantic color.
struct PhosphorIcon: View {
    private let name: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20
    @Environment(\.layoutDirection) private var layoutDirection

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Self.image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .scaleEffect(x: mirrorsInRightToLeft && layoutDirection == .rightToLeft ? -1 : 1)
            .accessibilityHidden(true)
    }

    /// Keep the asset's 24pt intrinsic size when used by a native tab item.
    static func image(_ name: String) -> Image {
        Image(assetName(name)).renderingMode(.template)
    }

    static func assetName(_ name: String) -> String {
        "phosphor-" + (aliases[name] ?? name)
    }

    private var mirrorsInRightToLeft: Bool {
        ["caret-right", "arrow-right", "arrow-up-right"].contains(Self.aliases[name] ?? name)
    }

    // Existing screen semantics map to Phosphor's official names. The assets are
    // deliberately a small, pinned subset; new names must be bundled with callers.
    private static let aliases: [String: String] = [
        "gearshape": "gear-six",
        "text.bubble": "chat-text",
        "text.bubble.fill": "chat-text-fill",
        "person.text.rectangle": "identification-card",
        "person.text.rectangle.fill": "identification-card-fill",
        "waveform.fill": "waveform-fill",
        "mic": "microphone",
        "mic.fill": "microphone-fill",
        "mic.slash": "microphone-slash",
        "checkmark.circle": "check-circle",
        "checkmark.circle.fill": "check-circle-fill",
        "exclamationmark.circle": "warning-circle",
        "chevron.right": "caret-right",
        "chevron.down": "caret-down",
        "chevron.up.chevron.down": "caret-up-down",
        "arrow.up.right": "arrow-up-right",
        "arrow.right": "arrow-right",
        "arrow.clockwise": "arrow-clockwise",
        "hand.thumbsup": "thumbs-up",
        "hand.thumbsdown": "thumbs-down",
        "minus.circle": "minus-circle",
        "circle.dashed": "circle-dashed",
        "circle.inset.filled": "dot-outline",
        "circle.fill": "circle-fill",
        "applewatch": "watch",
        "checkmark": "check",
        "ellipsis": "dots-three",
        "bubble.left": "chat",
        "bubble.right.fill": "chat-fill",
        "bubble.left.and.bubble.right": "chats",
        "person": "user",
        "info.circle": "info",
        "quote.bubble": "quotes",
        "play.fill": "play-fill",
        "pause.fill": "pause-fill",
        "stop.fill": "stop-fill",
        "play.circle": "play-circle",
        "pause.circle": "pause-circle",
        "xmark": "x",
        "speaker.wave.2": "speaker-high",
        "questionmark.circle": "question",
        "checkmark.shield": "shield-check",
        "arrow.down.to.line": "download-simple",
        "pencil": "pencil-simple"
    ]
}

struct PhosphorLabel: View {
    private let title: String
    private let icon: String
    private let size: CGFloat

    init(_ title: String, icon: String, size: CGFloat = 20) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Label { Text(title) } icon: { PhosphorIcon(icon, size: size) }
    }
}
