import Foundation

/// Settings snapshot for the paywall fallback (spec 3, "Paywall-Fetcher", ADR-010).
struct PaywallConfig: Sendable, Hashable {
    var enabled = false
    var useArchive = true
    var useWaterfox = true
    var waterfoxBinary = "/Applications/Waterfox.app/Contents/MacOS/waterfox"
    var geckodriver = ExecutableLocator.locate("geckodriver")?.path ?? "/opt/homebrew/bin/geckodriver"
    var profilePath = PaywallConfig.defaultProfilePath
    /// Max. paywalled articles per episode (each takes 10–30 s).
    var maxArticles = 3

    static let defaultProfilePath = AppPaths.applicationSupport().appending(path: "WaterfoxProfile").path

    /// Bypass Paywalls Clean installed in the DeepCast profile.
    var extensionInstalled: Bool {
        let file = ((profilePath as NSString).appendingPathComponent("extensions") as NSString).appendingPathComponent("magnolia@12.34.xpi")
        return FileManager.default.fileExists(atPath: file)
    }

    var waterfoxReady: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: waterfoxBinary) && fm.isExecutableFile(atPath: geckodriver)
            && fm.fileExists(atPath: (profilePath as NSString).appendingPathComponent("prefs.js"))
    }
}

enum PaywallError: LocalizedError {
    case noSnapshot, captcha, tooShort, waterfoxUnavailable(String), webDriver(String)

    var errorDescription: String? {
        switch self {
        case .noSnapshot: String(localized: "kein Archiv-Schnappschuss")
        case .captcha: String(localized: "archive.is verlangt ein Captcha")
        case .tooShort: String(localized: "auch über den Paywall-Abruf zu wenig Text")
        case .waterfoxUnavailable(let reason): String(localized: "Waterfox nicht bereit: \(reason)")
        case .webDriver(let message): String(localized: "Waterfox-Steuerung: \(message)")
        }
    }
}

/// Paywall fallback: 1. existing archive.is snapshot (no browser), 2. Waterfox with the
/// DeepCast profile and Bypass Paywalls Clean (headless, via geckodriver).
/// Full texts stay local: show notes and reports only contain links and short quotes.
struct PaywallFetcher: Sendable {
    let config: PaywallConfig

    struct Result: Sendable {
        let page: WebPageFetcher.Page
        let method: String
    }

    /// Fetches several articles; failures are reported per URL.
    func fetch(_ urls: [URL], progress: @Sendable (String) async -> Void) async -> [(URL, Swift.Result<Result, Error>)] {
        var results: [(URL, Swift.Result<Result, Error>)] = []
        var remaining: [URL] = []
        if config.useArchive {
            for url in urls {
                if Task.isCancelled { break }
                await progress("archive.is: \(url.host() ?? "")")
                do {
                    let page = try await ArchiveFetcher().fetch(url)
                    results.append((url, .success(Result(page: page, method: "archive.is"))))
                } catch {
                    remaining.append(url)
                    if !config.useWaterfox || !config.waterfoxReady { results.append((url, .failure(error))) }
                }
                try? await Task.sleep(for: .seconds(2)) // be gentle with archive.is
            }
        } else {
            remaining = urls
        }
        guard config.useWaterfox, !remaining.isEmpty, config.waterfoxReady else { return results }
        await progress("Waterfox: \(remaining.count) Artikel")
        do {
            let session = try await WaterfoxSession.start(config)
            for url in remaining {
                if Task.isCancelled { break }
                do {
                    let page = try await session.read(url)
                    results.append((url, .success(Result(page: page, method: "Waterfox + Bypass Paywalls Clean"))))
                } catch {
                    results.append((url, .failure(error)))
                }
            }
            await session.close()
        } catch {
            for url in remaining { results.append((url, .failure(error))) }
        }
        return results
    }
}

