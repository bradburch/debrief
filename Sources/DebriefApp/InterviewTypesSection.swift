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
        Section {
            ForEach(types, id: \.self) { type in
                HStack(spacing: Spacing.s) {
                    Text(type.displayName)
                    if transcriptOnly.contains(type.rawValue) {
                        StatusCapsule(text: "Transcript only")
                            .help("Recorded and transcribed, never scored")
                    }
                    Spacer()
                    // Icon-only and borderless: three bordered, titled buttons on every row
                    // turned the list into a wall of controls. The Label titles stay as the
                    // accessibility names, and the tooltips say the same thing.
                    HStack(spacing: Spacing.m) {
                        Button { editing = draft(for: type, duplicating: false) } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .help("Edit \(type.displayName)")
                        Button { editing = draft(for: type, duplicating: true) } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .help("Duplicate \(type.displayName)")
                        Button(role: .destructive) { attemptDelete(type) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete \(type.displayName)")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Edit…") { editing = draft(for: type, duplicating: false) }
                    Button("Duplicate") { editing = draft(for: type, duplicating: true) }
                    Divider()
                    Button("Delete…", role: .destructive) { attemptDelete(type) }
                }
            }
            Button {
                editing = TypeDraft(name: "", rawValue: nil, markdown: Self.starterMarkdown,
                                    transcriptOnly: false, isNew: true)
            } label: {
                Label("New type…", systemImage: "plus")
            }
            // macOS push buttons drop a Label's icon unless asked.
            .labelStyle(.titleAndIcon)
            if let error {
                InlineMessage(text: error, kind: .error)
            }
        } header: {
            Text("Interview types")
        } footer: {
            Text("Each type is a markdown file in the prompts folder. Transcript-only types are never sent to an LLM, so they cost nothing and stay out of your trends.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(spacing: 0) {
            Form {
                Section {
                    if draft.isNew {
                        TextField("Name", text: $draft.name, prompt: Text("e.g. Take Home Review"))
                        if !draft.name.isEmpty, resolvedRawValue == nil {
                            InlineMessage(text: "That name is already taken or can't be used as a filename.",
                                          kind: .error)
                        } else if let slug = resolvedRawValue {
                            LabeledContent("File", value: "\(slug).md")
                        }
                    }
                    Toggle(isOn: $draft.transcriptOnly) {
                        Text("Transcript only")
                        Text(draft.transcriptOnly
                             ? "No LLM call, no scores, and excluded from trends and re-coaching."
                             : "Scored using the dimensions declared in the prompt.")
                    }
                } header: {
                    Text(draft.isNew ? "New interview type" : "Edit \(draft.name)")
                        .font(.headline)
                }
                Section("Prompt") {
                    TextEditor(text: $draft.markdown)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 300)
                        .accessibilityLabel("Prompt")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let rawValue = resolvedRawValue { onSave(draft, rawValue) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(resolvedRawValue == nil)
            }
            .padding(Spacing.l)
        }
        .frame(minWidth: 600, minHeight: 520)
    }
}
