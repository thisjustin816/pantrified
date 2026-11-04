import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// Rebuilds the photo observations a `ReadExport` was made from and groups them again, so a shared
/// export can become a text-level test case. `docs/batch-intake.md` says how to add one under
/// `Tests/ReadExportFixtures`.
///
/// A replay has no images. Each photo with a feature print gets a stand-in print holding only its
/// sequence, and the recorded distance between two photos is used as theirs; a pair with no
/// recorded distance is too far apart to count. Two photos recorded as the same bytes get the same
/// stand-in digest. Times are the batch's day at noon UTC plus each photo's seconds.
public struct ReadExportReplay: Sendable {
    public let export: ReadExport

    public init(_ export: ReadExport) {
        self.export = export
    }

    public init(json: Data) throws {
        self.init(try ReadExport.decode(json))
    }

    public init(contentsOf file: URL) throws {
        try self.init(json: Data(contentsOf: file))
    }

    /// A stable photo identity for a sequence, so a replay is the same every run.
    public static func photoID(_ sequence: Int) -> IntakePhotoID {
        let digits = String(max(0, sequence))
        let hex = String(repeating: "0", count: max(0, 12 - digits.count)) + digits
        return IntakePhotoID(UUID(uuidString: "00000000-0000-4000-8000-\(hex.suffix(12))")!)
    }

    /// Noon UTC on the batch's day.
    public var start: Date {
        let parts = export.batchDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return Date(timeIntervalSince1970: 0) }
        return PrintedDateParser.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
            ?? Date(timeIntervalSince1970: 0)
    }

    public var observations: [PhotoObservation] {
        let start = self.start
        return export.photos.map { photo in
            PhotoObservation(
                photo: Self.photoID(photo.sequence),
                kind: photo.kind,
                sequence: photo.sequence,
                capturedAt: start.addingTimeInterval(photo.secondsAfterFirst),
                lines: photo.lines.compactMap { line in
                    RecognizedTextLine(
                        text: line.text,
                        box: NormalizedBox(x: line.box.x, y: line.box.y, width: line.box.width, height: line.box.height),
                        confidence: line.confidence
                    )
                },
                codes: photo.codes.compactMap(Self.meaning),
                featurePrint: photo.hasFeaturePrint ? FeaturePrint([Float(photo.sequence)]) : nil,
                contentDigest: Self.digest(photo.sameBytesAs ?? photo.sequence)
            )
        }
    }

    /// A grouper that uses the recorded distances in place of feature prints.
    public func grouper(policy: GroupingPolicy = .standard) -> PhotoGrouper {
        var distances: [[Int]: Double] = [:]
        for pair in export.pairs {
            if let distance = pair.distance { distances[[pair.first, pair.second].sorted()] = distance }
        }
        return PhotoGrouper(policy: policy, distance: RecordedDistance(distances: distances))
    }

    /// What grouping and the label proposals give for the replayed photos, with the given policy.
    public func run(policy: GroupingPolicy = .standard, proposer: IntakeProposer = IntakeProposer()) -> ReplayReport {
        let observations = self.observations
        let byID = Dictionary(uniqueKeysWithValues: observations.map { ($0.photo, $0) })
        let trace = grouper(policy: policy).trace(observations)
        let sequence = { (id: IntakePhotoID) in byID[id]?.sequence ?? -1 }
        let groups = trace.result.groups.map { group in
            let label = proposer.proposals(photos: group.photos, shared: Set(group.sharedPhotos), barcode: group.barcode, observations: byID)
            return ReplayReport.Group(
                photos: group.photos.map(sequence), barcode: group.barcode?.digits, labelName: label.name,
                links: group.links.map { ReadExport.Link(photo: sequence($0.photo), matchedWith: sequence($0.matchedWith), signals: $0.signals, score: $0.score) }
            )
        }
        let pairs = trace.pairs.map { pair in
            ReadExport.Pair(
                first: sequence(pair.first), second: sequence(pair.second), distance: pair.distance, signals: pair.signals,
                oneLetterOffPoints: pair.oneLetterOffPoints, shotOrderPoints: pair.shotOrderPoints, score: pair.score
            )
        }
        let suggestions = trace.result.suggestions.map {
            ReadExport.Suggestion(first: $0.first, second: $0.second, signals: $0.signals, score: $0.score)
        }
        return ReplayReport(groups: groups, suggestions: suggestions, pairs: pairs)
    }

    /// The groups the export recorded, as photo sequences.
    public var recordedGroups: [[Int]] { export.groups.map(\.photos) }

    /// The packages as the person left them, as photo sequences: the ground truth.
    public var personGroups: [[Int]] { export.corrections.packages.map(\.photos) }

    private static func digest(_ sequence: Int) -> String {
        String(max(0, sequence), radix: 16)
    }

    private static func meaning(_ code: ReadExport.Code) -> CodeMeaning? {
        switch code.kind {
        case .product: code.product.flatMap { GTIN($0) }.map(CodeMeaning.product)
        case .refused: code.refused.map(CodeMeaning.refused)
        case .link: .link
        case .otherQR: .otherQR
        }
    }
}

/// The result of a replay, in the export's own terms, so it can be compared with what was recorded.
public struct ReplayReport: Sendable, Hashable {
    public struct Group: Sendable, Hashable {
        public let photos: [Int]
        public let barcode: String?
        public let labelName: String?
        public let links: [ReadExport.Link]
    }

    public let groups: [Group]
    public let suggestions: [ReadExport.Suggestion]
    public let pairs: [ReadExport.Pair]

    /// A plain description for a test's output: each group with its photos and how they were linked.
    public var summary: String {
        var lines: [String] = []
        for (index, group) in groups.enumerated() {
            lines.append("group \(index): photos \(group.photos)\(group.barcode.map { " barcode \($0)" } ?? "")")
            for link in group.links {
                lines.append("  \(link.photo) with \(link.matchedWith): \(link.signals.map(\.rawValue).joined(separator: ", ")) (\(link.score))")
            }
        }
        for suggestion in suggestions {
            lines.append("suggested: groups \(suggestion.first) and \(suggestion.second) (\(suggestion.score))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Feature print distances read from an export, by the sequences the stand-in prints hold.
struct RecordedDistance: ImageDistance {
    let distances: [[Int]: Double]

    func distance(_ a: FeaturePrint, _ b: FeaturePrint) -> Double? {
        guard let x = a.values.first, let y = b.values.first else { return nil }
        return distances[[Int(x), Int(y)].sorted()]
    }
}
