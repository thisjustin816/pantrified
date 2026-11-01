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
    private var writesLeft: Int?
    private(set) var removed: [String] = []
    private var written: [String: Int] = [:]

    func write(_ data: Data, to name: String) throws {
        try lock.withLock {
            if failingWrites.contains(name) || failingWrites.contains("*") { throw FakeFailure() }
            if let left = writesLeft {
                guard left > 0 else { throw FakeFailure() }
                writesLeft = left - 1
            }
            contents[name] = data
            written[name, default: 0] += data.count
        }
    }

    /// Bytes written to a file so far, over every write.
    func bytesWritten(to name: String) -> Int { lock.withLock { written[name] ?? 0 } }

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
    func allowWrites() {
        lock.withLock {
            failingWrites.removeAll()
            writesLeft = nil
        }
    }
    /// Lets this many more writes through, then fails every write.
    func failWrites(after count: Int) { lock.withLock { writesLeft = count } }
    /// Every read fails, as before the first unlock after a restart.
    func failReads(_ failing: Bool) { lock.withLock { failingReads = failing } }
    func contents(of name: String) -> Data? { lock.withLock { contents[name] } }
    func put(_ name: String, _ data: Data = Data([1])) { lock.withLock { contents[name] = data } }
    func has(_ name: String) -> Bool { lock.withLock { contents[name] != nil } }
    var photoNames: [String] {
        lock.withLock { contents.keys.filter { $0 != StagingStore.manifestName && !$0.hasSuffix(".json") }.sorted() }
    }
    var observationNames: [String] { lock.withLock { contents.keys.filter { $0.hasSuffix(".read.json") }.sorted() } }
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

/// Stands for a read that takes the app down with it: reading a photo whose bytes are `crash` never
/// returns, as if the process had died inside the recognizer. Other photos read as `FakeRecognizer`.
actor CrashingRecognizer: PhotoRecognizer {
    private let files: MemoryStagingFiles
    private var stuck: [CheckedContinuation<Void, Never>] = []
    private(set) var reads: [String] = []

    init(files: MemoryStagingFiles) { self.files = files }

    var crashes: Int { stuck.count }

    func read(_ file: URL) async throws -> PhotoReading {
        let key = try files.read(file.lastPathComponent).map { String(decoding: $0, as: UTF8.self) } ?? ""
        reads.append(key)
        if key == "crash" { await withCheckedContinuation { stuck.append($0) } }
        return IntakeFixture.readings[key] ?? PhotoReading()
    }
}

/// Waits, without sleeping, until `condition` holds, yielding to other tasks in between.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<100_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

/// A lookup with set answers per barcode, counting calls.
actor FakeLookup: ProductLookupService {
    private var answers: [GTIN: ProductLookupResult]
    private(set) var calls: [GTIN] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(_ answers: [GTIN: ProductLookupResult]) { self.answers = answers }

    func set(_ answer: ProductLookupResult, for barcode: GTIN) { answers[barcode] = answer }

    func lookUp(_ barcode: GTIN) async -> ProductLookupResult {
        calls.append(barcode)
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        await Task.yield()
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

/// Holds callers until a test lets them go, by key. A held caller that is cancelled is let go at once
/// with a `CancellationError`, and counted.
actor KeyedGate<Key: Hashable & Sendable> {
    private var open: Set<Key> = []
    private var allOpen = false
    private var held: [Key: [(id: Int, continuation: CheckedContinuation<Void, any Error>)]] = [:]
    private var lastID = 0
    private(set) var cancellations = 0

    func pass(_ key: Key) async throws {
        if allOpen || open.contains(key) { return }
        lastID += 1
        let id = lastID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancellations += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    held[key, default: []].append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ key: Key) {
        open.insert(key)
        for waiter in held.removeValue(forKey: key) ?? [] { waiter.continuation.resume() }
    }

    func releaseAll() {
        allOpen = true
        for waiters in held.values { for waiter in waiters { waiter.continuation.resume() } }
        held = [:]
    }

    var waiting: Int { held.values.reduce(0) { $0 + $1.count } }

    private func cancel(_ id: Int) {
        for (key, waiters) in held {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { continue }
            held[key]?.remove(at: index)
            cancellations += 1
            waiters[index].continuation.resume(throwing: CancellationError())
            return
        }
    }
}

/// Reads like `FakeRecognizer`, but each photo waits at a gate keyed by its bytes until the test
/// lets it through. Counts reads and the most at once.
actor GatedRecognizer: PhotoRecognizer {
    private let files: MemoryStagingFiles
    private let readings: [String: PhotoReading]
    let gate = KeyedGate<String>()
    private(set) var reads: [String] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(files: MemoryStagingFiles, readings: [String: PhotoReading] = IntakeFixture.readings) {
        self.files = files
        self.readings = readings
    }

    func read(_ file: URL) async throws -> PhotoReading {
        let key = try files.read(file.lastPathComponent).map { String(decoding: $0, as: UTF8.self) } ?? ""
        reads.append(key)
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        try await gate.pass(key)
        return readings[key] ?? PhotoReading()
    }
}

/// A lookup whose answers wait at a gate keyed by barcode. Counts calls and the most at once. A
/// cancelled call answers `.failed(.cancelled)`, as the real service does.
actor GatedLookup: ProductLookupService {
    private var answers: [GTIN: ProductLookupResult]
    let gate = KeyedGate<GTIN>()
    private(set) var calls: [GTIN] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(_ answers: [GTIN: ProductLookupResult] = [:], open: Bool = false) {
        self.answers = answers
        if open { Task { [gate] in await gate.releaseAll() } }
    }

    func set(_ answer: ProductLookupResult, for barcode: GTIN) { answers[barcode] = answer }

    func lookUp(_ barcode: GTIN) async -> ProductLookupResult {
        calls.append(barcode)
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        do { try await gate.pass(barcode) } catch { return .failed(.cancelled) }
        return answers[barcode] ?? .notFound
    }
}
