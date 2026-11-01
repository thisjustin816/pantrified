import Foundation

/// A rough check for text that looks personal, run on every line and name before the person sees
/// the export. A line it flags starts out left out, and the person can put it back. It works on the
/// text's shape only, so it misses a lot: a name with no title or field label before it, an address
/// with no house number or street word, a number written in words, an email address written with
/// "at", anything handwritten or in another language. It also flags lines that are not personal,
/// such as a barcode's printed digits, a maker's address or "Dr Pepper". The preview says so, and
/// the person reads every line.
public enum SensitiveText {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case email
        case phone
        case streetAddress
        /// Nine or more digits in a row, which could be a card or account number.
        case longNumber
        /// A name after a title such as "Mrs" or a field label such as "Patient:".
        case personName
    }

    /// The first kind the text looks like, or nil.
    public static func flag(_ text: String) -> Kind? {
        Kind.allCases.first { kind in
            patterns[kind, default: []].contains { pattern in text.range(of: pattern.regex, options: pattern.options) != nil }
        }
    }

    struct Pattern {
        let regex: String
        let caseInsensitive: Bool

        var options: String.CompareOptions { caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression }
    }

    private static let streetWords = [
        "street", "st", "avenue", "ave", "road", "rd", "boulevard", "blvd", "lane", "ln", "drive", "dr", "court",
        "way", "place", "pl", "terrace", "circle", "cir", "highway", "hwy", "parkway", "pkwy", "suite", "ste", "apt", "apartment",
    ].joined(separator: "|")

    private static let fieldLabels = [
        "name", "patient", "customer", "member", "cardholder", "card holder", "ship to", "deliver to", "bill to",
        "attn", "recipient", "prescriber",
    ].joined(separator: "|")

    static let patterns: [Kind: [Pattern]] = [
        .email: [Pattern(regex: #"[A-Z0-9._%+-]+@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}"#, caseInsensitive: true)],
        .phone: [
            // A North American number: 555-123-4567, (555) 123 4567, +1 555.123.4567.
            Pattern(regex: #"(\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]?\d{3}[\s.-]\d{4}\b"#, caseInsensitive: false),
            // An international number written with a plus.
            Pattern(regex: #"\+\d{1,3}([\s.-]?\d){6,14}\b"#, caseInsensitive: false),
            // A short local number: 555-1234.
            Pattern(regex: #"\b\d{3}[.-]\d{4}\b"#, caseInsensitive: false),
            Pattern(regex: #"\b(tel|phone|call|mobile|cell|fax)\b\.?:?\s*\(?\d"#, caseInsensitive: true),
        ],
        .streetAddress: [
            Pattern(regex: #"\b\d{1,6}[A-Z]?\s+([A-Z0-9.'-]+\s+){0,4}(\#(streetWords))\b"#, caseInsensitive: true),
            Pattern(regex: #"\bP\.?\s?O\.?\s+Box\s+\d"#, caseInsensitive: true),
            // A state and ZIP code: "NY 13815", "CA 94105-1234".
            Pattern(regex: #"\b[A-Z]{2}\s+\d{5}(-\d{4})?\b"#, caseInsensitive: false),
        ],
        .longNumber: [Pattern(regex: #"\d([\s-]?\d){8,}"#, caseInsensitive: false)],
        .personName: [
            Pattern(regex: #"\b(Mr|Mrs|Ms|Mx|Miss|Dr)\.?\s+[A-Z][a-z]"#, caseInsensitive: false),
            Pattern(regex: #"\b(\#(fieldLabels))\s*:\s*\S"#, caseInsensitive: true),
        ],
    ]
}
