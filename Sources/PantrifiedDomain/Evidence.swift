import Foundation

public enum EvidenceTag: Sendable {}
public typealias EvidenceID = Identifier<EvidenceTag>

public enum EvidenceRegion: Sendable, Hashable, Codable {
    case printedDate
    case frontLabel
    case barcode
    case instructions
}

public enum EvidenceReview: Sendable, Hashable, Codable {
    case pending
    case approved
    case rejected
}

/// A useful region the app generated from a capture and keeps with an active package. Full
/// captures and imported photos are not evidence crops and have no synchronized form at all.
public struct EvidenceCrop: Sendable, Hashable, Identifiable {
    public let id: EvidenceID
    public let packageID: PackageID
    public let region: EvidenceRegion
    /// The app-owned file holding the cropped image.
    public let asset: String
    public var review: EvidenceReview
    /// Set when Sensitive Content Analysis flagged the crop. Defense in depth, not a guarantee.
    public var sensitiveContentFlagged: Bool

    public init(
        id: EvidenceID = EvidenceID(),
        packageID: PackageID,
        region: EvidenceRegion,
        asset: String,
        review: EvidenceReview = .pending,
        sensitiveContentFlagged: Bool = false
    ) {
        self.id = id
        self.packageID = packageID
        self.region = region
        self.asset = asset
        self.review = review
        self.sensitiveContentFlagged = sensitiveContentFlagged
    }

    /// A flagged crop stays local; the structured data extracted from it syncs with the package.
    public var mayUploadImage: Bool {
        review == .approved && !sensitiveContentFlagged
    }
}
