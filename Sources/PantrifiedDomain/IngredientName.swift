import Foundation

/// A comparable form of a food name, so "Boneless chicken breasts" and "chicken breast" meet.
/// Normalization is deliberately shallow: case, punctuation, invisible characters, a few
/// preparation descriptors, and simple plurals. Anything fuzzier is a possible match for the user
/// to confirm, not a guess.
public struct IngredientName: Sendable, Hashable, Codable {
    public let words: [String]

    public init(_ raw: String) {
        let tokens = raw.withoutInvisibleCharacters.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(Self.singular)
        let meaningful = tokens.filter { !Self.descriptors.contains($0) }
        words = meaningful.isEmpty ? tokens : meaningful
    }

    /// Decoded words are normalized again, so stored or synced data can never hold a name that
    /// typed text could not produce. Normalizing a normalized name changes nothing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([String].self, forKey: .words).joined(separator: " "))
    }

    private enum CodingKeys: String, CodingKey {
        case words
    }

    public var text: String { words.joined(separator: " ") }
    public var isEmpty: Bool { words.isEmpty }

    // Descriptors that describe preparation or size, not a different product. "whole" is absent
    // on purpose: whole milk is not milk. Compared after singular forms are taken, so normalizing
    // twice gives the same name.
    private static let descriptors: Set<String> = [
        "fresh", "chopped", "diced", "sliced", "minced", "grated",
        "large", "small", "medium", "ripe", "boneless", "skinless", "organic",
    ]

    private static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if ["ches", "shes", "xes", "sses"].contains(where: word.hasSuffix) { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !["ss", "us", "is"].contains(where: word.hasSuffix) {
            return String(word.dropLast())
        }
        return word
    }
}

extension String {
    /// The text as a person sees it. Characters that display as nothing are removed, because left
    /// in they split one visible word into several ("to\u{200B}ast" would read as "to" and "ast"):
    /// format characters such as zero-width spaces, joiners, soft hyphens and byte order marks,
    /// other default-ignorable code points such as variation selectors and Hangul fillers, and
    /// control characters other than tabs and line breaks.
    var withoutInvisibleCharacters: String {
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: unicodeScalars.filter { scalar in
            let properties = scalar.properties
            switch properties.generalCategory {
            case .format: return false
            case .control: return properties.isWhitespace
            default: return !properties.isDefaultIgnorableCodePoint
            }
        })
        return String(visible)
    }
}
