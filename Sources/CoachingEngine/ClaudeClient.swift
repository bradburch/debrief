import Foundation

public protocol CoachingLLM: Sendable {
    func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult
}

public enum ClaudeError: Error, Equatable {
    case httpStatus(Int, body: String)
    case refusal
    case truncated
    case emptyResponse
}

public struct AnthropicClient: CoachingLLM {
    /// Single source of truth for the default model — also referenced by the app's
    /// model setting so the picker default and the client default can't drift apart.
    public static let defaultModel = "claude-opus-4-8"

    let apiKey: String
    let model: String
    let session: URLSession

    public init(apiKey: String, model: String = AnthropicClient.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Adaptive thinking is a Claude 4.6+ feature; pre-4.6 models (e.g. Haiku 4.5)
    /// reject it with a 400 and require the older enabled+budget form. Without this
    /// branch, selecting Haiku in Settings would fail every debrief.
    /// ponytail: substring match over the one non-adaptive model we offer; extend the
    /// check if older models are added to the picker.
    var thinkingParam: [String: Any] {
        model.contains("haiku")
            ? ["type": "enabled", "budget_tokens": 8000]  // < max_tokens (16000), > 1024 min
            : ["type": "adaptive"]
    }

    /// JSON schema for structured outputs: guarantees the response text is a single
    /// valid JSON object decodable as CoachingResult. Scores use four fixed dimensions.
    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "prose_debrief": ["type": "string"],
            "scores": [
                "type": "object",
                "properties": [
                    "answer_relevance": ["type": "integer"],
                    "structure": ["type": "integer"],
                    "conciseness": ["type": "integer"],
                    "questions_asked": ["type": "integer"],
                ],
                "required": ["answer_relevance", "structure", "conciseness", "questions_asked"],
                "additionalProperties": false,
            ],
            "weakness_tags": ["type": "array", "items": ["type": "string"]],
            "highlights": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["t": ["type": "string"], "note": ["type": "string"]],
                    "required": ["t", "note"],
                    "additionalProperties": false,
                ],
            ],
            "action_items": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["prose_debrief", "scores", "weakness_tags", "highlights", "action_items"],
        "additionalProperties": false,
    ]

    public func generateCoaching(systemPrompt: String, userMessage: String) async throws -> CoachingResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "thinking": thinkingParam,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]],
            "output_config": ["format": ["type": "json_schema", "schema": Self.outputSchema]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        guard http.statusCode == 200 else {
            throw ClaudeError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        struct Envelope: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
            let stop_reason: String?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        switch envelope.stop_reason {
        case "refusal": throw ClaudeError.refusal
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        guard let text = envelope.content.first(where: { $0.type == "text" && $0.text?.isEmpty == false })?.text,
              let payload = text.data(using: .utf8) else {
            throw ClaudeError.emptyResponse
        }
        return try JSONDecoder().decode(CoachingResult.self, from: payload)
    }
}
