import Foundation
import EventKit
import Store
import os

private let logger = Logger(subsystem: "com.debrief.app", category: "calendar")

/// Reads scheduled interviews straight out of macOS Calendar, replacing the
/// `upcoming.json` hand-off as the primary source.
///
/// EventKit is a *local system framework*: it reads the calendar database macOS already
/// syncs on the user's behalf (including a Google account added in System Settings).
/// Debrief makes no network call, holds no OAuth token, and talks to no calendar service.
/// That is the entire reason this is acceptable in a local-only app — do not replace it
/// with a calendar HTTP client.
///
/// @MainActor because `EKEventStore` is not Sendable and the only caller
/// (`AppEnvironment.refreshUpcoming`) is already main-actor. `events(matching:)` is
/// synchronous, so the record path never has to await: only the access request is async,
/// and that lives in Settings.
@MainActor
final class CalendarEvents {
    static let shared = CalendarEvents()
    /// One long-lived store. A fresh `EKEventStore` per query re-opens the calendar
    /// database each time, which is slow enough to be felt on the record path.
    private let store = EKEventStore()

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Full access only. `.writeOnly` can create events but cannot read them, so it is
    /// useless here and must not be treated as authorized.
    static var isAuthorized: Bool { authorizationStatus == .fullAccess }

    /// Triggers the macOS TCC prompt. Requires `NSCalendarsFullAccessUsageDescription`
    /// in the bundle's Info.plist (scripts/make-app.sh) — without it this *crashes*.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            logger.error("Calendar access request failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Every readable calendar, for the Settings picker. Sorted by title so the list is
    /// stable across launches (EventKit's own order is not).
    func calendars() -> [(id: String, title: String)] {
        store.calendars(for: .event)
            .map { (id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func title(ofCalendar id: String) -> String? {
        store.calendar(withIdentifier: id)?.title
    }

    /// Upcoming interviews from one chosen calendar, mapped onto the same
    /// `UpcomingInterview` type the file loader produces. Every failure path returns []
    /// so the recording form falls back to `upcoming.json` and then to plain typing.
    ///
    /// ponytail: one calendar, not a multi-select. A dedicated "Interviews" calendar is
    /// how this is actually used, and searching every calendar for interview-shaped
    /// events is guesswork. Upgrade path: store a `Set<String>` of identifiers under the
    /// same defaults key and union the predicates.
    func upcoming(calendarID: String, knownRoundTypes: [String], now: Date = Date()) -> [UpcomingInterview] {
        guard Self.isAuthorized, let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        let window = UpcomingInterviews.window(now: now)
        let predicate = store.predicateForEvents(withStart: window.lowerBound,
                                                 end: window.upperBound,
                                                 calendars: [calendar])
        let events = store.events(matching: predicate)
        var seen = Set<UpcomingInterview>()
        return events
            .compactMap {
                Self.map(title: $0.title, notes: $0.notes, start: $0.startDate,
                         knownRoundTypes: knownRoundTypes, now: now)
            }
            // A recurring series expands to one event per occurrence; two of them inside
            // the window map to byte-identical values only if they share a start, but
            // dedup anyway — SwiftUI's `ForEach(id: \.self)` collides on equal Hashables.
            .filter { seen.insert($0).inserted }
            .sorted { $0.start < $1.start }
    }

    /// The whole mapping rule, with no EventKit types in the signature so it is testable
    /// without a real store or a TCC grant (EventKit itself cannot be unit-tested).
    /// Returns nil for an unusable or out-of-window event.
    static func map(title: String?, notes: String?, start: Date?,
                    knownRoundTypes: [String], now: Date) -> UpcomingInterview? {
        guard let start, UpcomingInterviews.window(now: now).contains(start) else { return nil }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roundType = matchRoundType(in: title, known: knownRoundTypes)
        let company = roundType.map { strippedCompany(from: title, roundType: $0) } ?? title
        return UpcomingInterview(
            company: company,
            roundType: roundType,
            start: start,
            notes: (notes?.isEmpty ?? true) ? nil : notes)
    }

    /// Finds a known round type named in the event's **title only**, matching either the
    /// raw key (`system_design`) or its display form (`System Design`) as a whole word
    /// (or, for a multi-word display form, a whole phrase) — never as a substring of a
    /// longer word.
    ///
    /// Notes are deliberately excluded: an invite body is prose written by Zoom/Meet/Teams
    /// or the organizer ("if you have technical difficulties, call the front desk"), not a
    /// label, and routinely contains round-type-shaped words that don't describe the
    /// interview. A title is a label someone chose on purpose. Word-boundary matching
    /// closes the other half of the same failure mode: "technicalities" must not match
    /// `technical`.
    ///
    /// Returns nil when nothing matches — `AppEnvironment.apply` already ignores an
    /// unknown/absent round type, leaving the sticky picker value alone.
    ///
    /// ponytail: plain word-boundary matching, longest candidate first (ties broken by raw
    /// value, so the result is deterministic regardless of `known`'s order) so
    /// `tech_deep_dive` wins over a `technical` that happens to also appear. No fuzzy
    /// matching and no LLM call — an interview invite that doesn't name its round in the
    /// title just doesn't pre-fill one. Upgrade path: match against the overlay's title
    /// line too.
    static func matchRoundType(in haystack: String, known: [String]) -> String? {
        let candidates = known.flatMap { raw -> [(needle: String, raw: String)] in
            [(raw, raw), (RoundType(rawValue: raw).displayName, raw)]
        }
        .sorted { lhs, rhs in
            if lhs.needle.count != rhs.needle.count { return lhs.needle.count > rhs.needle.count }
            return lhs.raw > rhs.raw
        }
        return candidates.first { wordBoundaryRange(of: $0.needle, in: haystack) != nil }?.raw
    }

    /// Case-insensitive whole-word(s) search: `needle` must be bounded by non-word
    /// characters (or the string's edges) on both sides, so "technical" cannot match
    /// inside "technicalities" and "system_design" cannot match inside "asystem_designer".
    private static func wordBoundaryRange(of needle: String, in haystack: String) -> Range<String.Index>? {
        guard !needle.isEmpty else { return nil }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsRange = NSRange(haystack.startIndex..., in: haystack)
        guard let match = regex.firstMatch(in: haystack, options: [], range: nsRange) else { return nil }
        return Range(match.range, in: haystack)
    }

    /// Removes the matched round-type mention (and the separators around it) from a
    /// title, so "Stripe — System Design" pre-fills company "Stripe" instead of a
    /// distinct row per round in the Pipeline/Trends company grouping.
    ///
    /// ponytail: strips one occurrence of the matched raw or display form, then trims a
    /// fixed separator set (`—`, `-`, `/`, `:`) plus whitespace off both edges. It does
    /// not parse compound titles beyond that (e.g. "Stripe / Brad — Onsite 2" is left
    /// alone when no round type matches, and a matched round type in the middle of a
    /// longer phrase only removes that word, not surrounding filler). If stripping would
    /// leave nothing, the original title is kept — never an empty company. Upgrade path:
    /// a real per-calendar/company title template if this stops being good enough.
    private static func strippedCompany(from title: String, roundType: String) -> String {
        var working = title
        for needle in [roundType, RoundType(rawValue: roundType).displayName] {
            if let range = wordBoundaryRange(of: needle, in: working) {
                working.removeSubrange(range)
                break
            }
        }
        let stripSet = CharacterSet(charactersIn: "—-/:").union(.whitespacesAndNewlines)
        let stripped = working.trimmingCharacters(in: stripSet)
        return stripped.isEmpty ? title : stripped
    }
}
