import Foundation

public enum IntakePhotoTag: Sendable {}
/// One photo in a batch. A photo is app-owned staging data, never an asset in Photos.
public typealias IntakePhotoID = Identifier<IntakePhotoTag>

/// Limits on what one batch may hold. Recognized text, codes and feature prints come from photos the
/// app does not control, so every input is cut to these sizes before anything else reads it.
public enum IntakeLimits {
    public static let photosPerBatch = 120
    public static let linesPerPhoto = 150
    public static let charactersPerLine = 160
    /// UTF-8 bytes, counted separately from characters: one character can take many bytes.
    public static let bytesPerLine = 640
    public static let bytesOfTextPerPhoto = 12_000
    public static let codesPerPhoto = 12
    /// A code longer than this is not read at all.
    public static let codePayloadBytes = 512
    public static let featurePrintValues = 4_096
    /// A batch can make more candidates than photos only through photos showing several barcodes.
    public static let candidatesPerBatch = 160
    public static let packagesPerCandidate = 24
    public static let nameCharacters = 80
    public static let nameBytes = 320
}

/// A rectangle in a photo, as fractions of its width and height, with the origin at the top left.
public struct NormalizedBox: Sendable, Hashable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    /// Values outside 0...1, and values that are not numbers, are clamped into the photo.
    public init(x: Double, y: Double, width: Double, height: Double) {
        let x = Self.unit(x), y = Self.unit(y)
        self.x = x
        self.y = y
        self.width = min(Self.unit(width), 1 - x)
        self.height = min(Self.unit(height), 1 - y)
    }

    public static let whole = NormalizedBox(x: 0, y: 0, width: 1, height: 1)

    public var midY: Double { y + height / 2 }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        self.init(x: raw.x, y: raw.y, width: raw.width, height: raw.height)
    }

    public func encode(to encoder: any Encoder) throws {
        try Raw(x: x, y: y, width: width, height: height).encode(to: encoder)
    }

    private struct Raw: Codable {
        let x, y, width, height: Double
    }
}

/// One line of text recognized in a photo. The text is untrusted: it is cleaned and bounded when the
/// line is made, and it is never logged.
public struct RecognizedTextLine: Sendable, Hashable, Codable {
    public let text: String
    public let box: NormalizedBox
    /// What the recognizer reported, 0 to 1. Not a calibrated probability.
    public let confidence: Double?

    /// Nil when nothing readable is left after cleaning.
    public init?(text: String, box: NormalizedBox, confidence: Double? = nil) {
        let cleaned = BoundedText.clean(text, characters: IntakeLimits.charactersPerLine, bytes: IntakeLimits.bytesPerLine)
        guard !cleaned.isEmpty else { return nil }
        self.text = cleaned
        self.box = box
        self.confidence = confidence.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        guard let line = RecognizedTextLine(text: raw.text, box: raw.box, confidence: raw.confidence) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "empty line"))
        }
        self = line
    }

    public func encode(to encoder: any Encoder) throws {
        try Raw(text: text, box: box, confidence: confidence).encode(to: encoder)
    }

    private struct Raw: Codable {
        let text: String
        let box: NormalizedBox
        let confidence: Double?
    }
}

/// The symbologies the photo recognizer reports.
public enum CodeSymbology: String, Sendable, Hashable, Codable {
    case ean13, ean8, upcA, upcE, qr
}

/// Why a product barcode in a photo was not taken as a GTIN, kept so the review can say so.
public enum RefusedCode: String, Sendable, Hashable, Codable {
    case unreadable
    case notAConsumerUnit
    case storeInternal
    case coupon
    case publication
    case refundReceipt

    init(_ rejection: GTINRejection) {
        switch rejection {
        case .malformed, .checkDigit: self = .unreadable
        case .notAConsumerUnit: self = .notAConsumerUnit
        case .storeInternal: self = .storeInternal
        case .coupon: self = .coupon
        case .publication: self = .publication
        case .refundReceipt: self = .refundReceipt
        }
    }
}

/// What a barcode or QR code in a photo means. The raw payload is classified once and then dropped:
/// a link is never kept, opened or fetched.
public enum CodeMeaning: Sendable, Hashable, Codable {
    /// A product's GTIN, from a retail barcode or from a QR code holding a GS1 Digital Link.
    case product(GTIN)
    case refused(RefusedCode)
    /// A QR code holding some other link. Only the fact that one was seen is kept.
    case link
    /// A QR code holding something that is not a link.
    case otherQR

