import Foundation

/// A title or instruction split into sentences of words, the way the validator reads it. Food names
/// and measures never run across punctuation, so "peanut, butter" is two foods, not peanut butter.
struct RecipeText {
    struct Word {
        /// Lowercased, as written. Cooking vocabulary is compared in this form, so "fries" is not
        /// the verb "fry".
        let written: String
        /// The singular form food names are compared in.
        let normalized: String
        /// Punctuation such as a comma or a parenthesis separates this word from the one before.
        let followsPause: Bool
    }

    let sentences: [[Word]]

    /// Expects text that has already had invisible characters removed.
    init(_ text: String) {
        let spaced = [(Self.spacedDash, ","), (Self.withinNumber, "")].reduce(text) { text, rule in
            rule.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.1)
        }
        var sentences: [[Word]] = []
        var sentence: [Word] = []
        var token = String.UnicodeScalarView()
        var pause = false

        func endWord() {
            guard !token.isEmpty else { return }
            let written = String(token)
            sentence.append(Word(
                written: written, normalized: IngredientName(written).words.first ?? written, followsPause: pause
            ))
            token = String.UnicodeScalarView()
            pause = false
        }

        for scalar in spaced.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.append(scalar)
                continue
            }
            endWord()
            if Self.isPictograph(scalar) {
                // A picture can name a food ("top with 🧈"), so it is a word to check, not punctuation.
                token.append(scalar)
                endWord()
            } else if Self.sentenceEnds.contains(scalar) {
                if !sentence.isEmpty { sentences.append(sentence) }
                sentence = []
                pause = false
            } else if scalar == "&" {
                // Read as the word it stands for, so "half & half" is not two halves.
                token.append(contentsOf: "and".unicodeScalars)
                endWord()
            } else if !Self.joiners.contains(scalar) && !CharacterSet.whitespaces.contains(scalar) {
                pause = true
            }
        }
        endWord()
        if !sentence.isEmpty { sentences.append(sentence) }
        self.sentences = sentences
    }

    private static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        return properties.isEmojiPresentation || (properties.isEmoji && properties.generalCategory == .otherSymbol)
    }

    private static let sentenceEnds = CharacterSet(charactersIn: ".!?;:\n\r\u{2026}\u{2028}\u{2029}")
    /// Marks inside a word: "half-and-half", "don't". A slash separates alternatives, so it is a
    /// pause like a comma.
    private static let joiners = CharacterSet(charactersIn: "-\u{2010}\u{2011}'\u{2019}")
    /// The point, slash or comma inside a number such as "1.5", "1/2" or "1,000", which would
    /// otherwise end a sentence or read as a pause.
    private static let withinNumber = try! NSRegularExpression(pattern: #"(?<=\d)[./,](?=\d)"#)
    /// A dash with space on either side separates clauses, unlike a hyphen inside a word.
    private static let spacedDash = try! NSRegularExpression(pattern: #"\s[-\u2010-\u2015]+|[-\u2010-\u2015]+\s"#)
}
