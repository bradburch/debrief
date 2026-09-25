import SwiftUI
import Store

/// Pure name logic behind `CompanyField`, kept apart from the view so it is testable.
enum CompanyNames {
    /// Recorded companies (already ranked active-first by the Store) followed by planned-call
    /// companies not yet recorded, deduplicated case-insensitively — first spelling wins, so a
    /// recorded company's spelling beats a plan's.
    static func merge(recorded: [String], planned: [String]) -> [String] {
        var seen = Set<String>()
        return (recorded + planned).compactMap { raw in
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != Company.placeholderName,
                  seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    /// What to offer for `query`: prefix matches, then other substring matches, both in the
    /// list's own (ranked) order. An empty query offers the top of the list. A name the field
    /// already holds exactly is left out, so the list goes away once one is chosen.
    static func matches(for query: String, in names: [String], limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = names.filter { $0 != q }
        guard !q.isEmpty else { return Array(candidates.prefix(limit)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let prefix = candidates.filter { $0.range(of: q, options: options.union(.anchored)) != nil }
        let contains = candidates.filter { !prefix.contains($0) && $0.range(of: q, options: options) != nil }
        return Array((prefix + contains).prefix(limit))
    }

    /// The name to store for what was typed: trimmed, and re-spelled as an existing company
    /// when it differs only by case — so "acme" files under "Acme" instead of starting a
    /// second pipeline. Blank stays blank (the caller decides what blank means).
    /// `current` is the name being edited: re-casing it ("acme" → "Acme") is a deliberate
    /// correction, so it is kept as typed instead of snapping back to the old spelling.
    static func canonical(_ typed: String, in names: [String], current: String? = nil) -> String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return t }
        if t.caseInsensitiveCompare(Company.placeholderName) == .orderedSame { return Company.placeholderName }
        return names.first { $0.caseInsensitiveCompare(t) == .orderedSame && $0 != current } ?? t
    }
}

/// A company-name text field that offers existing companies as you type (active pipelines
/// first). Used by every surface that names a company, so they all complete from the same
/// list — `AppEnvironment.companySuggestions`.
///
/// macOS 15 gets the native `textInputSuggestions` dropdown. On 14 there is no completion
/// API, so a small menu of matches sits beside the field instead.
struct CompanyField: View {
    @EnvironmentObject var env: AppEnvironment
    var title: LocalizedStringKey = "Company"
    @Binding var text: String
    /// Called on Return, and on 14 after picking from the menu (the menu is a commit).
    var onSubmit: () -> Void = {}

    private var matches: [String] { CompanyNames.matches(for: text, in: env.companySuggestions) }

    var body: some View {
        if #available(macOS 15.0, *) {
            TextField(title, text: $text)
                .textInputSuggestions {
                    ForEach(matches, id: \.self) { name in
                        Text(verbatim: name).textInputCompletion(name)
                    }
                }
                .onSubmit(onSubmit)
        } else {
            HStack(spacing: 2) {
                TextField(title, text: $text).onSubmit(onSubmit)
                if !matches.isEmpty {
                    Menu {
                        ForEach(matches, id: \.self) { name in
                            Button { text = name; onSubmit() } label: { Text(verbatim: name) }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose an existing company")
                    .accessibilityLabel("Existing companies")
                }
            }
        }
    }
}
