import Foundation
import PantrifiedDomain

/// What a recognizer found in one still photo. The platform adapter cleans nothing; the
/// observation it becomes bounds and cleans everything.
public struct PhotoReading: Sendable, Hashable {
    public var lines: [RecognizedTextLine]
    public var codes: [CodeMeaning]
    public var featurePrint: FeaturePrint?

    public init(lines: [RecognizedTextLine] = [], codes: [CodeMeaning] = [], featurePrint: FeaturePrint? = nil) {
        self.lines = lines
        self.codes = codes
        self.featurePrint = featurePrint
    }
}

/// Reads text, barcodes and a feature print from a staged photo, on the device. It must not save,
/// share or upload the photo, and must not open a link it finds.
public protocol PhotoRecognizer: Sendable {
    func read(_ file: URL) async throws -> PhotoReading
}

/// How far reading a batch has got.
public struct IntakeProgress: Sendable, Hashable {
    public let read: Int
    public let total: Int

    public init(read: Int, total: Int) {
        self.read = read
        self.total = total
    }
}

/// Where one photo of a batch is, for the strip under the camera.
public enum PhotoReadState: Sendable, Hashable {
    case waiting
    case reading
    case read
    case couldNotRead
}

/// What the batch screen shows while photos are taken and read. Tentative until the review exists.
public struct IntakeLiveStatus: Sendable, Hashable {
    public var batch: IntakeBatchID
    public var states: [IntakePhotoID: PhotoReadState]
    public var progress: IntakeProgress
    /// Candidates the photos read so far make. Only a count: grouping is final once every photo is read.
    public var packagesSoFar: Int
    /// Photos whose candidate nothing has joined for a while (`SettlingPolicy`). Only a hint.
    public var settled: Set<IntakePhotoID>
    public var pause: ReadingPause?
    /// Goes up whenever a lookup answer is kept, so a screen showing the review loads it again.
    public var lookupAnswers: Int

    /// Photos not read yet, including those being read.
    public var unread: Int { progress.total - progress.read }
}

