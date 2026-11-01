import Foundation
import PantrifiedDomain

/// What the app read from one batch and what it did with it, as one versioned JSON file a TestFlight
/// tester can share, so a real failure can become a text-level test case. It holds no image, crop,
/// thumbnail or feature print vector, no file name, path or photo identifier, no location, and no
/// household or person names: photos are numbered by their place in the batch, places are given by
/// kind and position, and times are seconds since the first photo. `docs/batch-intake.md` describes
/// each field.
public struct ReadExport: Sendable, Hashable, Codable {
    public static let formatName = "pantrified.read-export"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var app: AppInfo
    /// The calendar day of the first photo, in UTC, such as "2026-11-01". Printed dates are read
    /// against it, so a replay reads the same dates.
    public var batchDay: String
    public var photos: [Photo]
    /// The pairs grouping weighed, by photo sequence.
    public var pairs: [Pair]
    /// Pairs with no signal are listed when their feature prints are at most this far apart.
    public var distanceKeptUpTo: Double
    /// The groups grouping made, in order. A group is one candidate on the review as it first showed.
    public var groups: [Group]
    public var suggestions: [Suggestion]
    public var lookups: [Lookup]
    /// What the person did with the review, which is the ground truth for a test case.
    public var corrections: Corrections
    /// What was left out before sharing.
    public var withheld: Withheld

    public struct AppInfo: Sendable, Hashable, Codable {
        /// The marketing version, such as "0.1".
        public var version: String
        /// The build number, such as "57".
        public var build: String
        /// Such as "iOS 27.0".
        public var system: String
        /// The model identifier, such as "iPhone17,1".
        public var device: String

        public init(version: String, build: String, system: String, device: String) {
            self.version = version
            self.build = build
            self.system = system
            self.device = device
        }
    }

    public struct Photo: Sendable, Hashable, Codable {
        public var sequence: Int
        /// Rounded to a tenth of a second.
        public var secondsAfterFirst: Double
        public var kind: PhotoKind
        public var role: PhotoRole
        public var showsPanel: Bool
        /// Whether the photo had a feature print. The vector itself is never included.
        public var hasFeaturePrint: Bool
        /// The first photo holding the same bytes, when this one is a copy of it.
        public var sameBytesAs: Int?
        /// The person left this photo out: its lines and codes are not included.
        public var removed: Bool
        public var lines: [Line]
        public var codes: [Code]
    }

    public struct Line: Sendable, Hashable, Codable {
        public var text: String
        public var box: Box
        public var confidence: Double?
    }

    /// A line's box as fractions of the photo, rounded to a thousandth, origin at the top left.
    public struct Box: Sendable, Hashable, Codable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    public enum CodeKind: String, Sendable, Hashable, Codable {
        case product, refused, link, otherQR
    }

    /// A code in a photo. A product code keeps its number; a link keeps only the fact it was seen.
    public struct Code: Sendable, Hashable, Codable {
        public var kind: CodeKind
        public var product: String?
        public var refused: RefusedCode?
    }

    public struct Pair: Sendable, Hashable, Codable {
        public var first: Int
        public var second: Int
        /// Feature print distance, rounded to four decimals. Absent when either photo has none.
        public var distance: Double?
        public var signals: [SignalPoints]
        public var oneLetterOffPoints: Int
        public var shotOrderPoints: Int
        public var score: Int

        public init(
            first: Int, second: Int, distance: Double?, signals: [SignalPoints], oneLetterOffPoints: Int, shotOrderPoints: Int, score: Int
        ) {
            self.first = first
            self.second = second
            self.distance = distance
            self.signals = signals
            self.oneLetterOffPoints = oneLetterOffPoints
            self.shotOrderPoints = shotOrderPoints
            self.score = score
        }
    }

    public struct Group: Sendable, Hashable, Codable {
        public var photos: [Int]
        /// Absent when the group has none, or when it was shown only on photos the person removed.
        public var barcode: String?
        public var sharedPhotos: [Int]
        public var links: [Link]
        public var proposals: Proposals
    }

    public struct Link: Sendable, Hashable, Codable {
        public var photo: Int
        public var matchedWith: Int
        public var signals: [MatchSignal]
        public var score: Int

        public init(photo: Int, matchedWith: Int, signals: [MatchSignal], score: Int) {
            self.photo = photo
            self.matchedWith = matchedWith
            self.signals = signals
            self.score = score
        }
    }

    public enum NameSource: String, Sendable, Hashable, Codable {
        case label, lookup, person, none
    }

