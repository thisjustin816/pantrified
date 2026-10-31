import Foundation

/// Reads printed dates from the lines recognized in one photo. The seam where a fuller date engine
/// can replace the parser; whatever reads the dates, they are only ever proposals.
public protocol PrintedDateReader: Sendable {
    func readings(in lines: [RecognizedTextLine]) -> [PrintedDateReading]
}

/// Runs `PrintedDateParser` over each line and over each line joined to the one after it, in reading
/// order, so a label printed on the line above its date ("BEST BY" over "12 05 26") is still read.
public struct LineDateReader: PrintedDateReader {
    private let parser: PrintedDateParser
    private let hint: DateOrderHint

    public init(parser: PrintedDateParser = PrintedDateParser(), hint: DateOrderHint = .unknown) {
        self.parser = parser
        self.hint = hint
    }

    public func readings(in lines: [RecognizedTextLine]) -> [PrintedDateReading] {
        let ordered = LabelText.readingOrder(lines).map(\.text)
        var seen: Set<PrintedDateReading> = []
        var readings: [PrintedDateReading] = []
        func add(_ found: [PrintedDateReading]) {
            for reading in found where seen.insert(reading).inserted { readings.append(reading) }
        }
        for (index, line) in ordered.enumerated() {
            add(parser.parse(line, hint: hint))
            if index + 1 < ordered.count { add(parser.parse(line + " " + ordered[index + 1], hint: hint)) }
        }
        return readings
    }
}

/// The words on a label that can tell two packages apart, and the line most likely to be the
/// product's name. Numbers, units, date labels and words printed on most packages are left out,
/// because two different products share them.
public enum LabelText {
    /// Lines top to bottom, then left to right. Lines whose middles are within half a line height
    /// of each other count as one row.
    public static func readingOrder(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
        lines.enumerated().sorted { a, b in
            let rowTolerance = max(min(a.element.box.height, b.element.box.height) / 2, 0.005)
            if abs(a.element.box.midY - b.element.box.midY) > rowTolerance { return a.element.box.midY < b.element.box.midY }
            if a.element.box.x != b.element.box.x { return a.element.box.x < b.element.box.x }
            return a.offset < b.offset
        }
        .map(\.element)
    }

