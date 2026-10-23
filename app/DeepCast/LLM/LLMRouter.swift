import Foundation

enum LLMRole: String, Codable, Sendable {
    /// Planning and claim extraction (research).
    case research
    /// Outline, script, rewrites.
    case writer
    /// Independent fact verification (sees only claim + evidence).
    case verifier
}

/// One model call, recorded for the fact-check report and cost overview.
struct LLMCallRecord: Codable, Sendable, Hashable {
    let role: LLMRole
    let model: String
    let task: String
    let seconds: Double
    let succeeded: Bool
    let note: String?
}

struct LLMResult<T: Sendable>: Sendable {
    let value: T
    let model: String
}

/// Tries the clients of a role in order. Permanent errors (missing key, daily limit, model
/// blocked) disable a client for the rest of the run; temporary ones fall through to the next
/// client for this call only. `contextTooSmall` is rethrown so the caller can split the input.
actor LLMRouter {
    private let chains: [LLMRole: [any LLMClient]]
    private var disabled: [String: String] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private(set) var calls: [LLMCallRecord] = []
    /// After this many temporary failures in a row a client is skipped for the run
    /// (e.g. Gemma on the shared, often throttled Google AI Studio pool).
    private let failureLimit = 2

    init(chains: [LLMRole: [any LLMClient]]) {
        self.chains = chains
    }

    func activeClient(for role: LLMRole) -> (any LLMClient)? {
        chains[role]?.first { disabled[$0.id] == nil }
    }

    func inputBudget(for role: LLMRole) -> Int {
        activeClient(for: role)?.inputBudgetChars ?? AppleIntelligenceClient().inputBudgetChars
    }

    var disabledClients: [String: String] { disabled }

    func generate<T: StructuredOutput>(
        _ type: T.Type, role: LLMRole, task: String, system: String, prompt: String, reasoning: Bool = false
    ) async throws -> LLMResult<T> {
        let chain = chains[role] ?? []
        var lastError: Error = LLMError.unavailable(String(localized: "Kein Sprachmodell konfiguriert."))
        for client in chain where disabled[client.id] == nil {
            try Task.checkCancellation()
            let start = Date()
            do {
                let value = try await client.generate(T.self, system: system, prompt: prompt, reasoning: reasoning)
                record(role, client, task, start, ok: true, note: nil)
                consecutiveFailures[client.id] = 0
                return LLMResult(value: value, model: client.id)
            } catch is CancellationError {
                throw CancellationError()
            } catch LLMError.contextTooSmall {
                record(role, client, task, start, ok: false, note: "context")
                throw LLMError.contextTooSmall
            } catch {
                record(role, client, task, start, ok: false, note: error.localizedDescription)
                lastError = error
                if let llmError = error as? LLMError, llmError.isPermanent {
                    disable(client, reason: llmError.localizedDescription, sameKeyAs: chain)
                } else {
                    consecutiveFailures[client.id, default: 0] += 1
                    if consecutiveFailures[client.id, default: 0] >= failureLimit {
                        disabled[client.id] = error.localizedDescription
                    }
                }
            }
        }
        throw lastError
    }

    /// A daily limit or missing key affects every OpenRouter model, not just one.
    private func disable(_ client: any LLMClient, reason: String, sameKeyAs chain: [any LLMClient]) {
        disabled[client.id] = reason
        guard client is OpenRouterClient, reason == LLMError.dailyLimitReached.localizedDescription
                || reason == LLMError.missingKey.localizedDescription else { return }
        for role in chains.values {
            for other in role where other is OpenRouterClient { disabled[other.id] = reason }
        }
    }

    private func record(_ role: LLMRole, _ client: any LLMClient, _ task: String, _ start: Date, ok: Bool, note: String?) {
        calls.append(LLMCallRecord(role: role, model: client.id, task: task,
                                   seconds: Date().timeIntervalSince(start), succeeded: ok, note: note))
    }
}