/// Reads the newest archive.is snapshot of a URL (what Bypass Paywalls Clean does for
/// Spiegel and Tagesspiegel). No snapshot is created.
struct ArchiveFetcher: Sendable {
    func fetch(_ url: URL) async throws -> WebPageFetcher.Page {
        let clean = url.absoluteString.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? url.absoluteString
        guard let lookup = URL(string: "https://archive.is/newest/" + clean) else { throw PaywallError.noSnapshot }
        let (data, response) = try await HTTP.get(lookup, userAgent: HTTP.browserAgent, timeout: 30)
        let html = String(data: data, encoding: .utf8) ?? ""
        let final = response.url?.absoluteString ?? ""
        if html.range(of: "captcha", options: .caseInsensitive) != nil, html.count < 50_000 { throw PaywallError.captcha }
        guard response.statusCode == 200, !final.contains("/newest/"), final.range(of: #"archive\.[a-z]+/\d{8,}"#, options: .regularExpression) != nil
        else { throw PaywallError.noSnapshot }
        var extracted = Self.extract(html)
        extracted.paywalled = false
        guard extracted.text.count >= WebPageFetcher.minimumTextLength * 2 else { throw PaywallError.tooShort }
        return WebPageFetcher.Page(url: url, extracted: extracted)
    }

    /// archive.is inlines all styles and drops <p>; keep long text lines instead.
    static func extract(_ html: String) -> HTMLTextExtractor.Result {
        var base = HTMLTextExtractor.extract(html)
        var body = html
        for tag in ["script", "style", "noscript", "svg", "nav", "header", "footer", "form", "button"] {
            body = body.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Archive toolbar is the first table/div before the page; drop until the original <html> copy.
        if let range = body.range(of: "id=\"CONTENT\"", options: .caseInsensitive) { body = String(body[range.lowerBound...]) }
        let text = HTMLTextExtractor.decodeEntities(body.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression))
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard line.count > 80, lines.last != line else { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: "\n\n")
        if joined.count > base.text.count { base.text = joined }
        base.title = base.title.replacingOccurrences(of: #"\s*[-–|]\s*archive\.\w+$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return base
    }
}

/// Minimal W3C WebDriver client for geckodriver + Waterfox (headless, persistent profile).
actor WaterfoxSession {
    private let process: Process
    private let port: Int
    private var sessionID: String?

    static func start(_ config: PaywallConfig) async throws -> WaterfoxSession {
        guard config.waterfoxReady else {
            throw PaywallError.waterfoxUnavailable(String(localized: "Profil, Waterfox oder geckodriver fehlt"))
        }
        let port = Int.random(in: 47_000...48_999)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.geckodriver)
        process.arguments = ["--port", String(port)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let session = WaterfoxSession(process: process, port: port)
        try await session.open(config)
        return session
    }

    private init(process: Process, port: Int) {
        self.process = process
        self.port = port
    }

    private func open(_ config: PaywallConfig) async throws {
        var lastError: Error = PaywallError.webDriver("geckodriver startet nicht")
        for _ in 0..<20 { // wait for geckodriver
            do {
                let capabilities: [String: Any] = ["capabilities": ["alwaysMatch": [
                    "browserName": "firefox",
                    "pageLoadStrategy": "eager",
                    "moz:firefoxOptions": [
                        "binary": config.waterfoxBinary,
                        "args": ["-headless", "-profile", config.profilePath],
                    ],
                ]]]
                let value = try await call("POST", "/session", body: capabilities)
                guard let id = (value as? [String: Any])?["sessionId"] as? String else { throw PaywallError.webDriver("keine Sitzung") }
                sessionID = id
                _ = try? await call("POST", "/session/\(id)/timeouts", body: ["pageLoad": 30_000, "script": 10_000])
                return
            } catch let error as URLError where error.code == .cannotConnectToHost {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                close()
                throw error
            }
        }
        close()
        throw lastError
    }

    /// Loads the page, waits until the extension has replaced the text (stable length), returns HTML text.
    func read(_ url: URL) async throws -> WebPageFetcher.Page {
        guard let id = sessionID else { throw PaywallError.webDriver("keine Sitzung") }
        _ = try await call("POST", "/session/\(id)/url", body: ["url": url.absoluteString])
        var best = HTMLTextExtractor.Result(title: "", text: "", publishedAt: nil, language: nil, paywalled: true)
        var stableRounds = 0
        for _ in 0..<12 { // up to ~24 s
            try await Task.sleep(for: .seconds(2))
            guard let html = try await call("GET", "/session/\(id)/source") as? String else { continue }
            let extracted = HTMLTextExtractor.extract(html)
            if extracted.text.count > best.text.count + 50 {
                best = extracted
                stableRounds = 0
            } else {
                stableRounds += 1
                if stableRounds >= 2, best.text.count >= WebPageFetcher.minimumTextLength * 2 { break }
            }
        }
        guard best.text.count >= WebPageFetcher.minimumTextLength * 2 else { throw PaywallError.tooShort }
        best.paywalled = false
        return WebPageFetcher.Page(url: url, extracted: best)
    }

    func close() {
        if let id = sessionID {
            sessionID = nil
            Task { _ = try? await self.call("DELETE", "/session/\(id)") ; self.terminate() }
        } else {
            terminate()
        }
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let value = json?["value"]
        if (response as? HTTPURLResponse)?.statusCode ?? 500 >= 400 {
            let message = ((value as? [String: Any])?["message"] as? String) ?? "HTTP-Fehler"
            throw PaywallError.webDriver(String(message.prefix(160)))
        }
        return value
    }

    // MARK: Profile setup (one-time, done by the user)

    /// Creates the DeepCast profile folder and opens Waterfox with it, so the user can install
    /// Bypass Paywalls Clean and tick "opt-in". The normal Waterfox keeps running (-no-remote).
    static func openProfileForSetup(_ config: PaywallConfig) throws {
        try FileManager.default.createDirectory(atPath: config.profilePath, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.waterfoxBinary)
        process.arguments = ["-no-remote", "-profile", config.profilePath,
                             "https://gitflic.ru/project/magnolia1234/bypass-paywalls-firefox-clean/release"]
        try process.run()
    }
}
