import Foundation

/// Approved evidence crops sync as a record naming the crop's asset; the transport carries the image.
public enum EvidenceRecords {
    private static let region = TagTable<EvidenceRegion>([
        (.printedDate, "printedDate"), (.frontLabel, "frontLabel"), (.barcode, "barcode"), (.instructions, "instructions"),
    ])

    /// Nil unless the crop may upload its image.
    public static func record(for crop: EvidenceCrop, at stamp: HybridTimestamp) -> SyncRecord? {
        guard crop.mayUploadImage else { return nil }
        return SyncRecord(
            id: RecordID(kind: .evidenceCrop, entity: crop.id.rawValue),
            writing: ["package": crop.packageID.field, "region": region.encode(crop.region), "asset": .string(crop.asset)],
            at: stamp
        )
    }

    public static func materialize(
        from records: RecordSet,
        readerVersion: Int = SyncFormat.version
    ) -> [EvidenceCrop] {
        records.records(of: .evidenceCrop)
            .filter { $0.minimumReaderVersion <= readerVersion }
            .sorted { $0.created < $1.created }
            .compactMap { record in
                try? EvidenceCrop(
                    id: EvidenceID(record.id.entity),
                    packageID: PackageID(field: record.value("package").required()),
                    region: region.decode(record.value("region")),
                    asset: record.value("asset").required().string(),
                    review: .approved
                )
            }
    }
}
