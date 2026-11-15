import SwiftUI
import VocaCore

struct TasteFeedbackView: View {
    let episode: Episode
    @Bindable var store: TasteStore
    @Environment(\.dismiss) private var dismiss
    @State private var reasons = Set<TastePreference>()
    @State private var alternative = ""
    @State private var approved = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your cue") { Text(episode.cue?.text ?? "") }
                Section("What would make it more like you?") {
                    ForEach(TastePreference.allCases) { preference in
                        Toggle(preference.title, isOn: Binding(get: { reasons.contains(preference) }, set: {
                            if $0 { reasons.insert(preference) } else { reasons.remove(preference) }
                        }))
                    }
                }
                Section("What I would say instead · optional") {
                    TextField("Your version, up to 240 characters", text: $alternative, axis: .vertical)
                        .lineLimit(2...6)
                    Text("\(alternative.count) / 240").font(.caption).foregroundStyle(.secondary)
                    Toggle("Use my version as a future style example", isOn: $approved)
                    Text("Only approved examples guide future wording. They stay on this iPhone, never become personal memories, and are not facts about a new conversation.")
                        .font(.footnote)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Save preferences") {
                        do {
                            try store.save(episode: episode, reasons: Array(reasons), alternative: alternative, approvedExample: approved)
                            dismiss()
                        } catch { self.error = "Couldn’t save. Keep your version within 240 characters on one line, then try again." }
                    }.disabled(alternative.count > 240)
                    Text("Your cue rating is already saved. These details are optional and do not add another strategy reward.").font(.footnote)
                }
            }
            .navigationTitle("Make it yours").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .onAppear {
                if let note = store.note(for: episode) {
                    reasons = Set(note.reasons); alternative = note.alternative; approved = note.approvedExample
                }
            }
        }
    }
}

struct TasteProfileView: View {
    @Bindable var store: TasteStore
    let episodes: [Episode]
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
            Section("Your wording examples") {
                let rated = episodes.filter { store.note(for: $0) != nil }
                if rated.isEmpty { Text("Rate a delivered cue and add your own wording to start.") }
                ForEach(rated) { episode in
                    NavigationLink {
                        TasteFeedbackView(episode: episode, store: store)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.note(for: episode)?.alternative.isEmpty == false ? store.note(for: episode)!.alternative : episode.cue?.text ?? "Cue feedback")
                            Text(store.note(for: episode)?.approvedExample == true ? "Approved style example" : "Not used as a wording example")
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
