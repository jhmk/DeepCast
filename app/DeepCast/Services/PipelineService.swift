import Foundation
import Observation
import SwiftData

/// Drives the research pipeline for episodes: research → review pause → script → speech.
@MainActor
@Observable
final class PipelineService {
    struct RunState {
        var stage: PipelineStage
        var fraction: Double?
        var message: String
        var log: [String] = []
        var isRunning = true
        var startedAt = Date()
        var estimator = RemainingTimeEstimator()
        /// Remaining seconds of the current phase (nil = not yet known).
        var remaining: TimeInterval?
    }

    private(set) var runs: [UUID: RunState] = [:]
    private var dossiers: [UUID: ResearchDossier] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var quota: (used: Int, limit: Int, remaining: Int)?

    var runningCount: Int { runs.values.filter(\.isRunning).count }

    func isRunning(_ episode: Episode) -> Bool { runs[episode.id]?.isRunning ?? false }

    // MARK: Dossier

    func dossier(for episode: Episode) -> ResearchDossier? {
        if let cached = dossiers[episode.id] { return cached }
        let loaded = ArtifactStore.load(ResearchDossier.self, name: "dossier.json", in: episode.folderURL)
        if let loaded { dossiers[episode.id] = loaded }
        return loaded
    }

    func updateDossier(for episode: Episode, _ change: (inout ResearchDossier) -> Void) {
        guard var dossier = dossier(for: episode) else { return }
        change(&dossier)
        dossiers[episode.id] = dossier
        try? ArtifactStore.save(dossier, as: "dossier.json", in: episode.folderURL)
    }

    // MARK: Research

    /// True if an unfinished research run left artifacts that can be resumed.
    func canResume(_ episode: Episode) -> Bool {
        guard episode.isResearchEpisode, !isRunning(episode) else { return false }
        if let dossier = dossier(for: episode) { return !dossier.isComplete }
        return FileManager.default.fileExists(atPath: episode.folderURL.appending(path: "plan.json").path)
    }