    public static func classify(payload: String, symbology: CodeSymbology) -> CodeMeaning? {
        guard payload.utf8.count <= IntakeLimits.codePayloadBytes else {
            return symbology == .qr ? .otherQR : .refused(.unreadable)
        }
        switch symbology {
        case .qr:
            guard let link = Self.linkScheme(payload) else { return .otherQR }
            return Self.digitalLinkGTIN(payload, afterScheme: link).map(CodeMeaning.product) ?? .link
        case .ean13, .ean8, .upcA, .upcE:
            let retail: BarcodeSymbology = switch symbology {
            case .ean13: .ean13
            case .ean8: .ean8
            case .upcA: .upcA
            default: .upcE
            }
            switch GTIN.scanned(payload, as: retail) {
            case .success(let gtin): return .product(gtin)
            case .failure(let reason): return .refused(RefusedCode(reason))
            }
        }
    }

    /// The length of an `http://` or `https://` prefix, in any letter case.
    private static func linkScheme(_ payload: String) -> Int? {
        let lower = payload.prefix(8).lowercased()
        if lower.hasPrefix("https://") { return 8 }
        if lower.hasPrefix("http://") { return 7 }
        return nil
    }

    /// The GTIN in a GS1 Digital Link, such as `https://id.gs1.org/01/09506000134352`: the path
    /// segment after `01`. Any host may carry one, because brands publish Digital Links on their own
    /// domains; the link is only read as text, never followed.
    static func digitalLinkGTIN(_ payload: String, afterScheme start: Int) -> GTIN? {
        guard payload.allSatisfy(\.isASCII) else { return nil }
        let rest = payload.dropFirst(start)
        let beforeQuery = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? rest
        let withoutFragment = beforeQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? beforeQuery
        let segments = withoutFragment.split(separator: "/", omittingEmptySubsequences: false)
        guard let host = segments.first, !host.isEmpty, segments.count >= 3 else { return nil }
        // The first `01` segment is the GTIN's key. Later segments (batch, serial) are ignored.
        guard let index = segments.dropFirst().firstIndex(of: "01"), index + 1 < segments.count else { return nil }
        let digits = String(segments[index + 1])
        guard case .success(let gtin) = GTIN.parse(digits), digits == digits.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return gtin
    }
}

/// A photo's image feature print: a vector the recognizer computes so that two photos of the same
/// thing are close. Kept only while its batch is.
public struct FeaturePrint: Sendable, Hashable, Codable {
    public let values: [Float]

    /// Nil when the vector is empty, too long or holds a value that is not a number.
    public init?(_ values: [Float]) {
        guard !values.isEmpty, values.count <= IntakeLimits.featurePrintValues, values.allSatisfy(\.isFinite) else {
            return nil
        }
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let values = try [Float](from: decoder)
        guard let print = FeaturePrint(values) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad feature print"))
        }
        self = print
    }

    public func encode(to encoder: any Encoder) throws {
        try values.encode(to: encoder)
    }
}

/// What a photo shows. Every photo is a package photo today. A receipt, one photo naming many
/// items, is the expected next kind: it would be read by its own step and skipped by grouping,
/// and its candidates would share the one photo the way candidates from a photo of several
/// barcodes already do.
public enum PhotoKind: String, Sendable, Hashable, Codable {
    case package
}

/// Everything recognition found in one photo, bounded. Grouping reads only this.
public struct PhotoObservation: Sendable, Hashable, Codable {
    public let photo: IntakePhotoID
    public let kind: PhotoKind
    /// The photo's place in the batch, in the order it was taken or imported.
    public let sequence: Int
    /// When the photo was taken, as the app recorded it. Imported photos carry the time they were
    /// imported, which makes them adjacent in time to each other and nothing else.
    public let capturedAt: Date
    public let lines: [RecognizedTextLine]
    public let codes: [CodeMeaning]
    public let featurePrint: FeaturePrint?
    /// A digest of the photo's bytes, so the same photo imported twice is recognized. Lowercase hex.
    public let contentDigest: String?

