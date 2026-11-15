import SwiftUI
import VocaCore

struct AuditView: View {
    let episode: Episode
    @Bindable var store: MemoryStore
    let model: any ModelGenerating
    var canGenerate = true
    @State private var text = ""
    @State private var speaker = "unknown"
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var addingEvidence = false
    @FocusState private var excerptFocused: Bool
    private var report: AuditReport? { store.audits.first { $0.decisionID == episode.id } }
    private var dialogue: [Evidence] { store.dialogue(for: episode) }
    private var hasWearerEvidence: Bool { dialogue.contains { $0.speaker == "wearer" && !$0.text.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(episode.decision.context.requestedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                if let cue = episode.cue {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your cue").font(.caption.weight(.medium)).foregroundStyle(VocaTheme.secondary)
                        Text(cue.text).font(.title3).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                cueInfluences
                if let cue = episode.cue {
                    DisclosureGroup("Cue details") {
                        Text(cue.actualProfile.modelID == .gemma4E4B ? "E4B · processed on this iPhone" : "E2B fallback · processed on this iPhone")
                            .font(.caption).foregroundStyle(VocaTheme.secondary).padding(.top, 8)
                    }.font(.subheadline)
                }
                if busy {
                    VStack(spacing: 4) {
                        CueWave(active: true)
                        Text("Reviewing your words…").font(.subheadline).foregroundStyle(VocaTheme.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }.frame(maxWidth: .infinity)
                } else if let report, report.status == .ready {
                    VStack(alignment: .leading, spacing: 24) {
                        reportSection("What worked", symbol: "checkmark", text: report.strength)
                        reportSection("What to try", symbol: "arrow.up.right", text: report.opportunity)
                        reportSection("Practice this", symbol: "bubble.left.and.bubble.right", text: report.exercise)
                    }.vocaSurface()
                    DisclosureGroup("Based on your words") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(dialogue.filter { report.sourceIDs.contains($0.sourceID) }) { evidence in
                                Text(evidence.text).lineSpacing(4).textSelection(.enabled)
                            }
                            if let profile = report.generationProfile {
                                Text("Reviewed with \(profile.modelID == .gemma4E4B ? "E4B" : "E2B") on this iPhone")
                                    .font(.caption).foregroundStyle(VocaTheme.secondary)
                            }
                        }.padding(.top, 16)
                    }.font(.subheadline)
                } else {
                    VocaEmptyState(symbol: "text.bubble", title: hasWearerEvidence ? "Ready to review" : "Add your words",
                                   detail: hasWearerEvidence ? "Find one strength and something to try next." : "Add a conversation excerpt to get a grounded review.")
                }
                if !dialogue.isEmpty {
                    DisclosureGroup("Conversation excerpts (\(dialogue.count))") {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(dialogue) { item in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(item.text).lineSpacing(4).textSelection(.enabled)
                                    Text(item.speaker == "wearer" ? "Your words" : item.speaker == "other" ? "Someone else’s words" : "Speaker unknown")
                                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                                    if item.utteredAt == nil { Text("Time unknown").font(.caption).foregroundStyle(VocaTheme.secondary) }
                                }
                            }
                        }.padding(.top, 16)
                        Text("Delete excerpts and their reviews in Memory.")
                            .font(.caption).foregroundStyle(VocaTheme.secondary).padding(.top, 12)
                    }.font(.subheadline)
                }
                if let error {
                    PhosphorLabel(error, icon: "exclamationmark.circle").font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
        .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                if busy {
                    Button("Cancel review", role: .cancel) { work?.cancel() }.buttonStyle(VocaSecondaryButton())
                } else if !hasWearerEvidence {
                    Button { addingEvidence = true } label: {
                        PhosphorLabel("Add excerpt", icon: "plus")
                    }.buttonStyle(VocaPrimaryButton()).disabled(!store.loaded)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { reviewActions.fixedSize() }
                        VStack(alignment: .leading, spacing: 12) { reviewActions }
                    }
                }
                if !canGenerate {
                    Text("Prepare guidance in Settings to review this conversation.")
                        .font(.footnote).foregroundStyle(VocaTheme.secondary)
                }
            }.padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: 640).frame(maxWidth: .infinity).background(VocaTheme.background)
        }
        .sheet(isPresented: $addingEvidence) { evidenceSheet }
        .onChange(of: error) { _, message in
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
        .onDisappear { work?.cancel() }
    }

    private var cueInfluences: some View {
        let context = episode.decision.context
        let cited = Set(episode.cue?.sourceIDs ?? [])
        return VStack(alignment: .leading, spacing: 16) {
            Text("What shaped this cue").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Goal: \(context.goal.rawValue.capitalized) · \(strategyName(episode.decision.selectedAction))")
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Photo context") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(context.scene.observedAt, format: .dateTime.hour().minute().second())
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                    Text(context.scene.uncertain ? "The scene was uncertain." : "Setting: \(context.scene.setting.rawValue.capitalized)")
                    if context.scene.observations.isEmpty { Text("No visual details were identified.") }
                    ForEach(Array(context.scene.observations.enumerated()), id: \.offset) { _, observation in
                        Text(observation).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(cited.contains(context.scene.requestID.uuidString) ? "Photo context cited in this cue." : "Photo context saved with the request; not cited in this cue.")
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                }.padding(.top, 8)
            }
            let memories = context.snapshot.approvedMemories.filter { cited.contains($0.sourceID) }
            let dialogue = context.snapshot.dialogue.filter { cited.contains($0.sourceID) }
            if !memories.isEmpty {
                DisclosureGroup("Memories cited (\(memories.count))") {
                    ForEach(memories) { evidence in Text(evidence.text).padding(.top, 8).textSelection(.enabled) }
                }
            }
            if !dialogue.isEmpty {
                DisclosureGroup("Dialogue cited (\(dialogue.count))") {
                    ForEach(dialogue) { evidence in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(evidence.text).textSelection(.enabled)
                            Text(evidence.speaker ?? "Speaker unknown").font(.caption).foregroundStyle(VocaTheme.secondary)
                        }.padding(.top, 8)
                    }
                }
            }
            if let source = context.knownPointSourceID, cited.contains(source), let point = context.knownPoint {
                Text("Your point: \(point)").textSelection(.enabled)
            }
            DisclosureGroup("How your feedback shapes suggestions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Helpful and unhelpful ratings on delivered cues update strategy preferences for similar contexts. Not tried, invalid evidence, and undelivered cues do not count as rewards.")
                    Text("Strategy scores when this cue was requested:").font(.subheadline.weight(.medium))
                    ForEach(episode.decision.eligibleActions, id: \.rawValue) { strategy in
                        if let utility = episode.decision.utilities[strategy.rawValue] {
                            Text("\(strategyName(strategy)): \(utility.formatted(.number.precision(.fractionLength(2))))")
                                .font(.subheadline).monospacedDigit()
                        }
                    }
                    Text("These are preference scores, not accuracy estimates. Learning is separate for each model, prompt version, and live or practice mode. Model weights stay fixed.")
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                    if let feedback = episode.feedback {
                        Text("Your rating: \(feedbackName(feedback.verdict))")
                    } else { Text("No rating recorded for this cue.") }
                }.padding(.top, 8)
            }
            Text("This shows saved inputs and cited sources, not the model’s private reasoning. A citation does not guarantee that its wording is accurate.")
                .font(.caption).foregroundStyle(VocaTheme.secondary)
        }.font(.subheadline).vocaSurface()
    }

    private func strategyName(_ strategy: Strategy) -> String {
        switch strategy {
        case .followUp: "Ask a follow-up"
        case .personalConnection: "Make a personal connection"
        case .explainClearly: "Explain clearly"
        case .reflectClarify: "Reflect and clarify"
        case .situationalOpener: "Open with your surroundings"
        }
    }

    private func feedbackName(_ verdict: FeedbackVerdict) -> String {
        switch verdict {
        case .helpful: "Helpful"
        case .unhelpful: "Unhelpful"
        case .notTried: "Not tried"
        case .invalidEvidence: "Invalid evidence"
        }
    }

    @ViewBuilder private var reviewActions: some View {
        Button(report?.status == .ready ? "Review again" : "Review") { generate() }
            .buttonStyle(VocaPrimaryButton()).disabled(!canGenerate || !store.loaded)
        Button { addingEvidence = true } label: {
            PhosphorLabel("Add excerpt", icon: "plus")
        }.buttonStyle(VocaSecondaryButton()).disabled(!store.loaded)
    }

    private var evidenceSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Conversation excerpt").font(.headline)
                        TextField("For example, I started gardening last spring.", text: $text, axis: .vertical)
                            .lineLimit(3...8).focused($excerptFocused)
                            .padding(16).background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(VocaTheme.secondary, lineWidth: 1))
                            .accessibilityLabel("Conversation excerpt, up to 500 characters")
                        Text("\(text.count) / 500 characters").font(.caption).monospacedDigit().foregroundStyle(VocaTheme.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Who said this?").font(.headline)
                        Picker("Who said this?", selection: $speaker) {
                            Text("I’m not sure").tag("unknown")
                            Text("I said these words").tag("wearer")
                            Text("Someone else").tag("other")
                        }.pickerStyle(.inline).labelsHidden()
                    }
                    Toggle("This is a real excerpt from this conversation", isOn: $confirmed)
                    Text("Excerpts are saved with an unknown time. They don’t become shareable memories. Use only real dialogue, never practice or invented text.")
                        .font(.footnote).foregroundStyle(VocaTheme.secondary)
                    if let error { PhosphorLabel(error, icon: "exclamationmark.circle").font(.subheadline) }
                    Button("Save excerpt") { saveEvidence() }.buttonStyle(VocaPrimaryButton())
                        .disabled(busy || !store.loaded)
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("Add an excerpt").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { addingEvidence = false; error = nil }
                } }
        }
    }

    private func saveEvidence() {
        guard confirmed else { error = "Confirm that this is real dialogue from this conversation, then save again."; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500 else {
            error = "Enter an excerpt of 1–500 characters, then save again."; excerptFocused = true; return
        }
        do {
            try store.addDialogue(text: text, speaker: speaker == "unknown" ? nil : speaker,
                                  utteredAt: nil, decisionID: episode.id)
            text = ""; confirmed = false; speaker = "unknown"; error = nil; addingEvidence = false
        } catch { self.error = "The excerpt couldn’t be saved. Try again. \(error.localizedDescription)" }
    }

    private func reportSection(_ title: String, symbol: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PhosphorLabel(title, icon: symbol).font(.subheadline.weight(.medium)).foregroundStyle(VocaTheme.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(text ?? "").font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func generate() {
        guard !busy, canGenerate else { return }
        busy = true; error = nil
        let evidence = dialogue
        work = Task {
            defer { busy = false; work = nil }
            do {
                guard let url = Bundle.main.url(forResource: "coaching-cards", withExtension: "json") else { throw AuditPipeline.Failure.content }
                let cards = try JSONDecoder().decode([CoachingCard].self, from: Data(contentsOf: url))
                let result = try await AuditPipeline(model: model).generate(episode: episode, dialogue: evidence, cards: cards)
                try Task.checkCancellation()
                try store.saveAudit(result, dependencies: evidence.map(\.sourceID) + episode.decision.context.snapshot.approvedMemories.map(\.sourceID))
            } catch is CancellationError { }
            catch { self.error = "The review could not be saved. Try again: \(error.localizedDescription)" }
        }
    }
}