    /// Lower case, without accents, split on anything that is not a letter or digit. A token
    /// holding a digit, shorter than three letters, or in the boilerplate list is dropped.
    public static func significantTokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        var tokens: [String] = []
        var current = ""
        func finish() {
            if current.count >= 3, !current.contains(where: \.isNumber), !boilerplate.contains(current) {
                tokens.append(current)
            }
            current = ""
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "\u{2019}" {
                // "Joe's" reads as "joes", one token, instead of "joe" and a dropped "s".
                continue
            } else {
                finish()
            }
        }
        finish()
        return tokens
    }

    public static func significantTokens(of observation: PhotoObservation) -> Set<String> {
        var tokens: Set<String> = []
        for line in observation.lines {
            tokens.formUnion(significantTokens(line.text))
        }
        return tokens
    }

    /// A short name from the most prominent text: the tallest line with significant words, joined to
    /// the line directly above or below it when that line is nearly as tall, as when a brand is
    /// printed over the product. Nil when no line qualifies.
    public static func prominentName(in lines: [RecognizedTextLine]) -> String? {
        prominentLine(in: lines)?.name
    }

    /// The prominent name and the height of its tallest line, so photos can be compared.
    public static func prominentLine(in lines: [RecognizedTextLine]) -> (name: String, height: Double)? {
        let ordered = readingOrder(lines)
        let usable = Set(ordered.indices.filter {
            isNameLike(ordered[$0].text) && (ordered[$0].confidence ?? 1) >= minimumNameConfidence
        })
        guard let tallest = usable.max(by: { a, b in
            let (ha, hb) = (ordered[a].box.height, ordered[b].box.height)
            return ha != hb ? ha < hb : a > b
        }) else { return nil }
        let line = ordered[tallest].box
        var parts = [ordered[tallest].text]
        // A neighbour counts when it is at least 60% as tall and sits right beside the line.
        func partner(_ index: Int) -> Bool {
            guard usable.contains(index) else { return false }
            let other = ordered[index].box
            return other.height >= line.height * 0.6 && abs(other.midY - line.midY) <= max(line.height, other.height) * 1.8
        }
        if tallest > 0, partner(tallest - 1) {
            parts.insert(ordered[tallest - 1].text, at: 0)
        } else if tallest + 1 < ordered.count, partner(tallest + 1) {
            parts.append(ordered[tallest + 1].text)
        }
        let name = tidyName(parts.joined(separator: " "))
        return name.isEmpty ? nil : (name, line.height)
    }

    /// Lines at least half as tall as the photo's tallest line: what the label shows most.
    static func prominentLines(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
        let usable = lines.filter { ($0.confidence ?? 1) >= minimumNameConfidence }
        guard let tallest = usable.map(\.box.height).max(), tallest > 0 else { return [] }
        return usable.filter { $0.box.height >= tallest * 0.5 }
    }

    /// The significant words of the photo's prominent name, where a product's name, variety and
    /// flavour are printed. Empty when the photo has no name-like line.
    public static func nameTokens(of observation: PhotoObservation) -> Set<String> {
        Set(prominentName(in: observation.lines).map(significantTokens) ?? [])
    }

    /// Amounts that tell two versions of a product apart: percentages printed prominently ("2%"
    /// milk) and the net contents ("NET WT 16 OZ"). Percentages in small print, and on lines of only
    /// nutrition words, are left out, because every nutrition panel is full of them.
    public static func variantAmounts(of observation: PhotoObservation) -> (percents: Set<String>, sizes: Set<String>) {
        var percents: Set<String> = []
        // A nutrition panel line ("Total Fat 5g 6%") has no significant word and is skipped.
        for line in prominentLines(observation.lines) where !significantTokens(line.text).isEmpty {
            for (number, unit) in amounts(in: line.text) where unit == "%" { percents.insert(number + "%") }
        }
        var sizes: Set<String> = []
        for line in observation.lines {
            let words = line.text.lowercased().split(whereSeparator: { !$0.isLetter })
            guard words.contains("net") else { continue }
            for (number, unit) in amounts(in: line.text) where unit != "%" { sizes.insert(number + " " + unit) }
        }
        return (percents, sizes)
    }

    /// Numbers with the unit or percent sign printed after them, normalized: "1,5 L" is ("1.5",
    /// "l"), "16oz" is ("16", "oz") and "2.0%" is ("2", "%").
    static func amounts(in text: String) -> [(number: String, unit: String)] {
        let characters = Array(text.lowercased())
        var found: [(String, String)] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isASCII, characters[index].isNumber,
                  index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber) else {
                index += 1
                continue
            }
            var number = ""
            while index < characters.count, characters[index].isASCII,
                  characters[index].isNumber || ((characters[index] == "." || characters[index] == ",") && number.count < 6) {
                number.append(characters[index] == "," ? "." : characters[index])
                index += 1
            }
            while number.hasSuffix(".") { number.removeLast() }
            if number.contains(".") {
                while number.hasSuffix("0") { number.removeLast() }
                if number.hasSuffix(".") { number.removeLast() }
            }
            var cursor = index
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            if cursor < characters.count, characters[cursor] == "%" {
                found.append((number, "%"))
                index = cursor + 1
                continue
            }
            var word = ""
            while cursor < characters.count, characters[cursor].isLetter || characters[cursor] == "." {
                if characters[cursor] != "." { word.append(characters[cursor]) }
                cursor += 1
            }
            if word == "fl" {
                var next = cursor
                while next < characters.count, characters[next] == " " { next += 1 }
                if next + 1 < characters.count, characters[next] == "o", characters[next + 1] == "z" {
                    word = "floz"
                    cursor = next + 2
                }
            }
            if let unit = Self.units[word], !number.isEmpty {
                found.append((number, unit))
                index = cursor
            }
        }
        return found
    }

    private static let units: [String: String] = [
        "oz": "oz", "floz": "fl oz", "lb": "lb", "lbs": "lb", "g": "g", "gr": "g", "kg": "kg", "ml": "ml",
        "l": "l", "lt": "l", "ltr": "l", "ct": "ct", "count": "ct", "pk": "pack", "pack": "pack",
    ]

    /// Lines the recognizer was less sure of than this are never used for a name.
    static let minimumNameConfidence = 0.3

    /// Text printed in capitals is put in sentence case, and the result is bounded.
    public static func tidyName(_ text: String) -> String {
        let cleaned = BoundedText.clean(text, characters: IntakeLimits.nameCharacters, bytes: IntakeLimits.nameBytes)
        let letters = cleaned.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy({ !$0.isLowercase }) else { return cleaned }
        let lower = cleaned.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    /// Mostly letters, with at least one significant word, and short enough to be a name.
    static func isNameLike(_ text: String) -> Bool {
        guard text.count <= 48, !significantTokens(text).isEmpty else { return false }
        let letters = text.filter(\.isLetter).count
        let others = text.filter { !$0.isLetter && !$0.isWhitespace }.count
        return letters >= 3 && letters >= others * 3
    }

    /// The storage a label states plainly, such as "Keep frozen". "Refrigerate after opening" says
    /// nothing about an unopened package, so it is not read.
    public static func statedStorage(in lines: [RecognizedTextLine]) -> StorageType? {
        for line in lines {
            let words = line.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
                .split(whereSeparator: { !$0.isLetter })
            for (index, word) in words.enumerated() where word == "keep" && index + 1 < words.count {
                switch words[index + 1] {
                case "frozen": return .frozen
                case "refrigerated", "chilled": return .refrigerated
                default: continue
                }
            }
        }
        return nil
    }

    /// Words found on many packages that never tell two products apart: units, nutrition panel
    /// words, date labels and month names, storage instructions, legal and marketing filler.
    static let boilerplate = Set<String>([
        // Joining words.
        "the", "and", "with", "for", "from", "per", "not", "are", "this", "that", "you", "your", "our", "all",
        "into", "may", "has", "have", "any", "each", "use", "used", "can",
        // Units and amounts.
        "net", "wgt", "weight", "ozs", "lbs", "fl", "pint", "quart", "gallon", "grams", "gram", "liter", "litre",
        "count", "pack", "pcs", "pieces", "serving", "servings", "size", "approx", "about", "container",
        // Nutrition and ingredients panels.
        "nutrition", "facts", "calories", "calorie", "total", "fat", "saturated", "trans", "cholesterol", "sodium",
        "carbohydrate", "carbohydrates", "carb", "fiber", "fibre", "dietary", "sugars", "sugar", "added", "includes",
        "protein", "vitamin", "calcium", "iron", "potassium", "daily", "value", "values", "diet", "ingredients",
        "contains", "less", "than", "allergen", "allergens", "allergy", "information", "energy", "kcal", "per",
        "amount", "percent", "mcg",
        // Date labels and months, which the date reader handles.
        "best", "before", "sell", "freeze", "expires", "expiration", "exp", "packed", "pkd", "mfg", "manufactured",
        "date", "lot", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "january", "february", "march", "april", "june", "july", "august", "september", "october", "november",
        "december",
        // Storage and handling.
        "keep", "refrigerated", "refrigerate", "frozen", "freeze", "store", "cool", "dry", "place", "opening",
        "opened", "after", "once", "thaw", "cook", "cooking", "heat", "microwave", "oven", "instructions",
        "directions", "safe", "handling",
        // Legal, packaging and marketing.
        "distributed", "manufactured", "made", "product", "products", "inc", "llc", "ltd", "company", "corp",
        "www", "com", "usa", "recycle", "recyclable", "please", "questions", "comments", "call", "visit",
        "new", "natural", "naturally", "flavored", "flavor", "artificial", "free", "gluten", "non", "gmo",
        "organic", "certified", "usda", "grade", "quality", "fresh", "original", "classic", "family", "size",
    ])
}
