import Foundation
import Testing
@testable import DeepCast

struct PaywallTests {
    @Test func archiveExtractionKeepsLongLinesAndDropsToolbar() {
        let article = String(repeating: "Die Straße von Hormus ist ein Nadelöhr für den Öltransport und wird stark überwacht. ", count: 3)
        let html = """
        <html><head><title>Straße von Hormus - archive.ph</title><style>.x{}</style></head><body>
        <div>archive.ph · webpage capture · Saved from · history · share · download .zip · report bug or abuse</div>
        <div id="CONTENT"><div style="a"><div>\(article)</div><div>\(article)</div><span>kurz</span>
        <div>\(article.uppercased())</div></div></div></body></html>
        """
        let result = ArchiveFetcher.extract(html)
        #expect(result.title == "Straße von Hormus")
        #expect(result.text.components(separatedBy: "\n\n").count == 2) // duplicate line removed
        #expect(!result.text.contains("webpage capture"))
    }

    @Test func configReadinessNeedsProfileAndExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = PaywallConfig()
        config.profilePath = dir.path
        #expect(!config.waterfoxReady && !config.extensionInstalled)
        try FileManager.default.createDirectory(at: dir.appending(path: "extensions"), withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "prefs.js"))
        try Data().write(to: dir.appending(path: "extensions/magnolia@12.34.xpi"))
        #expect(config.extensionInstalled)
        #expect(config.waterfoxReady == (FileManager.default.isExecutableFile(atPath: config.waterfoxBinary)
                                         && FileManager.default.isExecutableFile(atPath: config.geckodriver)))
    }
}

/// Live: DEEPCAST_PAYWALL_URLS="url1 url2" – reads via archive.is (no browser).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEEPCAST_PAYWALL_URLS"] != nil), .tags(.live))
struct LivePaywallTests {
    @Test func readsPaywalledArticlesViaArchive() async throws {
        let urls = (ProcessInfo.processInfo.environment["DEEPCAST_PAYWALL_URLS"] ?? "").split(separator: " ").compactMap { URL(string: String($0)) }
        var config = PaywallConfig()
        config.enabled = true
        config.useWaterfox = false
        let results = await PaywallFetcher(config: config).fetch(urls) { _ in }
        for (url, result) in results {
            switch result {
            case .success(let fetched):
                print("LIVE-PAYWALL ✅ \(fetched.page.extracted.text.split(whereSeparator: \.isWhitespace).count) Wörter – \(url.lastPathComponent.prefix(60))")
            case .failure(let error):
                print("LIVE-PAYWALL ❌ \(error.localizedDescription) – \(url.lastPathComponent.prefix(60))")
            }
        }
        #expect(results.contains { if case .success = $0.1 { true } else { false } })
    }
}
