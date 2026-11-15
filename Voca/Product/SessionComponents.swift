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
        configuration.label.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            .padding(.horizontal, 20)
            .foregroundStyle(VocaTheme.onAccent)
            .background(VocaTheme.accent, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Decorative voice activity follows pipeline state; it is not a measured audio level.
struct CueWave: View {
    let active: Bool
    var speaking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion || scenePhase != .active)) { timeline in
            let time = active && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let speed = speaking ? 2.8 : 1.2
                for layer in 0..<4 {
                    var ribbon = Path()
                    let phase = time * speed + Double(layer) * 0.9
                    let amplitude = (speaking ? 24.0 : 16.0) + Double(layer) * 4
                    for side in [1.0, -1.0] {
                        for sample in 0...120 {
                            let x = side == 1 ? Double(sample) / 120 : 1 - Double(sample) / 120
                            let envelope = pow(sin(x * .pi), 3)
                            let center = sin(x * .pi * 3 + phase) * amplitude * envelope
                            let thickness = (3 + 9 * (1 + sin(phase + x * .pi * 2)) / 2) * envelope
                            let point = CGPoint(x: x * size.width, y: size.height / 2 + center + side * thickness)
                            if side == 1 && sample == 0 { ribbon.move(to: point) } else { ribbon.addLine(to: point) }
                        }
                    }
                    ribbon.closeSubpath()
                    context.blendMode = .plusLighter
                    context.fill(ribbon, with: .linearGradient(
                        Gradient(colors: [VocaTheme.wave.opacity(0.05), (layer.isMultiple(of: 2) ? VocaTheme.wave : VocaTheme.glow).opacity(0.6), VocaTheme.wave.opacity(0.05)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
                }
            }
        }
        .frame(maxWidth: .infinity).frame(height: 112)
        .background {
            Ellipse().fill(VocaTheme.glow.opacity(active ? 0.22 : 0.12)).frame(height: 40).blur(radius: 28)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct ReadinessRow: View {
    let title: String
    let detail: String
    let ready: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PhosphorIcon(ready ? "checkmark.circle" : "circle.dashed")
                .font(.body.weight(.medium)).frame(minWidth: 24)
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

struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .label
        view.accessibilityLabel = "Choose audio output"
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}


struct VocaSecondaryButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .frame(minHeight: 44).padding(.horizontal, 16)
            .foregroundStyle(VocaTheme.foreground)
            .background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(VocaTheme.surfaceEdge, lineWidth: 1))
            .opacity(!enabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct VocaSectionHeading: View {
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct VocaEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhosphorIcon(symbol, size: 24).foregroundStyle(VocaTheme.secondary).accessibilityHidden(true)
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(VocaTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).vocaSurface()
    }
}

extension View {
    func vocaSurface() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [VocaTheme.surfaceRaised, VocaTheme.surface], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VocaTheme.surfaceEdge, lineWidth: 0.5))
    }
}

struct CueGenerationView: View {
    var phase: CuePhase? = nil
    var active = true
    @State private var verbIndex = 0
    @State private var titleVisible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let verbs = ["Converse", "Talk", "Communicate", "Work", "Network", "Connect"]
    private var rotating: Bool { active && phase == nil && !reduceMotion && scenePhase == .active }

    var body: some View {
        VStack(spacing: 16) {
            CueWave(active: active, speaking: phase == .speaking)
                .padding(.horizontal, -24)
            Group {
                if let phase { Text(phase.title).contentTransition(.opacity) }
                else {
                    ZStack {
                        // Reserve the longest phrase so larger text never moves the controls.
                        Text("Communicate better.").hidden().accessibilityHidden(true)
                        Text("\(verbs[verbIndex]) better.").opacity(titleVisible ? 1 : 0)
                    }
                }
            }
            .font(.title.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phase?.title ?? "Converse better.")
            .accessibilityAddTraits(.isHeader)
            if let phase {
                Text(phase.detail).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                HStack(spacing: 16) {
                    ForEach(Array(["Context", "Cue", "Playback"].enumerated()), id: \.offset) { index, title in
                        VStack(spacing: 8) {
                            Rectangle().fill(index <= phase.step ? VocaTheme.wave : VocaTheme.surfaceEdge).frame(height: 2)
                            Text(title).font(.caption.weight(index == phase.step ? .semibold : .regular))
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity)
                            .foregroundStyle(index == phase.step ? VocaTheme.foreground : VocaTheme.secondary)
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(index < phase.step ? "Complete" : index == phase.step ? "In progress" : "Waiting")
                    }
                }.padding(.top, 8)
            }
        }.frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.3), value: phase)
            .task(id: rotating) {
                titleVisible = true
                guard rotating else { verbIndex = 0; return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(2850)) } catch { return }
                    withAnimation(.easeOut(duration: 0.15)) { titleVisible = false }
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    verbIndex = (verbIndex + 1) % verbs.count
                    withAnimation(.easeOut(duration: 0.15)) { titleVisible = true }
                }
            }
    }
}


/// A brief conversation on entry, reused by the practice invitation and its setup.
struct PracticeInvitationVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    var body: some View {
        ZStack {
            PhosphorIcon("bubble.left", size: 24).foregroundStyle(VocaTheme.wave)
                .offset(x: -6, y: -5)
                .phaseAnimator([0.0, 1.0, 0.0], trigger: entered) { content, phase in
                    content.offset(y: reduceMotion ? 0 : -4 * phase).opacity(0.75 + 0.25 * phase)
                } animation: { _ in .easeInOut(duration: 0.4) }
            PhosphorIcon("bubble.right.fill", size: 24).foregroundStyle(VocaTheme.foreground)
                .offset(x: 7, y: 6)
                .phaseAnimator([0.0, 1.0, 0.0], trigger: entered) { content, phase in
                    content.offset(x: reduceMotion ? 0 : -4 * phase).opacity(0.65 + 0.35 * phase)
                } animation: { _ in .easeInOut(duration: 0.5) }
        }.frame(width: 44, height: 44)
            .background(VocaTheme.glow.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .dynamicTypeSize(.large)
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { entered.toggle() }
    }
}