/// Reads a batch's photos as they are taken, groups what has been read after each reading, and looks
/// up each barcode as soon as a photo showing it has been read. One pipeline serves the whole app, so
/// a batch is never read by two runs at once.
///
/// - Reading follows `ReadingPolicy`: one photo at a time at low priority while the camera is open,
///   paused while the device is warm, in Low Power Mode or in the background, and two at a time
///   after Done. A photo already read is never read again, and one not read yet is read when the
///   batch opens again, after a kill too.
/// - Grouping for the screen re-runs `PhotoGrouper` over every observation read so far
///   (`LiveGrouping`). The review is made once, when every photo is read, from all of them, so it is
///   the one-shot grouping whatever order the readings arrived in. Until then nothing can be edited,
///   so no edit is ever lost to a regroup.
/// - Lookups go only through the injected `ProductLookupService`, at most `LookupPolicy.inFlight`
///   at once and `LookupPolicy.perPass` per pass, each distinct barcode once a pass. Answers are kept
///   by barcode on the batch, so they attach to whichever candidate forms. A miss is final. Offline
///   or rate limited defers the rest of the pass; a later pass, when the batch opens again or at
///   Done, asks again. Nothing here blocks taking photos, the review or adding.
public actor IntakePipeline {
    private let store: StagingStore
    private let recognizer: any PhotoRecognizer
    private let lookup: (any ProductLookupService)?
    private let grouper: PhotoGrouper
    private let proposer: IntakeProposer
    private let policy: ReadingPolicy
    private let lookupPolicy: LookupPolicy
    private let settling: SettlingPolicy
    private let time: any TimeSource
    /// A photo whose reads fail, crash or are stopped by the system this many times is kept with
    /// nothing read from it, so one bad file cannot stop a batch.
    static let attemptsPerPhoto = 2

    /// The batch being worked on, and a number that changes whenever work on it is stopped, so a read
    /// or lookup from before that changes nothing when it ends.
    private var batch: IntakeBatchID?
    private var generation = 0
    private var cameraOpen = false
    private var conditions = DeviceConditions()
    /// Reads and lookups still running, including cancelled ones until they end, so the limits on
    /// how many run at once, and on decoded photos in memory, always hold.
    private var reading: [IntakePhotoID: Task<Void, Never>] = [:]
    /// Counts reads that ended. A decision made from the store's list of unread photos is made again
    /// when a read ended while that list was fetched, since the list may already be out of date.
    private var readsEnded = 0
    /// Reads and lookups that ended and are still keeping their results or starting the next ones.
    private var ending = 0
    private var lookingUp: [GTIN: Task<Void, Never>] = [:]
    /// Photos whose read stopped, on a storage error or cancelled by the system rather than by this
    /// pipeline. Not tried again until the batch opens again or a new run of `finish` starts, as
    /// Done and Try Again do, so a lasting storage error ends the run.
    private var stalled: Set<IntakePhotoID> = []
    /// A read in `stalled` was cancelled.
    private var interrupted = false
    private var live: LiveGrouping
    private var pass = LookupPass()
    private var lookupAnswers = 0
    private var finishing: Task<IntakeReview, any Error>?
    private var observer: AsyncStream<IntakeLiveStatus>.Continuation?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// One pass of lookups.
    private struct LookupPass {
        var asked: Set<GTIN> = []
        var started = 0
        var answered = 0
        /// Offline or rate limited: the rest of this pass is deferred.
        var paused = false
    }

    private enum ReadOutcome: Sendable {
        case recorded
        case cancelled
        case stopped
    }

    public init(
        store: StagingStore,
        recognizer: any PhotoRecognizer,
        lookup: (any ProductLookupService)?,
        time: any TimeSource,
        grouper: PhotoGrouper = PhotoGrouper(),
        proposer: IntakeProposer = IntakeProposer(),
        policy: ReadingPolicy = .standard,
        lookupPolicy: LookupPolicy = .standard,
        settling: SettlingPolicy = .standard
    ) {
        self.store = store
        self.recognizer = recognizer
        self.lookup = lookup
        self.time = time
        self.grouper = grouper
        self.proposer = proposer
        self.policy = policy
        self.lookupPolicy = lookupPolicy
        self.settling = settling
        live = LiveGrouping(grouper: grouper)
    }

    // MARK: The batch screen

    /// Starts work on a batch: reading what is not read yet, and a new pass of lookups. `capturing`
    /// says the camera is open. Opening the batch already open carries on with it.
    public func open(_ id: IntakeBatchID, capturing: Bool) async {
        if batch != id {
            stop()
            batch = id
            live = LiveGrouping(grouper: grouper)
        }
        stalled = []
        interrupted = false
        cameraOpen = capturing && finishing == nil
        pass = LookupPass()
        await pump()
    }

    /// Updates for the screen, newest first when it falls behind. A new subscriber replaces the last.
    public func updates() -> AsyncStream<IntakeLiveStatus> {
        observer?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: IntakeLiveStatus.self, bufferingPolicy: .bufferingNewest(1))
        observer = continuation
        Task { await publish() }
        return stream
    }

    /// A photo was taken, picked or removed.
    public func photosChanged() async {
        await pump()
    }

    public func setConditions(_ conditions: DeviceConditions) async {
        guard conditions != self.conditions else { return }
        self.conditions = conditions
        wake()
        await pump()
    }

    /// The screen closed and the batch is kept. Reading for the camera stops, since the camera is
    /// gone; after Done, reading carries on to the review.
    public func leave(_ id: IntakeBatchID) {
        guard batch == id, finishing == nil else { return }
        stop()
        batch = nil
    }

    /// The batch is being discarded: everything running for it is cancelled now.
    public func discard(_ id: IntakeBatchID) {
        guard batch == id else { return }
        finishing?.cancel()
        finishing = nil
        stop()
        batch = nil
    }

    // MARK: Done

    /// Done: reads what is left two at a time, then groups the batch once and keeps the review. A
    /// batch that already has a review keeps it, with the person's edits. Returns once the review
    /// exists; closing the screen does not stop it.
    public func finish(_ id: IntakeBatchID, places: PlaceContext) async throws -> IntakeReview {
        if batch != id { await open(id, capturing: false) }
        if let finishing { return try await finishing.value }
        let run = Task { try await self.runFinish(id, places: places) }
        finishing = run
        defer { if finishing == run { finishing = nil } }
        return try await run.value
    }

    /// Reads every photo not read yet, then groups the batch, unless it already has a review.
    public func process(_ id: IntakeBatchID, places: PlaceContext) async throws -> IntakeReview {
        try await finish(id, places: places)
    }

    private func runFinish(_ id: IntakeBatchID, places: PlaceContext) async throws -> IntakeReview {
        let started = generation
        stalled = []
        interrupted = false
        try await store.startProcessing(id)
        if let existing = await store.batch(id)?.review { return existing }
        cameraOpen = false
        pass = LookupPass()
        while true {
            guard generation == started, batch == id else { throw CancellationError() }
            let ended = readsEnded
            await pump()
            let unread = await store.photosToRecognize(in: id).map(\.id)
            guard generation == started, batch == id else { throw CancellationError() }
            if unread.isEmpty { break }
            if readsEnded != ended { continue }
            if let running = reading.values.first {
                await running.value
            } else if policy.pause(cameraOpen: false, conditions: conditions) != nil {
                await waitForChange()
            } else {
                // Every photo left stopped in this run; the next run tries them again.
                throw interrupted ? CancellationError() : StagingError.notRecognized
            }
        }
        guard generation == started, let record = await store.batch(id) else { throw CancellationError() }
        let observations = record.photos.compactMap(\.observation)
        let review = IntakeReview(
            space: record.space, observations: observations, grouping: grouper.group(observations),
            proposer: proposer, places: places, looksUp: lookup != nil
        )
        let kept = try await store.finishRecognition(id, review: review)
        await pump()
        return kept
    }

    /// A review of what has been read so far, for the screen to show, unchangeable, while the last
    /// few photos are read. Never stored.
    public func preview(places: PlaceContext) async -> IntakeReview? {
        guard let id = batch, let record = await store.batch(id) else { return nil }
        if let review = record.review { return review }
        live.sync(with: record.photos.compactMap(\.observation))
        var review = IntakeReview(
            space: record.space, observations: Array(live.observations.values), grouping: live.result,
            proposer: proposer, places: places, looksUp: lookup != nil
        )
        review.useLookups(record.lookups)
        return review
    }

    // MARK: Lookups

    /// Starts a new pass of lookups for the batch and waits for it to end. Returns the answers kept,
    /// not counting deferrals.
    @discardableResult
    public func lookUpNames(_ id: IntakeBatchID) async -> Int {
        if batch != id {
            await open(id, capturing: false)
        } else {
            pass = LookupPass()
            await pumpLookups()
        }
        while let running = lookingUp.values.first { await running.value }
        return pass.answered
    }

    /// Waits until nothing is being read or looked up that can run now. For tests and for the end
    /// of a launch's resume.
    public func settle() async {
        while true {
            await pump()
            if let running = reading.values.first {
                await running.value
            } else if let running = lookingUp.values.first {
                await running.value
            } else if ending > 0 {
                await waitForChange()
            } else {
                return
            }
        }
    }

    // MARK: Work

    private func stop() {
        generation += 1
        for task in reading.values { task.cancel() }
        for task in lookingUp.values { task.cancel() }
        cameraOpen = false
        wake()
    }

    private func pump() async {
        await pumpReads()
        await pumpLookups()
        await publish()
    }

    private func pumpReads() async {
        guard let id = batch else { return }
        var ended: Int
        var waiting: [StagedPhoto]
        repeat {
            ended = readsEnded
            waiting = await store.photosToRecognize(in: id)
            guard batch == id else { return }
        } while ended != readsEnded
        let slots = policy.slots(cameraOpen: cameraOpen, conditions: conditions)
        let byID = Dictionary(uniqueKeysWithValues: waiting.map { ($0.id, $0) })
        let start = policy.next(waiting: waiting.map(\.id).filter { !stalled.contains($0) }, reading: Set(reading.keys), slots: slots)
        let started = generation
        let priority: TaskPriority = cameraOpen ? .utility : .userInitiated
        for photoID in start {
            guard let photo = byID[photoID] else { continue }
            reading[photoID] = Task(priority: priority) { [store, recognizer] in
                let outcome = await Self.read(photo, in: id, store: store, recognizer: recognizer)
                await self.readEnded(photoID, outcome, generation: started)
            }
        }
    }

    private func readEnded(_ photo: IntakePhotoID, _ outcome: ReadOutcome, generation started: Int) async {
        reading[photo] = nil
        readsEnded += 1
        ending += 1
        defer {
            ending -= 1
            wake()
        }
        if started == generation {
            switch outcome {
            case .recorded: break
            case .stopped: stalled.insert(photo)
            case .cancelled:
                stalled.insert(photo)
                interrupted = true
            }
        }
        wake()
        guard started == generation else { return }
        await pump()
    }

    /// Reads one photo, trying again after a failure. Each attempt is counted in the store before it
    /// starts, so the limit holds across relaunches and also counts a read that crashed the app: a
    /// photo that crashes the reader every time is kept as unreadable instead of stopping every launch.
    private static func read(
        _ photo: StagedPhoto,
        in id: IntakeBatchID,
        store: StagingStore,
        recognizer: any PhotoRecognizer
    ) async -> ReadOutcome {
        do {
            while true {
                try Task.checkCancellation()
                guard let url = await store.url(of: photo.id, in: id) else { return .recorded }
                guard try await store.beginRead(photo.id, in: id) <= attemptsPerPhoto else {
                    try await store.record(observation(photo, PhotoReading()), couldNotRead: true, in: id)
                    return .recorded
                }
                let reading: PhotoReading
                do {
                    reading = try await recognizer.read(url)
                } catch is CancellationError {
                    try? await store.cancelRead(photo.id, in: id)
                    return .cancelled
                } catch {
                    continue
                }
                try await store.record(observation(photo, reading), in: id)
                return .recorded
            }
        } catch is CancellationError {
            return .cancelled
        } catch StagingError.unknownBatch, StagingError.unknownPhoto {
            // Discarded, expired or taken back while it was read.
            return .recorded
        } catch {
            return .stopped
        }
    }

    private static func observation(_ photo: StagedPhoto, _ reading: PhotoReading) -> PhotoObservation {
        PhotoObservation(
            photo: photo.id, sequence: photo.sequence, capturedAt: photo.capturedAt, lines: reading.lines,
            codes: reading.codes, featurePrint: reading.featurePrint, contentDigest: photo.contentDigest
        )
    }

    private func pumpLookups() async {
        guard let lookup, let id = batch, let record = await store.batch(id), batch == id else { return }
        var deferred: [GTIN] = []
        let started = generation
        for barcode in record.barcodesToLookUp where !pass.asked.contains(barcode) && lookingUp[barcode] == nil {
            if pass.paused {
                pass.asked.insert(barcode)
                deferred.append(barcode)
                continue
            }
            guard lookingUp.count < lookupPolicy.inFlight, pass.started < lookupPolicy.perPass else { break }
            pass.asked.insert(barcode)
            pass.started += 1
            lookingUp[barcode] = Task(priority: .utility) {
                let result = await lookup.lookUp(barcode)
                await self.answered(barcode, result, generation: started)
            }
        }
        if !deferred.isEmpty, (try? await store.recordLookups(deferred.map { ($0, .deferred) }, in: id)) != nil {
            lookupAnswers += 1
        }
    }

    /// Keeps an answer. The lookup counts as running until its answer is kept, so it is neither asked
    /// again nor missed by anything waiting for lookups to end.
    private func answered(_ barcode: GTIN, _ result: ProductLookupResult, generation started: Int) async {
        ending += 1
        defer {
            ending -= 1
            wake()
        }
        guard started == generation, let id = batch else {
            lookingUp[barcode] = nil
            return
        }
        let answer: LookupAnswer
        switch result {
        case .found(let suggestion): answer = .found(rawName: suggestion.name, source: suggestion.source)
        case .notFound: answer = .notFound
        case .failed(.cancelled):
            lookingUp[barcode] = nil
            return
        case .failed(.offline), .failed(.rateLimited):
            pass.paused = true
            answer = .deferred
        case .failed: answer = .failed(attempts: 1)
        }
        if (try? await store.recordLookups([(barcode, answer)], in: id)) != nil {
            lookupAnswers += 1
            if answer != .deferred { pass.answered += 1 }
        }
        lookingUp[barcode] = nil
        guard started == generation else { return }
        await pumpLookups()
        await publish()
    }

    // MARK: The screen

    private func publish() async {
        guard let id = batch, let observer, let record = await store.batch(id), batch == id else { return }
        live.sync(with: record.photos.compactMap(\.observation))
        var states: [IntakePhotoID: PhotoReadState] = [:]
        for photo in record.livePhotos {
            states[photo.id] = photo.couldNotRead ? .couldNotRead
                : photo.observation != nil ? .read
                : reading[photo.id] != nil ? .reading
                : .waiting
        }
        let read = record.livePhotos.filter { $0.observation != nil }.count
        let latest = record.photos.map(\.sequence).max() ?? -1
        observer.yield(IntakeLiveStatus(
            batch: id, states: states, progress: IntakeProgress(read: read, total: record.livePhotos.count),
            packagesSoFar: live.packagesSoFar,
            settled: live.settledPhotos(latestSequence: latest, now: time.now(), policy: settling),
            pause: policy.pause(cameraOpen: cameraOpen, conditions: conditions), lookupAnswers: lookupAnswers
        ))
    }

    private func waitForChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wake() {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }
}
