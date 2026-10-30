import Foundation

/// A comparable form of a food name, so "Boneless chicken breasts" and "chicken breast" meet.
/// Normalization is deliberately shallow: case, punctuation, a few preparation descriptors, and
/// simple plurals. Anything fuzzier is a possible match for the user to confirm, not a guess.
public struct IngredientName: Sendable, Hashable, Codable {
    public let words: [String]

    public init(_ raw: String) {
        let tokens = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let meaningful = tokens.filter { !Self.descriptors.contains($0) }
        words = (meaningful.isEmpty ? tokens : meaningful).map(Self.singular)
    }

    public var text: String { words.joined(separator: " ") }
    public var isEmpty: Bool { words.isEmpty }

    // Descriptors that describe preparation or size, not a different product. "whole" is absent
    // on purpose: whole milk is not milk.
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
