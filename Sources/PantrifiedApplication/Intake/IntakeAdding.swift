import Foundation
import PantrifiedDomain

/// What one Add put away, for its undo.
public struct IntakeAddition: Sendable, Hashable {
    public let batch: IntakeBatchID
    public let candidates: Set<IntakeCandidateID>
    public let packages: [PackageID]
    /// Candidates asked for but left in review because they had no name or place.
    public let notReady: Int
}

/// Turns reviewed candidates into packages and back. The inventory is usable as soon as `add`
/// returns; nothing waits for recognition or lookups. An add or undo cut off by a crash is finished
/// by `resume`.
public struct IntakeAdding: Sendable {
    private let pantry: Pantry
    private let store: StagingStore

    public init(pantry: Pantry, store: StagingStore) {
        self.pantry = pantry
        self.store = store
    }

    /// Adds the ready candidates among `ids`, all or none. Packages keep the candidate's barcode and
    /// printed date; a name or date the person did not set is saved as a proposal.
    public func add(_ ids: [IntakeCandidateID], in batch: IntakeBatchID) async throws -> IntakeAddition {
        guard let review = await store.batch(batch)?.review else { throw StagingError.notRecognized }
        let ready = Set(review.readyToAdd).intersection(ids)
        let drafts = review.drafts(for: ids.filter(ready.contains))
        let candidates = Set(ids.filter(ready.contains))
        guard !drafts.isEmpty else {
            return IntakeAddition(batch: batch, candidates: [], packages: [], notReady: Set(ids).count)
        }
        try await store.updateReview(batch) { $0.beginAdd(candidates) }
        do {
            _ = try await pantry.putAway(drafts)
        } catch {
            // All or nothing: nothing was saved, so nothing is left to finish on the next launch.
            _ = try? await store.updateReview(batch) { $0.cancelAdd() }
            throw error
        }
        try await store.updateReview(batch) { $0.markAdded(candidates) }
        return IntakeAddition(batch: batch, candidates: candidates, packages: drafts.map(\.id), notReady: Set(ids).count - candidates.count)
    }

    /// Takes the packages back out of active inventory and returns the candidates to review. The
    /// package histories keep them as discarded, because a package's record is never deleted.
    public func undo(_ addition: IntakeAddition) async throws {
        guard !addition.candidates.isEmpty else { return }
        try await store.updateReview(addition.batch) { $0.beginUndo(addition.candidates) }
        try await discard(addition.packages)
        try await store.updateReview(addition.batch) { $0.markReviewing(addition.candidates) }
    }

    /// Finishes an add or undo that a crash or kill cut off. Adding the same drafts again finds the
    /// packages already made, so nothing is added twice.
    public func resume(_ batch: IntakeBatchID) async throws {
        guard let review = await store.batch(batch)?.review else { return }
        if !review.pendingUndo.isEmpty {
            let packages = review.candidates.filter { review.pendingUndo.contains($0.id) }.flatMap(\.packagesToAdd)
            try await discard(packages)
            try await store.updateReview(batch) { $0.markReviewing(review.pendingUndo) }
        }
        if !review.pendingAdd.isEmpty {
            let ids = review.candidates.filter { review.pendingAdd.contains($0.id) && $0.status == .reviewing }.map(\.id)
            let drafts = review.drafts(for: ids)
            if !drafts.isEmpty { _ = try await pantry.putAway(drafts) }
            try await store.updateReview(batch) { $0.markAdded(review.pendingAdd) }
        }
    }

    private func discard(_ packages: [PackageID]) async throws {
        let active = try await pantry.activity(of: packages)
        for id in packages where active[id] == true {
            _ = try await pantry.perform(.discard(reason: nil), on: id)
        }
    }
}
