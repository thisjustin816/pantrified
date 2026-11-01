import Foundation

public enum IntakeCandidateTag: Sendable {}
public typealias IntakeCandidateID = Identifier<IntakeCandidateTag>

/// A product lookup's answer for a barcode, as the review keeps it. The name is untrusted text from
/// a remote service and is cleaned and bounded on the way in.
public enum LookupAnswer: Sendable, Hashable, Codable {
    case found(name: String, source: String)
    case notFound
    /// Timed out, refused or unreadable. Tried again later, a few times; never blocks anything.
    case failed(attempts: Int)
    /// Not asked yet because the device was offline or the service asked for fewer requests. Tried
    /// again later without counting as a failure.
    case deferred

    /// A lookup that failed this many times is not tried again.
    public static let maximumAttempts = 3

    /// Whether a barcode with this answer is still to be asked: never asked, deferred, or failed
    /// fewer than `maximumAttempts` times. A miss is final.
    public static func needsAsking(_ answer: LookupAnswer?) -> Bool {
        switch answer {
        case nil, .deferred?: true
        case .failed(let attempts)?: attempts < maximumAttempts
        case .found?, .notFound?: false
        }
    }

    /// The answer to keep when `new` arrives after `old`. A failure or a deferral never replaces an
    /// answer already found, and failures are counted.
    public static func combining(_ old: LookupAnswer?, with new: LookupAnswer) -> LookupAnswer {
        switch (old, new) {
        case (.found?, .failed), (.notFound?, .failed), (.found?, .deferred), (.notFound?, .deferred), (.failed?, .deferred):
            old ?? new
        case (.failed(let before)?, .failed(let now)): .failed(attempts: max(before, now) + 1)
        case (_, .failed): .failed(attempts: 1)
        default: new
        }
    }

    /// A found answer, cleaned. An empty name counts as not found.
    public static func found(rawName: String, source: String) -> LookupAnswer {
        let name = LabelText.tidyName(rawName)
        let source = BoundedText.clean(source, characters: 60, bytes: 240)
        return name.isEmpty ? .notFound : .found(name: name, source: source)
    }
}

/// A date read from the label: one date, or a numeric date that reads two ways.
public enum DateProposal: Sendable, Hashable, Codable {
    case resolved(PrintedDate)
    case ambiguous(PendingDateChoice)
}

/// A recognized numeric date that reads two ways, held until the person picks one.
public struct PendingDateChoice: Sendable, Hashable, Codable {
    public let label: PrintedDateLabel
    public let monthFirst: Date
    public let dayFirst: Date
}

/// Where a candidate's location came from.
public enum LocationOrigin: String, Sendable, Hashable, Codable {
    /// The batch's default, usually the first location.
    case standard
    /// The label says how to keep it, such as "Keep frozen".
    case label
    case person
}

public enum CandidateStatus: Sendable, Hashable, Codable {
    case reviewing
    case added
}

/// What the label of a candidate's photos proposes. Recomputed whenever its photos change.
public struct LabelProposals: Sendable, Hashable, Codable {
    public var name: String?
    public var date: DateProposal?
    /// The photos show more than one different date.
    public var datesDisagree = false
    public var storage: StorageType?
    public var refusedCodes: [RefusedCode] = []
    /// A QR code with a link was seen. The link is not kept or opened.
    public var sawLink = false
    /// The candidate's barcode is in two photos that were not taken one after the other, which can
    /// mean two packages of one product.
    public var barcodeSeenApart = false

    public init() {}
}

/// One package candidate under review: the photos that show it, why they were grouped, what the
/// labels propose and what the person decided. Recognition only proposes; a field the person set
/// is never replaced by a later proposal.
public struct IntakeCandidate: Sendable, Hashable, Codable, Identifiable {
    public let id: IntakeCandidateID
    public internal(set) var photos: [IntakePhotoID]
    public internal(set) var links: [GroupLink]
    /// Photos that also show other products, used for the barcode but not for name or date.
    public internal(set) var sharedPhotos: [IntakePhotoID]
    public internal(set) var barcode: GTIN?
    public internal(set) var label: LabelProposals
    /// Other candidates that might be the same package, for the person to merge or keep apart.
    public internal(set) var mightBeSameAs: [IntakeCandidateID]

    /// The person's own name, once set. An empty name the person chose is kept as their decision.
    public internal(set) var personName: String?
    public internal(set) var nameDecided = false
    public internal(set) var personDate: PrintedDate?
    public internal(set) var dateDecided = false
    public internal(set) var location: LocationID?
    public internal(set) var locationOrigin: LocationOrigin
    /// How many packages of this product, 1 unless the person says more.
    public internal(set) var count = 1
    /// Stable package identities, so adding again after a crash finds the packages already made.
    public internal(set) var packageIDs: [PackageID]
    public internal(set) var status: CandidateStatus = .reviewing

    init(
        id: IntakeCandidateID = IntakeCandidateID(),
        photos: [IntakePhotoID],
        links: [GroupLink] = [],
        sharedPhotos: [IntakePhotoID] = [],
        barcode: GTIN?,
        label: LabelProposals,
        location: LocationID?,
        locationOrigin: LocationOrigin
    ) {
        self.id = id
        self.photos = photos
        self.links = links
        self.sharedPhotos = sharedPhotos
        self.barcode = barcode
        self.label = label
        self.mightBeSameAs = []
        self.location = location
        self.locationOrigin = locationOrigin
        self.packageIDs = [PackageID()]
    }

    /// The distinct signals that grouped its photos, strongest kinds first.
    public var signals: [MatchSignal] {
        let present = Set(links.flatMap(\.signals))
        return MatchSignal.allCases.filter(present.contains)
    }

    public var packagesToAdd: [PackageID] { Array(packageIDs.prefix(count)) }
}

/// Where a proposed name came from, for the person to see.
public enum NameOrigin: Sendable, Hashable {
    case lookup(source: String)
    case label
    case person
}

public enum DateOrigin: Sendable, Hashable {
    case label
    case person
}

/// A plainly worded doubt about a candidate, shown on its card.
public enum CandidateNote: Sendable, Hashable {
    case mightBeSameAs([IntakeCandidateID])
    case noName
    /// A date that reads two ways and needs a choice.
    case dateUnclear
    case datesDisagree
    /// A photo of only a date was matched to this package by the order the photos were taken in.
    case dateMatchedByOrder
    case severalProducts
    case duplicatePhotos
    case maybeSeveralPackages
    case refusedBarcode(RefusedCode)
    case linkSeen
    case lookingUp
    case lookupFailed
    /// Offline, or the lookup service asked to slow down; the barcode is kept for later.
    case lookupPaused
    case lookupFoundNothing
}

/// What the review screen shows for one candidate: the values that would be added, where each came
/// from, and the doubts.
public struct CandidateSummary: Sendable, Hashable, Identifiable {
    public let id: IntakeCandidateID
    public let photos: [IntakePhotoID]
    public let name: String?
    public let nameOrigin: NameOrigin?
    public let date: PrintedDate?
    public let dateOrigin: DateOrigin?
    public let pendingDate: PendingDateChoice?
    public let location: LocationID?
    public let locationOrigin: LocationOrigin
    public let count: Int
    public let barcode: GTIN?
    public let signals: [MatchSignal]
    public let notes: [CandidateNote]
    public let status: CandidateStatus

    /// A name and a place are all a package needs; date and quantity may stay unknown.
    public var isReady: Bool {
        location != nil && !(name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
