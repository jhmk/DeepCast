import Foundation

/// Estimates the remaining time of a phase from its progress fraction (linear extrapolation,
/// smoothed). Phases restart the estimate; "Skript" and "Skript prüfen" count as one phase.
struct RemainingTimeEstimator: Sendable {
    private var phase: String?
    private var start = Date()
    private var smoothed: TimeInterval?

    static let minimumFraction = 0.08
    static let minimumElapsed: TimeInterval = 4

    static func phaseKey(_ stage: PipelineStage) -> String {
        switch stage {
        case .script, .check, .outline: "script"
        case .plan, .search, .fetch: "sources"
        default: stage.title
        }
    }

    mutating func update(phase newPhase: String, fraction: Double?, now: Date = .now) -> TimeInterval? {
        if newPhase != phase {
            phase = newPhase
            start = now
            smoothed = nil
        }
        guard let fraction, fraction >= Self.minimumFraction, fraction < 1 else {
            return fraction == 1 ? 0 : smoothed.map { max(0, $0) }
        }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed >= Self.minimumElapsed else { return nil }
        let estimate = elapsed * (1 - fraction) / fraction
        smoothed = smoothed.map { 0.6 * $0 + 0.4 * estimate } ?? estimate
        return smoothed
    }

    static func format(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return String(localized: "gleich fertig") }
        if seconds < 60 { return String(localized: "noch ca. \(Int((seconds / 5).rounded(.up)) * 5) s") }
        let minutes = Int(seconds) / 60, rest = Int(seconds) % 60
        return String(localized: "noch ca. \(minutes):\(String(format: "%02d", rest)) min")
    }
}
