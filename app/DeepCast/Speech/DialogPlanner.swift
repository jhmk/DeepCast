import Foundation

/// Groups consecutive segments of a chapter into Fish dialogue requests ("natürlicher Dialog")
/// and estimates per-segment timings inside a rendered group.
enum DialogPlanner {
    static let maxCharacters = 1_500
    static let maxSegments = 12

    /// Consecutive indices with the same section, limited by length; single segments stay alone.
    static func groups(sections: [String], lengths: [Int], maxCharacters: Int = maxCharacters, maxSegments: Int = maxSegments) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var characters = 0
        for index in sections.indices {
            let sameSection = current.last.map { sections[$0] == sections[index] } ?? true
            if !current.isEmpty, !sameSection || current.count >= maxSegments || characters + lengths[index] > maxCharacters {
                groups.append(current)
                current = []
                characters = 0
            }
            current.append(index)
            characters += lengths[index]
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Splits a group's duration proportionally to text length (+ a small constant per line for
    /// breaths and turn-taking). Returns (offset, duration) per line.
    static func distribute(duration: TimeInterval, lengths: [Int]) -> [(offset: TimeInterval, duration: TimeInterval)] {
        let weights = lengths.map { Double($0) + 12 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return lengths.map { _ in (0, 0) } }
        var offset: TimeInterval = 0
        return weights.map { weight in
            let part = duration * weight / total
            defer { offset += part }
            return (offset, part)
        }
    }
}
