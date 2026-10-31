import Foundation
import PantrifiedDomain

public enum IntakeBatchTag: Sendable {}
public typealias IntakeBatchID = Identifier<IntakeBatchTag>

/// The app's own folder of staged photos and the batch list. File names are the store's own, and
/// the store only ever reads or removes names it made, so it can never touch a file it does not
/// own, such as a photo in the Photos library.
public protocol StagingFiles: Sendable {
    func write(_ data: Data, to name: String) throws
    /// Nil when there is no such file.
    func read(_ name: String) throws -> Data?
    /// Removing a file that is not there succeeds.
    func remove(_ name: String) throws
    func names() throws -> [String]
    /// Where a recognizer can read the file. Never handed to anything that writes.
    func url(for name: String) -> URL
}

public enum PhotoSource: String, Sendable, Hashable, Codable {
    case camera
    /// Copied in from the Photos picker. The original stays in Photos, untouched.
    case imported
}

/// One photo in the staging folder. Times come from the app's own records, never from file dates.
public struct StagedPhoto: Sendable, Hashable, Codable, Identifiable {
    public let id: IntakePhotoID
    public let fileName: String
    public let source: PhotoSource
    public let sequence: Int
    public let capturedAt: Date
    public let contentDigest: String?
    public internal(set) var observation: PhotoObservation?
    /// Reads started and not cancelled. Counted before each read, so a read that crashes the app or
    /// is stopped by the system counts as well as one that fails.
    public internal(set) var readAttempts = 0
    /// Read too many times without a result. It is kept with nothing read from it.
    public internal(set) var couldNotRead = false
    /// The file has been deleted; what was read from it may still be in the review.
    public internal(set) var fileRemoved = false
}

extension StagedPhoto {
    private enum CodingKeys: String, CodingKey {
        case id, fileName, source, sequence, capturedAt, contentDigest, observation, readAttempts, couldNotRead, fileRemoved
    }

    /// Fields added after the first records default to their starting values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(IntakePhotoID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        source = try container.decode(PhotoSource.self, forKey: .source)
        sequence = try container.decode(Int.self, forKey: .sequence)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        contentDigest = try container.decodeIfPresent(String.self, forKey: .contentDigest)
        observation = try container.decodeIfPresent(PhotoObservation.self, forKey: .observation)
        readAttempts = try container.decodeIfPresent(Int.self, forKey: .readAttempts) ?? 0
        couldNotRead = try container.decodeIfPresent(Bool.self, forKey: .couldNotRead) ?? false
        fileRemoved = try container.decodeIfPresent(Bool.self, forKey: .fileRemoved) ?? false
    }
}

public enum BatchPhase: String, Sendable, Hashable, Codable {
    /// Photos are being taken or imported.
    case capturing
    /// Done was tapped; photos are being read.
    case processing
    case reviewing
    /// Nothing is left to review. The record and its photos are kept for the recovery window.
    case finished
}

/// One batch of photos and, once read, its review, kept across crashes and relaunches. It is deleted
/// with its photo files a recovery window after it is finished, `unfinishedBatchLifetime` after it
/// was last used if it is not finished, or at once when it is discarded.
public struct IntakeBatch: Sendable, Hashable, Codable, Identifiable {
    public let id: IntakeBatchID
    public let space: SpaceID
    public let startedAt: Date
    public internal(set) var photos: [StagedPhoto] = []
    public internal(set) var phase: BatchPhase = .capturing
    public internal(set) var processedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var review: IntakeReview?
    /// The last time the person used the batch: opened it, took or removed a photo, changed the
    /// review or added from it. An unfinished batch expires a set time after this.
    public internal(set) var lastActivityAt: Date
    var nextSequence = 0

    public var livePhotos: [StagedPhoto] { photos.filter { !$0.fileRemoved } }

    init(id: IntakeBatchID, space: SpaceID, startedAt: Date) {
        self.id = id
        self.space = space
        self.startedAt = startedAt
        lastActivityAt = startedAt
    }
}

extension IntakeBatch {
    private enum CodingKeys: String, CodingKey {
        case id, space, startedAt, photos, phase, processedAt, finishedAt, review, lastActivityAt, nextSequence
    }

