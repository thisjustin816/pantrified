import Foundation
import Testing
@testable import PantrifiedDomain

private let stamp = HybridTimestamp(physicalMillis: 1, counter: 0, replica: ReplicaID())

private func crop(_ review: EvidenceReview, flagged: Bool = false) -> EvidenceCrop {
    EvidenceCrop(
        packageID: PackageID(), region: .printedDate, asset: "crop.heic",
        review: review, sensitiveContentFlagged: flagged
    )
}

@Suite("Evidence crop records")
struct EvidenceRecordsTests {
    @Test("crops awaiting review or rejected have no record", arguments: [EvidenceReview.pending, .rejected])
    func unapprovedStaysLocal(review: EvidenceReview) {
        #expect(EvidenceRecords.record(for: crop(review), at: stamp) == nil)
    }

    @Test("an approved crop flagged by sensitive content analysis has no record")
    func flaggedStaysLocal() {
        #expect(EvidenceRecords.record(for: crop(.approved, flagged: true), at: stamp) == nil)
    }

    @Test("an approved crop syncs its package, region and asset")
    func approvedSyncs() throws {
        let approved = crop(.approved)
        var records = RecordSet()
        records.merge(try #require(EvidenceRecords.record(for: approved, at: stamp)))

        #expect(EvidenceRecords.materialize(from: records) == [approved])
    }
}
