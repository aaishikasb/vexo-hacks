import SwiftUI
import VocaCore

struct PracticeView: View {
    let model: any ModelGenerating
    let voice: PipecatSpeech
    let audio: NativeAudio
    @State private var practice = PracticeSession()
    @State private var scenarios: [PracticeScenario] = []
    @State private var selectedID = ""
    @State private var contentError: String?
    @State private var preparing = false
    @State private var stopping = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("A little rehearsal.").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("A simulated conversation using your selected audio output. Nothing here becomes a personal memory or a rating.")
                        .foregroundStyle(VocaTheme.secondary)
                    Label(practice.status, systemImage: practice.listening ? "mic.fill" : "bubble.left.and.bubble.right")
                        .font(.subheadline).accessibilityElement(children: .combine)
                    if let contentError { Text(contentError) }
                    else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Practice scenario").font(.headline)
                            Menu {
                                Picker("Practice scenario", selection: $selectedID) {
                                    ForEach(scenarios) { Text($0.title).tag($0.id) }
                                }
                            } label: {
                                HStack(alignment: .top) {
                                    Text(scenarios.first(where: { $0.id == selectedID })?.title ?? "Choose a scenario")
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.bordered)
                                .accessibilityLabel("Practice scenario")
                                .accessibilityValue(scenarios.first(where: { $0.id == selectedID })?.title ?? "Choose a scenario")
                                .disabled(practice.enabled || preparing)
                        }
                        if !practice.enabled {
                            Text("Use your selected output in a private place. Voca listens only after you tap Speak; Finish sends the final transcript for an on-device reply.")
                                .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                            HStack {
                                Text("Audio output").font(.subheadline)
                                Spacer()
                                AudioOutputPicker().frame(width: 48, height: 48)
                            }
                            Button(preparing ? "Starting practice…" : "Start practice") {
                                guard let scenario = scenarios.first(where: { $0.id == selectedID }) else { contentError = "Choose a practice scenario before starting."; return }
                                preparing = true
                                Task { await practice.start(scenario: scenario, model: model, voice: voice, audio: audio); preparing = false }
                            }.buttonStyle(VocaPrimaryButton()).disabled(preparing)
                        }
                    }
                    if !practice.partial.isEmpty && practice.listening {
                        Text(practice.partial).foregroundStyle(VocaTheme.secondary)
                            .accessibilityLabel("Partial transcript: \(practice.partial)")
                    }
                    ForEach(practice.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message.fromUser ? "You · practice" : "Simulated partner").font(.caption).foregroundStyle(VocaTheme.secondary)
                            Text(message.text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let profile = message.profile {
                                Text(profile.modelID == .gemma4E4B ? "E4B · on device" : "E2B · on device")
                                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                    }
                    if practice.enabled {
                        if practice.listening {
                            Button("Finish my turn") { practice.finishListening(audio: audio) }.buttonStyle(VocaPrimaryButton())
                        } else {
                            Button(practice.startingListening ? "Opening microphone…" : practice.busy ? "Interrupt and speak" : "Speak my turn") {
                                Task { await practice.listen(model: model, voice: voice, audio: audio) }
                            }.buttonStyle(VocaPrimaryButton()).disabled(practice.startingListening)
                        }
                        Button("End practice", role: .cancel) { stopPractice(dismissAfter: false) }
                            .frame(minHeight: 44)
                    }
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity).disabled(stopping)
            }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
                .navigationTitle("Practice").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(stopping ? "Stopping…" : "Done") { stopPractice(dismissAfter: true) }.disabled(stopping)
                } }
        }
        .interactiveDismissDisabled(practice.enabled || preparing || practice.startingListening || stopping)
        .task {
            do {
                guard let url = Bundle.main.url(forResource: "practice-scenarios", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                scenarios = try JSONDecoder().decode([PracticeScenario].self, from: Data(contentsOf: url))
                selectedID = scenarios.first?.id ?? ""
            } catch { contentError = "Practice scenarios could not be opened. Restart Voca to retry." }
        }
        .onDisappear {
            if practice.enabled || practice.busy || practice.listening { stopPractice(dismissAfter: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopPractice(dismissAfter: false) }
        }
    }

    private func stopPractice(dismissAfter: Bool) {
        guard !stopping else { return }
        stopping = true
        Task {
            await practice.stop(voice: voice, audio: audio)
            stopping = false
            if dismissAfter { dismiss() }
        }
    }
}
