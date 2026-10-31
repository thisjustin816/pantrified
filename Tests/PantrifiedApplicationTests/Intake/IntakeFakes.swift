import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// A staging folder in memory. Shared between store instances to stand for the same folder across
/// a relaunch. Holds files the store did not make, to show it never touches them.
final class MemoryStagingFiles: StagingFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: Data] = [:]
    private var failingWrites: Set<String> = []
    private var failingReads = false
    private(set) var removed: [String] = []

    func write(_ data: Data, to name: String) throws {
        try lock.withLock {
            if failingWrites.contains(name) || failingWrites.contains("*") { throw FakeFailure() }
            contents[name] = data
        }
    }

    func read(_ name: String) throws -> Data? {
        try lock.withLock {
            if failingReads { throw FakeFailure() }
            return contents[name]
        }
    }

    func remove(_ name: String) throws {
        lock.withLock {
            removed.append(name)
            contents[name] = nil
        }
    }

    func names() throws -> [String] { lock.withLock { Array(contents.keys) } }

    func url(for name: String) -> URL { URL(fileURLWithPath: "/staging").appendingPathComponent(name) }

    func failWrites(to name: String) { lock.withLock { _ = failingWrites.insert(name) } }
    func allowWrites() { lock.withLock { failingWrites.removeAll() } }
    /// Every read fails, as before the first unlock after a restart.
    func failReads(_ failing: Bool) { lock.withLock { failingReads = failing } }
    func contents(of name: String) -> Data? { lock.withLock { contents[name] } }
    func put(_ name: String, _ data: Data = Data([1])) { lock.withLock { contents[name] = data } }
    func has(_ name: String) -> Bool { lock.withLock { contents[name] != nil } }
    var photoNames: [String] { lock.withLock { contents.keys.filter { $0 != StagingStore.manifestName }.sorted() } }
}

/// Answers by the photo's bytes: the test stages each photo's data as its key. Counts reads and the
/// most at once.
actor FakeRecognizer: PhotoRecognizer {
    private let files: MemoryStagingFiles
    private let readings: [String: PhotoReading]
    private var failuresLeft: [String: Int]
    private(set) var reads = 0
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0
    private var cancelAfter: Int?

    init(files: MemoryStagingFiles, readings: [String: PhotoReading], failures: [String: Int] = [:], cancelAfter: Int? = nil) {
        self.files = files
        self.readings = readings
        failuresLeft = failures
        self.cancelAfter = cancelAfter
    }

    struct Unreadable: Error {}

    func read(_ file: URL) async throws -> PhotoReading {
        reads += 1
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
        if let limit = cancelAfter, reads > limit { throw CancellationError() }
        guard let data = try files.read(file.lastPathComponent) else { throw Unreadable() }
        let key = String(decoding: data, as: UTF8.self)
        if let left = failuresLeft[key], left > 0 {
            failuresLeft[key] = left - 1
            throw Unreadable()
        }
        return readings[key] ?? PhotoReading()
    }
}

/// A lookup with set answers per barcode, counting calls.
actor FakeLookup: ProductLookupService {
    private var answers: [GTIN: ProductLookupResult]
    private(set) var calls: [GTIN] = []

    init(_ answers: [GTIN: ProductLookupResult]) { self.answers = answers }

    func set(_ answer: ProductLookupResult, for barcode: GTIN) { answers[barcode] = answer }

    func lookUp(_ barcode: GTIN) async -> ProductLookupResult {
        calls.append(barcode)
        return answers[barcode] ?? .notFound
    }
}

enum IntakeFixture {
    static func gtin(_ twelve: String) -> GTIN {
        let digits = twelve.compactMap(\.wholeNumberValue)
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return GTIN("0" + twelve + String((10 - sum % 10) % 10))!
    }

    static let yogurt = gtin("400638133393")
    static let beans = gtin("501234567890")

    static func line(_ text: String, row: Double = 0.2, size: Double = 0.1) -> RecognizedTextLine {
        RecognizedTextLine(text: text, box: NormalizedBox(x: 0.1, y: row, width: 0.7, height: size), confidence: 0.9)!
    }

    /// Front of yogurt, back of yogurt with its barcode and a date, and a bag of rice.
    static let readings: [String: PhotoReading] = [
        "yogurt-front": PhotoReading(lines: [line("CHOBANI", row: 0.1, size: 0.09), line("GREEK YOGURT")]),
        "yogurt-back": PhotoReading(
            lines: [line("Chobani greek yogurt", row: 0.1, size: 0.03), line("USE BY 11/20/2026", row: 0.8, size: 0.02)],
            codes: [.product(yogurt)]
        ),
        "rice": PhotoReading(lines: [line("Basmati rice")]),
        "beans": PhotoReading(lines: [line("Black beans")], codes: [.product(beans)]),
    ]
}
