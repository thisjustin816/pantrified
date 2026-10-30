import Foundation
import Testing
import PantrifiedTestSupport
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

    @Test("crops recorded with equal stamps list in record ID order whatever order they arrive in")
    func equalStampsOrderByRecordID() throws {
        let crops = (0..<4).map { _ in crop(.approved) }
        let records = try crops.map { try #require(EvidenceRecords.record(for: $0, at: stamp)) }
        let expected = crops.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }

        var orders: Set<[EvidenceID]> = []
        for (index, arrival) in records.permutations.enumerated() {
            var set = RecordSet()
            for _ in 0..<(index % 7) {
                set.merge(SyncRecord(id: RecordID(kind: .shoppingItem, entity: UUID()), created: stamp, fields: [:]))
            }
            for record in arrival { set.merge(record) }
            orders.insert(EvidenceRecords.materialize(from: set).map(\.id))
        }

        #expect(orders == [expected.map(\.id)])
    }
}
