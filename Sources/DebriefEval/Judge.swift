import Foundation
import CoachingEngine

/// The judge is not the system under test, so it gets its own small Messages API call
/// rather than going through AnthropicClient.
struct Judge: Sendable {
    struct Verdict {
        var grade: [String: Double]
        var explanation: [String: String]
        var model: String
        var usage: ResponseMeta.Usage
        var raw: String
    }

    /// A judge call that billed but couldn't be scored — the usage must still be counted.
    struct Failure: Error, CustomStringConvertible {
        let message: String
        let model: String?
        let usage: ResponseMeta.Usage?
        var description: String { message }
    }

    let apiKey: String
    let model: String
    let session: URLSession

    func judge(roundType: String, coachRubric: String, transcript: String, debrief: String) async throws -> Verdict {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 16000,
            "thinking": ["type": "adaptive"],
            "system": JudgeRubric.system,
            "messages": [["role": "user", "content": JudgeRubric.userMessage(
                roundType: roundType, coachRubric: coachRubric, transcript: transcript, debrief: debrief)]],
            "output_config": ["effort": "high",
                              "format": ["type": "json_schema", "schema": JudgeRubric.schema]],
        ] as [String: Any], options: [.sortedKeys])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError.httpStatus(status, body: String(data: data, encoding: .utf8) ?? "")
        }
        struct Envelope: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let model: String?
            let stop_reason: String?
            let usage: ResponseMeta.Usage?
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let served = env.model ?? ""
        func fail(_ m: String) -> Failure { Failure(message: m, model: served, usage: env.usage) }
        guard servedMatches(served, model) else { throw fail("model_mismatch: judge served \(served), asked \(model)") }
        guard env.stop_reason != "max_tokens", env.stop_reason != "refusal" else {
            throw fail("judge stop_reason \(env.stop_reason ?? "")")
        }
        guard let text = env.content.first(where: { $0.type == "text" })?.text,
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: [String: Any]]
        else { throw fail("judge returned unparseable JSON") }

        var grade: [String: Double] = [:], why: [String: String] = [:]
        for c in JudgeRubric.criteria {
            guard let pass = obj[c]?["satisfied"] as? Bool else { throw fail("judge omitted \(c)") }
            grade[c] = pass ? 1 : 0
            why[c] = obj[c]?["reason"] as? String ?? ""
        }
        grade["judge_mean"] = JudgeRubric.criteria.compactMap { grade[$0] }.reduce(0, +) / Double(JudgeRubric.criteria.count)
        return Verdict(grade: grade, explanation: why, model: served,
                       usage: env.usage ?? .init(inputTokens: 0, outputTokens: 0), raw: text)
    }
}

/// Counts retries so they land in the row — attempts run vs attempts scored stays visible.
final class RetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// Jittered exponential backoff on 429 / 529 / 5xx / "overloaded", capped at `tries`.
/// Everything else (a 400 included) is thrown straight through.
func withBackoff<T>(_ counter: RetryCounter, tries: Int = 5, _ op: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do { return try await op() } catch ClaudeError.httpStatus(let code, let body)
            where attempt < tries - 1 && (code == 429 || code >= 500 || body.contains("overloaded")) {
            counter.bump()
            let delay = min(60, pow(2, Double(attempt))) * Double.random(in: 0.5...1.5)
            attempt += 1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
