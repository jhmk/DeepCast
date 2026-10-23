import Foundation

enum FishAudioError: LocalizedError, Equatable {
    case missingKey
    case http(status: Int, message: String)
    case invalidResponse

    /// Errors that will not go away by retrying (key, payment, bad request).
    var isPermanent: Bool {
        switch self {
        case .missingKey: true
        case .http(let status, _): [400, 401, 402, 403, 404, 422].contains(status)
        case .invalidResponse: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            String(localized: "Kein Fish-Audio-Key im Schlüsselbund.")
        case .http(401, _):
            String(localized: "Fish Audio: Key ungültig (401).")
        case .http(402, _):
            String(localized: "Fish Audio: Zahlung erforderlich (402) – Gratisangebot beendet?")
        case .http(let status, let message):
            String(localized: "Fish Audio: HTTP \(status) \(message)")
        case .invalidResponse:
            String(localized: "Fish Audio: ungültige Antwort.")
        }
    }
}

struct FishVoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let description: String
    let languages: [String]
    let sampleURL: URL?
    let uses: Int
    let licensed: Bool
}

/// Fish Audio REST API (https://docs.fish.audio). TTS model `s2.1-pro-free`.
struct FishAudioProvider: Sendable {
    static let model = "s2.1-pro-free"
    static let baseURL = URL(string: "https://api.fish.audio")!

    let apiKey: String
    var session: URLSession = .shared
    var maxAttempts = 3

    /// Synthesizes one segment into an MP3 file (44.1 kHz mono, 128 kbit/s).
    /// Multi-speaker dialogue in one request (S2 family): text with <|speaker:i|> tags,
    /// `reference_id` as array of voice IDs in speaker-index order.
    func synthesizeDialog(lines: [(speaker: Int, text: String)], voiceIDs: [String], speed: Double = 1.0, to url: URL) async throws {
        let text = Self.dialogText(lines)
        try await synthesize(text: text, referenceID: voiceIDs, speed: speed, timeout: 300, to: url)
    }

    static func dialogText(_ lines: [(speaker: Int, text: String)]) -> String {
        lines.map { "<|speaker:\($0.speaker)|>\($0.text)" }.joined()
    }

    func synthesize(text: String, voiceID: String, speed: Double = 1.0, to url: URL) async throws {
        try await synthesize(text: text, referenceID: voiceID, speed: speed, timeout: 120, to: url)
    }

    private func synthesize(text: String, referenceID: Any, speed: Double, timeout: TimeInterval, to url: URL) async throws {
        var request = URLRequest(url: Self.baseURL.appending(path: "v1/tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.model, forHTTPHeaderField: "model")
        let body: [String: Any] = [
            "text": text,
            "reference_id": referenceID,
            "format": "mp3",
            "sample_rate": 44100,
            "mp3_bitrate": 128,
            "latency": "normal",
            "prosody": ["speed": min(2.0, max(0.5, speed)), "volume": 0, "normalize_loudness": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        guard data.count > 1_000 else { throw FishAudioError.invalidResponse }
        try data.write(to: url, options: .atomic)
    }

    /// Searches public library voices. `licensed` limits to voices with cleared rights.
    func searchVoices(title: String?, language: String = "de", licensed: Bool = false, pageSize: Int = 40) async throws -> [FishVoice] {
        var components = URLComponents(url: Self.baseURL.appending(path: "model"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort_by", value: "score"),
        ]
        if let title, !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
        if licensed { items.append(URLQueryItem(name: "licensed", value: "true")) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let data = try await send(request)
        return try Self.parseVoices(data)
    }

    static func parseVoices(_ data: Data) throws -> [FishVoice] {
        struct Page: Decodable { let items: [Item] }
        struct Item: Decodable {
            let _id: String
            let title: String
            let description: String?
            let languages: [String]?
            let samples: [Sample]?
            let task_count: Int?
            let licensed: Bool?
            let state: String?
        }
        struct Sample: Decodable { let audio: String? }
        return try JSONDecoder().decode(Page.self, from: data).items
            .filter { ($0.state ?? "trained") == "trained" }
            .map { item in
                FishVoice(
                    id: item._id,
                    title: item.title.trimmingCharacters(in: .whitespaces),
                    description: item.description ?? "",
                    languages: item.languages ?? [],
                    sampleURL: item.samples?.first?.audio.flatMap(URL.init(string:)),
                    uses: item.task_count ?? 0,
                    licensed: item.licensed ?? false
                )
            }
    }

    /// Sends a request with retries and exponential backoff for 429/5xx.
    private func send(_ request: URLRequest) async throws -> Data {
        var lastError: Error = FishAudioError.invalidResponse
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw FishAudioError.invalidResponse }
                if (200..<300).contains(http.statusCode) { return data }
                let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
                let error = FishAudioError.http(status: http.statusCode, message: message)
                if error.isPermanent { throw error }
                lastError = error
            } catch let error as FishAudioError where error.isPermanent {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            if attempt < maxAttempts {
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        throw lastError
    }
}
