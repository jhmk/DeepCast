import Foundation

/// Spells out German numbers for TTS engines that read digits poorly in German
/// (Fish Audio normalizes only English/Chinese). "1.300" → "eintausenddreihundert",
/// "1777" → "siebzehnhundertsiebenundsiebzig", "80–90 %" → "achtzig bis neunzig Prozent".
enum NumberSpeller {
    private static let small = ["null", "eins", "zwei", "drei", "vier", "fünf", "sechs", "sieben", "acht", "neun", "zehn",
                                "elf", "zwölf", "dreizehn", "vierzehn", "fünfzehn", "sechzehn", "siebzehn", "achtzehn", "neunzehn"]
    private static let tens = ["", "", "zwanzig", "dreißig", "vierzig", "fünfzig", "sechzig", "siebzig", "achtzig", "neunzig"]

    /// Integer in words (0 … 999 999 999).
    static func words(_ number: Int) -> String {
        if number < 0 { return "minus " + words(-number) }
        if number >= 1_000_000 {
            let millions = number / 1_000_000, rest = number % 1_000_000
            let head = millions == 1 ? "eine Million" : words(millions) + " Millionen"
            return rest == 0 ? head : head + " " + words(rest)
        }
        if number >= 1_000 {
            let thousands = number / 1_000, rest = number % 1_000
            return compound(thousands) + "tausend" + (rest == 0 ? "" : below1000(rest))
        }
        return below1000(number)
    }

    /// Four-digit numbers 1100–1999 are read as years ("siebzehnhundert…"), which is also natural for counts.
    static func yearWords(_ year: Int) -> String {
        guard (1100...1999).contains(year), year % 1000 >= 100 else { return words(year) }
        let rest = year % 100
        return below100(year / 100) + "hundert" + (rest == 0 ? "" : below100(rest))
    }

    private static func compound(_ number: Int) -> String {
        number == 1 ? "ein" : below1000(number).replacingOccurrences(of: "eins$", with: "ein", options: .regularExpression)
    }

    private static func below1000(_ number: Int) -> String {
        guard number >= 100 else { return below100(number) }
        let hundreds = number / 100, rest = number % 100
        return (hundreds == 1 ? "ein" : small[hundreds]) + "hundert" + (rest == 0 ? "" : below100(rest))
    }

    private static func below100(_ number: Int) -> String {
        if number < 20 { return small[number] }
        let unit = number % 10
        return unit == 0 ? tens[number / 10] : (unit == 1 ? "ein" : small[unit]) + "und" + tens[number / 10]
    }

    /// Replaces numbers in German text with words. Leaves text without digits untouched.
    static func spellOut(_ text: String) -> String {
        guard text.contains(where: \.isNumber) else { return text }
        var result = text
        // Ranges "80–90" / "80-90" → "80 bis 90"
        result = result.replacingOccurrences(of: #"(\d)\s?[–-]\s?(\d)"#, with: "$1 bis $2", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s?%"#, with: " Prozent", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s?°C\b"#, with: " Grad Celsius", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s?°"#, with: " Grad", options: .regularExpression)
        result = result.replacingOccurrences(of: "−", with: "minus ")

        let pattern = #"(?<![\p{L}\d])(\d{1,3}(?:\.\d{3})+|\d+)(?:,(\d+))?(?![\p{L}\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        var output = ""
        var last = 0
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let integerPart = ns.substring(with: match.range(at: 1))
            let digits = integerPart.replacingOccurrences(of: ".", with: "")
            guard let value = Int(digits), value < 1_000_000_000 else {
                output += ns.substring(with: match.range)
                last = match.range.location + match.range.length
                continue
            }
            var spoken: String
            if match.range(at: 2).location == NSNotFound, !integerPart.contains("."), digits.count == 4 {
                spoken = yearWords(value)
            } else {
                spoken = words(value)
            }
            if match.range(at: 2).location != NSNotFound {
                let decimals = ns.substring(with: match.range(at: 2)).compactMap { $0.wholeNumberValue }.map { small[$0] }
                spoken += " Komma " + decimals.joined(separator: " ")
            }
            output += spoken
            last = match.range.location + match.range.length
        }
        output += ns.substring(from: last)
        return output
    }
}
