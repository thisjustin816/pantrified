import Foundation
import PantrifiedDomain

/// What an export is made from: one batch's review, with the observations it holds, and the
/// household's places, which are given only by kind and position.
public struct ReadExportSource: Sendable {
    public var app: ReadExport.AppInfo
    public var review: IntakeReview
    public var locations: [StorageLocation]
    public var grouper: PhotoGrouper
    public var proposer: IntakeProposer

    public init(
        app: ReadExport.AppInfo,
        review: IntakeReview,
        locations: [StorageLocation],
        grouper: PhotoGrouper = PhotoGrouper(),
        proposer: IntakeProposer = IntakeProposer()
    ) {
        self.app = app
        self.review = review
        self.locations = locations
        self.grouper = grouper
        self.proposer = proposer
    }
}

/// An export being previewed: every line and name that would be shared, and what the person left
/// out. Lines and names `SensitiveText` flags start left out; the person can put them back, and
/// leave out any photo, line or name. Nothing is written anywhere until `export()` is encoded and
/// shared.
public struct ReadExportDraft: Sendable {
    /// A line by its photo's sequence and its place among the photo's lines.
    public struct LineKey: Sendable, Hashable {
        public let photo: Int
        public let index: Int

        public init(photo: Int, index: Int) {
            self.photo = photo
            self.index = index
        }
    }

    public enum NameKey: Sendable, Hashable {
        /// The name read from the label of a group, by group index.
        case label(group: Int)
        /// The name the lookup gave for a barcode.
        case lookup(barcode: String)
        /// The name the person set on a package, by package index.
        case person(package: Int)
    }

    public struct LineItem: Sendable, Hashable, Identifiable {
        public let id: LineKey
        public let text: String
        public let flag: SensitiveText.Kind?
    }

    public struct PhotoItem: Sendable, Hashable, Identifiable {
        /// The photo's sequence.
        public let id: Int
        public let secondsAfterFirst: Double
        public let lines: [LineItem]
        public let codes: [ReadExport.Code]
    }

    public struct NameItem: Sendable, Hashable, Identifiable {
        public let id: NameKey
        public let text: String
        public let flag: SensitiveText.Kind?
        /// The photos of the group or package the name belongs to, by sequence.
        public let photos: [Int]
    }

    public let source: ReadExportSource
    public let trace: GroupingTrace
    public let photos: [PhotoItem]
    public let names: [NameItem]
    public private(set) var excludedPhotos: Set<Int> = []
    public private(set) var excludedLines: Set<LineKey> = []
    public private(set) var excludedNames: Set<NameKey> = []

    private let observations: [PhotoObservation]

    public init(source: ReadExportSource) {
        self.source = source
        let observations = source.review.observations.values.sorted { $0.sequence < $1.sequence }
        self.observations = observations
        let trace = source.grouper.trace(observations)
        self.trace = trace
        let first = observations.first?.capturedAt
        photos = observations.map { observation in
            PhotoItem(
                id: observation.sequence,
                secondsAfterFirst: ReadExportBuilder.seconds(observation.capturedAt, after: first),
                lines: observation.lines.enumerated().map { index, line in
                    LineItem(id: LineKey(photo: observation.sequence, index: index), text: line.text, flag: SensitiveText.flag(line.text))
                },
                codes: observation.codes.map(ReadExportBuilder.code)
            )
        }

        let sequence = Dictionary(observations.map { ($0.photo, $0.sequence) }, uniquingKeysWith: { first, _ in first })
        var names: [NameItem] = []
        for (index, group) in trace.result.groups.prefix(IntakeLimits.candidatesPerBatch).enumerated() {
            let label = source.proposer.proposals(
                photos: group.photos, shared: Set(group.sharedPhotos), barcode: group.barcode, observations: source.review.observations
            )
            if let name = label.name {
                names.append(NameItem(
                    id: .label(group: index), text: name, flag: SensitiveText.flag(name), photos: group.photos.compactMap { sequence[$0] }
                ))
            }
        }
        for (barcode, answer) in source.review.lookups.sorted(by: { $0.key.digits < $1.key.digits }) {
            guard case .found(let name, _) = answer else { continue }
            let shown = trace.result.groups.filter { $0.barcode == barcode }.flatMap(\.photos).compactMap { sequence[$0] }
            names.append(NameItem(id: .lookup(barcode: barcode.digits), text: name, flag: SensitiveText.flag(name), photos: shown))
        }
        for (index, candidate) in source.review.candidates.enumerated() where candidate.nameDecided {
            guard let name = candidate.personName else { continue }
            names.append(NameItem(
                id: .person(package: index), text: name, flag: SensitiveText.flag(name),
                photos: candidate.photos.compactMap { sequence[$0] }.sorted()
            ))
        }
        self.names = names
        excludedLines = Set(photos.flatMap(\.lines).filter { $0.flag != nil }.map(\.id))
        excludedNames = Set(names.filter { $0.flag != nil }.map(\.id))
    }

    // MARK: The person's choices

    public func includes(photo: Int) -> Bool { !excludedPhotos.contains(photo) }

    public func includes(_ line: LineKey) -> Bool { includes(photo: line.photo) && !excludedLines.contains(line) }

    /// Whether a name is shared: the person did not leave it out, and, for a name read from a label,
    /// it does not come from a line or photo that is left out.
    public func includes(_ name: NameKey) -> Bool {
        guard !excludedNames.contains(name) else { return false }
        switch name {
        case .label(let group):
            return !builder.labelNameWithheldByText(group: group)
        case .lookup(let barcode):
            return !builder.withheldBarcodes.contains(barcode)
        case .person:
            return true
        }
    }

    public mutating func setIncluded(_ included: Bool, photo: Int) {
        if included { excludedPhotos.remove(photo) } else { excludedPhotos.insert(photo) }
    }

    public mutating func setIncluded(_ included: Bool, line: LineKey) {
        if included { excludedLines.remove(line) } else { excludedLines.insert(line) }
    }

    public mutating func setIncluded(_ included: Bool, name: NameKey) {
        if included { excludedNames.remove(name) } else { excludedNames.insert(name) }
    }

    /// Lines the automatic check flagged that are still left out.
    public var linesLeftOutByCheck: Int {
        photos.flatMap(\.lines).filter { $0.flag != nil && !includes($0.id) && includes(photo: $0.id.photo) }.count
    }

    // MARK: The export

    /// The export as it would be shared now.
    public func export() -> ReadExport {
        builder.export(linesByCheck: linesLeftOutByCheck)
    }

    private var builder: ReadExportBuilder {
        ReadExportBuilder(
            source: source, trace: trace, observations: observations, excludedPhotos: excludedPhotos,
            excludedLines: excludedLines, excludedNames: excludedNames
        )
    }
}
