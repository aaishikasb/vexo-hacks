import SwiftUI
import VocaCore

struct MemoryView: View {
    @Bindable var store: MemoryStore
    let invalidate: @MainActor (String) async throws -> Void
    @State private var text = ""
    @State private var approved = false
    @State private var message: String?
    @State private var deleting: MemoryEntry?
    @State private var saving = false
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Only what you choose.").font(.largeTitle.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text("Save a true detail you’re comfortable bringing into a conversation. Voca uses only memories you approve.")
                        .foregroundStyle(VocaTheme.secondary)
                }
                if let error = store.loadError {
                    Label(error, systemImage: "exclamationmark.circle")
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("A detail about you").font(.headline)
                        TextField("For example, I’m learning to grow herbs", text: $text, axis: .vertical)
                            .lineLimit(3...7).textFieldStyle(.roundedBorder).focused($editing)
                            .accessibilityLabel("A personal memory, up to 240 characters")
                        Text("\(text.count) / 240 characters").font(.caption).foregroundStyle(VocaTheme.secondary)
                        Toggle("This is about me, and I approve sharing it in a cue", isOn: $approved)
                        Button("Save approved memory") {
                            do {
                                try store.addMemory(text: text)
                                text = ""; approved = false; editing = false
                                message = "Memory saved on this iPhone."
                            } catch { message = error.localizedDescription }
                        }.buttonStyle(VocaPrimaryButton())
                            .disabled(!approved || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 240 || !store.loaded)
                    }
                }
                if let message { Text(message).font(.subheadline).accessibilityAddTraits(.updatesFrequently) }
                if !store.pendingDeletionIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The memory was deleted. Removing its saved cues and learning still needs to finish.")
                        Button("Retry deletion") {
                            saving = true
                            Task {
                                defer { saving = false }
                                do { try await store.finishPendingDeletions(invalidate: invalidate); message = "Deletion complete." }
                                catch { message = "Associated history could not be removed. Retry deletion: \(error.localizedDescription)" }
                            }
                        }.buttonStyle(.bordered).disabled(saving)
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Approved memories").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if store.records.filter({ $0.kind == .personalMemory }).isEmpty {
                        Text("No memories yet. Add one detail above when you’re ready.").foregroundStyle(VocaTheme.secondary)
                    }
                    ForEach(store.records.filter { $0.kind == .personalMemory }.reversed()) { entry in entryView(entry) }
                }
                if store.records.contains(where: { $0.kind == .dialogue }) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Conversation evidence").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text("Added to individual cue reviews. These excerpts are not approved personal memories.")
                            .font(.subheadline).foregroundStyle(VocaTheme.secondary)
                        ForEach(store.records.filter { $0.kind == .dialogue }.reversed()) { entry in entryView(entry) }
                    }
                }
                Text("Saved only on this iPhone and excluded from backups. Deleting an entry also removes reviews, cues, and learned updates that depend on it. Practice dialogue never becomes a personal memory.")
                    .font(.footnote).foregroundStyle(VocaTheme.secondary)
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.background(VocaTheme.background).foregroundStyle(VocaTheme.foreground)
            .scrollDismissesKeyboard(.interactively)
            .confirmationDialog("Delete this entry and associated history?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                    if let entry = deleting {
                        Button("Delete entry and associated history", role: .destructive) {
                            deleting = nil; saving = true
                            Task {
                                defer { saving = false }
                                do { try await store.delete(sourceID: entry.id, invalidate: invalidate); message = "Entry and associated history deleted." }
                                catch { message = "Deletion could not finish. \(error.localizedDescription)" }
                            }
                        }
                    }
                    Button("Keep entry", role: .cancel) { deleting = nil }
                } message: { Text("This also removes any dependent cues, feedback learning, and reviews. This cannot be undone.") }
    }

    private func entryView(_ entry: MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.evidence.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(entry.kind == .personalMemory ? "Approved by you" : entry.evidence.speaker == "wearer" ? "Confirmed as your words" : "Speaker: \(entry.evidence.speaker ?? "unknown")")
                .font(.caption).foregroundStyle(VocaTheme.secondary)
            if let date = entry.evidence.utteredAt {
                Text(date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(VocaTheme.secondary)
            } else if entry.kind == .dialogue {
                Text("Utterance time unknown").font(.caption).foregroundStyle(VocaTheme.secondary)
            }
            Button("Delete entry", role: .destructive) { deleting = entry }.buttonStyle(.bordered).disabled(saving)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(VocaTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}
