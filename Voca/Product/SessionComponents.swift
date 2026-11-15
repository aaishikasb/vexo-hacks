import SwiftUI
import AVKit

/// Semantic colors keep the conversation surface independent of device diagnostics.
enum VocaTheme {
    static let background = adaptive(light: 0xF5F5F2, dark: 0x000000)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x141416)
    static let surfaceRaised = adaptive(light: 0xFFFFFF, dark: 0x202027)
    static let surfaceEdge = adaptive(light: 0xD7D7DC, dark: 0x34343F)
    static let foreground = adaptive(light: 0x15171C, dark: 0xFAFAFA)
    static let secondary = adaptive(light: 0x50584F, dark: 0xB0B3BA)
    static let accent = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let glow = Color(red: 0.85, green: 0.06, blue: 0.12)
    static let wave = Color(red: 1, green: 0.32, blue: 0.32)
    static let border = adaptive(light: 0x767680, dark: 0x73737D)
    static let onAccent = Color(red: 21.0 / 255, green: 23.0 / 255, blue: 28.0 / 255)
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct VocaPrimaryButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16).padding(.vertical, 4)
            .foregroundStyle(VocaTheme.onAccent)
            .background(VocaTheme.accent, in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Request feedback, never presented as microphone activity or an audio meter.
struct CueWave: View {
    var trigger = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entrance = false
    var body: some View {
        Canvas { context, size in
            for layer in 0..<3 {
                var path = Path()
                for step in 0...120 {
                    let x = Double(step) / 120
                    let envelope = pow(sin(x * .pi), 3)
                    let y = size.height / 2 + sin(x * .pi * 4 + Double(layer) * 0.8) * envelope * Double(12 + layer * 7)
                    let point = CGPoint(x: x * size.width, y: y)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(VocaTheme.accent.opacity(0.35 + Double(layer) * 0.25)), lineWidth: 1.5)
            }
        }
        .frame(height: 80)
        .phaseAnimator([false, true, false], trigger: trigger + (entrance ? 1 : 0)) { content, lifted in
            content
                .scaleEffect(x: 1, y: lifted && !reduceMotion ? 1.16 : 1)
                .opacity(lifted ? 1 : 0.8)
        } animation: { _ in .easeInOut(duration: 0.25) }
        .onAppear { entrance = true }
        .accessibilityHidden(true)
    }
}

struct ReadinessRow: View {
    let title: String
    let detail: String
    let ready: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.body.weight(.medium)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(VocaTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(VocaTheme.foreground).padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityValue(ready ? "Ready" : "Needs setup")
    }
}

struct GuidanceOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var moving = false
    var body: some View {
        ZStack {
            ZStack {
                Circle().fill(RadialGradient(colors: [.black, Color.blue.opacity(0.65), .black],
                                             center: .topLeading, startRadius: 8, endRadius: 180))
                Ellipse().fill(LinearGradient(colors: [.cyan.opacity(0.7), .blue.opacity(0.25), .clear],
                                              startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(height: 70).rotationEffect(.degrees(-25)).blur(radius: 18)
            }
            .rotationEffect(.degrees(moving ? 360 : 0))
            // A slow continuous turn indicates ongoing generation, not measured progress.
            .animation(moving ? .linear(duration: 8).repeatForever(autoreverses: false) : nil, value: moving)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }.frame(width: 176, height: 176).clipShape(Circle())
            .frame(maxWidth: .infinity).padding(.vertical, 16).accessibilityHidden(true)
            .onAppear { moving = !reduceMotion && scenePhase == .active }
            .onChange(of: scenePhase) { _, phase in moving = !reduceMotion && phase == .active }
            .onChange(of: reduceMotion) { _, reduced in moving = !reduced && scenePhase == .active }
            .onDisappear { moving = false }
    }
}

struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        view.accessibilityLabel = "Choose audio output"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

extension View {
    func vocaSurface() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [VocaTheme.surfaceRaised, VocaTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VocaTheme.surfaceEdge, lineWidth: 0.5))
    }
}
