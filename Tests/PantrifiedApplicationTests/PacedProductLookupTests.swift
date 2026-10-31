import Foundation
import Testing
@testable import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let cola = GTIN("036000291452")!
private let pencils = GTIN("4006381333931")!
private let codes = ["036000291452", "4006381333931", "012000001772", "044700063491", "5000112637922"].map { GTIN($0)! }
private let suggestion = ProductSuggestion(name: "Cola", source: "Test")
private let tooMany = ReportedLookup(.failed(.rateLimited(resumesAt: nil)))

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = t0

    var now: Date { lock.withLock { time } }
    func set(_ date: Date) { lock.withLock { time = date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// Records each wait and moves the clock by it at once, so spacing is checked without waiting.
private final class AdvancingSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private var waits: [TimeInterval] = []

    init(_ clock: TestClock) { self.clock = clock }

    var recorded: [TimeInterval] { lock.withLock { waits } }

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        lock.withLock { waits.append(seconds) }
        clock.advance(seconds)
    }
}

/// Holds every wait until released, and throws when the waiting task is cancelled.
private actor HeldSleeper {
    private var held: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var lastID = 0

    var waiting: Int { held.count }

    func sleep(_ seconds: TimeInterval) async throws {
        lastID += 1
        let id = lastID
        let released = await withTaskCancellationHandler {
            await withCheckedContinuation { held[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        if !released { throw CancellationError() }
    }

    private func cancel(_ id: Int) { held.removeValue(forKey: id)?.resume(returning: false) }

    func releaseAll() {
        for waiter in held.values { waiter.resume(returning: true) }
        held = [:]
    }
}

/// Answers from a script, counts calls and how many run at once, and can hold a barcode's calls
/// until it is released.
private actor ScriptedLookup: RateLimitReportingLookup {
    private var replies: [GTIN: [ReportedLookup]]
    private let fallback: ReportedLookup
    private var holding: Set<GTIN>
    private var held: [GTIN: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls: [GTIN] = []
    private(set) var mostAtOnce = 0
    private var running = 0

    init(_ replies: [GTIN: [ReportedLookup]] = [:], otherwise fallback: ReportedLookup = ReportedLookup(.found(suggestion)), holding: Set<GTIN> = []) {
        self.replies = replies
        self.fallback = fallback
        self.holding = holding
    }

    func lookUpReportingRateLimit(_ barcode: GTIN) async -> ReportedLookup {
        calls.append(barcode)
        running += 1
        mostAtOnce = max(mostAtOnce, running)
        if holding.contains(barcode) {
            await withCheckedContinuation { held[barcode, default: []].append($0) }
        }
        running -= 1
        guard var queue = replies[barcode], !queue.isEmpty else { return fallback }
        let reply = queue.removeFirst()
        replies[barcode] = queue
        return reply
    }

    func then(_ reply: ReportedLookup, for barcode: GTIN) { replies[barcode, default: []].append(reply) }

    func release(_ barcode: GTIN) {
        holding.remove(barcode)
        for waiter in held.removeValue(forKey: barcode) ?? [] { waiter.resume() }
    }

    func releaseAll() {
        for barcode in Array(holding) { release(barcode) }
    }

    func calls(for barcode: GTIN) -> Int { calls.filter { $0 == barcode }.count }
}

/// Keeps the saved time in memory and records every save.
private final class MemoryPauseStore: LookupPauseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?
    private var saves: [Date?] = []

    init(_ stored: Date? = nil) { self.stored = stored }

    var value: Date? { lock.withLock { stored } }
    var saved: [Date?] { lock.withLock { saves } }

    func load() -> Date? { lock.withLock { stored } }
    func save(_ resumesAt: Date?) {
        lock.withLock {
            stored = resumesAt
            saves.append(resumesAt)
        }
    }
}

/// Checks a condition until it holds, yielding between tries. No clock is involved; it gives up
/// after a fixed number of tries so a broken pacing fails rather than hangs.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<20_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func paced(
    _ inner: ScriptedLookup, store: (any LookupPauseStore)? = nil, clock: TestClock = TestClock(),
    sleeper: AdvancingSleeper? = nil
) -> PacedProductLookup {
    let sleeper = sleeper ?? AdvancingSleeper(clock)
    return PacedProductLookup(inner: inner, store: store, now: { clock.now }, sleep: { try await sleeper.sleep($0) })
}

private func paused(_ seconds: TimeInterval) -> ProductLookupResult {
    .failed(.rateLimited(resumesAt: t0.addingTimeInterval(seconds)))
}

@Suite("Paced product lookup")
struct PacedProductLookupTests {
    // MARK: Pausing after a rate limit

    @Test("a 429 pauses lookups for an hour without a Retry-After; nothing is sent until then")
    func pauseWithoutRetryAfter() async {
        let clock = TestClock()
        let inner = ScriptedLookup([cola: [tooMany]])
        let lookup = paced(inner, clock: clock)

        #expect(await lookup.lookUp(cola) == paused(3_600))
        clock.advance(1_800)
        #expect(await lookup.lookUp(cola) == paused(3_600))
        #expect(await lookup.lookUp(pencils) == paused(3_600))
        clock.set(t0.addingTimeInterval(3_599.999))
        #expect(await lookup.lookUp(pencils) == paused(3_600))
        #expect(await inner.calls == [cola])

        clock.set(t0.addingTimeInterval(3_600))
        #expect(await lookup.lookUp(pencils) == .found(suggestion))
        #expect(await inner.calls == [cola, pencils])
    }

    @Test("a sane Retry-After sets the pause, and anything else falls back to an hour or is held to a day", arguments: [
        (120.0 as TimeInterval?, 120.0 as TimeInterval),
        (1, 1),
        (0, 1),
        (0.2, 1),
        (86_400, 86_400),
        (1e9, 86_400),
        (nil, 3_600),
        (-5, 3_600),
        (-.infinity, 3_600),
        (.infinity, 3_600),
        (.nan, 3_600),
    ])
    func retryAfter(retryAfter: TimeInterval?, pause: TimeInterval) async {
        let clock = TestClock()
        let inner = ScriptedLookup([cola: [ReportedLookup(.failed(.rateLimited(resumesAt: nil)), rateLimit: RateLimitReport(retryAfter: retryAfter))]])
        let lookup = paced(inner, clock: clock)

        #expect(await lookup.lookUp(cola) == paused(pause))
        clock.set(t0.addingTimeInterval(pause).addingTimeInterval(-0.001))
        #expect(await lookup.lookUp(cola) == paused(pause))
        clock.set(t0.addingTimeInterval(pause))
        #expect(await lookup.lookUp(cola) == .found(suggestion))
        #expect(await inner.calls(for: cola) == 2)
    }

    @Test("a failure other than a rate limit starts no pause", arguments: [
        ProductLookupFailure.offline, .timedOut, .keyRejected, .providerError, .cancelled,
    ])
    func otherFailures(failure: ProductLookupFailure) async {
        let store = MemoryPauseStore()
        let inner = ScriptedLookup([cola: [ReportedLookup(.failed(failure), rateLimit: RateLimitReport(retryAfter: 600))]])
        let lookup = paced(inner, store: store)

        #expect(await lookup.lookUp(cola) == .failed(failure))
        #expect(await lookup.lookUp(cola) == .found(suggestion))
        #expect(await inner.calls(for: cola) == 2)
        #expect(store.saved.isEmpty)
    }

    @Test("an answer after the pause ends clears the saved time")
    func answerClearsPause() async {
        let clock = TestClock()
        let store = MemoryPauseStore()
        let inner = ScriptedLookup([cola: [tooMany]])
        let lookup = paced(inner, store: store, clock: clock)

        #expect(await lookup.lookUp(cola) == paused(3_600))
        #expect(store.value == t0.addingTimeInterval(3_600))
        clock.advance(3_600)
        #expect(await lookup.lookUp(cola) == .found(suggestion))
        #expect(store.value == nil)
        #expect(store.saved == [t0.addingTimeInterval(3_600), nil])
    }

    @Test("an answer to a request sent before a pause began does not end the pause")
    func earlierAnswerKeepsPause() async {
        let store = MemoryPauseStore()
        let inner = ScriptedLookup([cola: [tooMany]], holding: [pencils])
        let lookup = paced(inner, store: store)

        let early = Task { await lookup.lookUp(pencils) }
        #expect(await eventually { await inner.calls == [pencils] })
        #expect(await lookup.lookUp(cola) == paused(3_601))
        await inner.release(pencils)
        #expect(await early.value == .found(suggestion))

        #expect(await lookup.lookUp(cola) == paused(3_601))
        #expect(store.value == t0.addingTimeInterval(3_601))
        #expect(await inner.calls == [pencils, cola])
    }

    @Test("a lookup waiting for its turn when a pause begins sends nothing")
    func pauseReachesWaitingLookup() async {
        let clock = TestClock()
        let sleeper = HeldSleeper()
        let inner = ScriptedLookup([cola: [tooMany]], holding: [cola])
        let lookup = PacedProductLookup(inner: inner, now: { clock.now }, sleep: { try await sleeper.sleep($0) })

        let first = Task { await lookup.lookUp(cola) }
        #expect(await eventually { await inner.calls == [cola] })
        let second = Task { await lookup.lookUp(pencils) }
        #expect(await eventually { await sleeper.waiting == 1 })
        await inner.release(cola)
        #expect(await first.value == paused(3_600))
        await sleeper.releaseAll()

        #expect(await second.value == paused(3_600))
        #expect(await inner.calls == [cola])
    }

    // MARK: Remembering a pause

    @Test("a pause survives a new instance, as after a relaunch")
    func pauseSurvivesRelaunch() async {
        let clock = TestClock()
        let store = MemoryPauseStore()
        #expect(await paced(ScriptedLookup([cola: [tooMany]]), store: store, clock: clock).lookUp(cola) == paused(3_600))

        clock.advance(60)
        let inner = ScriptedLookup()
        let relaunched = paced(inner, store: store, clock: clock)
        #expect(await relaunched.lookUp(pencils) == paused(3_600))
        #expect(await inner.calls.isEmpty)

        clock.set(t0.addingTimeInterval(3_600))
        #expect(await relaunched.lookUp(pencils) == .found(suggestion))
    }

    @Test("a pause saved to a file survives a new instance")
    func pauseSurvivesRelaunchInFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = LookupPauseFile(file: directory.appendingPathComponent("nested").appendingPathComponent("lookup-resumes-at"))
        let clock = TestClock()
        #expect(await paced(ScriptedLookup([cola: [tooMany]]), store: file, clock: clock).lookUp(cola) == paused(3_600))
        #expect(try String(contentsOf: file.file, encoding: .utf8) == "1800003600")

        clock.advance(60)
        let inner = ScriptedLookup()
        #expect(await paced(inner, store: LookupPauseFile(file: file.file), clock: clock).lookUp(cola) == paused(3_600))
        #expect(await inner.calls.isEmpty)
    }

    @Test("a saved time that has passed, or is further ahead than a day, is no pause and is forgotten", arguments: [
        t0.addingTimeInterval(-1),
        t0,
        Date(timeIntervalSince1970: 0),
        t0.addingTimeInterval(86_400.001),
        t0.addingTimeInterval(10 * 86_400),
        Date.distantFuture,
    ])
    func unusableSavedTime(saved: Date) async {
        let store = MemoryPauseStore(saved)
        let inner = ScriptedLookup()

        #expect(await paced(inner, store: store).lookUp(cola) == .found(suggestion))
        #expect(await inner.calls == [cola])
        #expect(store.value == nil)
    }

    @Test("a saved time within a day is a pause")
    func usableSavedTime() async {
        let inner = ScriptedLookup()
        #expect(await paced(inner, store: MemoryPauseStore(t0.addingTimeInterval(86_400))).lookUp(cola) == paused(86_400))
        #expect(await paced(inner, store: MemoryPauseStore(t0.addingTimeInterval(1))).lookUp(cola) == paused(1))
        #expect(await inner.calls.isEmpty)
    }

    @Test("a pause that is suddenly more than a day away, because the clock moved back, is forgotten")
    func clockMovedBack() async {
        let clock = TestClock()
        let store = MemoryPauseStore()
        let inner = ScriptedLookup([cola: [tooMany]])
        let lookup = paced(inner, store: store, clock: clock)

        #expect(await lookup.lookUp(cola) == paused(3_600))
        clock.set(t0.addingTimeInterval(-86_400))
        #expect(await lookup.lookUp(cola) == .found(suggestion))
        #expect(store.value == nil)
    }

    @Test("an unreadable pause file is no pause", arguments: [
        "", "abc", "-5", "1e10", "1800003600\n", " 1800003600", "+1800003600", "1800003600.0", "\u{0661}\u{0668}",
        "180000360000",
    ])
    func corruptFile(text: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("lookup-resumes-at")
        try Data(text.utf8).write(to: file)
        let inner = ScriptedLookup()

        #expect(await paced(inner, store: LookupPauseFile(file: file)).lookUp(cola) == .found(suggestion))
        #expect(await inner.calls == [cola])
    }

    // MARK: Spacing

    @Test("requests start at least a second apart, further apart as the allowance runs low")
    func spacing() async {
        let clock = TestClock()
        let sleeper = AdvancingSleeper(clock)
        let inner = ScriptedLookup()
        let lookup = paced(inner, clock: clock, sleeper: sleeper)
        let reports: [Int?] = [nil, 500, 101, 100, 21, 20, 1, 3_593, nil]
        for remaining in reports {
            await inner.then(ReportedLookup(.found(suggestion), rateLimit: RateLimitReport(remaining: remaining)), for: cola)
        }

        for _ in reports {
            #expect(await lookup.lookUp(cola) == .found(suggestion))
        }

        // The first request waits for nothing; each later one for the gap the previous report set.
        // No report keeps the last one.
        #expect(sleeper.recorded == [1, 1, 1, 6, 6, 30, 30, 1])
        #expect(await inner.calls.count == reports.count)
    }

    @Test("time already passed counts toward the gap")
    func spacingCountsElapsedTime() async {
        let clock = TestClock()
        let sleeper = AdvancingSleeper(clock)
        let inner = ScriptedLookup([cola: [ReportedLookup(.found(suggestion), rateLimit: RateLimitReport(remaining: 20))]])
        let lookup = paced(inner, clock: clock, sleeper: sleeper)

        _ = await lookup.lookUp(cola)
        clock.advance(25)
        _ = await lookup.lookUp(cola)
        clock.advance(31)
        _ = await lookup.lookUp(cola)

        #expect(sleeper.recorded == [5])
    }

    @Test("an allowance reported as used up pauses lookups for ten minutes")
    func exhaustedAllowance() async {
        let store = MemoryPauseStore()
        let inner = ScriptedLookup([cola: [ReportedLookup(.found(suggestion), rateLimit: RateLimitReport(remaining: 0))]])
        let lookup = paced(inner, store: store)

        #expect(await lookup.lookUp(cola) == .found(suggestion))
        #expect(await lookup.lookUp(pencils) == paused(600))
        #expect(store.value == t0.addingTimeInterval(600))
        #expect(await inner.calls == [cola])
    }

    @Test("the spacing thresholds", arguments: [
        (nil as Int?, 1.0 as TimeInterval), (10_000_000, 1), (101, 1), (100, 6), (21, 6), (20, 30), (0, 30),
    ])
    func thresholds(remaining: Int?, spacing: TimeInterval) {
        #expect(LookupPacing.spacing(remaining: remaining) == spacing)
    }

    // MARK: Concurrency

    @Test("at most three lookups run at once; the rest wait their turn")
    func mostInFlight() async {
        let inner = ScriptedLookup(holding: Set(codes))
        let lookup = paced(inner)

        let tasks = codes.map { code in Task { await lookup.lookUp(code) } }
        #expect(await eventually {
            let calls = await inner.calls.count
            let queued = await lookup.waiting.forSlot
            return calls == 3 && queued == 2
        })
        #expect(await inner.calls.count == 3)

        await inner.releaseAll()
        for task in tasks { #expect(await task.value == .found(suggestion)) }
        #expect(await inner.calls.count == 5)
        #expect(await inner.mostAtOnce == 3)
    }

    @Test("callers asking for a barcode already being looked up share that one request")
    func sharedRequest() async {
        let inner = ScriptedLookup(holding: [cola])
        let lookup = paced(inner)

        let tasks = (0..<3).map { _ in Task { await lookup.lookUp(cola) } }
        let other = Task { await lookup.lookUp(pencils) }
        #expect(await eventually {
            let calls = await inner.calls
            let sharing = await lookup.waiting.perBarcode[cola]
            return sharing == 3 && calls.contains(cola)
        })
        #expect(await other.value == .found(suggestion))
        await inner.release(cola)

        for task in tasks { #expect(await task.value == .found(suggestion)) }
        #expect(await inner.calls(for: cola) == 1)
        #expect(await lookup.waiting.perBarcode.isEmpty)
    }

    @Test("a cancelled lookup waiting for a turn returns at once and sends nothing")
    func cancelWhileQueued() async {
        let inner = ScriptedLookup(holding: Set(codes))
        let lookup = paced(inner)

        let running = codes.prefix(3).map { code in Task { await lookup.lookUp(code) } }
        #expect(await eventually { await inner.calls.count == 3 })
        let queued = Task { await lookup.lookUp(codes[3]) }
        #expect(await eventually { await lookup.waiting.forSlot == 1 })

        queued.cancel()
        #expect(await queued.value == .failed(.cancelled))
        #expect(await eventually { await lookup.waiting.forSlot == 0 })

        await inner.releaseAll()
        for task in running { #expect(await task.value == .found(suggestion)) }
        #expect(await inner.calls(for: codes[3]) == 0)
    }

    @Test("a cancelled lookup waiting out its spacing returns cancelled and sends nothing")
    func cancelWhileSpacing() async {
        let sleeper = HeldSleeper()
        let inner = ScriptedLookup()
        let lookup = PacedProductLookup(inner: inner, now: { t0 }, sleep: { try await sleeper.sleep($0) })

        #expect(await lookup.lookUp(cola) == .found(suggestion))
        let spaced = Task { await lookup.lookUp(pencils) }
        #expect(await eventually { await sleeper.waiting == 1 })
        spaced.cancel()

        #expect(await spaced.value == .failed(.cancelled))
        #expect(await inner.calls == [cola])
    }

    @Test("one caller giving up leaves a shared request running for the others")
    func cancelOneSharer() async {
        let inner = ScriptedLookup(holding: [cola])
        let lookup = paced(inner)

        let staying = Task { await lookup.lookUp(cola) }
        let leaving = Task { await lookup.lookUp(cola) }
        #expect(await eventually {
            let calls = await inner.calls
            let sharing = await lookup.waiting.perBarcode[cola]
            return sharing == 2 && calls == [cola]
        })
        leaving.cancel()
        #expect(await leaving.value == .failed(.cancelled))
        await inner.release(cola)

        #expect(await staying.value == .found(suggestion))
        #expect(await inner.calls == [cola])
    }

    @Test("a lookup already cancelled sends nothing")
    func alreadyCancelled() async {
        let inner = ScriptedLookup()
        let lookup = paced(inner)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await lookup.lookUp(cola)
        }

        #expect(await task.value == .failed(.cancelled))
        #expect(await inner.calls.isEmpty)
    }
}
