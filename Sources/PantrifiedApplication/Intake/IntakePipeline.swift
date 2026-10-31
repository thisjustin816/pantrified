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

/// Reads a batch's photos, groups them into candidates and looks up barcodes. Every step can stop
/// and start again: a photo already read is not read again, a batch already grouped keeps its
/// review and the person's edits, and a lookup that fails is tried again next time.
public struct IntakePipeline: Sendable {
    private let store: StagingStore
    private let recognizer: any PhotoRecognizer
    private let lookup: (any ProductLookupService)?
    private let grouper: PhotoGrouper
    private let proposer: IntakeProposer
    /// Photos read at the same time. Small, because each read holds a full photo in memory.
    private let concurrency: Int
    /// A photo that fails this many times is kept with nothing read from it, so one bad file
    /// cannot stop a batch.
    static let attemptsPerPhoto = 2
    /// Lookups per pass, to stay well inside the shared key's hourly limit.
    static let lookupsPerPass = 40

    public init(
        store: StagingStore,
        recognizer: any PhotoRecognizer,
        lookup: (any ProductLookupService)?,
        grouper: PhotoGrouper = PhotoGrouper(),
        proposer: IntakeProposer = IntakeProposer(),
        concurrency: Int = 2
    ) {
        self.store = store
        self.recognizer = recognizer
        self.lookup = lookup
        self.grouper = grouper
        self.proposer = proposer
        self.concurrency = max(1, concurrency)
    }

    /// Reads every photo not read yet, then groups the batch, unless it already has a review.
    /// Cancelling stops between photos; what was read is kept.
    public func process(
        _ id: IntakeBatchID,
        locations: [StorageLocation],
        defaultLocation: LocationID?,
        progress: @escaping @Sendable (IntakeProgress) -> Void = { _ in }
    ) async throws -> IntakeReview {
        try await store.startProcessing(id)
        if let existing = await store.batch(id)?.review { return existing }
        let pending = await store.photosToRecognize(in: id)
        let total = await store.batch(id)?.photos.count ?? 0
        var done = total - pending.count
        progress(IntakeProgress(read: done, total: total))

        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = pending[...]
            func next() -> Bool {
                guard let photo = queue.popFirst() else { return false }
                group.addTask { try await self.read(photo, in: id) }
                return true
            }
            for _ in 0..<concurrency where !next() { break }
            while try await group.next() != nil {
                done += 1
                progress(IntakeProgress(read: done, total: total))
                try Task.checkCancellation()
                _ = next()
            }
        }
        try Task.checkCancellation()
        guard let batch = await store.batch(id) else { throw StagingError.unknownBatch }
        // Nothing is grouped half read.
        guard !batch.photos.contains(where: { $0.observation == nil && !$0.fileRemoved }) else {
            throw StagingError.notRecognized
        }
        let observations = batch.photos.compactMap(\.observation)
        let review = IntakeReview(
            space: batch.space, observations: observations, grouping: grouper.group(observations),
            proposer: proposer, locations: locations, defaultLocation: defaultLocation, looksUp: lookup != nil
        )
        return try await store.finishRecognition(id, review: review)
    }

    /// Reads one photo, trying again after a failure. Failures are counted in the store, so the
    /// limit holds across relaunches.
    private func read(_ photo: StagedPhoto, in id: IntakeBatchID) async throws {
        while true {
            try Task.checkCancellation()
            guard let url = await store.url(of: photo.id, in: id) else { return }
            let reading: PhotoReading?
            do {
                reading = try await recognizer.read(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reading = nil
            }
            if let reading {
                try await store.record(observation(photo, reading), in: id)
                return
            }
            if try await store.recordFailure(of: photo.id, in: id) >= Self.attemptsPerPhoto {
                try await store.record(observation(photo, PhotoReading()), in: id)
                return
            }
        }
    }

    private func observation(_ photo: StagedPhoto, _ reading: PhotoReading) -> PhotoObservation {
        PhotoObservation(
            photo: photo.id, sequence: photo.sequence, capturedAt: photo.capturedAt, lines: reading.lines,
            codes: reading.codes, featurePrint: reading.featurePrint, contentDigest: photo.contentDigest
        )
    }

    /// Looks up the barcodes still without an answer, one distinct barcode at a time, through the
    /// injected lookup service only. Never throws and never blocks review or adding. A miss is final.
    /// When the device is offline or the service asks for fewer requests, the rest of the pass is
    /// deferred, not failed: the barcodes stay on their candidates and are asked again on a later pass.
    /// Returns the number of answers recorded.
    @discardableResult
    public func lookUpNames(_ id: IntakeBatchID) async -> Int {
        guard let lookup, let review = await store.batch(id)?.review else { return 0 }
        var recorded = 0
        let barcodes = Array(review.barcodesToLookUp.prefix(Self.lookupsPerPass))
        for (index, barcode) in barcodes.enumerated() {
            if Task.isCancelled { break }
            let answer: LookupAnswer
            switch await lookup.lookUp(barcode) {
            case .found(let suggestion): answer = .found(rawName: suggestion.name, source: suggestion.source)
            case .notFound: answer = .notFound
            case .failed(.cancelled): return recorded
            case .failed(.offline), .failed(.rateLimited):
                let rest = Array(barcodes[index...])
                _ = try? await store.updateReview(id) { review in
                    for barcode in rest { review.record(.deferred, for: barcode) }
                }
                return recorded
            case .failed: answer = .failed(attempts: 1)
            }
            if (try? await store.updateReview(id, { $0.record(answer, for: barcode) })) != nil { recorded += 1 }
        }
        return recorded
    }
}
