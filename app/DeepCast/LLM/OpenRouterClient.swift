import Foundation
import FoundationModels

/// OpenAI-compatible endpoints used by DeepCast.
enum LLMEndpoint: String, Sendable {
    /// https://openrouter.ai/docs – free models with `:free` suffix.
    case openRouter
    /// Google AI Studio (Gemini API), OpenAI-compatible layer:
    /// https://ai.google.dev/gemini-api/docs/openai
    case googleAI

    var baseURL: URL {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .googleAI: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        }
    }
}

/// OpenAI-compatible chat completions (OpenRouter or Google AI Studio).
/// Uses strict JSON Schema output; falls back to `json_object` if a provider rejects it.
struct OpenRouterClient: LLMClient {
    static let baseURL = LLMEndpoint.openRouter.baseURL

    let model: String
    let apiKey: String
    var endpoint: LLMEndpoint = .openRouter
    var session: URLSession = .shared
    var maxAttempts = 3
    var inputBudgetChars = 40_000

    var id: String { endpoint == .googleAI ? "google/\(model)" : model }

    var displayName: String {
        let name = model.split(separator: "/").last.map(String.init) ?? model
        return name.replacingOccurrences(of: ":free", with: "")
    }

    func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T {
        let schema = try Self.jsonSchema(for: T.self)
        var useSchemaFormat = true
        var lastError: Error = LLMError.unavailable(model)
        var decodeRetries = 1

        var attempt = 1
        while attempt <= maxAttempts {
            try Task.checkCancellation()
            do {
                let content = try await complete(system: system, prompt: prompt, schema: schema,
                                                 schemaFormat: useSchemaFormat, reasoning: reasoning)
                do {
                    return try JSONResponseCleaner.decode(T.self, from: content)
                } catch let error as LLMError where decodeRetries > 0 {
                    decodeRetries -= 1
                    lastError = error
                    continue // retry without counting as a failed attempt
                }
            } catch LLMError.http(400, let message) where useSchemaFormat && message.localizedCaseInsensitiveContains("response_format") {
                useSchemaFormat = false
                continue
            } catch let error as LLMError where error.isPermanent {
                throw error
            } catch let error as LLMError {
                lastError = error
                if case .rateLimited = error, attempt < maxAttempts {
                    try await Task.sleep(for: .seconds(min(20, 4 * attempt)))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = LLMError.unavailable(error.localizedDescription)
                if attempt < maxAttempts { try await Task.sleep(for: .seconds(2 * attempt)) }
            }
            attempt += 1
        }
        throw lastError
    }

    /// Remaining free-model requests today (account-wide), if reported.
    func freeQuota() async throws -> (used: Int, limit: Int, remaining: Int)? {
        guard endpoint == .openRouter else { return nil }
        var request = URLRequest(url: Self.baseURL.appending(path: "key"))
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = (json["data"] as? [String: Any])?["free_model_daily_requests"] as? [String: Any],
              let used = info["used"] as? Int, let limit = info["limit"] as? Int, let remaining = info["remaining"] as? Int
        else { return nil }
        return (used, limit, remaining)
    }

    static func jsonSchema<T: Generable>(for type: T.Type) throws -> [String: Any] {
        let data = try JSONEncoder().encode(T.generationSchema)
        guard var schema = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidOutput("schema")
        }
        stripVendorKeys(&schema)
        return schema
    }

    /// `x-order` is Apple-specific; some providers reject unknown keywords in strict mode.
    private static func stripVendorKeys(_ object: inout [String: Any]) {
        object.removeValue(forKey: "x-order")
        for (key, value) in object {
            if var nested = value as? [String: Any] {
                stripVendorKeys(&nested)
                object[key] = nested
            } else if let array = value as? [Any] {
                object[key] = array.map { element -> Any in
                    guard var nested = element as? [String: Any] else { return element }
                    stripVendorKeys(&nested)
                    return nested
                }
            }
        }
    }

    private func complete(system: String, prompt: String, schema: [String: Any], schemaFormat: Bool, reasoning: Bool) async throws -> String {
        var request = URLRequest(url: endpoint.baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepCast", forHTTPHeaderField: "X-Title")

        var systemText = system
        let responseFormat: [String: Any]
        if schemaFormat {
            responseFormat = ["type": "json_schema", "json_schema": ["name": "output", "strict": true, "schema": schema]]
        } else {
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            systemText += "\n\nAntworte ausschließlich mit JSON nach diesem Schema:\n\(schemaText)"
            responseFormat = ["type": "json_object"]
        }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "response_format": responseFormat,
            "messages": [
                ["role": "system", "content": systemText],
                ["role": "user", "content": prompt],
            ],
        ]
        switch endpoint {
        case .openRouter: body["reasoning"] = ["enabled": reasoning]
        case .googleAI: body["reasoning_effort"] = reasoning ? "medium" : "low"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.unavailable("no response") }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // OpenRouter: {"error":{…}}, Google: [{"error":{…}}] or {"error":{…}}
        let errorObject = (json?["error"] as? [String: Any])
            ?? ((try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first?["error"] as? [String: Any])
        let message = (errorObject?["message"] as? String) ?? String(data: data.prefix(200), encoding: .utf8) ?? ""

        if http.statusCode == 429 || (errorObject?["code"] as? Int) == 429 {
            if message.localizedCaseInsensitiveContains("per-day") || message.localizedCaseInsensitiveContains("per day")
                || message.localizedCaseInsensitiveContains("PerDay") {
                throw LLMError.dailyLimitReached
            }
            throw LLMError.rateLimited(displayName)
        }
        guard (200..<300).contains(http.statusCode), errorObject == nil else {
            if http.statusCode >= 500 || http.statusCode == 408 {
                throw http.statusCode == 503 ? LLMError.rateLimited(displayName) : LLMError.unavailable("HTTP \(http.statusCode)")
            }
            throw LLMError.http(status: http.statusCode, message: String(message.prefix(200)))
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let content = (choices.first?["message"] as? [String: Any])?["content"] as? String,
              !content.isEmpty
        else { throw LLMError.invalidOutput("leere Antwort") }
        return content
    }
}
