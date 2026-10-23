import Foundation
import FoundationModels

/// On-device Apple Intelligence (`SystemLanguageModel.default`). Small context (8k tokens
/// measured), so the pipeline sends small batches. One session per call.
struct AppleIntelligenceClient: LLMClient {
    let id = "apple-on-device"
    let displayName = "Apple Intelligence"
    let inputBudgetChars = 5_500

    func generate<T: StructuredOutput>(_ type: T.Type, system: String, prompt: String, reasoning: Bool) async throws -> T {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw LLMError.unavailable(String(localized: "Apple Intelligence ist nicht verfügbar."))
        }
        let session = LanguageModelSession(model: model, instructions: system)
        do {
            let response = try await session.respond(
                to: prompt, generating: T.self, options: GenerationOptions(temperature: 0.3)
            )
            return response.content
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    /// Newer SDKs report refusals and rate limits through `LanguageModelError`; matched by name
    /// so deprecated enum cases are not referenced.
    private static func map(_ error: Error) -> LLMError {
        let description = String(describing: error)
        if description.contains("ontext") && description.contains("xceed") { return .contextTooSmall }
        if description.contains("rateLimited") || description.contains("concurrentRequests") {
            return .rateLimited("Apple Intelligence")
        }
        if description.contains("refusal") || description.contains("guardrail") {
            return .refused(error.localizedDescription)
        }
        return .invalidOutput(error.localizedDescription)
    }
}
