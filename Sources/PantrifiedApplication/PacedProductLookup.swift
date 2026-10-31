import Foundation
import PantrifiedDomain

/// Every number that paces product lookups. FoodData Central documents a default of 1,000 requests
/// an hour per IP address for a registered key, and a key that goes over is blocked for an hour.
/// A key's real limit can be higher, so pacing follows the allowance the provider reports with each
/// answer rather than a fixed figure.
public enum LookupPacing {
    /// The pause after a rate-limited answer with no usable Retry-After: the block FoodData Central
    /// documents.
    public static let defaultPause: TimeInterval = 3_600
    /// Bounds on any pause, whether a provider asked for it or it was read back after a launch. A
    /// pause past `longestPause` is treated as a mistake, such as a clock that moved, and ignored.
    public static let shortestPause: TimeInterval = 1
    public static let longestPause: TimeInterval = 86_400
    /// The pause once the provider reports no requests left, because the next one would be refused
    /// and block the key for an hour. Shorter than that block, since how the allowance refills is
    /// not documented.
    public static let exhaustedPause: TimeInterval = 600
    /// Lookups sent at once. More wait their turn.
    public static let mostInFlight = 3
    /// The least time between the starts of two requests.
    public static let minimumSpacing: TimeInterval = 1
    /// The time between request starts once the reported allowance is at or below `remaining`. A
    /// start every 6 seconds is 600 an hour, under the documented default of 1,000, so a long batch
    /// cannot spend the rest of an allowance in a few minutes.
    public static let lowAllowance: (remaining: Int, spacing: TimeInterval) = (100, 6)
    public static let veryLowAllowance: (remaining: Int, spacing: TimeInterval) = (20, 30)

    /// The time between request starts with this many requests reported left, or with no report.
    public static func spacing(remaining: Int?) -> TimeInterval {
        guard let remaining else { return minimumSpacing }
        if remaining <= veryLowAllowance.remaining { return veryLowAllowance.spacing }
        if remaining <= lowAllowance.remaining { return lowAllowance.spacing }
        return minimumSpacing
    }

    /// A provider's Retry-After as a pause: nil when it is missing, negative or not finite,
    /// otherwise held between `shortestPause` and `longestPause`.
    public static func pause(retryAfter: TimeInterval?) -> TimeInterval? {
        guard let retryAfter, retryAfter.isFinite, retryAfter >= 0 else { return nil }
        return min(max(retryAfter, shortestPause), longestPause)
    }
}

/// Remembers when lookups may resume, so a pause outlasts the app being closed. It holds one time
/// and nothing else. It never throws: what it cannot read is nil, and a failed save only means the
/// pause is not remembered.
public protocol LookupPauseStore: Sendable {
    func load() -> Date?
    /// Saves the time, or forgets it when nil.
    func save(_ resumesAt: Date?)
}

