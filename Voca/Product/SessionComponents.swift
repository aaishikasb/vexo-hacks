import SwiftUI
import AVKit

/// Semantic colors keep the conversation surface independent of device diagnostics.
enum VocaTheme {
    static let background = adaptive(light: 0xF5F5F2, dark: 0x0A0A0A)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1F2023)
    static let foreground = adaptive(light: 0x15171C, dark: 0xFAFAFA)
    static let secondary = adaptive(light: 0x50584F, dark: 0xB0B3BA)
    static let accent = adaptive(light: 0xE7E3DC, dark: 0xE7E3DC)
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

/// A static brand motif, never presented as microphone activity or an audio meter.
struct CueWave: View {
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
        }.frame(height: 80).accessibilityHidden(true)
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
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [.black, Color.blue.opacity(0.65), .black],
                                         center: .topLeading, startRadius: 8, endRadius: 180))
            Ellipse().fill(LinearGradient(colors: [.cyan.opacity(0.7), .blue.opacity(0.25), .clear],
                                          startPoint: .bottomLeading, endPoint: .topTrailing))
                .frame(height: 70).rotationEffect(.degrees(-25)).blur(radius: 18)
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }.frame(width: 176, height: 176).clipShape(Circle())
            .frame(maxWidth: .infinity).padding(.vertical, 16).accessibilityHidden(true)
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