    /// A record from before activity was kept counts as last used when its newest photo was taken.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(IntakeBatchID.self, forKey: .id)
        space = try container.decode(SpaceID.self, forKey: .space)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        photos = try container.decode([StagedPhoto].self, forKey: .photos)
        phase = try container.decode(BatchPhase.self, forKey: .phase)
        processedAt = try container.decodeIfPresent(Date.self, forKey: .processedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        review = try container.decodeIfPresent(IntakeReview.self, forKey: .review)
        lastActivityAt = try container.decodeIfPresent(Date.self, forKey: .lastActivityAt)
            ?? photos.map(\.capturedAt).max() ?? startedAt
        nextSequence = try container.decode(Int.self, forKey: .nextSequence)
    }
}

public enum StagingError: Error, Sendable, Equatable {
    case batchFull
    case photoTooLarge
    case unknownBatch
    case unknownPhoto
    /// Photos can be added or removed only before the batch is read.
    case notCapturing
    case notRecognized
    case storage
    /// The batch list cannot be used now: it could not be read, or a newer version of the app
    /// wrote it. Nothing is changed or deleted meanwhile.
    case unavailable
}

/// Why the batch list is not, or not fully, in use.
public enum StagingLoadProblem: Sendable, Equatable {
    /// The file could not be read, such as before the first unlock after a restart. Reading is tried
    /// again on the next call; until then nothing is written or deleted.
    case unreadable
    /// The file, or a batch in it, could not be understood. It was set aside and the batches that
    /// could be read were kept; the rest are lost.
    case damaged
    /// A newer version of the app wrote the file. It is read only, so nothing it holds is lost.
    case newerVersion
}

