import Foundation

/// The retail product barcodes a camera reads. Cameras report a UPC-A barcode as EAN-13 with a
/// leading zero, so `upcA` is for text that names a UPC-A directly.
public enum BarcodeSymbology: Sendable, Hashable, CaseIterable {
    case ean13
    case ean8
    case upcA
    case upcE
}

/// Why a barcode is not taken as a food product's GTIN.
public enum GTINRejection: Error, Sendable, Hashable {
    /// Not digits, the wrong length for its symbology, or a UPC-E with a number system other than
    /// 0 or 1.
    case malformed
    case checkDigit
    /// A GTIN-14 with a packaging indicator names a case or pack, not what a person puts away.
    case notAConsumerUnit
    /// A restricted circulation number: a store's own code, often a weighed item with the price
    /// inside it. The same code names different things in different stores.
    case storeInternal
    case coupon
    /// A book or periodical number (ISBN, ISSN, ISMN).
    case publication
    case refundReceipt
}

/// A Global Trade Item Number read from a package. It names a product, never a physical package:
/// two packages with one GTIN are still two packages.
///
/// Every accepted form (EAN-13, UPC-A, EAN-8 and UPC-E) is stored as the 14-digit GTIN it pads
/// to, so one product reads the same whichever barcode was printed on it.
public struct GTIN: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Fourteen ASCII digits, zero padded on the left.
    public let digits: String

    private init(validated digits: String) {
        self.digits = digits
    }

    /// A GTIN from text that names one directly: 8, 12, 13 or 14 digits, such as a stored value or
    /// a product database's UPC field. A UPC-E is not expanded here because 8 digits read as a
    /// GTIN-8; use `scanned(_:as:)` when the symbology is known.
    public static func parse(_ text: String) -> Result<GTIN, GTINRejection> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard isASCIIDigits(trimmed), [8, 12, 13, 14].contains(trimmed.count) else { return .failure(.malformed) }
        return validate(String(repeating: "0", count: 14 - trimmed.count) + trimmed)
    }

    /// A GTIN from a camera's barcode payload and the symbology it reported.
    public static func scanned(_ payload: String, as symbology: BarcodeSymbology) -> Result<GTIN, GTINRejection> {
        guard isASCIIDigits(payload) else { return .failure(.malformed) }
        switch symbology {
        case .ean13:
            guard payload.count == 13 else { return .failure(.malformed) }
            return validate("0" + payload)
        case .upcA:
            guard payload.count == 12 else { return .failure(.malformed) }
            return validate("00" + payload)
        case .ean8:
            guard payload.count == 8 else { return .failure(.malformed) }
            return validate("000000" + payload)
        case .upcE:
            guard let upcA = expandUPCE(payload) else { return .failure(.malformed) }
            return validate("00" + upcA)
        }
    }

    /// A stored or known-good value, or nil when it is not an accepted GTIN.
    public init?(_ text: String) {
        guard case .success(let gtin) = Self.parse(text) else { return nil }
        self = gtin
    }

    /// The GTIN in the length it was issued as: GTIN-8, GTIN-12 (UPC-A), GTIN-13 or GTIN-14. This
    /// is the form printed under a barcode and the form product databases usually hold.
    public var issuedForm: String {
        if digits.hasPrefix("000000") { return String(digits.suffix(8)) }
        if digits.hasPrefix("00") { return String(digits.suffix(12)) }
        if digits.hasPrefix("0") { return String(digits.suffix(13)) }
        return digits
    }

    public var description: String { issuedForm }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard text.count == 14, let gtin = GTIN(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a 14-digit GTIN"))
        }
        self = gtin
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(digits)
    }

    // MARK: Rules

    private static func validate(_ digits: String) -> Result<GTIN, GTINRejection> {
        let values = digits.unicodeScalars.map { Int($0.value) - 48 }
        guard checkDigit(of: values.dropLast()) == values.last else { return .failure(.checkDigit) }
        guard values.first == 0 else { return .failure(.notAConsumerUnit) }
        if let rejection = reservedRange(digits) { return .failure(rejection) }
        return .success(GTIN(validated: digits))
    }

    /// GS1's mod 10 check: weights 3 and 1 alternate leftwards from the digit next to the check.
    static func checkDigit<Digits: BidirectionalCollection>(of data: Digits) -> Int where Digits.Element == Int {
        let sum = data.reversed().enumerated().reduce(0) { total, entry in
            total + entry.element * (entry.offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10
    }

    /// GS1 prefixes that never name a trade item a household buys and keeps.
    private static func reservedRange(_ digits: String) -> GTINRejection? {
        if digits.hasPrefix("000000") {
            // GTIN-8s starting 0 or 2 are restricted circulation numbers.
            let first = digits.dropFirst(6).first
            return first == "0" || first == "2" ? .storeInternal : nil
        }
        let gtin13 = digits.dropFirst()
        func starts(_ prefixes: String...) -> Bool { prefixes.contains { gtin13.hasPrefix($0) } }
        if starts("02", "04", "2") { return .storeInternal }
        if starts("05", "981", "982", "983", "984", "99") { return .coupon }
        if starts("977", "978", "979") { return .publication }
        if starts("980") { return .refundReceipt }
        return nil
    }

    /// The UPC-A a zero-suppressed UPC-E stands for, or nil when the payload is not a UPC-E. The
    /// payload is the number system digit, six data digits and the UPC-A's check digit.
    static func expandUPCE(_ payload: String) -> String? {
        guard payload.count == 8, isASCIIDigits(payload) else { return nil }
        let d = Array(payload)
        guard d[0] == "0" || d[0] == "1" else { return nil }
        let body: [Character]
        switch d[6] {
        case "0", "1", "2": body = [d[1], d[2], d[6], "0", "0", "0", "0", d[3], d[4], d[5]]
        case "3": body = [d[1], d[2], d[3], "0", "0", "0", "0", "0", d[4], d[5]]
        case "4": body = [d[1], d[2], d[3], d[4], "0", "0", "0", "0", "0", d[5]]
        default: body = [d[1], d[2], d[3], d[4], d[5], "0", "0", "0", "0", d[6]]
        }
        return String([d[0]] + body + [d[7]])
    }

    private static func isASCIIDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }
}
