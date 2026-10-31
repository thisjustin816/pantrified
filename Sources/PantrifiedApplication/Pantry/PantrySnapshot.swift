import Foundation
import PantrifiedDomain

/// One active package with where it is kept and what needs attention.
public struct PantryEntry: Sendable, Identifiable {
    public let package: Package
    /// Nil when the package's location is not among the Space's locations.
    public let locationName: String?
    public let assessment: AttentionAssessment

    public var id: PackageID { package.id }

    public var needsAttention: Bool {
        assessment.state == .useSoon || assessment.state == .pastGuidance
    }

    public init(package: Package, locationName: String?, assessment: AttentionAssessment) {
        self.package = package
        self.locationName = locationName
        self.assessment = assessment
    }
}

/// Everything the Today and Food screens show, read at one moment.
public struct PantrySnapshot: Sendable {
    public let locations: [StorageLocation]
    /// Active packages: those needing attention first, soonest first, then the rest by name.
    public let entries: [PantryEntry]

    public init(locations: [StorageLocation], entries: [PantryEntry]) {
        self.locations = locations
        self.entries = entries
    }

    public var attention: [PantryEntry] { entries.filter(\.needsAttention) }

    public func entries(in location: LocationID) -> [PantryEntry] {
        entries.filter { $0.package.location == location }
    }

    /// Packages whose location is not in `locations`, so they still show somewhere.
    public var unplaced: [PantryEntry] {
        let known = Set(locations.map(\.id))
        return entries.filter { !known.contains($0.package.location) }
    }
}
