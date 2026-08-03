import SwiftUI
import CoachingEngine
import Store

/// Settings UI for the round types offered when tagging a recording.
///
/// A round type IS its prompt file — `PromptStore.availableRoundTypes()` enumerates the
/// prompts directory — so everything here is file management with a text editor on top.
/// That keeps "the rubric is data, not code" true: this pane is a convenience over the
/// prompts folder, never a second source of truth. Editing the files by hand still works.
struct InterviewTypesSection: View {
    @EnvironmentObject var env: AppEnvironment

    @State private var types: [RoundType] = []
    @State private var transcriptOnly: Set<String> = []
    @State private var editing: TypeDraft?
    @State private var deleteTarget: RoundType?
    @State private var deleteBlockedMessage: String?
    @State private var error: String?

    var body: some View {
        Section("Interview types") {
            ForEach(types, id: \.self) { type in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(type.displayName)
                        if transcriptOnly.contains(type.rawValue) {
                            Text("Transcript only — recorded and transcribed, never scored")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Edit") { editing = draft(for: type, duplicating: false) }
                    Button("Duplicate") { editing = draft(for: type, duplicating: true) }
                    Button(role: .destructive) { attemptDelete(type) } label: { Text("Delete") }
                }
            }
            Button("New type…") {
                editing = TypeDraft(name: "", rawValue: nil, markdown: Self.starterMarkdown,
                                    transcriptOnly: false, isNew: true)
            }
            Text("Each type is a markdown file in the prompts folder. Transcript-only types are recorded and transcribed but never sent to an LLM, so they cost nothing and stay out of your trends.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { draft in
            TypeEditor(draft: draft, existing: types.map(\.rawValue), onSave: save)
        }
        // Real two-way bindings, not `.constant(x != nil)`: SwiftUI writes `false` back on
        // dismiss, and a constant binding drops that write — leaving the state non-nil so
        // the dialog re-presents itself immediately.
        .alert("Can't delete this type", isPresented: binding(for: $deleteBlockedMessage)) {
            Button("OK") { deleteBlockedMessage = nil }
        } message: {
            Text(deleteBlockedMessage ?? "")
        }
        .confirmationDialog("Delete \(deleteTarget?.displayName ?? "")?",
                            isPresented: binding(for: $deleteTarget), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { performDelete(target) }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Removes its prompt file. Recordings already tagged with it are unaffected.")
        }
    }

    /// Presents while `state` is non-nil, and clears it when SwiftUI dismisses.
    private func binding<T>(for state: Binding<T?>) -> Binding<Bool> {
        Binding(get: { state.wrappedValue != nil },
                set: { if !$0 { state.wrappedValue = nil } })
    }

    private func reload() {
        types = env.prompts.availableRoundTypes()
        transcriptOnly = Set(types.filter { env.prompts.isTranscriptOnly($0) }.map(\.rawValue))
    }

    private func draft(for type: RoundType, duplicating: Bool) -> TypeDraft {
        TypeDraft(name: duplicating ? "\(type.displayName) Copy" : type.displayName,
                  rawValue: duplicating ? nil : type.rawValue,
                  markdown: env.prompts.markdown(for: type),
                  transcriptOnly: transcriptOnly.contains(type.rawValue),
                  isNew: duplicating)
    }

    /// A type whose prompt file is gone can't be assembled into a system prompt, so
    /// sessions already tagged with it would break on re-coach. Block rather than cascade:
    /// deleting stored interviews to remove a menu entry is never what was meant.
    private func attemptDelete(_ type: RoundType) {
        let used = (try? env.db.sessionCount(forRoundType: type)) ?? 0
        if used > 0 {
            deleteBlockedMessage = "\(used) recording\(used == 1 ? " uses" : "s use") "
                + "\(type.displayName). Re-tag them first, or keep the type."
        } else {
            deleteTarget = type
        }
    }

    private func performDelete(_ type: RoundType) {
        do {
            try env.prompts.delete(type)
            error = nil
        } catch {
            self.error = "Could not delete: \(error.localizedDescription)"
        }
        reload()
    }

    private func save(_ draft: TypeDraft, _ rawValue: String) {
        do {
            let markdown = PromptStore.settingTranscriptOnly(draft.transcriptOnly, in: draft.markdown)
            try env.prompts.write(markdown, for: RoundType(rawValue: rawValue))
            error = nil
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
        }
        editing = nil
        reload()
    }

    private static let starterMarkdown = """
        # Overlay: new round type

        Describe what this round tests and what the interviewer is listening for.

        ## Scored dimensions

        - example_dimension: what this dimension measures, and what earns a low vs high score.
        """
}

/// One round type being created or edited. `rawValue` is nil for a new type, where the
/// filename is derived from the name on save.
struct TypeDraft: Identifiable {
    let id = UUID()
    var name: String
    var rawValue: String?
    var markdown: String
    var transcriptOnly: Bool
    var isNew: Bool
}

private struct TypeEditor: View {
    @State var draft: TypeDraft
    let existing: [String]
    let onSave: (TypeDraft, String) -> Void
    @Environment(\.dismiss) private var dismiss

    /// nil when the name can't become a filename, or would collide with another type.
    private var resolvedRawValue: String? {
        if let rawValue = draft.rawValue { return rawValue }  // editing in place, name is fixed
        guard let slug = PromptStore.normalizedRawValue(from: draft.name) else { return nil }
        return existing.contains(slug) || slug == "base" ? nil : slug
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "New interview type" : "Edit \(draft.name)").font(.headline)
            if draft.isNew {
                TextField("Name (e.g. Take Home Review)", text: $draft.name)
                if !draft.name.isEmpty, resolvedRawValue == nil {
                    Text("That name is already taken or can't be used as a filename.")
                        .font(.caption).foregroundStyle(.red)
                } else if let slug = resolvedRawValue {
                    Text("Saved as \(slug).md").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Transcript only (record and transcribe, never score)", isOn: $draft.transcriptOnly)
            Text(draft.transcriptOnly
                 ? "No LLM call, no scores, and excluded from trends and re-coaching."
                 : "Scored using the dimensions declared below.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Prompt").font(.subheadline)
            TextEditor(text: $draft.markdown)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 520, minHeight: 300)
                .border(.separator)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    if let rawValue = resolvedRawValue { onSave(draft, rawValue) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(resolvedRawValue == nil)
            }
        }
        .padding()
    }
}
