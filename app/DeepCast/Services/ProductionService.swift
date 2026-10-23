import Foundation
import Observation
import SwiftData

/// Renders the script of an episode to speech and assembles the final M4A.
@MainActor
@Observable
final class ProductionService {
    private(set) var activeEpisodeID: UUID?
    private(set) var progress: Double = 0
    private(set) var message = ""
    private(set) var remaining: TimeInterval?
    private var estimator = RemainingTimeEstimator()
    private var task: Task<Void, Never>?

    var isRunning: Bool { activeEpisodeID != nil }

    /// Fish allows 5 concurrent requests on the free tier; 3 leaves headroom.
    nonisolated static let maxParallelRenders = 3

    func produce(_ episode: Episode, personas: PersonaStore, settings: AppSettings, context: ModelContext) {
        guard !isRunning else { return }
        let segments = episode.sortedSegments
        guard !segments.isEmpty else {
            episode.lastError = String(localized: "Das Skript ist leer.")
            return
        }

        // Snapshot everything the background work needs as Sendable values.
        let jobs: [RenderJob] = segments.enumerated().map { index, segment in
            let persona = personas.persona(id: segment.speakerID) ?? personas.personas.first ?? Persona.defaults[0]
            return RenderJob(index: index, text: segment.text, persona: persona, section: segment.section)
        }
        let mode = settings.resolvedAI(for: episode.options).speechMode
        let pronunciations = settings.preferences.pronunciationMap
        let language = episode.language
        let categoryMix = episode.options?.categoryMix ?? CategoryMix([])
        let fishKey = mode == .fishWithAppleFallback ? KeychainStore.read(.fishAudio) : nil
        let naturalDialog = settings.naturalDialog && mode == .fishWithAppleFallback
        let soundProfile = settings.soundProfile
        let title = episode.title
        let summary = episode.topic
        let createdAt = episode.createdAt
        let folder = episode.folderURL
        let fileName = "\(episode.folderName).m4a"
        let dossier = ArtifactStore.load(ResearchDossier.self, name: "dossier.json", in: folder)
        let sourceLines = dossier.map(FactCheckReport.sourceLines) ?? []
        let factCheck = dossier.map { "🟢 \($0.count(.green)) belegt · 🟡 \($0.count(.yellow)) mit Einschränkung · 🔴 \($0.count(.red)) entfernt" }

        activeEpisodeID = episode.id
        estimator = RemainingTimeEstimator()
        remaining = nil
        episode.status = .rendering
        episode.lastError = nil
        progress = 0
        message = String(localized: "Starte Vertonung …")

        task = Task {
            do {
                let outcome = try await Self.run(
                    jobs: jobs, mode: mode, fishKey: fishKey, naturalDialog: naturalDialog, soundProfile: soundProfile, pronunciations: pronunciations, language: language, categoryMix: categoryMix,
                    metadata: EpisodeMetadata(title: title, summary: summary, date: createdAt),
                    folder: folder, fileName: fileName, sources: sourceLines, factCheck: factCheck
                ) { [weak self] fraction, text in
                    await MainActor.run {
                        self?.remaining = self?.estimator.update(phase: "speech", fraction: fraction)
                        self?.progress = fraction
                        self?.message = text
                    }
                }
                apply(outcome, to: episode, segments: segments, fileName: fileName)
                Self.recordSpeakingRate(words: segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count },
                                        duration: outcome.totalDuration, language: language)
                Task.detached(priority: .background) { StorageManager.pruneSpeechCache() }
                Notifier.post(title: String(localized: "Episode fertig: \(title)"),
                              body: String(localized: "\(EpisodeExporter.shortTime(outcome.totalDuration)) · bereit zum Hören."))
            } catch is CancellationError {
                episode.status = .needsRender
                episode.lastError = String(localized: "Vertonung abgebrochen.")
            } catch {
                episode.status = .failed
                episode.lastError = error.localizedDescription
            }
            try? context.save()
            activeEpisodeID = nil
            task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func apply(_ outcome: ProductionOutcome, to episode: Episode, segments: [EpisodeSegment], fileName: String) {
        for (segment, rendered) in zip(segments, outcome.segments) {
            segment.startTime = rendered.start
            segment.duration = rendered.duration
            segment.renderedProvider = rendered.provider.rawValue
        }
        episode.duration = outcome.totalDuration
        episode.chapters = outcome.chapters
        episode.audioFileName = fileName
        episode.renderNote = outcome.note
        episode.playbackPosition = 0
        episode.status = .ready
    }

    // MARK: - Background work

    struct RenderJob: Sendable {
        let index: Int
        let text: String
        let persona: Persona
        let section: String
    }

    struct RenderedSegment: Sendable {
        let start: TimeInterval
        let duration: TimeInterval
        let provider: SpeechProviderKind
    }

    struct ProductionOutcome: Sendable {
        let segments: [RenderedSegment]
        let totalDuration: TimeInterval
        let chapters: [ChapterMarker]
        let note: String?
    }

    typealias ProgressHandler = @Sendable (Double, String) async -> Void

    nonisolated private static func run(
        jobs: [RenderJob],
        mode: SpeechMode,
        fishKey: String?,
        naturalDialog: Bool,
        soundProfile: SoundProfile,
        pronunciations: [String: String],
        language: String,
        categoryMix: CategoryMix,
        metadata: EpisodeMetadata,
        folder: URL,
        fileName: String,
        sources: [String],
        factCheck: String?,
        progress: ProgressHandler
    ) async throws -> ProductionOutcome {
        let renderer = SpeechRenderer(mode: mode, fishAPIKey: fishKey, pronunciations: pronunciations, language: language,
                                      speechRate: categoryMix.speechRate)
        let assembler = try AudioAssembler(profile: soundProfile)

        // Units: single segments, or (natural dialogue) groups of a chapter in one Fish request.
        let units: [[Int]] = naturalDialog
            ? DialogPlanner.groups(sections: jobs.map(\.section), lengths: jobs.map { $0.text.count })
            : jobs.indices.map { [$0] }
        struct UnitResult: Sendable {
            let url: URL
            let speeches: [RenderedSpeech]   // per job of the unit
            let isDialog: Bool
        }

        var results = [UnitResult?](repeating: nil, count: units.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, UnitResult).self) { group in
            var next = 0
            func addNext() {
                guard next < units.count else { return }
                let unitIndex = next
                let unit = units[unitIndex]
                next += 1
                group.addTask {
                    if unit.count > 1 {
                        do {
                            let url = try await renderer.renderDialog(unit.map { (jobs[$0].text, jobs[$0].persona) })
                            let speeches = unit.map { RenderedSpeech(url: url, provider: .fish, voiceName: jobs[$0].persona.fishVoice?.title ?? "",
                                                                     fromCache: false, fallbackReason: nil) }
                            return (unitIndex, UnitResult(url: url, speeches: speeches, isDialog: true))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Fall back to single segments for this group (stitched below).
                            var speeches: [RenderedSpeech] = []
                            for index in unit { speeches.append(try await renderer.render(text: jobs[index].text, persona: jobs[index].persona)) }
                            return (unitIndex, UnitResult(url: speeches[0].url, speeches: speeches, isDialog: false))
                        }
                    }
                    let speech = try await renderer.render(text: jobs[unit[0]].text, persona: jobs[unit[0]].persona)
                    return (unitIndex, UnitResult(url: speech.url, speeches: [speech], isDialog: false))
                }
            }
            for _ in 0..<min(maxParallelRenders, units.count) { addNext() }
            while let (index, result) = try await group.next() {
                results[index] = result
                done += units[index].count
                await progress(0.8 * Double(done) / Double(jobs.count),
                               String(localized: "Sprachausgabe \(done) von \(jobs.count)"))
                addNext()
            }
        }
        let unitResults = results.compactMap { $0 }
        var speeches = [RenderedSpeech?](repeating: nil, count: jobs.count)
        for (unit, result) in zip(units, unitResults) {
            for (jobIndex, speech) in zip(unit, result.speeches) { speeches[jobIndex] = speech }
        }
        let allSpeeches = speeches.compactMap { $0 }

        // Assembly items: a dialogue unit is one item; failed groups were rendered per segment.
        await progress(0.85, String(localized: "Audio wird zusammengesetzt und normalisiert …"))
        var items: [AssemblyItem] = []
        var itemJobs: [[Int]] = []
        var chapterStarts: [(title: String, segmentIndex: Int)] = []
        func addItem(_ url: URL, jobs indices: [Int]) {
            let first = jobs[indices[0]]
            let previous = itemJobs.last.map { jobs[$0.last!] }
            let chapterChanged = previous?.section != first.section
            if chapterChanged { chapterStarts.append((first.section, items.count)) }
            items.append(AssemblyItem(audioURL: url, pauseBefore: AudioAssembler.pause(
                previousSpeaker: previous?.persona.id, speaker: first.persona.id,
                chapterChanged: previous != nil && chapterChanged,
                previousText: previous?.text ?? "", text: first.text) * categoryMix.pauseFactor))
            itemJobs.append(indices)
        }
        for (unit, result) in zip(units, unitResults) {
            if result.isDialog {
                addItem(result.url, jobs: unit)
            } else {
                for (jobIndex, speech) in zip(unit, result.speeches) { addItem(speech.url, jobs: [jobIndex]) }
            }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let assembly = try await assembler.assemble(
            items: items, chapterStarts: chapterStarts, metadata: metadata,
            output: folder.appending(path: fileName), workDirectory: folder.appending(path: ".work")
        )
        // Per-segment timings (estimated inside dialogue items).
        var segmentTimings = [(start: TimeInterval, duration: TimeInterval)](repeating: (0, 0), count: jobs.count)
        for (indices, timing) in zip(itemJobs, assembly.segmentTimings) {
            let parts = DialogPlanner.distribute(duration: timing.duration, lengths: indices.map { jobs[$0].text.count })
            for (jobIndex, part) in zip(indices, parts) { segmentTimings[jobIndex] = (timing.start + part.offset, part.duration) }
        }

        // Transcript, show notes.
        await progress(0.97, String(localized: "Transkript und Shownotes …"))
        let exportSegments = zip(jobs, segmentTimings).map { job, timing in
            ExportSegment(speakerName: job.persona.name, text: TextNormalizer.normalize(job.text),
                          section: job.section, start: timing.start, duration: timing.duration)
        }
        var note = Self.renderNote(speeches: allSpeeches, jobs: jobs)
        let dialogItems = zip(units, unitResults).filter { $0.1.isDialog }.count
        if naturalDialog {
            let failed = zip(units, unitResults).filter { $0.0.count > 1 && !$0.1.isDialog }.count
            let text = String(localized: "Natürlicher Dialog: \(dialogItems) Abschnitte am Stück vertont\(failed > 0 ? ", \(failed) einzeln (Fallback)" : ""); Satz-Zeitpunkte im Transkript geschätzt.")
            note = [note, text].compactMap { $0 }.joined(separator: " ")
        }
        let speakers = Array(NSOrderedSet(array: jobs.map(\.persona.name))) as? [String] ?? []
        try EpisodeExporter.webVTT(exportSegments)
            .write(to: folder.appending(path: "transcript.vtt"), atomically: true, encoding: .utf8)
        try EpisodeExporter.transcriptMarkdown(title: metadata.title, segments: exportSegments)
            .write(to: folder.appending(path: "transcript.md"), atomically: true, encoding: .utf8)
        try EpisodeExporter.showNotes(title: metadata.title, date: metadata.date, chapters: assembly.chapters,
                                      speakers: speakers, renderNote: note, sources: sources, factCheck: factCheck)
            .write(to: folder.appending(path: "shownotes.md"), atomically: true, encoding: .utf8)
        await progress(1, String(localized: "Fertig"))

        return ProductionOutcome(
            segments: zip(segmentTimings, allSpeeches).map {
                RenderedSegment(start: $0.start, duration: $0.duration, provider: $1.provider)
            },
            totalDuration: assembly.totalDuration,
            chapters: assembly.chapters,
            note: note
        )
    }

    /// Remembers the real speaking rate so planned lengths match the audio (ADR-012).
    static func recordSpeakingRate(words: Int, duration: TimeInterval, language: String) {
        guard duration > 60, words > 100, !KeychainStore.isDisabled else { return }
        let measured = Int((Double(words) / (duration / 60)).rounded())
        guard (110...190).contains(measured) else { return }
        let key = "measuredWPM.\(language)"
        let previous = UserDefaults.standard.object(forKey: key) as? Int ?? measured
        UserDefaults.standard.set((previous + measured) / 2, forKey: key)
    }

    /// Human readable summary of fallbacks, shown in the app and the show notes.
    nonisolated static func renderNote(speeches: [RenderedSpeech], jobs: [RenderJob]) -> String? {
        let fallbacks = zip(speeches, jobs).filter { $0.0.fallbackReason != nil }
        guard !fallbacks.isEmpty else { return nil }
        let names = Array(Set(fallbacks.map(\.1.persona.name))).sorted().joined(separator: ", ")
        let reasons = Array(Set(fallbacks.compactMap(\.0.fallbackReason))).sorted().joined(separator: " · ")
        return String(localized: "\(fallbacks.count) Segmente (\(names)) mit Apple-Stimme statt Fish Audio. Grund: \(reasons)")
    }
}