/// Wraps a lookup so the provider is asked no more often than it allows (`LookupPacing`).
///
/// - After a rate-limited answer it sends nothing until the pause ends, answering at once with
///   `.failed(.rateLimited(resumesAt:))`. The pause is the provider's Retry-After when usable,
///   otherwise `defaultPause`, and is saved to the store so a relaunch keeps it. A saved time that
///   has passed, or is further ahead than `longestPause`, is ignored.
/// - Requests start at least `minimumSpacing` apart, further apart as the reported allowance runs
///   low, and not at all for `exhaustedPause` once it reports none left.
/// - At most `mostInFlight` lookups run at once; one barcode already being looked up is shared by
///   every caller asking for it. A caller that is cancelled while waiting gets `.cancelled` at once,
///   and the request is cancelled when no caller is left waiting for it.
public actor PacedProductLookup: ProductLookupService {
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let inner: any RateLimitReportingLookup
    private let store: (any LookupPauseStore)?
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    private var loaded = false
    /// When lookups may resume after a pause, the same time the store holds.
    private var resumesAt: Date?
    /// The allowance the provider last reported.
    private var remaining: Int?
    private var lastStart: Date?
    private var running = 0
    private var slotQueue: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var shared: [GTIN: Shared] = [:]
    private var lastID = 0

    /// One barcode's lookup and the callers waiting for it.
    private struct Shared {
        let id: Int
        var waiters: [Int: CheckedContinuation<ProductLookupResult, Never>] = [:]
        var task: Task<Void, Never>?
    }

    public init(
        inner: any RateLimitReportingLookup,
        store: (any LookupPauseStore)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.inner = inner
        self.store = store
        self.now = now
        self.sleep = sleep
    }

    public func lookUp(_ barcode: GTIN) async -> ProductLookupResult {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        if let pause = currentPause() { return .failed(.rateLimited(resumesAt: pause)) }
        let entry: Int
        if let existing = shared[barcode] {
            entry = existing.id
        } else {
            entry = nextID()
            shared[barcode] = Shared(id: entry)
            shared[barcode]?.task = Task { await self.run(barcode, entry: entry) }
        }
        let waiter = nextID()
        // Registering happens in this same actor turn, so `leave` always runs after it.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard shared[barcode]?.id == entry else {
                    continuation.resume(returning: .failed(.cancelled))
                    return
                }
                shared[barcode]?.waiters[waiter] = continuation
            }
        } onCancel: {
            Task { await self.leave(barcode, entry: entry, waiter: waiter) }
        }
    }

    private func nextID() -> Int {
        lastID += 1
        return lastID
    }

    private func leave(_ barcode: GTIN, entry: Int, waiter: Int) {
        guard var record = shared[barcode], record.id == entry,
              let continuation = record.waiters.removeValue(forKey: waiter)
        else { return }
        continuation.resume(returning: .failed(.cancelled))
        if record.waiters.isEmpty {
            shared[barcode] = nil
            record.task?.cancel()
        } else {
            shared[barcode] = record
        }
    }

    private func run(_ barcode: GTIN, entry: Int) async {
        let result = await paced(barcode)
        guard let record = shared[barcode], record.id == entry else { return }
        shared[barcode] = nil
        for waiter in record.waiters.values { waiter.resume(returning: result) }
    }

    private func paced(_ barcode: GTIN) async -> ProductLookupResult {
        guard await acquireSlot() else { return .failed(.cancelled) }
        defer { releaseSlot() }
        if let pause = currentPause() { return .failed(.rateLimited(resumesAt: pause)) }
        let wait = reserveStart()
        if wait > 0 {
            do { try await sleep(wait) } catch { return .failed(.cancelled) }
        }
        guard !Task.isCancelled else { return .failed(.cancelled) }
        // Another request may have been refused while this one waited.
        if let pause = currentPause() { return .failed(.rateLimited(resumesAt: pause)) }
        return record(await inner.lookUpReportingRateLimit(barcode))
    }

    // MARK: Pauses

    /// When lookups resume, or nil when they are not paused.
    private func currentPause() -> Date? {
        if !loaded {
            loaded = true
            if let saved = store?.load() {
                if Self.isUsable(saved, at: now()) { resumesAt = saved } else { store?.save(nil) }
            }
        }
        guard let resumesAt else { return nil }
        let time = now()
        if Self.isUsable(resumesAt, at: time) { return resumesAt }
        if resumesAt > time {
            // Further ahead than any pause can be, so the clock moved: forget it.
            self.resumesAt = nil
            store?.save(nil)
        }
        return nil
    }

    private static func isUsable(_ resumesAt: Date, at time: Date) -> Bool {
        let left = resumesAt.timeIntervalSince(time)
        return left > 0 && left <= LookupPacing.longestPause
    }

    /// Notes what the provider said and turns a refusal into a pause.
    private func record(_ reply: ReportedLookup) -> ProductLookupResult {
        let time = now()
        if case .failed(.rateLimited) = reply.result {
            let pause = LookupPacing.pause(retryAfter: reply.rateLimit.retryAfter) ?? LookupPacing.defaultPause
            return .failed(.rateLimited(resumesAt: pauseLookups(until: time.addingTimeInterval(pause))))
        }
        if let remaining = reply.rateLimit.remaining, remaining >= 0 {
            self.remaining = remaining
            if remaining == 0 { pauseLookups(until: time.addingTimeInterval(LookupPacing.exhaustedPause)) }
        }
        switch reply.result {
        case .found, .notFound:
            // The provider answered after a pause ended, so there is nothing left to remember.
            if let resumesAt, resumesAt <= time {
                self.resumesAt = nil
                store?.save(nil)
            }
        case .failed:
            break
        }
        return reply.result
    }

    /// Starts a pause, or keeps the current one when it ends later. Returns when lookups resume.
    @discardableResult
    private func pauseLookups(until date: Date) -> Date {
        if let current = currentPause(), current >= date { return current }
        resumesAt = date
        store?.save(date)
        return date
    }

    // MARK: Spacing and slots

    /// Books the next request start and returns how long to wait for it.
    private func reserveStart() -> TimeInterval {
        let time = now()
        let gap = LookupPacing.spacing(remaining: remaining)
        var start = time
        if let lastStart, lastStart.addingTimeInterval(gap) > time {
            // Each request in flight has booked at most one gap, so a later start means the clock moved.
            start = min(lastStart.addingTimeInterval(gap), time.addingTimeInterval(gap * Double(LookupPacing.mostInFlight)))
        }
        lastStart = start
        return start.timeIntervalSince(time)
    }

    private func acquireSlot() async -> Bool {
        if running < LookupPacing.mostInFlight {
            running += 1
            return true
        }
        let id = nextID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                slotQueue.append((id, continuation))
            }
        } onCancel: {
            Task { await self.abandonSlot(id) }
        }
    }

    private func abandonSlot(_ id: Int) {
        guard let index = slotQueue.firstIndex(where: { $0.id == id }) else { return }
        slotQueue.remove(at: index).continuation.resume(returning: false)
    }

    /// Hands the slot to the longest waiting lookup, or frees it.
    private func releaseSlot() {
        if slotQueue.isEmpty {
            running -= 1
        } else {
            slotQueue.removeFirst().continuation.resume(returning: true)
        }
    }

    /// What is waiting, for tests: lookups queued for a slot, and callers per barcode.
    var waiting: (forSlot: Int, perBarcode: [GTIN: Int]) {
        (slotQueue.count, shared.mapValues(\.waiters.count))
    }
}
