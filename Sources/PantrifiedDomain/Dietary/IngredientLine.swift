import Foundation

/// A recipe ingredient line reduced to the foods it names. Parsing is deliberately narrow: a line
/// it cannot account for word by word is reported as unparsed, never guessed at.
struct IngredientLine: Sendable, Hashable {
    /// Foods that are all used, each with the alternatives a cook may choose between.
    let components: [[IngredientName]]
    /// Text such as "may contain traces of peanuts".
    let advisories: [String]
    /// Parenthetical notes that are neither quantities nor advisories, such as "such as malt".
    let unrecognizedNotes: [String]

    static func parse(_ raw: String) -> IngredientLine? {
        var text = raw.lowercased()
            .replacingOccurrences(of: "and/or", with: "or")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var advisories: [String] = []
        var unrecognized: [String] = []
        for note in matches(of: parenthetical, in: text) {
            if isAdvisory(note) {
                advisories.append(note)
            } else if !isQuantity(note) {
                unrecognized.append(note)
            }
        }
        text = replace(parenthetical, in: text, with: " ")
        guard !text.contains("("), !text.contains(")") else { return nil }

        // The rest of the line is kept whole as an advisory. A food named there stops the advisory
        // from being read as about allergens alone, so it concerns every restriction.
        if let marker = advisoryMarkers.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            advisories.append(String(text[marker.lowerBound...]))
            text = String(text[..<marker.lowerBound])
        }

        text = replace(trailingNote, in: text, with: "")
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for suffix in parts.dropFirst() {
            let words = suffix.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard words.allSatisfy({ preparationWords.contains($0) || $0.allSatisfy(\.isNumber) }) else { return nil }
        }

        let food = replace(quantity, in: collapse(parts[0]), with: "")
        var components: [[IngredientName]] = []
        for group in food.components(separatedBy: " and ") {
            let alternatives = group.components(separatedBy: " or ")
                .flatMap { $0.components(separatedBy: "/") }
                .map(IngredientName.init)
            guard !alternatives.isEmpty, alternatives.allSatisfy({ !$0.isEmpty }) else { return nil }
            components.append(alternatives)
        }
        return IngredientLine(components: components, advisories: advisories, unrecognizedNotes: unrecognized)
    }

    // MARK: Vocabulary

    static let advisoryMarkers = [
        "may contain", "traces of", "processed in", "manufactured in", "manufactured on",
        "made in a facility", "facility", "cross-contact", "cross contact",
    ]

    private static func isAdvisory(_ note: String) -> Bool {
        advisoryMarkers.contains { note.contains($0) }
    }

    private static func isQuantity(_ note: String) -> Bool {
        note.trimmingCharacters(in: .whitespaces) == "optional"
            || noteQuantity.firstMatch(in: note, range: NSRange(note.startIndex..., in: note)) != nil
    }

    private static let preparationWords: Set<String> = [
        "diced", "chopped", "minced", "sliced", "peeled", "softened", "melted", "divided", "beaten",
        "drained", "rinsed", "cubed", "grated", "shredded", "crushed", "halved", "quartered", "trimmed",
        "seeded", "cored", "thawed", "cooked", "warmed", "torn", "packed", "sifted", "patted", "dry",
        "at", "room", "temperature", "finely", "roughly", "coarsely", "thinly", "lightly", "freshly",
        "and", "into", "pieces", "piece", "inch", "cut", "plus", "more", "for", "to", "taste",
        "serving", "garnish", "as", "needed", "optional",
    ]

    private static let units = #"cups?|tbsps?|tablespoons?|tsps?|teaspoons?|oz|ounces?|lbs?|pounds?|g|grams?|kg|ml|l|liters?|litres?|pinch(?:es)?|dash(?:es)?|cloves?|cans?|packages?|pkgs?|slices?|sticks?|bunch(?:es)?|handfuls?|pieces?|jars?|bottles?|heads?|sprigs?|stalks?"#
    private static let number = #"(?:\d*[½¼¾⅓⅔⅛]|\d+\s+\d+/\d+|\d+(?:[./]\d+)?)"#

    private static let parenthetical = try! NSRegularExpression(pattern: #"\(([^()]*)\)"#)
    private static let trailingNote = try! NSRegularExpression(
        pattern: #"[\s,]*(?:to taste|for garnish|for serving|as needed|optional)\s*$"#
    )
    private static let quantity = try! NSRegularExpression(
        pattern: #"^\s*(?:"# + number + #"(?:\s*(?:-|to)\s*"# + number + #")?|an?(?=\s))\s*(?:(?:"# + units + #")\.?(?:\s+|$))?(?:of\s+)?"#
    )
    private static let noteQuantity = try! NSRegularExpression(pattern:
        #"^\s*(?:about |approximately |approx\.? )?"# + number + #"(?:\s*(?:-|to)\s*"# + number + #")?\s*(?:"# + units + #")?\.?(?:\s+each)?\s*$"#
    )

    private static func matches(of regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
