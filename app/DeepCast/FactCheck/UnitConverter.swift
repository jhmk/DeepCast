import Foundation

/// Physical quantities in text, normalised to SI so that "300.000 km/s" matches
/// "299.792.458 Meter pro Sekunde" and "150 °C" matches "423 K" (spec 5.4, ADR-010).
enum UnitConverter {
    enum Dimension: String, Sendable { case length, speed, temperature, mass, time, area, volume, percent }

    struct Quantity: Hashable, Sendable {
        let raw: String
        let number: Double
        let dimension: Dimension
        /// Value in the SI base unit (m, m/s, K, kg, s, m², m³, %).
        let si: Double
    }

    private struct Unit {
        let pattern: String
        let dimension: Dimension
        let convert: @Sendable (Double) -> Double
    }

    private static let units: [Unit] = {
        func factor(_ f: Double) -> @Sendable (Double) -> Double { { $0 * f } }
        let kmh = 1000.0 / 3600
        return [
            // speed first (longest patterns win)
            Unit(pattern: #"km\s?/\s?s|kilometern? pro sekunde|kilometres? per second|kilometers? per second"#, dimension: .speed, convert: factor(1000)),
            Unit(pattern: #"km\s?/\s?h|kilometern? pro stunde|stundenkilometern?|kilometres? per hour|kph"#, dimension: .speed, convert: factor(kmh)),
            Unit(pattern: #"mph|meilen pro stunde|miles per hour"#, dimension: .speed, convert: factor(0.44704)),
            Unit(pattern: #"m\s?/\s?s|metern? pro sekunde|metres? per second|meters? per second"#, dimension: .speed, convert: factor(1)),
            // temperature
            Unit(pattern: #"°\s?c|grad celsius|degrees? celsius"#, dimension: .temperature, convert: { $0 + 273.15 }),
            Unit(pattern: #"°\s?f|grad fahrenheit|degrees? fahrenheit"#, dimension: .temperature, convert: { ($0 - 32) * 5 / 9 + 273.15 }),
            Unit(pattern: #"kelvin|k(?![a-zäöü])"#, dimension: .temperature, convert: factor(1)),
            // area / volume
            Unit(pattern: #"km²|km2|quadratkilometern?|square kilometres?|square kilometers?"#, dimension: .area, convert: factor(1e6)),
            Unit(pattern: #"m²|quadratmetern?|square metres?|square meters?"#, dimension: .area, convert: factor(1)),
            Unit(pattern: #"hektar|hectares?|ha(?![a-zäöü])"#, dimension: .area, convert: factor(1e4)),
            Unit(pattern: #"m³|kubikmetern?|cubic metres?|cubic meters?"#, dimension: .volume, convert: factor(1)),
            Unit(pattern: #"litern?|litres?|liters?|l(?![a-zäöü])"#, dimension: .volume, convert: factor(0.001)),
            // length
            Unit(pattern: #"km|kilometern?|kilometres?|kilometers?"#, dimension: .length, convert: factor(1000)),
            Unit(pattern: #"mm|millimetern?|millimetres?|millimeters?"#, dimension: .length, convert: factor(0.001)),
            Unit(pattern: #"µm|μm|mikrometern?|micrometres?|micrometers?|microns?"#, dimension: .length, convert: factor(1e-6)),
            Unit(pattern: #"nm|nanometern?|nanometres?|nanometers?"#, dimension: .length, convert: factor(1e-9)),
            Unit(pattern: #"cm|zentimetern?|centimetres?|centimeters?"#, dimension: .length, convert: factor(0.01)),
            Unit(pattern: #"meilen|miles?"#, dimension: .length, convert: factor(1609.344)),
            Unit(pattern: #"m(?![a-zäöü²³/])|metern?|metres?|meters?"#, dimension: .length, convert: factor(1)),
            // mass
            Unit(pattern: #"tonnen|tonnes?|tons?|t(?![a-zäöü])"#, dimension: .mass, convert: factor(1000)),
            Unit(pattern: #"kg|kilogramm|kilograms?"#, dimension: .mass, convert: factor(1)),
            Unit(pattern: #"mg|milligramm|milligrams?"#, dimension: .mass, convert: factor(1e-6)),
            Unit(pattern: #"g(?![a-zäöü])|gramm|grams?"#, dimension: .mass, convert: factor(0.001)),
            // time
            Unit(pattern: #"jahrzehnten?|decades?"#, dimension: .time, convert: factor(10 * 365.25 * 86400)),
            Unit(pattern: #"jahren?|jahres|years?"#, dimension: .time, convert: factor(365.25 * 86400)),
            Unit(pattern: #"monaten?|months?"#, dimension: .time, convert: factor(30.44 * 86400)),
            Unit(pattern: #"wochen?|weeks?"#, dimension: .time, convert: factor(7 * 86400)),
            Unit(pattern: #"tagen?|days?"#, dimension: .time, convert: factor(86400)),
            Unit(pattern: #"stunden?|hours?|std\.?|h(?![a-zäöü])"#, dimension: .time, convert: factor(3600)),
            Unit(pattern: #"minuten?|minutes?|min(?![a-zäöü])"#, dimension: .time, convert: factor(60)),
            Unit(pattern: #"sekunden?|seconds?|sek\.?|s(?![a-zäöü])"#, dimension: .time, convert: factor(1)),
            // percent
            Unit(pattern: #"%|prozent|percent|per cent"#, dimension: .percent, convert: factor(1)),
        ]
    }()

    private static let regex: NSRegularExpression? = {
        let alternatives = units.map { "(\($0.pattern))" }.joined(separator: "|")
        let number = #"(minus\s|−|-)?(\d{1,3}(?:[.,\x{00A0}\x{202F} ]\d{3})+|\d+(?:[.,]\d+)?)"#
        let magnitude = #"(?:\s*(tausend|thousand|millionen|million|millions|mio\.?|milliarden|milliarde|mrd\.?|billions|billion))?"#
        return try? NSRegularExpression(pattern: number + magnitude + #"\s*(?:"# + alternatives + ")", options: .caseInsensitive)
    }()

    private static let magnitudes: [String: Double] = [
        "tausend": 1e3, "thousand": 1e3, "million": 1e6, "millionen": 1e6, "millions": 1e6, "mio": 1e6, "mio.": 1e6,
        "milliarde": 1e9, "milliarden": 1e9, "mrd": 1e9, "mrd.": 1e9, "billion": 1e9, "billions": 1e9,
    ]

    static func quantities(in text: String) -> [Quantity] {
        guard let regex else { return [] }
        let ns = text as NSString
        var result: [Quantity] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard var number = NumberMatcher.parse(ns.substring(with: match.range(at: 2))) else { continue }
            if match.range(at: 1).location != NSNotFound { number = -number }
            if match.range(at: 3).location != NSNotFound {
                number *= magnitudes[ns.substring(with: match.range(at: 3)).lowercased()] ?? 1
            }
            // Which unit group matched (groups start at 4).
            for (index, unit) in units.enumerated() where match.range(at: 4 + index).location != NSNotFound {
                result.append(Quantity(raw: ns.substring(with: match.range).trimmingCharacters(in: .whitespaces),
                                       number: number, dimension: unit.dimension, si: unit.convert(number)))
                break
            }
        }
        return result
    }

    /// True if `quantity` equals one of `candidates` after conversion (within `tolerance`, relative;
    /// temperatures compared absolutely within 1.5 K).
    static func matches(_ quantity: Quantity, in candidates: [Quantity], tolerance: Double) -> Bool {
        candidates.contains { other in
            guard other.dimension == quantity.dimension else { return false }
            if quantity.dimension == .temperature { return abs(other.si - quantity.si) <= 1.5 }
            guard other.si != 0 else { return quantity.si == 0 }
            return abs(other.si - quantity.si) / abs(other.si) <= tolerance
        }
    }
}