    public init(
        photo: IntakePhotoID,
        kind: PhotoKind = .package,
        sequence: Int,
        capturedAt: Date,
        lines: [RecognizedTextLine] = [],
        codes: [CodeMeaning] = [],
        featurePrint: FeaturePrint? = nil,
        contentDigest: String? = nil
    ) {
        self.photo = photo
        self.kind = kind
        self.sequence = max(0, sequence)
        self.capturedAt = capturedAt
        var kept: [RecognizedTextLine] = []
        var bytes = 0
        for line in lines.prefix(IntakeLimits.linesPerPhoto) {
            bytes += line.text.utf8.count
            guard bytes <= IntakeLimits.bytesOfTextPerPhoto else { break }
            kept.append(line)
        }
        self.lines = kept
        self.codes = Array(codes.prefix(IntakeLimits.codesPerPhoto))
        self.featurePrint = featurePrint
        self.contentDigest = contentDigest.flatMap { digest in
            let lower = digest.lowercased()
            return (1...128).contains(lower.utf8.count) && lower.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                ? lower : nil
        }
    }

    /// The distinct product GTINs the photo shows, in a stable order.
    public var products: [GTIN] {
        var seen: Set<GTIN> = []
        return codes.compactMap { code -> GTIN? in
            guard case .product(let gtin) = code, seen.insert(gtin).inserted else { return nil }
            return gtin
        }
        .sorted { $0.digits < $1.digits }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        self.init(
            photo: raw.photo, kind: raw.kind ?? .package, sequence: raw.sequence, capturedAt: raw.capturedAt, lines: raw.lines,
            codes: raw.codes, featurePrint: raw.featurePrint, contentDigest: raw.contentDigest
        )
    }

    public func encode(to encoder: any Encoder) throws {
        try Raw(
            photo: photo, kind: kind, sequence: sequence, capturedAt: capturedAt, lines: lines, codes: codes,
            featurePrint: featurePrint, contentDigest: contentDigest
        ).encode(to: encoder)
    }

    private struct Raw: Codable {
        let photo: IntakePhotoID
        /// Optional so a batch written before kinds existed still reads.
        let kind: PhotoKind?
        let sequence: Int
        let capturedAt: Date
        let lines: [RecognizedTextLine]
        let codes: [CodeMeaning]
        let featurePrint: FeaturePrint?
        let contentDigest: String?
    }
}

/// Cleans untrusted text: control and format characters (including bidirectional overrides) become
/// spaces, runs of white space collapse, and the result is cut between characters to a character and
/// a UTF-8 byte limit. Invisible scalars attached to a visible character, such as tag characters or a
/// zero width joiner between letters, are removed one by one; only an emoji keeps its joiners,
/// variation selectors and tags. Hangul fillers, which draw nothing, count as spaces.
public enum BoundedText {
    /// Letters that draw nothing.
    static let fillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: true
        default: (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
        }
    }

    /// The character as it may be kept: whole when it is an emoji, otherwise without invisible scalars.
    static func visible(_ character: Character) -> String {
        let scalars = character.unicodeScalars
        let emoji = scalars.contains { $0.properties.isEmojiPresentation }
            || (scalars.count > 1 && scalars.first?.properties.isEmoji == true && scalars.first?.isASCII == false)
        if emoji { return String(character) }
        var kept = String.UnicodeScalarView()
        for scalar in scalars where !isInvisible(scalar) && !fillers.contains(scalar.value) { kept.append(scalar) }
        return String(kept)
    }

    public static func clean(_ text: String, characters: Int, bytes: Int) -> String {
        var out = ""
        var bytesSoFar = 0
        var count = 0
        var pendingSpace = false
        // Reading stops well past the limits, so a huge input costs no more than a long line.
        for character in text.prefix(characters * 4) {
            let kept = visible(character)
            if character.isWhitespace || kept.isEmpty {
                pendingSpace = !out.isEmpty
                continue
            }
            let piece = pendingSpace ? " " + kept : kept
            let pieceBytes = piece.utf8.count
            let pieceCount = pendingSpace ? 2 : 1
            guard count + pieceCount <= characters, bytesSoFar + pieceBytes <= bytes else { break }
            out += piece
            bytesSoFar += pieceBytes
            count += pieceCount
            pendingSpace = false
        }
        return out
    }
}
