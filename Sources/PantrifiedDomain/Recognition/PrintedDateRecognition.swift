import Foundation

/// The lines text recognition read in one photo, bounded as they are read. Recognized text is
/// untrusted input: a line is checked before it is kept, and the photo stops taking lines once it
/// is full, so a reader can stop asking for more.
public struct RecognizedText: Sendable, Hashable {
    /// Lines offered, kept or not. Later lines are not looked at.
    public static let maxLines = 256
    /// A longer line is dropped whole, because cutting it could turn a date into a different one.
    /// Counted in UTF-8 bytes, since one character can be many bytes.
    public static let maxLineBytes = 200
    /// Once the kept lines reach this many UTF-8 bytes the photo is full.
    public static let maxBytes = 16_384

    public private(set) var lines: [String] = []
    private var offered = 0
    private var bytes = 0

    public init() {}

    public init(lines: [String]) {
        for line in lines {
            guard add(line) else { break }
        }
    }

    /// Keeps the line if it fits. Returns false once the photo takes no more lines.
    @discardableResult
    public mutating func add(_ line: String) -> Bool {
        guard offered < Self.maxLines else { return false }
        offered += 1
        let size = line.utf8.count
        guard size > 0, size <= Self.maxLineBytes else { return true }
        guard bytes + size <= Self.maxBytes else {
            offered = Self.maxLines
            return false
        }
        bytes += size
        lines.append(line)
        return true
    }
}

/// Reads printed dates out of the text recognized in one or more photos of the same package. It
/// knows nothing about cameras or images: a caller recognizes the text, and this turns it into
/// readings that `PackageDraft.apply(_:)` proposes, which keeps a date the person confirmed and
/// holds an ambiguous date as a pending choice.
public struct PrintedDateRecognition: Sendable {
    /// Photos after this many are not read.
    public static let maxPhotos = 8
    /// A date further than this before or after the time the photos were taken is taken for a
    /// misread or for a number that is not a food date, and is not read.
    public static let plausiblePast: TimeInterval = 2 * 366 * 86_400
    public static let plausibleFuture: TimeInterval = 10 * 366 * 86_400

    private let parser: PrintedDateParser
    private let hint: DateOrderHint

    /// `hint` is passed to the parser; give one only when the package or locale settles the order.
    public init(parser: PrintedDateParser = PrintedDateParser(), hint: DateOrderHint = .unknown) {
        self.parser = parser
        self.hint = hint
    }

    /// The plausible dates in the photos' text, photo by photo. Each photo is read on its own, so a
    /// label at the end of one photo's text never labels a date in the next.
    public func readings(in photos: [RecognizedText], at time: Date) -> [PrintedDateReading] {
        photos.prefix(Self.maxPhotos).flatMap { photo -> [PrintedDateReading] in
            guard !photo.lines.isEmpty else { return [] }
            // A label and its date are often on separate lines; the parser reads a line break as a space.
            return parser.parse(photo.lines.joined(separator: "\n"), hint: hint)
                .filter { Self.isPlausible($0.value, at: time) }
        }
    }

    /// The reading to propose for the package, chosen as `PrintedDateParser.preferred` chooses.
    public func proposal(in photos: [RecognizedText], at time: Date) -> PrintedDateReading? {
        PrintedDateParser.preferred(readings(in: photos, at: time))
    }

    /// Both readings of an ambiguous date must be plausible, so a choice never offers a date that
    /// would be refused on its own.
    static func isPlausible(_ value: PrintedDateValue, at time: Date) -> Bool {
        let range = time.addingTimeInterval(-plausiblePast)...time.addingTimeInterval(plausibleFuture)
        switch value {
        case .resolved(let date, _): return range.contains(date)
        case .ambiguous(let monthFirst, let dayFirst): return range.contains(monthFirst) && range.contains(dayFirst)
        }
    }
}
