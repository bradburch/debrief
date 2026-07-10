import Foundation

/// Coaching via any OpenAI-compatible /chat/completions server: Ollama,
/// LM Studio, llama.cpp, or remote providers like DeepSeek cloud.
///
/// These servers disagree on response_format support (json_schema vs
/// json_object vs 400), so instead of structured outputs we ask for JSON in
/// the prompt and parse tolerantly — see candidateObjects.
public struct OpenAICompatibleClient: CoachingLLM {
    let baseURL: URL
    let model: String
    let apiKey: String
    let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    /// Sentinel prose from the format appendix's example object. A weak local
    /// model sometimes echoes the example (verbatim or ahead of its real
    /// answer) instead of following it, so `generateCoaching` rejects any
    /// decoded candidate whose prose still equals this exact sentinel.
    static let exampleProse = "The 300-600 word markdown debrief."

    static let formatAppendix = """
    ## Output format (mandatory)

    Respond with ONLY a single JSON object — no commentary, no text before or after it, and no code-fence wrapper around the object itself (do not wrap your reply in ```). Markdown formatting INSIDE the "prose_debrief" string is welcome.

    Example shape (values are illustrative, not defaults to copy):

    {
      "prose_debrief": "\(exampleProse)",
      "scores": {"answer_relevance": 4, "structure": 3, "conciseness": 3, "questions_asked": 2},
      "weakness_tags": ["rambling_intro"],
      "highlights": [{"t": "00:14:32", "note": "Strong recovery after the hint"}],
      "action_items": ["Prep a 90-second intro"]
    }

    Rules:
    - All five top-level fields are required. "scores" must contain exactly the 4 keys shown — integer values 1-5, no other keys.
    - "weakness_tags": use the exact snake_case spellings from the vocabulary above; do not invent or reword tags.
    - "highlights" and "action_items": 2-5 items each. "t" is an "HH:MM:SS" timestamp from the transcript.
    - Inside string values, escape quotation marks you quote from the transcript as \\\" and write line breaks as \\n.
    """

    public func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600  // local inference on a long transcript is slow
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt + "\n\n" + Self.formatAppendix],
                ["role": "user", "content": userMessage],
            ],
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw ClaudeError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct Envelope: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let content = envelope.choices.first?.message.content else {
            throw ClaudeError.emptyResponse
        }
        let decoder = JSONDecoder()
        // A weak local model may echo the format appendix's example object
        // (verbatim, or ahead of its real answer) rather than follow it, so
        // skip any decodable candidate whose prose is still the example's
        // sentinel text and keep scanning for the model's actual answer.
        for candidate in Self.candidateObjects(in: content) {
            if let result = try? decoder.decode(CoachingResult.self, from: candidate),
               result.proseDebrief != Self.exampleProse {
                return result
            }
        }
        throw ClaudeError.emptyResponse
    }

    /// Local models wrap JSON in <think> blocks, fences, or prose. Reasoning
    /// models emit the final answer after their reasoning, so first try the
    /// substring after the LAST "</think>" (this is robust to nested/stray
    /// think markers, which make span-stripping unreliable). If that doesn't
    /// yield a balanced object, fall back to stripping well-formed
    /// <think>…</think> spans and scanning the remainder for balanced
    /// top-level JSON objects, tracking strings/escapes so braces inside
    /// string values don't fool the depth counter. Fences need no handling:
    /// the scan starts at the first "{".
    ///
    /// Known residual gap: an UNCLOSED <think> tag isn't stripped, so a brace
    /// fragment inside the un-terminated reasoning can still be extracted and
    /// returned. That fragment then fails to decode downstream, which marks
    /// the session failed and retryable — an accepted, non-silent failure mode.
    ///
    /// Yields every balanced object found in each candidate text, in order,
    /// rather than just the first. This lets `generateCoaching` look past an
    /// echoed example object for the model's real answer. Dedupe across the
    /// two candidate texts is not required.
    static func candidateObjects(in text: String) -> [Data] {
        var candidates: [Data] = []
        if let lastClose = text.range(of: "</think>", options: .backwards) {
            candidates.append(contentsOf: balancedObjects(in: String(text[lastClose.upperBound...])))
        }

        var s = text
        while let open = s.range(of: "<think>"),
              let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        candidates.append(contentsOf: balancedObjects(in: s))
        return candidates
    }

    /// Scans `s` for every balanced top-level JSON object in order (each scan
    /// resuming just past the previous object's closing brace), tracking
    /// strings/escapes so braces inside string values don't fool the depth
    /// counter.
    static func balancedObjects(in s: String) -> [Data] {
        var results: [Data] = []
        var searchStart = s.startIndex
        while let start = s[searchStart...].firstIndex(of: "{") {
            var depth = 0, inString = false, escaped = false
            var i = start
            var close: String.Index?
            while i < s.endIndex {
                let c = s[i]
                if escaped { escaped = false }
                else if inString && c == "\\" { escaped = true }
                else if c == "\"" { inString.toggle() }
                else if !inString && c == "{" { depth += 1 }
                else if !inString && c == "}" {
                    depth -= 1
                    if depth == 0 { close = i; break }
                }
                i = s.index(after: i)
            }
            guard let close else { break }
            if let data = String(s[start...close]).data(using: .utf8) {
                results.append(data)
            }
            searchStart = s.index(after: close)
        }
        return results
    }
}
