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
    private var report: AuditReport? { store.audits.first { $0.decisionID == episode.id } }
    private var dialogue: [Evidence] { store.dialogue(for: episode) }
    private var hasWearerEvidence: Bool { dialogue.contains { $0.speaker == "wearer" && !$0.text.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A moment to reflect.").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if let cue = episode.cue { Text(cue.text).font(.title3).fixedSize(horizontal: false, vertical: true) }
                    Text(episode.decision.context.requestedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                }
                if let report, report.status == .ready {
                    reportSection("A strength in your words", text: report.strength)
                    reportSection("Something you could try", text: report.opportunity)
                    reportSection("One small exercise", text: report.exercise)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Based on your words").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(dialogue.filter { report.sourceIDs.contains($0.sourceID) }) { evidence in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(evidence.text).textSelection(.enabled)
                                Text(evidence.sourceID).font(.caption2).foregroundStyle(VocaTheme.secondary).textSelection(.enabled)
                            }
                        }
                        if let profile = report.generationProfile {
                            Text("Reviewed with \(profile.modelID == .gemma4E4B ? "E4B" : "E2B") on this iPhone")
                                .font(.caption).foregroundStyle(VocaTheme.secondary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(hasWearerEvidence ? "Ready to reflect" : "Waiting for transcript").font(.title2.weight(.semibold))
                        Text(hasWearerEvidence ? "Your confirmed words are ready. Review them for one strength, one possibility to explore, and one short exercise." : "A photo or a cue cannot tell us how the conversation went. Add a real excerpt and confirm which words were yours to get a grounded review.")
                            .foregroundStyle(VocaTheme.secondary)
                    }
                }
                if !dialogue.isEmpty {
                    DisclosureGroup("Conversation evidence (\(dialogue.count))") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(dialogue) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.text)
                                    Text(item.speaker == "wearer" ? "Confirmed as your words" : "Speaker: \(item.speaker ?? "unknown")")
                                        .font(.caption).foregroundStyle(VocaTheme.secondary)
                                    if item.utteredAt == nil { Text("Utterance time unknown").font(.caption).foregroundStyle(VocaTheme.secondary) }
                                }
                            }
                        }.padding(.top, 12)
                    }
                }
                DisclosureGroup("Add real conversation evidence") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("An exact excerpt from this conversation").font(.headline)
                        TextField("What was actually said", text: $text, axis: .vertical).lineLimit(3...8)
                            .textFieldStyle(.roundedBorder).accessibilityLabel("Real conversation excerpt, up to 500 characters")
                        Text("\(text.count) / 500 characters").font(.caption).foregroundStyle(VocaTheme.secondary)
                        Text("Who said this?").font(.subheadline)
                        Menu {
                            Picker("Who said this?", selection: $speaker) {
                                Text("I’m not sure").tag("unknown")
                                Text("I said these words").tag("wearer")
                                Text("Someone else").tag("other")
                            }
                        } label: {
                            HStack(alignment: .top) {
                                Text(speaker == "wearer" ? "I said these words" : speaker == "other" ? "Someone else" : "I’m not sure")
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.bordered).accessibilityLabel("Who said this?")
                        Toggle("This is a real excerpt from this conversation, not practice or invented text", isOn: $confirmed)
                        Text("Saved as a partial excerpt with unknown utterance time. This does not become a shareable memory.")
                            .font(.footnote).foregroundStyle(VocaTheme.secondary)
                        Button("Save conversation evidence") {
                            do {
                                try store.addDialogue(text: text, speaker: speaker == "unknown" ? nil : speaker,
                                                      utteredAt: nil, decisionID: episode.id)
                                text = ""; confirmed = false; speaker = "unknown"; error = nil
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.bordered)
                            .disabled(!confirmed || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 500 || busy || !store.loaded)
                    }.padding(.top, 16)
                }
                if busy {
                    ProgressView("Reviewing your words…")
                    Button("Cancel review", role: .cancel) { work?.cancel() }.buttonStyle(.bordered)
                } else {
                    Button(report?.status == .ready ? "Review again" : "Review this conversation") { generate() }
                        .buttonStyle(VocaPrimaryButton()).disabled(!canGenerate || !store.loaded)
                }
                if !canGenerate { Text("Prepare on-device guidance in Session, then return to this review.").font(.subheadline) }
                if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline) }
                Text("A review is a suggestion based on limited evidence, not a score. It never changes your learning rewards. You can delete evidence and its review in Memory.")
                    .font(.footnote).foregroundStyle(VocaTheme.secondary)
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
            .scrollDismissesKeyboard(.interactively)
            .onDisappear { work?.cancel() }
    }

    private func reportSection(_ title: String, text: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            Text(text ?? "").font(.title3).fixedSize(horizontal: false, vertical: true)
        }
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
