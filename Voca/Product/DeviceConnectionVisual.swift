import SwiftUI

/// Decorative pairing states; the adjacent readiness rows carry accessible status.
struct DeviceConnectionVisual: View {
    let connected: Bool
    let connecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = 0

    var body: some View {
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [VocaTheme.glow.opacity(0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: 140))
                .frame(width: 280, height: 140)
                .blur(radius: 16)
                .offset(y: 20)
                .phaseAnimator([0.0, 1.0, 0.0], trigger: pulse) { content, phase in
                    content
                        .scaleEffect(reduceMotion ? 1 : 1 + phase * 0.12)
                        .opacity((connected ? 0.85 : connecting ? 0.7 : 0.45) + phase * 0.15)
                } animation: { _ in .easeInOut(duration: 0.6) }

            HStack(spacing: 16) {
                device("eyeglasses")
                    .offset(x: reduceMotion || appeared ? 0 : -12, y: reduceMotion || appeared ? 0 : 8)

                ZStack {
                    Rectangle().fill(VocaTheme.surfaceEdge).frame(height: 1)
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, VocaTheme.wave, .clear], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .phaseAnimator([0.0, 1.0, 0.0], trigger: pulse) { content, phase in
                            content.opacity((connected ? 0.8 : 0.25) + phase * 0.2)
                        } animation: { _ in .easeInOut(duration: 0.6) }
                    PhosphorIcon(connected ? "checkmark" : connecting ? "link" : "ellipsis", size: 16)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(connected ? VocaTheme.wave : VocaTheme.secondary)
                        .frame(width: 28, height: 28)
                        .background(VocaTheme.background, in: Circle())
                        .contentTransition(.opacity)
                }.frame(width: 56)

                device("applewatch")
                    .offset(x: reduceMotion || appeared ? 0 : 12, y: reduceMotion || appeared ? 0 : 8)
            }
            .opacity(appeared ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .dynamicTypeSize(.large)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.3), value: appeared)
        .animation(.easeOut(duration: 0.3), value: connected)
        .animation(.easeOut(duration: 0.3), value: connecting)
        .onAppear { appeared = true; pulse += 1 }
        .onChange(of: connected) { _, _ in pulse += 1 }
        .onChange(of: connecting) { _, _ in pulse += 1 }
        .accessibilityHidden(true)
    }

    private func device(_ symbol: String) -> some View {
        PhosphorIcon(symbol, size: 28)
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(VocaTheme.foreground)
            .frame(width: 68, height: 68)
            .background(LinearGradient(colors: [VocaTheme.surfaceRaised, VocaTheme.surface],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VocaTheme.surfaceEdge, lineWidth: 1))
            .shadow(color: VocaTheme.glow.opacity(connected ? 0.18 : 0.08), radius: 16, y: 8)
    }
}
