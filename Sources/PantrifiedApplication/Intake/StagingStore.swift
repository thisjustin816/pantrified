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
    /// When the store kept it. A picked photo may have been taken long before.
    public let stagedAt: Date
    public internal(set) var observation: PhotoObservation?
    public internal(set) var failedAttempts = 0
    /// The file has been deleted; what was read from it may still be in the review.
    public internal(set) var fileRemoved = false
}

extension StagedPhoto {
    private enum CodingKeys: String, CodingKey {
        case id, fileName, source, sequence, capturedAt, contentDigest, stagedAt, observation, failedAttempts, fileRemoved
    }

    /// A record from before `stagedAt` was kept counts as staged when it was taken.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(IntakePhotoID.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        source = try container.decode(PhotoSource.self, forKey: .source)
        sequence = try container.decode(Int.self, forKey: .sequence)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        contentDigest = try container.decodeIfPresent(String.self, forKey: .contentDigest)
        stagedAt = try container.decodeIfPresent(Date.self, forKey: .stagedAt) ?? capturedAt
        observation = try container.decodeIfPresent(PhotoObservation.self, forKey: .observation)
        failedAttempts = try container.decodeIfPresent(Int.self, forKey: .failedAttempts) ?? 0
        fileRemoved = try container.decodeIfPresent(Bool.self, forKey: .fileRemoved) ?? false
    }
}

public enum BatchPhase: String, Sendable, Hashable, Codable {
    /// Photos are being taken or imported.
    case capturing
    /// Done was tapped; photos are being read.
    case processing
    case reviewing
    /// Nothing is left to review. The record is kept for the recovery window.
    case finished
}

/// One batch of photos and, once read, its review. It is kept until the person adds or discards
/// everything in it, across crashes and relaunches. Its photo files are deleted a recovery window
/// after they were read, or at once when the batch is discarded.
public struct IntakeBatch: Sendable, Hashable, Codable, Identifiable {
    public let id: IntakeBatchID
    public let space: SpaceID
    public let startedAt: Date
    public internal(set) var photos: [StagedPhoto] = []
    public internal(set) var phase: BatchPhase = .capturing
    public internal(set) var processedAt: Date?
    public internal(set) var finishedAt: Date?
    public internal(set) var review: IntakeReview?
    var nextSequence = 0

    public var livePhotos: [StagedPhoto] { photos.filter { !$0.fileRemoved } }
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
    /// About a day, the recovery window in docs/product-decisions.md.
    public static let defaultRecoveryWindow: TimeInterval = 24 * 60 * 60
    /// The longest a photo file is kept after it was staged, read or not. What was read from it stays
    /// with the batch until the batch is finished or discarded.
    public static let photoFileLimit: TimeInterval = 2 * 24 * 60 * 60
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
    /// What went wrong reading the batch list in this launch, for the screen to say once.
    public private(set) var loadProblem: StagingLoadProblem?

    public init(files: any StagingFiles, time: any TimeSource, recoveryWindow: TimeInterval = StagingStore.defaultRecoveryWindow) {
        self.files = files
        self.time = time
        self.recoveryWindow = recoveryWindow
        let load = Self.load(files: files, now: time.now())
        (loaded, batches, setAsideAt, readOnly, loadProblem) = (load.loaded, load.batches, load.setAsideAt, load.readOnly, load.problem)
    }

    private struct Manifest: Codable {
        var version = StagingStore.manifestVersion
        var batches: [IntakeBatch]
        var setAsideAt: Date?
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
    }

    /// The outcome of reading the batch list.
    private struct Load {
        var loaded = true
        var batches: [IntakeBatch] = []
        var setAsideAt: Date?
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
            return Load(batches: batches, setAsideAt: stored.setAsideAt, readOnly: true, problem: .newerVersion)
        }
        if batches.count < stored.batches.count { return setAside(data, keeping: batches, files: files, now: now) }
        return Load(batches: batches, setAsideAt: stored.setAsideAt)
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
            (loaded, batches, setAsideAt, readOnly, loadProblem) = (load.loaded, load.batches, load.setAsideAt, load.readOnly, load.problem)
        }
        return loaded
    }

    /// Whether changes can be written: the list was read and no newer version wrote it.
    private func writable() throws(StagingError) {
        guard ensureLoaded(), !readOnly else { throw .unavailable }
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
        if let existing = unfinished(in: space) { return existing }
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
            capturedAt: capturedAt ?? time.now(), contentDigest: digest, stagedAt: time.now()
        )
        batches[index].photos.append(photo)
        batches[index].nextSequence += 1
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
    /// read twice, as after a relaunch, changes nothing. Returns whether it was kept.
    @discardableResult
    public func record(_ observation: PhotoObservation, in id: IntakeBatchID) throws(StagingError) -> Bool {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == observation.photo }) else { throw .unknownPhoto }
        guard batches[index].photos[position].observation == nil else { return false }
        batches[index].photos[position].observation = observation
        try save()
        return true
    }

    /// Counts a failed read. Returns the number of failures so far.
    @discardableResult
    public func recordFailure(of photo: IntakePhotoID, in id: IntakeBatchID) throws(StagingError) -> Int {
        try writable()
        guard let index = index(id) else { throw .unknownBatch }
        guard let position = batches[index].photos.firstIndex(where: { $0.id == photo }) else { throw .unknownPhoto }
        batches[index].photos[position].failedAttempts += 1
        try save()
        return batches[index].photos[position].failedAttempts
    }

    public func observations(in id: IntakeBatchID) -> [PhotoObservation] {
        batch(id)?.photos.compactMap(\.observation) ?? []
    }

    /// Stores the review made once every photo was read, and starts the recovery window. A batch
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
    /// - photo files a recovery window after their batch was read, and every photo file
    ///   `photoFileLimit` after it was staged, read or not;
    /// - a batch still capturing a recovery window after its last photo is moved on to reading, so
    ///   an abandoned capture does not keep photos indefinitely;
    /// - finished batches a recovery window after they finished;
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
        for index in batches.indices {
            let read = batches[index].processedAt.map { now.timeIntervalSince($0) >= recoveryWindow } ?? false
            for photo in batches[index].photos.indices where !batches[index].photos[photo].fileRemoved {
                guard read || now.timeIntervalSince(batches[index].photos[photo].stagedAt) >= Self.photoFileLimit else { continue }
                doomed.append(batches[index].photos[photo].fileName)
                batches[index].photos[photo].fileRemoved = true
                changed = true
            }
            let lastPhoto = batches[index].photos.map(\.capturedAt).max() ?? batches[index].startedAt
            if batches[index].phase == .capturing, !batches[index].photos.isEmpty, now.timeIntervalSince(lastPhoto) >= recoveryWindow {
                batches[index].phase = .processing
                changed = true
            }
        }
        let expired = batches.filter { batch in
            guard batch.phase == .finished, let finished = batch.finishedAt else { return false }
            return now.timeIntervalSince(finished) >= recoveryWindow
        }
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            for batch in expired { doomed += batch.photos.filter { !$0.fileRemoved }.map(\.fileName) }
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
            let data = try JSONEncoder().encode(Manifest(batches: batches, setAsideAt: setAsideAt))
            try files.write(data, to: Self.manifestName)
        } catch {
            throw .storage
        }
    }
}
