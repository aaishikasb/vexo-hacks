import SwiftUI

/// Decorative pairing states; the adjacent readiness rows carry accessible status.
struct DeviceConnectionVisual: View {
    let connected: Bool
    let connecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color.accentColor.opacity(0.28), .clear],
                                     center: .center, startRadius: 0, endRadius: 120))
                .frame(width: 240, height: 140)
                .blur(radius: reduceMotion ? 0 : 16)
                .offset(y: 40)
                .opacity(connected ? 1 : connecting ? 0.75 : 0.3)

            HStack(spacing: 24) {
                device("eyeglasses")
                    .rotationEffect(.degrees(reduceMotion || connected ? 0 : -8))
                    .offset(x: reduceMotion ? 0 : connected ? 8 : -8)

                ZStack {
                    Capsule().fill(.secondary.opacity(0.3)).frame(width: 32, height: 1)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(VocaTheme.foreground)
                        .background(VocaTheme.background, in: Circle())
                        .opacity(connected ? 1 : 0)
                }.frame(width: 32)

                device("applewatch")
                    .rotationEffect(.degrees(reduceMotion || connected ? 0 : 8))
                    .offset(x: reduceMotion ? 0 : connected ? -8 : 8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0), value: connected)
        .animation(.easeOut(duration: 0.15), value: connecting)
        .accessibilityHidden(true)
    }

    private func device(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(VocaTheme.foreground)
            .frame(width: 68, height: 68)
            .background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }
}
