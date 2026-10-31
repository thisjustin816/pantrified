import Foundation
import Observation
import SwiftUI
import UIKit
import PantrifiedApplication
import PantrifiedDomain

/// One batch from the first photo to the last package added. The rules live in the application
/// layer; this keeps what the screens show, and every change is in the staging store before the
/// screen shows it, so a crash or kill loses nothing the person did.
@MainActor
@Observable
final class IntakeModel {
    enum Stage: Equatable {
        case opening
        case capturing
        case reading(IntakeProgress)
        /// Reading stopped with an error; trying again carries on where it stopped.
        case readingStopped
        case reviewing
        /// The staging folder could not be opened.
        case unavailable
    }

    /// The last Add, which stays undoable while the batch is open.
    struct AddedPrompt: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let addition: IntakeAddition
    }

    private(set) var stage = Stage.opening
    private(set) var photos: [StagedPhoto] = []
    private(set) var review: IntakeReview?
    private(set) var thumbnails: [IntakePhotoID: UIImage] = [:]
    /// A failure to tell the person about, once.
    private(set) var problem: String?
    /// Why batches cannot be opened, when it is not the folder itself.
    private(set) var unavailableDetail: String?
    private(set) var added: AddedPrompt?
    private(set) var isAdding = false

    let services: IntakeServices
    let pantry: PantryModel
    @ObservationIgnored private var batchID: IntakeBatchID?
    @ObservationIgnored private var lookups: Task<Void, Never>?

    init(services: IntakeServices, pantry: PantryModel) {
        self.services = services
        self.pantry = pantry
    }

    var locations: [StorageLocation] { pantry.snapshot?.locations ?? [] }
    var summaries: [CandidateSummary] { review?.summaries ?? [] }
    var readyIDs: [IntakeCandidateID] { review?.readyToAdd ?? [] }
    var canUndoChange: Bool { review?.canUndo ?? false }
    var photoLimit: Int { IntakeLimits.photosPerBatch }

    func locationName(_ id: LocationID?) -> String? {
        locations.first { $0.id == id }?.name
    }

    func name(of id: IntakeCandidateID) -> String? {
        review?.summary(of: id)?.name
    }

    // MARK: Opening

    /// Opens the Space's unfinished batch where it was left, or a new one.
    func start() async {
        guard stage == .opening else { return }
        do {
            _ = try? await services.store.sweep()
            let batch = try await services.store.open(in: services.space)
            if await services.store.takeLoadProblem() == .damaged { problem = IntakeText.damagedBatch }
            batchID = batch.id
            photos = batch.livePhotos
            switch batch.phase {
            case .capturing:
                stage = .capturing
            case .processing:
                await read()
            case .reviewing, .finished:
                try? await services.adding.resume(batch.id)
                await reloadReview()
                stage = .reviewing
                lookUpNames()
            }
        } catch {
            unavailableDetail = await services.store.takeLoadProblem() == .newerVersion ? IntakeText.newerVersion : nil
            stage = .unavailable
        }
    }

    // MARK: Capture

    /// Keeps a photo the camera took or the picker gave. It is written to the staging folder only.
    func keep(_ data: Data, source: PhotoSource, takenAt: Date?) async {
        guard let batchID else { return }
        do {
            let photo = try await services.store.stage(
                data, fileExtension: PhotoFormat.fileExtension(of: data), source: source, capturedAt: takenAt,
                digest: PhotoFormat.digest(of: data), in: batchID
            )
            photos.append(photo)
            let thumbnail = await Task.detached(priority: .userInitiated) { SentImage(PhotoFormat.thumbnail(of: data)) }.value
            thumbnails[photo.id] = thumbnail.image
        } catch StagingError.batchFull {
            problem = "A batch holds up to \(photoLimit) photos. Tap Done to review these first."
        } catch StagingError.photoTooLarge {
            problem = "That photo is too large to use."
        } catch {
            problem = "That photo couldn't be kept. Try again."
        }
    }

    func remove(_ photo: IntakePhotoID) async {
        guard let batchID else { return }
        do {
            try await services.store.removePhoto(photo, from: batchID)
            photos.removeAll { $0.id == photo }
            thumbnails[photo] = nil
        } catch {
            problem = "That photo couldn't be removed."
        }
    }

    /// Done taking photos: read them, then review.
    func finishCapture() async {
        await read()
    }

    // MARK: Reading

    func read() async {
        guard let batchID else { return }
        stage = .reading(IntakeProgress(read: 0, total: photos.count))
        do {
            let review = try await services.pipeline.process(
                batchID, locations: locations, defaultLocation: locations.first?.id
            ) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .reading = self.stage else { return }
                    self.stage = .reading(progress)
                }
            }
            self.review = review
            stage = .reviewing
            lookUpNames()
        } catch is CancellationError {
            // The sheet closed. What was read is kept; opening the batch carries on.
        } catch {
            stage = .readingStopped
        }
    }

    /// Looks up barcodes in the background. The review is usable meanwhile, and adding never waits.
    private func lookUpNames() {
        guard services.looksUp, let batchID, lookups == nil else { return }
        lookups = Task { [weak self, services] in
            if await services.pipeline.lookUpNames(batchID) > 0 { await self?.reloadReview() }
            self?.lookups = nil
        }
    }

    func stopLookups() {
        lookups?.cancel()
        lookups = nil
    }

    func loadThumbnail(_ photo: IntakePhotoID) async {
        guard thumbnails[photo] == nil, let batchID, let url = await services.store.url(of: photo, in: batchID) else { return }
        let made = await Task.detached(priority: .utility) { SentImage(PhotoFormat.thumbnail(at: url)) }.value
        if let image = made.image { thumbnails[photo] = image }
    }

    // MARK: Review changes

    func setName(_ name: String, for id: IntakeCandidateID) async {
        await change { try $0.setName(name, for: id) }
    }

    func setDate(_ date: PrintedDate?, for id: IntakeCandidateID) async {
        await change { try $0.setDate(date, for: id) }
    }

    func chooseDateOrder(_ order: DateOrderHint, for id: IntakeCandidateID) async {
        await change { try $0.chooseDateOrder(order, for: id) }
    }

    func setCount(_ count: Int, for id: IntakeCandidateID) async {
        await change { try $0.setCount(count, for: id) }
    }

    func assign(_ location: LocationID, to ids: Set<IntakeCandidateID>) async {
        await change { $0.assignLocation(location, to: ids) }
    }

    func merge(_ ids: [IntakeCandidateID]) async {
        await change { _ = try $0.merge(ids) }
    }

    func split(_ photo: IntakePhotoID, from id: IntakeCandidateID) async {
        await change { _ = try $0.split(photo, from: id) }
    }

    func delete(_ ids: Set<IntakeCandidateID>) async {
        await change { $0.delete(ids) }
    }

    func keepApart(_ a: IntakeCandidateID, _ b: IntakeCandidateID) async {
        await change { try $0.keepApart(a, b) }
    }

    func undoChange() async {
        await change { _ = $0.undo() }
    }

    private func change(_ body: @escaping @Sendable (inout IntakeReview) throws -> Void) async {
        guard let batchID else { return }
        do {
            try await services.store.updateReview(batchID) { try body(&$0) }
        } catch IntakeReviewError.differentBarcodes {
            problem = "These have different barcodes, so they're different products."
        } catch IntakeReviewError.tooManyCandidates {
            problem = "This batch can't hold any more items."
        } catch {
            problem = "That change didn't save. Try again."
        }
        await reloadReview()
    }

    private func reloadReview() async {
        guard let batchID else { return }
        let fresh = await services.store.batch(batchID)?.review
        animated { review = fresh }
    }

    // MARK: Adding

    /// Adds every candidate that has a name and a place. The rest stay for review.
    func addAll() async {
        await add(readyIDs)
    }

    func add(_ ids: [IntakeCandidateID]) async {
        guard let batchID, !ids.isEmpty, !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        do {
            let addition = try await services.adding.add(ids, in: batchID)
            await reloadReview()
            await pantry.load()
            if !addition.packages.isEmpty {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                animated { added = AddedPrompt(message: IntakeText.added(addition.packages.count), addition: addition) }
            }
        } catch {
            problem = "Nothing was added. Check your list, then try again."
            await reloadReview()
        }
    }

    func undoAdd() async {
        guard let prompt = added else { return }
        animated { added = nil }
        do {
            try await services.adding.undo(prompt.addition)
        } catch {
            problem = "Couldn't undo that. Your list has been refreshed."
        }
        await reloadReview()
        await pantry.load()
    }

    func dismissAdded() {
        animated { added = nil }
    }

    /// Deletes the batch's photos and everything read from them, now.
    func discard() async {
        stopLookups()
        guard let batchID else { return }
        try? await services.store.discard(batchID)
        self.batchID = nil
    }

    func dismissProblem() { problem = nil }

    private func animated(_ change: () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            withAnimation(.snappy, change)
        }
    }
}

/// A thumbnail made off the main thread and handed to it once. Nothing else holds the image.
private struct SentImage: @unchecked Sendable {
    let image: UIImage?

    init(_ image: UIImage?) {
        self.image = image
    }
}