    /// A name, or the fact that one was left out.
    public struct Name: Sendable, Hashable, Codable {
        public var text: String?
        public var withheld: Bool?

        static func kept(_ text: String?, unless withheld: Bool) -> Name {
            withheld ? Name(text: nil, withheld: true) : Name(text: text, withheld: nil)
        }
    }

    public enum DateLabel: String, Sendable, Hashable, Codable {
        case useBy, bestBy, sellBy, freezeBy, packed, unlabeled
    }

    /// A printed date as read or set: one day, or two readings of a date that reads two ways. Days
    /// are written as "2027-05-06".
    public struct DateRead: Sendable, Hashable, Codable {
        public var label: DateLabel?
        public var date: String?
        public var monthFirst: String?
        public var dayFirst: String?
        public var withheld: Bool?
    }

    public enum PlaceKind: String, Sendable, Hashable, Codable {
        case fridge, freezer, pantry
    }

    /// A place by its kind and its position in the household's list of places, from 1. Its name is
    /// never included.
    public struct Place: Sendable, Hashable, Codable {
        public var kind: PlaceKind
        public var position: Int
        public var source: LocationOrigin
    }

    /// What the labels of a group's photos proposed when the review first showed it.
    public struct Proposals: Sendable, Hashable, Codable {
        /// The name read from the label, whether or not the lookup's name was shown instead.
        public var labelName: Name?
        /// Where the name the card showed came from.
        public var nameSource: NameSource
        public var date: DateRead?
        public var datesDisagree: Bool
        public var place: Place?
        public var refusedCodes: [RefusedCode]
        public var sawLink: Bool
        public var barcodeSeenApart: Bool
    }

    public struct Suggestion: Sendable, Hashable, Codable {
        /// Group indexes.
        public var first: Int
        public var second: Int
        public var signals: [MatchSignal]
        public var score: Int

        public init(first: Int, second: Int, signals: [MatchSignal], score: Int) {
            self.first = first
            self.second = second
            self.signals = signals
            self.score = score
        }
    }

    public enum LookupAnswerKind: String, Sendable, Hashable, Codable {
        case found, notFound, failed, deferred
    }

    public struct Lookup: Sendable, Hashable, Codable {
        public var barcode: String
        public var answer: LookupAnswerKind
        /// The name as the service returned it, after the app's cleaning.
        public var name: Name?
        public var service: String?
        public var attempts: Int?
    }

    public enum PackageStatus: String, Sendable, Hashable, Codable {
        case reviewing, added
    }

    /// One candidate as the person left it.
    public struct Package: Sendable, Hashable, Codable {
        public var photos: [Int]
        /// The groups its photos came from. More than one means the person merged them.
        public var fromGroups: [Int]
        public var mergedByPerson: Bool
        public var status: PackageStatus
        public var nameDecided: Bool
        /// The name the person set. Absent text with `nameDecided` means they cleared it.
        public var name: Name?
        public var dateDecided: Bool
        public var date: DateRead?
        public var place: Place?
        public var count: Int
        /// Other packages, by index, still suggested as maybe the same.
        public var suggestedWith: [Int]
    }

    public struct Corrections: Sendable, Hashable, Codable {
        public var packages: [Package]
        /// Photos in no package: the person deleted their candidates.
        public var deletedPhotos: [Int]
        /// Groups whose photos ended up in more than one package.
        public var splitGroups: [Int]
    }

    public struct Withheld: Sendable, Hashable, Codable {
        public var photos: [Int]
        /// Lines left out on photos that are included.
        public var lines: Int
        /// Of those, the ones the automatic check left out and the person did not put back.
        public var linesByCheck: Int
        public var names: Int
        /// Barcodes shown only on removed photos, left out everywhere.
        public var barcodes: Int
    }
}

public enum ReadExportError: Error, Sendable, Equatable {
    case notAnExport
    /// Written by a newer version of the format.
    case unsupportedVersion(Int)
}

extension ReadExport {
    /// Readable JSON with keys in a stable, sorted order.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads an export, refusing anything that is not one and versions newer than this code reads.
    public static func decode(_ data: Data) throws -> ReadExport {
        struct Header: Decodable {
            let format: String
            let version: Int
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == formatName else {
            throw ReadExportError.notAnExport
        }
        guard (1...currentVersion).contains(header.version) else { throw ReadExportError.unsupportedVersion(header.version) }
        return try JSONDecoder().decode(ReadExport.self, from: data)
    }
}