/// Keeps staged photos and batch records, and deletes them on schedule. Every change is written
/// before it returns, so a crash or a kill loses at most the change in progress. A photo file is
/// written before the record that names it; a file no record names is removed by `sweep`.
public actor StagingStore {
    public static let manifestName = "batches.json"
    /// About a day, the recovery window in docs/product-decisions.md: how long a finished batch, with
    /// its photos, stays for Undo and recovery.
    public static let defaultRecoveryWindow: TimeInterval = 24 * 60 * 60
    /// How long an unfinished batch is kept after the person last used it. After that the whole
    /// batch is deleted: photos, what was read from them and the review.
    public static let unfinishedBatchLifetime: TimeInterval = 3 * 24 * 60 * 60
    public static let maximumPhotoBytes = 40 * 1_024 * 1_024
    static let photoExtensions: Set<String> = ["jpg", "heic", "png"]

    /// The batch list's format. A file with a higher version is opened read only.
    public static let manifestVersion = 1
    /// A batch list that could not be understood is kept under this name for a recovery window,
    /// then deleted.
    public static let setAsideName = "batches.unreadable.json"

    private let files: any StagingFiles
    private let time: any TimeSource
    public let recoveryWindow: TimeInterval
    private var batches: [IntakeBatch] = []
    /// False until the batch list has been read. Nothing is written or deleted before that, so a
    /// read that fails for a while cannot replace the real list with an empty one.
    private var loaded = false
    private var readOnly = false
    /// When a damaged batch list was set aside. Until a recovery window after it, photo files no
    /// batch names are kept, because the lost batch named them.
    private var setAsideAt: Date?
    /// An unfinished batch expired and the person has not been told yet.
    private var unfinishedExpired = false
    /// What went wrong reading the batch list in this launch, for the screen to say once.
    public private(set) var loadProblem: StagingLoadProblem?

    public init(files: any StagingFiles, time: any TimeSource, recoveryWindow: TimeInterval = StagingStore.defaultRecoveryWindow) {
        self.files = files
        self.time = time
        self.recoveryWindow = recoveryWindow
        let load = Self.load(files: files, now: time.now())
        (loaded, batches, setAsideAt, unfinishedExpired, readOnly, loadProblem) =
            (load.loaded, load.batches, load.setAsideAt, load.unfinishedExpired, load.readOnly, load.problem)
    }

    private struct Manifest: Codable {
        var version = StagingStore.manifestVersion
        var batches: [IntakeBatch]
        var setAsideAt: Date?
        var unfinishedExpired = false
    }

    /// Reads a batch on its own, so one that cannot be understood does not lose the others.
    private struct Lenient: Decodable {
        let batch: IntakeBatch?
        init(from decoder: any Decoder) throws { batch = try? IntakeBatch(from: decoder) }
    }

    private struct Stored: Decodable {
        var version: Int
        var batches: [Lenient]
        var setAsideAt: Date?
        var unfinishedExpired: Bool?
    }

    /// The outcome of reading the batch list.
    private struct Load {
        var loaded = true
        var batches: [IntakeBatch] = []
        var setAsideAt: Date?
        var unfinishedExpired = false
        var readOnly = false
        var problem: StagingLoadProblem?

        static let unreadable = Load(loaded: false, problem: .unreadable)
    }

    private static func load(files: any StagingFiles, now: Date) -> Load {
        let data: Data?
        do { data = try files.read(manifestName) } catch { return .unreadable }
        guard let data else { return Load() }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return setAside(data, keeping: [], files: files, now: now)
        }
        let batches = stored.batches.compactMap(\.batch)
        if stored.version > manifestVersion {
            return Load(batches: batches, setAsideAt: stored.setAsideAt, unfinishedExpired: stored.unfinishedExpired ?? false, readOnly: true, problem: .newerVersion)
        }
        if batches.count < stored.batches.count { return setAside(data, keeping: batches, files: files, now: now) }
        return Load(batches: batches, setAsideAt: stored.setAsideAt, unfinishedExpired: stored.unfinishedExpired ?? false)
    }

    /// Keeps a copy of a damaged list and writes the batches that could be read. When either write
    /// fails, nothing is replaced and the list is tried again later.
    private static func setAside(_ data: Data, keeping batches: [IntakeBatch], files: any StagingFiles, now: Date) -> Load {
        do {
            try files.write(data, to: setAsideName)
            let manifest = try JSONEncoder().encode(Manifest(batches: batches, setAsideAt: now))
            try files.write(manifest, to: manifestName)
        } catch {
            return .unreadable
        }
        return Load(batches: batches, setAsideAt: now, problem: .damaged)
    }

    /// Reads the batch list again when it could not be read before. Returns whether it is in use.
    @discardableResult
    private func ensureLoaded() -> Bool {
        if !loaded {
            let load = Self.load(files: files, now: time.now())
            (loaded, batches, setAsideAt, unfinishedExpired, readOnly, loadProblem) =
            (load.loaded, load.batches, load.setAsideAt, load.unfinishedExpired, load.readOnly, load.problem)
        }
        return loaded
    }

    /// Whether changes can be written: the list was read and no newer version wrote it.
    private func writable() throws(StagingError) {
        guard ensureLoaded(), !readOnly else { throw .unavailable }
    }

    /// Says once that an unfinished batch was deleted because it was not used for
    /// `unfinishedBatchLifetime`.
    public func takeExpiryNotice() -> Bool {
        guard ensureLoaded(), !readOnly, unfinishedExpired else { return false }
        unfinishedExpired = false
        try? save()
        return true
    }

    /// Says what went wrong reading the batch list, once.
    public func takeLoadProblem() -> StagingLoadProblem? {
        ensureLoaded()
        defer { if loadProblem != .unreadable { loadProblem = nil } }
        return loadProblem
    }

    // MARK: Batches

    public var all: [IntakeBatch] {
        ensureLoaded()
        return batches
    }

    public func batch(_ id: IntakeBatchID) -> IntakeBatch? {
        ensureLoaded()
        return batches.first { $0.id == id }
    }

    /// The Space's batch that is not finished, if any: the one to resume.
    public func unfinished(in space: SpaceID) -> IntakeBatch? {
        ensureLoaded()
        return batches.last { $0.space == space && $0.phase != .finished }
    }

    /// The unfinished batch to carry on with, or a new one.
    public func open(in space: SpaceID) throws(StagingError) -> IntakeBatch {
        try writable()
        if let existing = unfinished(in: space), let index = index(existing.id) {
            batches[index].lastActivityAt = time.now()
            try save()
            return batches[index]
        }
        let batch = IntakeBatch(id: IntakeBatchID(), space: space, startedAt: time.now())
        batches.append(batch)
        try save()
        return batch
    }

    // MARK: Capture

    /// Writes a photo's bytes into the staging folder and records it. `fileExtension` is one of jpg,
    /// heic or png.
    @discardableResult
    public func stage(
        _ data: Data,
        fileExtension: String,
        source: PhotoSource,
        capturedAt: Date? = nil,
        digest: String? = nil,
        in id: IntakeBatchID
    ) throws(StagingError) -> StagedPhoto {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard batches[index].phase == .capturing else { throw .notCapturing }
        guard batches[index].photos.count < IntakeLimits.photosPerBatch else { throw .batchFull }
        guard data.count <= Self.maximumPhotoBytes, !data.isEmpty else { throw .photoTooLarge }
        let ext = Self.photoExtensions.contains(fileExtension.lowercased()) ? fileExtension.lowercased() : "jpg"
        let photoID = IntakePhotoID()
        let name = "\(photoID.rawValue.uuidString).\(ext)"
        do { try files.write(data, to: name) } catch { throw .storage }
        let photo = StagedPhoto(
            id: photoID, fileName: name, source: source, sequence: batches[index].nextSequence,
            capturedAt: capturedAt ?? time.now(), contentDigest: digest
        )
        batches[index].photos.append(photo)
        batches[index].nextSequence += 1
        batches[index].lastActivityAt = time.now()
        do {
            try save()
        } catch {
            batches[index].photos.removeLast()
            try? files.remove(name)
            throw error
        }
        return photo
    }

    /// Takes a photo back out before the batch is read, deleting its file.
    public func removePhoto(_ photo: IntakePhotoID, from id: IntakeBatchID) throws(StagingError) {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard batches[index].phase == .capturing else { throw .notCapturing }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == photo }) else { throw .unknownPhoto }
        let removed = batches[index].photos.remove(at: position)
        batches[index].lastActivityAt = time.now()
        try save()
        try? files.remove(removed.fileName)
    }

    public func url(of photo: IntakePhotoID, in id: IntakeBatchID) -> URL? {
        guard let staged = batch(id)?.photos.first(where: { $0.id == photo }), !staged.fileRemoved else { return nil }
        return files.url(for: staged.fileName)
    }

    // MARK: Recognition

    /// Moves a capturing batch on to reading. Calling it again changes nothing.
    public func startProcessing(_ id: IntakeBatchID) throws(StagingError) {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard batches[index].phase == .capturing else { return }
        batches[index].phase = .processing
        try save()
    }

    /// Photos still to read, in order.
    public func photosToRecognize(in id: IntakeBatchID) -> [StagedPhoto] {
        batch(id)?.photos.filter { $0.observation == nil && !$0.fileRemoved } ?? []
    }

    /// Keeps what was read from a photo. Only the first observation of a photo is kept, so a photo
    /// read twice, as after a relaunch, changes nothing. `couldNotRead` marks an empty observation
    /// kept for a photo that was tried too many times. Returns whether it was kept.
    @discardableResult
    public func record(_ observation: PhotoObservation, couldNotRead: Bool = false, in id: IntakeBatchID) throws(StagingError) -> Bool {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == observation.photo }) else { throw .unknownPhoto }
        guard batches[index].photos[position].observation == nil else { return false }
        batches[index].photos[position].observation = observation
        batches[index].photos[position].couldNotRead = couldNotRead
        try save()
        return true
    }

    /// Counts a read as started, before it starts. Returns the number of reads started so far.
    @discardableResult
    public func beginRead(_ photo: IntakePhotoID, in id: IntakeBatchID) throws(StagingError) -> Int {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == photo }) else { throw .unknownPhoto }
        batches[index].photos[position].readAttempts += 1
        try save()
        return batches[index].photos[position].readAttempts
    }

    /// Takes back the count of a read that was cancelled, such as by closing the batch, since that
    /// says nothing about the photo.
    public func cancelRead(_ photo: IntakePhotoID, in id: IntakeBatchID) throws(StagingError) {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == photo }) else { throw .unknownPhoto }
        guard batches[index].photos[position].readAttempts > 0 else { return }
        batches[index].photos[position].readAttempts -= 1
        try save()
    }

    public func observations(in id: IntakeBatchID) -> [PhotoObservation] {
        batch(id)?.photos.compactMap(\.observation) ?? []
    }

    /// Stores the review made once every photo was read. A batch
    /// that already has a review keeps it, with the person's edits: grouping runs once per batch.
    @discardableResult
    public func finishRecognition(_ id: IntakeBatchID, review: IntakeReview) throws(StagingError) -> IntakeReview {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        if let existing = batches[index].review { return existing }
        batches[index].review = review
        batches[index].phase = review.isFinished ? .finished : .reviewing
        batches[index].processedAt = time.now()
        if review.isFinished { batches[index].finishedAt = time.now() }
        try save()
        return review
    }

    // MARK: Review

    /// Changes the review and writes it before returning. Nothing is written when `change` throws.
    public func updateReview<Result: Sendable>(
        _ id: IntakeBatchID,
        _ change: @Sendable (inout IntakeReview) throws -> Result
    ) throws -> Result {
        try writable()
        guard let index = index(id) else { throw StagingError.unknownBatch }
        guard var review = batches[index].review else { throw StagingError.notRecognized }
        let result = try change(&review)
        let before = batches[index]
        batches[index].review = review
        batches[index].lastActivityAt = time.now()
        if review.isFinished {
            if batches[index].phase != .finished {
                batches[index].phase = .finished
                batches[index].finishedAt = time.now()
            }
        } else if batches[index].phase == .finished {
            batches[index].phase = .reviewing
            batches[index].finishedAt = nil
        }
        do {
            try save()
        } catch {
            batches[index] = before
            throw error
        }
        return result
    }

    // MARK: Deleting

    /// Deletes the batch's photos and record now.
    public func discard(_ id: IntakeBatchID) throws(StagingError) {
        try writable()
        guard let index = index(id) else { return }
        let removed = batches.remove(at: index)
        try save()
        for photo in removed.photos where !photo.fileRemoved { try? files.remove(photo.fileName) }
    }

    /// Deletes what is due, and returns how many photo files were deleted:
    ///
    /// - an unfinished batch, entirely, `unfinishedBatchLifetime` after its last activity;
    /// - a finished batch, with its photos, a recovery window after it finished;
    /// - photo files no batch names, left by a crash between writing a file and recording it, once
    ///   no damaged batch list is set aside;
    /// - a damaged batch list set aside a recovery window ago.
    ///
    /// Nothing is deleted while the batch list cannot be read or a newer version wrote it.
    @discardableResult
    public func sweep() throws(StagingError) -> Int {
        guard ensureLoaded(), !readOnly else { return 0 }
        let now = time.now()
        var doomed: [String] = []
        var changed = false
        if let setAside = setAsideAt, now.timeIntervalSince(setAside) >= recoveryWindow {
            try? files.remove(Self.setAsideName)
            setAsideAt = nil
            changed = true
        }
        let expired = batches.filter { batch in
            if batch.phase == .finished {
                guard let finished = batch.finishedAt else { return false }
                return now.timeIntervalSince(finished) >= recoveryWindow
            }
            return now.timeIntervalSince(batch.lastActivityAt) >= Self.unfinishedBatchLifetime
        }
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            for batch in expired { doomed += batch.photos.filter { !$0.fileRemoved }.map(\.fileName) }
            if expired.contains(where: { $0.phase != .finished }) { unfinishedExpired = true }
            batches.removeAll { ids.contains($0.id) }
            changed = true
        }
        if changed { try save() }

        let named = Set(batches.flatMap { $0.photos.filter { !$0.fileRemoved }.map(\.fileName) })
        // While a damaged list is set aside, the photos it named are kept with it.
        if setAsideAt == nil, let present = try? files.names() {
            for name in present where !named.contains(name) { doomed.append(name) }
        }
        var deleted = 0
        // The one guard on every deletion: only a name this store makes is ever removed.
        for name in Set(doomed) where Self.isPhotoName(name) {
            if (try? files.remove(name)) != nil { deleted += 1 }
        }
        return deleted
    }

    /// Only names the store makes: an uppercase UUID and a photo extension.
    static func isPhotoName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, photoExtensions.contains(String(parts[1])), parts[0].count == 36 else { return false }
        return UUID(uuidString: String(parts[0]))?.uuidString == String(parts[0])
    }

    // MARK: Helpers

    private func index(_ id: IntakeBatchID) -> Int? {
        batches.firstIndex { $0.id == id }
    }

    private func save() throws(StagingError) {
        try writable()
        do {
            let data = try JSONEncoder().encode(Manifest(batches: batches, setAsideAt: setAsideAt, unfinishedExpired: unfinishedExpired))
            try files.write(data, to: Self.manifestName)
        } catch {
            throw .storage
        }
    }
}