    func startResearch(_ episode: Episode, settings: AppSettings, context: ModelContext, resume: Bool = false) {
        guard let options = episode.options, !isRunning(episode) else { return }
        Notifier.requestPermissionIfNeeded()
        let folder = episode.folderURL
        if !resume {
            for name in ["plan.json", "dossier.json", "outline.json", "script.json", "factcheck.md"] {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
        var pipeline = LocalPipeline(router: settings.makeRouter(for: options))
        pipeline.styleGuide = settings.styleGuide.text
        pipeline.domainRules = settings.preferences.rulesSnapshot
        pipeline.paywall = settings.paywallConfig
        episode.status = .researching
        episode.lastError = nil
        dossiers[episode.id] = nil
        runs[episode.id] = RunState(stage: .plan, fraction: nil,
                                    message: resume ? String(localized: "Setze Recherche fort …") : String(localized: "Starte Recherche …"))
        try? ArtifactStore.save(options, as: "options.json", in: folder)

        let id = episode.id
        tasks[id] = Task {
            do {
                let dossier = try await pipeline.research(options, folder: folder, resume: resume) { event in
                    await self.handle(event, for: id)
                }
                dossiers[id] = dossier
                episode.status = .review
                runs[id]?.stage = .review
                runs[id]?.fraction = nil
                runs[id]?.message = String(localized: "Bitte Quellen und Aussagen prüfen.")
                Notifier.post(title: String(localized: "Recherche fertig: \(episode.title)"),
                              body: String(localized: "🟢 \(dossier.count(.green)) · 🟡 \(dossier.count(.yellow)) · 🔴 \(dossier.count(.red)) – bitte prüfen und freigeben."))
            } catch is CancellationError {
                episode.status = .failed
                episode.lastError = String(localized: "Recherche abgebrochen – kann fortgesetzt werden.")
            } catch {
                episode.status = .failed
                episode.lastError = error.localizedDescription
                runs[id]?.log.append("❌ \(error.localizedDescription)")
            }
            dossiers[id] = nil // reload from disk (checkpoint state)
            runs[id]?.isRunning = false
            tasks[id] = nil
            try? context.save()
            await refreshQuota(settings: settings)
        }
    }

    // MARK: Script + speech (after review)

    func approve(_ episode: Episode, personas: PersonaStore, settings: AppSettings, production: ProductionService, context: ModelContext) {
        guard let dossier = dossier(for: episode), !isRunning(episode) else { return }
        let folder = episode.folderURL
        var pipeline = LocalPipeline(router: settings.makeRouter(for: dossier.options))
        pipeline.styleGuide = settings.styleGuide.text
        let cast = personas.personas
        episode.status = .scripting
        episode.lastError = nil
        var state = runs[episode.id] ?? RunState(stage: .outline, fraction: nil, message: "")
        state.stage = .outline
        state.isRunning = true
        state.message = String(localized: "Gliederung …")
        runs[episode.id] = state

        let id = episode.id
        tasks[id] = Task {
            do {
                let (script, updated) = try await pipeline.writeScript(dossier, personas: cast, folder: folder) { event in
                    await self.handle(event, for: id)
                }
                dossiers[id] = updated
                apply(script, to: episode, context: context)
                runs[id]?.stage = .speech
                runs[id]?.message = String(localized: "Vertonung läuft …")
                runs[id]?.isRunning = false
                try? context.save()
                production.produce(episode, personas: personas, settings: settings, context: context)
            } catch is CancellationError {
                episode.status = .review
                episode.lastError = String(localized: "Skript abgebrochen.")
                runs[id]?.isRunning = false
            } catch {
                episode.status = .review
                episode.lastError = error.localizedDescription
                runs[id]?.log.append("❌ \(error.localizedDescription)")
                runs[id]?.isRunning = false
            }
            tasks[id] = nil
            try? context.save()
            await refreshQuota(settings: settings)
        }
    }

    // MARK: Follow-ups (spec 8: Nachfrage-Modus, "Tiefer eintauchen")

    /// Short answer episode from the existing dossier – no new research, only script + speech.
    @discardableResult
    func askFollowUp(_ question: String, minutes: Int, from parent: Episode, personas: PersonaStore, settings: AppSettings,
                     production: ProductionService, context: ModelContext) -> Episode? {
        guard var dossier = dossier(for: parent), dossier.isComplete else { return nil }
        var options = dossier.options
        options.topic = question
        options.minutes = minutes
        options.followUpOf = parent.title
        options.simpleSpeech = settings.resolvedAI(for: options).speechMode == .appleOnly
        let episode = Episode(title: question, topic: question, language: options.language.rawValue)
        episode.options = options
        context.insert(episode)
        dossier.options = options
        dossier.scriptIssues = []
        dossier.calls = []
        dossier.notes.append(String(localized: "Nachfrage zu „\(parent.title)“ – beantwortet aus der vorhandenen Recherche-Mappe."))
        try? ArtifactStore.save(options, as: "options.json", in: episode.folderURL)
        try? ArtifactStore.save(dossier, as: "dossier.json", in: episode.folderURL)
        dossiers[episode.id] = dossier
        episode.status = .review
        try? context.save()
        approve(episode, personas: personas, settings: settings, production: production, context: context)
        return episode
    }

    /// New research episode about one chapter of an existing episode.
    @discardableResult
    func deepDive(chapter: String, from parent: Episode, settings: AppSettings, context: ModelContext) -> Episode? {
        var options = parent.options ?? EpisodeOptions(topic: parent.title)
        options.topic = "\(chapter) (Vertiefung zu: \(parent.title))"
        options.followUpOf = parent.title
        options.nerdLevel = min(5, options.nerdLevel + 1)
        let episode = Episode(title: chapter, topic: options.topic, language: options.language.rawValue)
        episode.options = options
        context.insert(episode)
        try? context.save()
        startResearch(episode, settings: settings, context: context)
        return episode
    }

    // MARK: Own sources in review

    func addCustomSource(_ custom: CustomSource, to episode: Episode, settings: AppSettings, context: ModelContext) {
        guard let dossier = dossier(for: episode), !isRunning(episode) else { return }
        var pipeline = LocalPipeline(router: settings.makeRouter(for: dossier.options))
        pipeline.styleGuide = settings.styleGuide.text
        pipeline.paywall = settings.paywallConfig
        pipeline.domainRules = settings.preferences.rulesSnapshot
        let folder = episode.folderURL
        let id = episode.id
        var state = runs[id] ?? RunState(stage: .fetch, fraction: nil, message: "")
        state.isRunning = true
        state.stage = .fetch
        runs[id] = state
        tasks[id] = Task {
            do {
                let updated = try await pipeline.addSource(custom, to: dossier, folder: folder) { event in
                    await self.handle(event, for: id)
                }
                dossiers[id] = updated
                episode.options = updated.options
                runs[id]?.stage = .review
                runs[id]?.message = String(localized: "Quelle hinzugefügt – bitte prüfen.")
            } catch {
                runs[id]?.log.append("❌ \(error.localizedDescription)")
                runs[id]?.message = String(localized: "Quelle nicht hinzugefügt: \(error.localizedDescription)")
                runs[id]?.stage = .review
            }
            runs[id]?.isRunning = false
            tasks[id] = nil
            try? context.save()
        }
    }

    // MARK: Feedback → style guide

    /// Turns listener feedback into general rules (shown for confirmation before saving).
    func proposeGuideRules(feedback: String, episode: Episode, settings: AppSettings) async -> [String] {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let router = settings.makeRouter(for: episode.options)
        guard let prompt = try? PromptLibrary.load("guide_feedback", values: [
            "guide": settings.styleGuide.text, "title": episode.title, "feedback": text,
        ]), let output = try? await router.generate(GuideRulesOutput.self, role: .writer, task: "guide feedback",
                                                   system: prompt.system, prompt: prompt.user).value,
           !output.rules.isEmpty else {
            // Without a model: keep the feedback as written.
            return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-• ").union(.whitespaces)) }
                .filter { !$0.isEmpty }
        }
        return output.rules
    }

    // MARK: Editor support

    private(set) var rewriting: Set<UUID> = []
    private(set) var rewriteErrors: [UUID: String] = [:]

    /// Usable claims of a research episode (nil for manual scripts).
    func usableClaims(for episode: Episode) -> [Claim]? {
        dossier(for: episode)?.usableClaims
    }

    /// Rewrites one segment with the writer model (closed book) and re-checks it.
    func rewrite(_ segment: EpisodeSegment, in episode: Episode, instruction: String,
                 personas: PersonaStore, settings: AppSettings, context: ModelContext) {
        guard let dossier = dossier(for: episode), !rewriting.contains(segment.id) else { return }
        let id = segment.id
        let draft = ScriptSegmentDraft(speakerID: segment.speakerID, text: segment.text,
                                       section: segment.section, claimIDs: segment.claimIDs)
        var pipeline = LocalPipeline(router: settings.makeRouter(for: dossier.options))
        pipeline.styleGuide = settings.styleGuide.text
        let cast = personas.personas
        rewriting.insert(id)
        rewriteErrors[id] = nil
        Task {
            do {
                let result = try await pipeline.rewriteSegment(draft, instruction: instruction, dossier: dossier, personas: cast)
                segment.text = result.text
                segment.claimIDs = result.claimIDs
                let sourceIDs: [String] = result.claimIDs.flatMap { id -> [String] in dossier.claim(id)?.sourceIDs ?? [] }
                segment.sourceIDs = Array(NSOrderedSet(array: sourceIDs)) as? [String] ?? []
                episode.markEdited()
                try? context.save()
            } catch {
                rewriteErrors[id] = error.localizedDescription
            }
            rewriting.remove(id)
        }
    }

    func cancel(_ episode: Episode) {
        tasks[episode.id]?.cancel()
    }

    private func apply(_ script: EpisodeScript, to episode: Episode, context: ModelContext) {
        for segment in episode.segments { context.delete(segment) }
        episode.segments = []
        let dossier = dossiers[episode.id]
        for (index, draft) in script.segments.enumerated() {
            let sourceIDs = draft.claimIDs.flatMap { dossier?.claim($0)?.sourceIDs ?? [] }
            let segment = EpisodeSegment(order: index, speakerID: draft.speakerID, text: draft.text, section: draft.section,
                                         claimIDs: draft.claimIDs, sourceIDs: Array(NSOrderedSet(array: sourceIDs)) as? [String] ?? [])
            segment.episode = episode
            context.insert(segment)
        }
        episode.title = script.title
        episode.topic = script.summary.isEmpty ? episode.topic : script.summary
        episode.status = .draft
    }

    private func handle(_ event: PipelineEvent, for id: UUID) {
        guard var state = runs[id] else { return }
        if event.stage != state.stage || event.fraction == 1 {
            state.log.append("\(event.stage.title): \(event.message)")
        }
        state.stage = event.stage
        state.fraction = event.fraction
        state.message = event.message
        state.remaining = state.estimator.update(phase: RemainingTimeEstimator.phaseKey(event.stage), fraction: event.fraction)
        runs[id] = state
    }

    // MARK: Quota

    func refreshQuota(settings: AppSettings) async {
        guard settings.llmMode == .openRouter, let key = KeychainStore.read(.openRouter) else {
            quota = nil
            return
        }
        quota = try? await OpenRouterClient(model: settings.writer.model, apiKey: key).freeQuota()
    }
}
