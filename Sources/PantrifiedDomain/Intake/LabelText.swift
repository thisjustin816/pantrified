import Foundation

/// Reads printed dates from the lines recognized in one photo. `PrintedDateRecognition` is the
/// reader; the protocol lets tests and a later engine stand in. Whatever reads the dates, they are
/// only ever proposals.
public protocol PrintedDateReader: Sendable {
    func readings(in lines: [RecognizedTextLine], takenAt time: Date) -> [PrintedDateReading]
}

extension PrintedDateRecognition: PrintedDateReader {
    /// The photo's lines in reading order, so a label printed above its date is read with it, and
    /// only dates plausible for when the photo was taken.
    public func readings(in lines: [RecognizedTextLine], takenAt time: Date) -> [PrintedDateReading] {
        readings(in: [RecognizedLines(lines: LabelText.readingOrder(lines).map(\.text))], at: time)
    }
}

/// The words on a label that can tell two packages apart, and the line most likely to be the
/// product's name. Numbers, units, date labels and words printed on most packages are left out,
/// because two different products share them, and so is every line of a nutrition, supplement or
/// ingredients panel or an allergen statement, which never names the product.
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

    /// The significant words of every line outside a panel.
    public static func significantTokens(of observation: PhotoObservation) -> Set<String> {
        var tokens: Set<String> = []
        for line in observation.lines where !isPanelLine(line.text) {
            tokens.formUnion(significantTokens(line.text))
        }
        return tokens
    }

    /// A short name from the most prominent text: the tallest line with significant words, joined to
    /// the line directly above or below it when that line is nearly as tall, as when a brand is
    /// printed over the product. A panel line is never part of it. Nil when no line qualifies.
    public static func prominentName(in lines: [RecognizedTextLine]) -> String? {
        prominentLine(in: lines)?.name
    }

    /// The prominent name and the height of its tallest line, so photos can be compared.
    public static func prominentLine(in lines: [RecognizedTextLine]) -> (name: String, height: Double)? {
        guard let block = nameBlock(in: lines) else { return nil }
        let name = tidyName(block.ordered[block.lines].map(\.text).joined(separator: " "))
        return name.isEmpty ? nil : (name, block.ordered[block.tallest].box.height)
    }

    /// The lines in reading order, and which of them make the name: the tallest usable line and the
    /// neighbor joined to it.
    private static func nameBlock(in lines: [RecognizedTextLine]) -> (ordered: [RecognizedTextLine], lines: ClosedRange<Int>, tallest: Int)? {
        let ordered = readingOrder(lines)
        let usable = Set(ordered.indices.filter { isUsableName(ordered[$0]) })
        guard let tallest = usable.max(by: { a, b in
            let (ha, hb) = (ordered[a].box.height, ordered[b].box.height)
            return ha != hb ? ha < hb : a > b
        }) else { return nil }
        let line = ordered[tallest].box
        // A neighbour counts when it is at least 60% as tall and sits right beside the line.
        func partner(_ index: Int) -> Bool {
            guard usable.contains(index) else { return false }
            let other = ordered[index].box
            return other.height >= line.height * 0.6 && abs(other.midY - line.midY) <= max(line.height, other.height) * 1.8
        }
        if tallest > 0, partner(tallest - 1) { return (ordered, (tallest - 1)...tallest, tallest) }
        if tallest + 1 < ordered.count, partner(tallest + 1) { return (ordered, tallest...(tallest + 1), tallest) }
        return (ordered, tallest...tallest, tallest)
    }

    private static func isUsableName(_ line: RecognizedTextLine) -> Bool {
        isNameLike(line.text) && (line.confidence ?? 1) >= minimumNameConfidence && !isPanelLine(line.text)
    }

    /// The short line printed right under the name, where a flavor or variety often is ("Minis",
    /// then "VANILLA"): the next line in reading order outside a panel, with one to `varietyWords`
    /// significant words, starting within `varietyGap` name heights of the name's bottom. Nil when
    /// there is none.
    static func varietyLine(in lines: [RecognizedTextLine]) -> RecognizedTextLine? {
        guard let block = nameBlock(in: lines),
              let next = block.ordered[(block.lines.upperBound + 1)...].first(where: { !isPanelLine($0.text) }) else { return nil }
        let name = block.ordered[block.tallest].box
        let bottom = block.ordered[block.lines].map { $0.box.y + $0.box.height }.max() ?? 0
        let words = significantTokens(next.text).count
        guard isUsableName(next), (1...varietyWords).contains(words), next.box.y >= bottom - name.height / 2,
              next.box.y - bottom <= name.height * varietyGap else { return nil }
        return next
    }

    /// A variety line has at most this many significant words.
    static let varietyWords = 3
    /// A variety line starts within this many name heights below the name.
    static let varietyGap = 2.0

    /// Lines at least half as tall as the photo's tallest line outside a panel: what the label shows
    /// most.
    static func prominentLines(_ lines: [RecognizedTextLine]) -> [RecognizedTextLine] {
        let usable = lines.filter { ($0.confidence ?? 1) >= minimumNameConfidence && !isPanelLine($0.text) }
        guard let tallest = usable.map(\.box.height).max(), tallest > 0 else { return [] }
        return usable.filter { $0.box.height >= tallest * 0.5 }
    }

    /// The significant words of the photo's prominent name and of the variety line under it, where
    /// a product's name, variety and flavour are printed. Empty when the photo has no name-like
    /// line.
    public static func nameTokens(of observation: PhotoObservation) -> Set<String> {
        let name = prominentName(in: observation.lines).map(significantTokens) ?? []
        let variety = varietyLine(in: observation.lines).map { significantTokens($0.text) } ?? []
        return Set(name + variety)
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

    // MARK: Panels

    /// Whether the photo shows a nutrition, supplement or ingredients panel or an allergen statement:
    /// a panel's heading, its serving line or its daily values. A line of nutrients alone, such as
    /// "0 calories" printed on a front, does not make a photo a panel.
    public static func showsPanel(_ lines: [RecognizedTextLine]) -> Bool {
        lines.contains { panelKind($0.text) == .heading }
    }

    /// Whether the line belongs to a nutrition, supplement or ingredients panel or an allergen
    /// statement. Such a line is never a name and never tells two products apart.
    public static func isPanelLine(_ text: String) -> Bool {
        panelKind(text) != nil
    }

    private enum PanelLine {
        /// A line that only a panel prints: its title, serving line, daily values, ingredients or
        /// allergens.
        case heading
        /// A nutrient with its amount, which a front can also print ("0g sugar").
        case nutrient
    }

    /// Only a line's first `IntakeLimits.charactersPerLine` characters are read, as for a recognized
    /// line. Words are compared after folding, and a panel word of `panelWordTolerantLetters` letters or
    /// more also matches a word one letter off, since recognition misreads small print ("Nutritlon",
    /// "Calorles").
    private static func panelKind(_ text: String) -> PanelLine? {
        let folded = text.prefix(IntakeLimits.charactersPerLine)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty else { return nil }
        var found: Set<String> = []
        for word in words {
            if panelWords.contains(word) { found.insert(word) }
            if tolerantPanelLetters.contains(word.unicodeScalars.count) { found.formUnion(panelWordIndex.near(.init(word))) }
        }
        func has(_ keywords: Set<String>) -> Bool { !found.isDisjoint(with: keywords) }
        let hasDigit = folded.contains(where: \.isNumber)
        if has(titleWords), has(titleEndWords) { return .heading }
        if has(servingWords), hasDigit || has(servingEndWords) { return .heading }
        if has(ingredientWords) { return .heading }
        if has(["daily"]), has(["value", "values"]) { return .heading }
        if words.contains("dv"), folded.contains("%") { return .heading }
        if let first = words.first, first == "contains" || (first == "may" && words.dropFirst().first == "contain"),
           has(allergenWords) { return .heading }
        if has(calorieWords), hasDigit { return .nutrient }
        if has(nutrientWords), hasNutrientAmount(folded) { return .nutrient }
        // An ingredients list running on from the line above it.
        if folded.filter({ $0 == "," }).count >= 3 { return .nutrient }
        return nil
    }

    /// A number followed by grams, milligrams or micrograms, as a nutrient's amount is printed.
    private static func hasNutrientAmount(_ text: String) -> Bool {
        let characters = Array(text)
        for index in characters.indices where characters[index].isNumber {
            var cursor = index + 1
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            var unit = ""
            while cursor < characters.count, characters[cursor].isLetter, unit.count < 4 {
                unit.append(characters[cursor])
                cursor += 1
            }
            if ["g", "mg", "mcg"].contains(unit) { return true }
        }
        return false
    }

    /// Panel words this long or longer also match a word one letter off.
    static let panelWordTolerantLetters = 5

    private static let titleWords: Set<String> = ["nutrition", "supplement"]
    private static let titleEndWords: Set<String> = ["facts", "fact", "information", "info", "label"]
    private static let servingWords: Set<String> = ["serving", "servings", "serv", "svg"]
    private static let servingEndWords: Set<String> = ["size", "per", "container"]
    private static let ingredientWords: Set<String> = ["ingredients", "ingredient", "allergen", "allergens", "allergy"]
    private static let calorieWords: Set<String> = ["calories", "calorie", "kcal"]

    /// Every word a panel rule looks for.
    private static let panelWords: Set<String> = titleWords.union(titleEndWords).union(servingWords).union(servingEndWords)
        .union(ingredientWords).union(calorieWords).union(nutrientWords).union(allergenWords).union(["daily", "value", "values"])

    /// The lengths of words that can be one letter off a panel word long enough to be tolerant.
    private static let tolerantPanelLetters: ClosedRange<Int> =
        (panelWordTolerantLetters - 1)...(panelWords.map(\.unicodeScalars.count).max() ?? 0) + 1

    /// The panel words long enough to match a word one letter off.
    private static let panelWordIndex: NearWords = {
        var index = NearWords()
        for word in panelWords where word.unicodeScalars.count >= panelWordTolerantLetters { index.add(word) }
        return index
    }()

    private static let nutrientWords: Set<String> = [
        "fat", "sodium", "cholesterol", "cholest", "carbohydrate", "carbohydrates", "carb", "carbs", "fiber",
        "fibre", "sugars", "sugar", "protein", "vitamin", "calcium", "iron", "potassium", "sat", "trans",
    ]

    private static let allergenWords: Set<String> = [
        "milk", "wheat", "soy", "egg", "eggs", "peanut", "peanuts", "tree", "nut", "nuts", "fish", "shellfish",
        "sesame", "almond", "almonds", "hazelnut", "hazelnuts", "gluten",
    ]

    // MARK: Words

    /// Whether two words differ by exactly one letter added, dropped or changed: the common start
    /// and the common end, which must not overlap, cover all but one letter of the longer word.
    static func isOneEditApart(_ a: String, _ b: String) -> Bool {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        guard abs(x.count - y.count) <= 1, x != y else { return false }
        let shorter = min(x.count, y.count)
        var prefix = 0
        while prefix < shorter, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        return prefix + suffix >= max(x.count, y.count) - 1
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

/// Words prepared for finding words one letter off without comparing every word with every other:
/// each word with one letter removed, and with one letter replaced by a mark that is never a
/// letter. Two words are one letter off exactly when one is the other with a letter removed (a
/// letter added or dropped), or when they share a replacement key at the same place (a letter
/// changed).
struct NearWords: Sendable {
    struct Query: Sendable {
        let word: String
        let removals: [String]
        let replacements: [String]

        init(_ word: String) {
            self.word = word
            (removals, replacements) = NearWords.keys(word)
        }
    }

    private(set) var words: Set<String> = []
    /// Each key, with the words it was made from.
    private var removals: [String: [String]] = [:]
    private var replacements: [String: [String]] = [:]
    /// The name words to look for in another photo.
    var queries: [Query] = []

    mutating func add(_ word: String) {
        guard words.insert(word).inserted else { return }
        let keys = Self.keys(word)
        for key in keys.removals { removals[key, default: []].append(word) }
        for key in keys.replacements { replacements[key, default: []].append(word) }
    }

    static func keys(_ word: String) -> (removals: [String], replacements: [String]) {
        let scalars = Array(word.unicodeScalars)
        var removals: [String] = []
        var replacements: [String] = []
        for index in scalars.indices {
            var removed = String.UnicodeScalarView()
            removed.append(contentsOf: scalars[..<index])
            removed.append(contentsOf: scalars[(index + 1)...])
            removals.append(String(removed))
            var replaced = String.UnicodeScalarView()
            replaced.append(contentsOf: scalars[..<index])
            replaced.append("*")
            replaced.append(contentsOf: scalars[(index + 1)...])
            replacements.append(String(replaced))
        }
        return (removals, replacements)
    }

    /// The words here one letter off the query's word.
    func near(_ query: Query) -> Set<String> {
        var found: Set<String> = []
        for word in removals[query.word] ?? [] { found.insert(word) }
        for key in query.removals where words.contains(key) { found.insert(key) }
        for key in query.replacements {
            for word in replacements[key] ?? [] where word != query.word { found.insert(word) }
        }
        return found
    }

    /// Whether the query's word is one letter off a word here other than the batch's common words.
    /// Adds each lookup made to `lookups`.
    func hasNear(_ query: Query, ignoring common: Set<String>, lookups: inout Int) -> Bool {
        guard !common.contains(query.word) else { return false }
        func usable(_ found: [String]?) -> Bool {
            found?.contains { $0 != query.word && !common.contains($0) } ?? false
        }
        lookups += 1
        if usable(removals[query.word]) { return true }
        for key in query.removals {
            lookups += 1
            if words.contains(key), !common.contains(key) { return true }
        }
        for key in query.replacements {
            lookups += 1
            if usable(replacements[key]) { return true }
        }
        return false
    }
}
