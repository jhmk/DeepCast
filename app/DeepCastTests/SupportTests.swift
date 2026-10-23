import Foundation
import Testing
@testable import DeepCast

struct AppPathsTests {
    private let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    @Test func folderNameStripsForbiddenCharacters() {
        let name = AppPaths.episodeFolderName(topic: "Wie funktionieren Tardigraden?", date: date)
        #expect(name.hasSuffix(" Wie funktionieren Tardigraden"))
        #expect(!name.contains("?"))
    }

    @Test func folderNameFallsBackToDate() {
        let name = AppPaths.episodeFolderName(topic: "  ?/:  ", date: date)
        #expect(name.count == 10) // yyyy-MM-dd
    }

    @Test func folderNameIsLimited() {
        let name = AppPaths.episodeFolderName(topic: String(repeating: "a", count: 300), date: date)
        #expect(name.count <= 91)
    }

    @Test func episodesLiveInMusicFolder() {
        #expect(AppPaths.episodesRoot().path.hasSuffix("/Music/DeepCast"))
    }
}

struct ExecutableLocatorTests {
    @Test func findsExecutableInGivenDirectory() {
        #expect(ExecutableLocator.locate("ls", searchDirectories: ["/nonexistent", "/bin"])?.path == "/bin/ls")
    }

    @Test func returnsNilWhenMissing() {
        #expect(ExecutableLocator.locate("definitely-not-a-tool", searchDirectories: ["/bin"]) == nil)
    }
}

struct StorageManagerTests {
    func makeFile(_ url: URL, bytes: Int, date: Date) throws {
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    @Test func prunesOldestFirstBelowLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir.appending(path: "old.mp3"), bytes: 400_000, date: .now.addingTimeInterval(-86_400 * 30))
        try makeFile(dir.appending(path: "new.mp3"), bytes: 400_000, date: .now)
        let freed = StorageManager.pruneSpeechCache(dir, limit: 600_000)
        #expect(freed > 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "old.mp3").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "new.mp3").path))
    }

    @Test func clearsOnlyIntermediates() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: ".work"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["plan.json", "outline.json", "dossier.json", "factcheck.md", "episode.m4a", ".work/seg.wav"] {
            try Data(count: 5000).write(to: folder.appending(path: name))
        }
        #expect(StorageManager.intermediatesSize(in: folder) > 0)
        StorageManager.clearIntermediates(in: [folder])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["dossier.json", "episode.m4a", "factcheck.md"])
    }
}

struct RemainingTimeTests {
    @Test func extrapolatesLinearlyAndResetsPerPhase() {
        var estimator = RemainingTimeEstimator()
        let start = Date(timeIntervalSince1970: 0)
        #expect(estimator.update(phase: "script", fraction: 0, now: start) == nil)
        #expect(estimator.update(phase: "script", fraction: 0.05, now: start.addingTimeInterval(5)) == nil) // too early
        let estimate = estimator.update(phase: "script", fraction: 0.25, now: start.addingTimeInterval(30))
        #expect(estimate == 90)
        #expect(estimator.update(phase: "speech", fraction: 0.5, now: start.addingTimeInterval(31)) == nil) // new phase, too short
        #expect(estimator.update(phase: "speech", fraction: 1, now: start.addingTimeInterval(40)) == 0)
    }

    @Test func scriptAndCheckShareOnePhase() {
        #expect(RemainingTimeEstimator.phaseKey(.script) == RemainingTimeEstimator.phaseKey(.check))
    }

    @Test func formatsNicely() {
        #expect(RemainingTimeEstimator.format(0.5) == "gleich fertig")
        #expect(RemainingTimeEstimator.format(42) == "noch ca. 45 s")
        #expect(RemainingTimeEstimator.format(160) == "noch ca. 2:40 min")
    }
}

struct KeyStoreTests {
    @Test func everyAccountHasHTTPSCreateLink() {
        for account in KeychainStore.Account.allCases { #expect(account.createURL.scheme == "https") }
    }

    @Test func testsNeverTouchStorage() {
        #expect(KeychainStore.isDisabled)
        #expect(KeychainStore.read(.openRouter) == nil)
    }
}
