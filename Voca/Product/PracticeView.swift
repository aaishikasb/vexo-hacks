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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var scenarioTitle: String {
        scenarios.first(where: { $0.id == selectedID })?.title ?? "Choose a scenario"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if practice.enabled {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(scenarioTitle).font(.title2.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                                Text("Live practice · Simulated conversation").font(.caption).foregroundStyle(VocaTheme.secondary)
                            }
                            directionInput
                            situationBrief
                            retainedContext
                        } else { preparation }
                        if let contentError {
                            PhosphorLabel(contentError, icon: "exclamationmark.circle")
                                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 24) {
                            ForEach(practice.messages) { message in
                                VStack(alignment: .leading, spacing: 8) {
                                    PhosphorLabel(message.fromUser ? "You" : "Practice partner",
                                          icon: message.fromUser ? "person" : "sparkle")
                                        .font(.caption.weight(.medium)).foregroundStyle(VocaTheme.secondary)
                                    Text(message.text).font(.body).lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(message.fromUser ? 16 : 0)
                                .background(message.fromUser ? VocaTheme.surface : VocaTheme.background,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            if !practice.partial.isEmpty && practice.listening {
                                VStack(alignment: .leading, spacing: 8) {
                                    PhosphorLabel("Your words so far", icon: "mic").font(.caption.weight(.medium))
                                    Text(practice.partial).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                                }.foregroundStyle(VocaTheme.secondary).vocaSurface()
                            }
                            if !practice.enabled && practice.status != "Choose a scenario to begin." {
                                Text(practice.status).font(.subheadline).foregroundStyle(VocaTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest-turn")
                    }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: practice.messages.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        scroll.scrollTo("latest-turn", anchor: .bottom)
                    }
                }
            }
            .background(VocaTheme.background).foregroundStyle(VocaTheme.foreground).tint(VocaTheme.foreground)
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--practice-live-check") {
                    practice.brief = PracticeBrief(audience: "A technical founder", relationship: "We just met",
                        topic: "My plant-watering robot", goal: "Tell a clear story about why I built it")
                }
                #endif
            } catch { contentError = "Practice scenarios could not be opened. Restart Voca to retry." }
        }
        .task {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains("--practice-live-check") else { return }
            while !Task.isCancelled {
                practice.writePracticeCheck()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            #endif
        }
        .onChange(of: practice.status) { _, status in
            UIAccessibility.post(notification: .announcement, argument: status)
        }
        .onDisappear {
            if practice.enabled || practice.busy || practice.listening { stopPractice(dismissAfter: false) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { stopPractice(dismissAfter: false) }
        }
    }

    private var preparation: some View {
        VStack(alignment: .leading, spacing: 24) {
            PracticeInvitationVisual()
            VStack(alignment: .leading, spacing: 12) {
                Text("Situation").font(.caption).foregroundStyle(VocaTheme.secondary)
                Menu {
                    Picker("Practice scenario", selection: $selectedID) {
                        ForEach(scenarios) { Text($0.title).tag($0.id) }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        Text(scenarioTitle).font(.title2.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        PhosphorIcon("chevron.up.chevron.down")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary).accessibilityHidden(true)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).disabled(preparing)
                    .accessibilityLabel("Practice scenario, \(scenarioTitle)")
                Text("You do most of the talking. Your partner listens, asks one follow-up, and follows topic changes. This simulation stays separate from your memories.")
                    .font(.subheadline).foregroundStyle(VocaTheme.secondary)
            }
            directionInput
            situationBrief
            Text("The mic opens after each reply. Adaptive pacing allows 3–8 seconds to think; Finish sends your turn sooner. Each turn can last up to 55 seconds. Tap Interrupt to speak while the partner is talking.")
                .font(.subheadline).foregroundStyle(VocaTheme.secondary)
            HStack(spacing: 12) {
                PhosphorIcon("speaker.wave.2").foregroundStyle(VocaTheme.secondary).accessibilityHidden(true)
                Text("Audio output").font(.subheadline)
                Spacer(minLength: 0)
                AudioOutputPicker().frame(width: 44, height: 44)
            }.vocaSurface()
        }
    }

    private var directionInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(practice.enabled ? "Direction for the next reply" : "Make it your own (optional)")
                .font(.subheadline.weight(.medium))
            TextField("Topic or situation",
                      text: $practice.direction, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Conversation direction")
                .onChange(of: practice.direction) { _, value in
                    if value.count > 500 { practice.direction = String(value.prefix(500)) }
                }
            Text(practice.enabled ? "You can also change the topic aloud. Keep talking to add detail or tell your partner what you prefer." : "Choose any topic or situation. You can change direction during practice.")
                .font(.caption).foregroundStyle(VocaTheme.secondary)
        }
    }

    private var situationBrief: some View {
        DisclosureGroup("Situation brief") {
            VStack(alignment: .leading, spacing: 16) {
                briefField("Who you’re speaking with", placeholder: "A founder who isn’t technical", text: $practice.brief.audience)
                briefField("Your relationship", placeholder: "We’re meeting for the first time", text: $practice.brief.relationship)
                briefField("Topic", placeholder: "My plant-watering robot", text: $practice.brief.topic)
                briefField("What you want to practice", placeholder: "Explain why it matters, without jargon", text: $practice.brief.goal)
                Text("Optional. Your goal guides the exercise privately. Spoken corrections replace older details for this session.")
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
            }.padding(.top, 12)
        }
    }

    private func briefField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder).accessibilityLabel(title)
                .onChange(of: text.wrappedValue) { _, value in
                    if value.count > 240 { text.wrappedValue = String(value.prefix(240)) }
                }
        }
    }

    private var retainedContext: some View {
        DisclosureGroup("What I’m keeping in mind (\(practice.context.entries.count))") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Only your words, retained for this practice session. These are not saved personal memories. Remove notes that no longer fit. The visible conversation remains until you leave practice.")
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                ForEach(PracticeContext.Field.allCases, id: \.self) { field in
                    if let entry = practice.context.entries[field] {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(field.title).font(.subheadline.weight(.medium))
                            Text(entry.quote).fixedSize(horizontal: false, vertical: true)
                            Button("Remove note") { practice.forgetContext(field) }
                                .accessibilityLabel("Remove \(field.title)")
                                .frame(minHeight: 44)
                        }
                    }
                }
            }.padding(.top, 12)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Text("Thinking time").font(.caption).foregroundStyle(VocaTheme.secondary)
            Picker("Thinking time", selection: $practice.pacingMode) {
                ForEach(PracticePacing.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
                .onChange(of: practice.pacingMode) { _, _ in practice.adjustPacing(audio: audio) }
            if practice.enabled {
                // Keep voice feedback visible as the transcript grows.
                if !dynamicTypeSize.isAccessibilitySize {
                    CueWave(active: practice.busy || practice.listening || practice.startingListening,
                            speaking: practice.listening || practice.busy)
                }
                Text(practice.status).font(.caption).foregroundStyle(VocaTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { practiceActions.fixedSize() }
                    VStack(spacing: 12) { practiceActions }
                }
            } else if contentError == nil {
                Button(preparing ? "Starting…" : "Start practice") {
                    guard let scenario = scenarios.first(where: { $0.id == selectedID }) else {
                        contentError = "Choose a practice scenario before starting."; return
                    }
                    preparing = true
                    Task { await practice.start(scenario: scenario, model: model, voice: voice, audio: audio); preparing = false }
                }.buttonStyle(VocaPrimaryButton()).disabled(preparing)
            }
        }
        .disabled(stopping)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 640).frame(maxWidth: .infinity)
        .background(VocaTheme.background)
    }

    @ViewBuilder private var practiceActions: some View {
        if practice.listening {
            Button { practice.finishListening(audio: audio) } label: {
                PhosphorLabel("Finish", icon: "checkmark")
            }.buttonStyle(VocaPrimaryButton()).accessibilityLabel("Finish my turn")
        } else {
            Button {
                Task { await practice.listen(model: model, voice: voice, audio: audio) }
            } label: {
                PhosphorLabel(practice.startingListening ? "Opening mic…" : practice.finishing ? "Finishing…" : practice.busy ? "Interrupt" : practice.paused ? "Resume" : "Speak", icon: "mic")
            }.buttonStyle(VocaPrimaryButton()).disabled(practice.startingListening || practice.finishing)
                .accessibilityLabel(practice.busy ? "Interrupt and speak" : practice.paused ? "Resume listening" : "Speak my turn")
        }
        if !practice.paused {
            Button("Pause") {
                stopping = true
                Task {
                    await practice.pause(voice: voice, audio: audio)
                    stopping = false
                }
            }.buttonStyle(VocaSecondaryButton())
        }
        Button("End practice", role: .cancel) { stopPractice(dismissAfter: false) }
            .buttonStyle(VocaSecondaryButton())
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
