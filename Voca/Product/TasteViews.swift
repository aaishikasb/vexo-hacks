import SwiftUI
import VocaCore

struct TasteFeedbackView: View {
    let episode: Episode
    @Bindable var store: TasteStore
    var audio: NativeAudio? = nil
    var beforeCapture: (() async -> Void)? = nil
    var onReport: ((FeedbackIssue, Episode, [TastePreference], String, Bool) async throws -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var capture = FeedbackCapture()
    @State private var captureTask: Task<Void, Never>?
    @State private var issue: FeedbackIssue = .wrongWording
    @State private var reasons = Set<TastePreference>()
    @State private var alternative = ""
    @State private var approved = false
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Your cue") { Text(episode.cue?.text ?? "") }
                Section("What missed?") {
                    Picker("Issue", selection: $issue) {
                        ForEach(FeedbackIssue.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                    Text(explanation).font(.footnote)
                }
                Section("Say it your way · optional") {
                    if let audio {
                        Button(capture.listening ? "Finish speaking" : "Speak a correction", systemImage: capture.listening ? "stop.circle" : "mic") {
                            if capture.listening { capture.finish() }
                            else {
                                captureTask = Task {
                                    await beforeCapture?()
                                    guard !Task.isCancelled else { return }
                                    await capture.start(audio: audio)
                                }
                            }
                        }.disabled(capture.preparing || saving)
                        if !capture.status.isEmpty { Text(capture.status).font(.footnote) }
                    }
                    if !alternative.isEmpty { Text(alternative).textSelection(.enabled) }
                    DisclosureGroup("Type or edit instead") {
                        TextField("Your correction, up to 240 characters", text: $alternative, axis: .vertical).lineLimit(2...6)
                        Text("\(alternative.count) / 240").font(.caption)
                    }
                    Text("Recording starts only when you tap Speak. Recognition stays on this iPhone; check the words before saving.").font(.footnote)
                }
                if issue == .wrongWording {
                    Section("Future wording") {
                        ForEach(TastePreference.allCases) { preference in
                            Toggle(preference.title, isOn: Binding(get: { reasons.contains(preference) }, set: {
                                if $0 { reasons.insert(preference) } else { reasons.remove(preference) }
                            }))
                        }
                        Toggle("Approve my wording as a style example", isOn: $approved)
                        Text("Examples guide tone, never facts about a new conversation.").font(.footnote)
                    }
                }
                if let error { Section { Text(error) } }
                Section {
                    Button(saving ? "Saving…" : "Save feedback") {
                        saving = true; capture.stop()
                        Task {
                            defer { saving = false }
                            do {
                                if let onReport { try await onReport(issue, episode, Array(reasons), alternative, approved) }
                                else { try store.save(episode: episode, reasons: Array(reasons), alternative: alternative, approvedExample: approved, issue: issue) }
                                dismiss()
                            } catch { self.error = "Couldn’t save these details. Keep the correction within 240 characters, then try again." }
                        }
                    }.disabled(saving || capture.listening || capture.preparing || alternative.count > 240)
                }
            }
            .navigationTitle("What missed?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .onAppear {
                if let note = store.note(for: episode) {
                    issue = note.issue ?? .wrongWording
                    reasons = Set(note.reasons); alternative = note.alternative; approved = note.approvedExample
                }
            }
            .onChange(of: capture.finalText) { _, text in alternative = text }
            .onChange(of: phase) { _, value in if value != .active { captureTask?.cancel(); capture.stop() } }
            .onDisappear { captureTask?.cancel(); capture.stop() }
        }
    }
    private var explanation: String {
        switch issue {
        case .wrongFacts: "Exclude this cue from strategy rewards. Your correction is a report, not a memory or style preference. The next cue uses a fresh photo."
        case .wrongMoment: "Save a timing report without creating a strategy reward or style preference. Existing explicit ratings stay unchanged."
        case .wrongStrategy: "Mark this approach unhelpful for the original context. This changes strategy preference, not your wording style."
        case .wrongWording: "Save wording preferences without adding a strategy reward. Existing explicit ratings stay unchanged."
        }
    }
}

struct TasteProfileView: View {
    @Bindable var store: TasteStore
    let episodes: [Episode]
    var audio: NativeAudio? = nil
    var beforeCapture: (() async -> Void)? = nil
    var onReport: ((FeedbackIssue, Episode, [TastePreference], String, Bool) async throws -> Void)? = nil
    @State private var error: String?
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section("Your preferences") {
                ForEach(TastePreference.allCases) { preference in
                    Toggle(preference.title, isOn: Binding(get: { store.enabled(preference, episodes: episodes) }, set: { value in
                        do { try store.set(preference, enabled: value) }
                        catch { self.error = "Couldn’t save this preference. Try again." }
                    }))
                }
                Text("Reasons you select after rating a cue suggest these preferences. Your edits take priority. They carry across model and prompt versions; strategy rewards remain separate.").font(.footnote)
            }
            Section("Feedback details and examples") {
                let rated = episodes.filter { store.note(for: $0) != nil }
                if rated.isEmpty { Text("Rate a delivered cue and add your own wording to start.") }
                ForEach(rated) { episode in
                    NavigationLink {
                        TasteFeedbackView(episode: episode, store: store, audio: audio, beforeCapture: beforeCapture, onReport: onReport)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.note(for: episode)?.alternative.isEmpty == false ? store.note(for: episode)!.alternative : episode.cue?.text ?? "Cue feedback")
                            Text(store.note(for: episode)?.issue?.title ?? (store.note(for: episode)?.approvedExample == true ? "Approved style example" : "Wording preferences"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                Button("Reset wording preferences", role: .destructive) { confirmReset = true }
                Text("Removes reasons, rewrites, and style preferences. Cue ratings and strategy learning stay saved.").font(.footnote)
            }
        }
        .navigationTitle("Your style").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset your wording preferences and examples?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset wording preferences", role: .destructive) {
                do { try store.reset() } catch { self.error = "Couldn’t reset preferences. Try again." }
            }
        }
    }
}
