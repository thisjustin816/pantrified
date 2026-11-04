import Foundation
import PantrifiedDomain

/// Turns a batch, its grouping trace and what the person left out into a `ReadExport`.
struct ReadExportBuilder {
    let source: ReadExportSource
    let trace: GroupingTrace
    /// In sequence order.
    let observations: [PhotoObservation]
    let excludedPhotos: Set<Int>
    let excludedLines: Set<ReadExportDraft.LineKey>
    let excludedNames: Set<ReadExportDraft.NameKey>

    private var review: IntakeReview { source.review }

    private var sequence: [IntakePhotoID: Int] {
        Dictionary(observations.map { ($0.photo, $0.sequence) }, uniquingKeysWith: { first, _ in first })
    }

    private var groups: ArraySlice<PhotoGroup> { trace.result.groups.prefix(IntakeLimits.candidatesPerBatch) }

    /// Product numbers shown only on photos left out. They are left out everywhere.
    var withheldBarcodes: Set<String> {
        var removed: Set<String> = []
        var kept: Set<String> = []
        for observation in observations {
            let digits = observation.products.map(\.digits)
            if excludedPhotos.contains(observation.sequence) { removed.formUnion(digits) } else { kept.formUnion(digits) }
        }
        return removed.subtracting(kept)
    }

    /// The observations as shared: lines left out are gone, and photos left out have no lines or codes.
    private var redacted: [IntakePhotoID: PhotoObservation] {
        var result: [IntakePhotoID: PhotoObservation] = [:]
        for observation in observations {
            let removed = excludedPhotos.contains(observation.sequence)
            let lines = removed ? [] : observation.lines.enumerated()
                .filter { !excludedLines.contains(.init(photo: observation.sequence, index: $0.offset)) }
                .map(\.element)
            result[observation.photo] = PhotoObservation(
                photo: observation.photo, kind: observation.kind, sequence: observation.sequence,
                capturedAt: observation.capturedAt, lines: lines, codes: removed ? [] : observation.codes,
                featurePrint: observation.featurePrint, contentDigest: observation.contentDigest
            )
        }
        return result
    }

    /// Whether the label name of a group would change if the lines and photos left out were not
    /// there, which means the name comes from text the person left out.
    func labelNameWithheldByText(group index: Int) -> Bool {
        guard groups.indices.contains(index) else { return false }
        let group = groups[index]
        return proposals(group, from: review.observations).name != proposals(group, from: redacted).name
    }

    private func proposals(_ group: PhotoGroup, from observations: [IntakePhotoID: PhotoObservation]) -> LabelProposals {
        source.proposer.proposals(photos: group.photos, shared: Set(group.sharedPhotos), barcode: group.barcode, observations: observations)
    }

    func export(linesByCheck: Int) -> ReadExport {
        let sequence = self.sequence
        let withheldBarcodes = self.withheldBarcodes
        let redacted = self.redacted
        let roles = Dictionary(trace.photos.map { ($0.photo, $0) }, uniquingKeysWith: { first, _ in first })
        let first = observations.first?.capturedAt
        var firstWithBytes: [String: Int] = [:]

        var photos: [ReadExport.Photo] = []
        var linesLeftOut = 0
        for observation in observations {
            let removed = excludedPhotos.contains(observation.sequence)
            var sameBytesAs: Int?
            if let digest = observation.contentDigest {
                if let earlier = firstWithBytes[digest] { sameBytesAs = earlier } else { firstWithBytes[digest] = observation.sequence }
            }
            let kept = redacted[observation.photo]
            if !removed { linesLeftOut += observation.lines.count - (kept?.lines.count ?? 0) }
            photos.append(ReadExport.Photo(
                sequence: observation.sequence,
                secondsAfterFirst: Self.seconds(observation.capturedAt, after: first),
                kind: observation.kind,
                role: roles[observation.photo]?.role ?? .other,
                showsPanel: roles[observation.photo]?.showsPanel ?? false,
                hasFeaturePrint: observation.featurePrint != nil,
                sameBytesAs: sameBytesAs,
                removed: removed,
                lines: (kept?.lines ?? []).map(Self.line),
                codes: (kept?.codes ?? []).map(Self.code)
            ))
        }

        let pairs = trace.pairs.compactMap { pair -> ReadExport.Pair? in
            guard let a = sequence[pair.first], let b = sequence[pair.second] else { return nil }
            return ReadExport.Pair(
                first: a, second: b, distance: pair.distance.map { Self.rounded($0, places: 4) }, signals: pair.signals,
                oneLetterOffPoints: pair.oneLetterOffPoints, shotOrderPoints: pair.shotOrderPoints, score: pair.score
            )
        }

        let exportedGroups = groups.enumerated().map { index, group in
            let original = proposals(group, from: review.observations)
            let shared = proposals(group, from: redacted)
            let barcode = group.barcode.map(\.digits).flatMap { withheldBarcodes.contains($0) ? nil : $0 }
            var nameSource = ReadExport.NameSource.none
            if let gtin = group.barcode, case .found? = review.lookups[gtin] {
                nameSource = .lookup
            } else if original.name != nil {
                nameSource = .label
            }
            let stated = original.storage.flatMap { type in source.locations.firstIndex { $0.storageType == type } }
            let proposedPlace = stated.map { self.place($0, origin: .label) }
                ?? (source.locations.isEmpty ? nil : self.place(0, origin: .standard))
            return ReadExport.Group(
                photos: group.photos.compactMap { sequence[$0] },
                barcode: barcode,
                sharedPhotos: group.sharedPhotos.compactMap { sequence[$0] },
                links: group.links.compactMap { link in
                    guard let photo = sequence[link.photo], let matched = sequence[link.matchedWith] else { return nil }
                    return ReadExport.Link(photo: photo, matchedWith: matched, signals: link.signals, score: link.score)
                },
                proposals: ReadExport.Proposals(
                    labelName: original.name.map { name in
                        .kept(name, unless: excludedNames.contains(.label(group: index)) || shared.name != original.name)
                    },
                    nameSource: nameSource,
                    date: original.date.map { Self.date($0, withheld: shared.date != original.date) },
                    datesDisagree: original.datesDisagree,
                    place: proposedPlace,
                    refusedCodes: original.refusedCodes,
                    sawLink: original.sawLink,
                    barcodeSeenApart: original.barcodeSeenApart
                )
            )
        }

        let suggestions = trace.result.suggestions
            .filter { $0.first < exportedGroups.count && $0.second < exportedGroups.count }
            .map { ReadExport.Suggestion(first: $0.first, second: $0.second, signals: $0.signals, score: $0.score) }

        var namesLeftOut = 0
        var lookups: [ReadExport.Lookup] = []
        for (gtin, answer) in review.lookups.sorted(by: { $0.key.digits < $1.key.digits }) where !withheldBarcodes.contains(gtin.digits) {
            switch answer {
            case .found(let name, let service):
                let withheld = excludedNames.contains(.lookup(barcode: gtin.digits))
                if withheld { namesLeftOut += 1 }
                lookups.append(.init(barcode: gtin.digits, answer: .found, name: .kept(name, unless: withheld), service: service, attempts: nil))
            case .notFound:
                lookups.append(.init(barcode: gtin.digits, answer: .notFound, name: nil, service: nil, attempts: nil))
            case .failed(let attempts):
                lookups.append(.init(barcode: gtin.digits, answer: .failed, name: nil, service: nil, attempts: attempts))
            case .deferred:
                lookups.append(.init(barcode: gtin.digits, answer: .deferred, name: nil, service: nil, attempts: nil))
            }
        }
        namesLeftOut += exportedGroups.filter { $0.proposals.labelName?.withheld == true }.count

        let corrections = self.corrections(sequence: sequence, groups: exportedGroups)
        namesLeftOut += corrections.packages.filter { $0.name?.withheld == true }.count

        return ReadExport(
            format: ReadExport.formatName,
            version: ReadExport.currentVersion,
            app: source.app,
            batchDay: first.map(Self.day) ?? "",
            photos: photos,
            pairs: pairs,
            distanceKeptUpTo: trace.distanceKeptUpTo,
            groups: exportedGroups,
            suggestions: suggestions,
            lookups: lookups,
            corrections: corrections,
            withheld: ReadExport.Withheld(
                photos: excludedPhotos.filter { number in observations.contains { $0.sequence == number } }.sorted(),
                lines: linesLeftOut,
                linesByCheck: linesByCheck,
                names: namesLeftOut,
                barcodes: withheldBarcodes.count
            )
        )
    }

    private func corrections(sequence: [IntakePhotoID: Int], groups: [ReadExport.Group]) -> ReadExport.Corrections {
        let candidates = review.candidates
        let index = Dictionary(candidates.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let packages = candidates.enumerated().map { position, candidate in
            let photos = candidate.photos.compactMap { sequence[$0] }.sorted()
            return ReadExport.Package(
                photos: photos,
                fromGroups: groups.indices.filter { !Set(groups[$0].photos).isDisjoint(with: photos) },
                mergedByPerson: candidate.links.contains { $0.signals.contains(.groupedByPerson) },
                status: candidate.status == .added ? .added : .reviewing,
                nameDecided: candidate.nameDecided,
                name: candidate.nameDecided
                    ? .kept(candidate.personName, unless: candidate.personName != nil && excludedNames.contains(.person(package: position)))
                    : nil,
                dateDecided: candidate.dateDecided,
                date: candidate.dateDecided ? candidate.personDate.map { Self.date(.resolved($0), withheld: false) } : nil,
                place: candidate.location.flatMap { id in source.locations.firstIndex { $0.id == id } }
                    .map { place($0, origin: candidate.locationOrigin) },
                count: candidate.count,
                suggestedWith: candidate.mightBeSameAs.compactMap { index[$0] }.sorted()
            )
        }
        let inPackages = Set(packages.flatMap(\.photos))
        let splitGroups = groups.indices.filter { group in
            packages.filter { !Set($0.photos).isDisjoint(with: groups[group].photos) }.count > 1
        }
        return ReadExport.Corrections(
            packages: packages,
            deletedPhotos: observations.map(\.sequence).filter { !inPackages.contains($0) },
            splitGroups: splitGroups
        )
    }

    private func place(_ position: Int, origin: LocationOrigin) -> ReadExport.Place {
        let kind: ReadExport.PlaceKind = switch source.locations[position].storageType {
        case .refrigerated: .fridge
        case .frozen: .freezer
        case .roomTemperature: .pantry
        }
        return ReadExport.Place(kind: kind, position: position + 1, source: origin)
    }

    // MARK: Values

    static func seconds(_ time: Date, after first: Date?) -> Double {
        rounded(time.timeIntervalSince(first ?? time), places: 1)
    }

    static func rounded(_ value: Double, places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    static func line(_ line: RecognizedTextLine) -> ReadExport.Line {
        ReadExport.Line(
            text: line.text,
            box: ReadExport.Box(
                x: rounded(line.box.x, places: 3), y: rounded(line.box.y, places: 3),
                width: rounded(line.box.width, places: 3), height: rounded(line.box.height, places: 3)
            ),
            confidence: line.confidence.map { rounded($0, places: 3) }
        )
    }

    static func code(_ code: CodeMeaning) -> ReadExport.Code {
        switch code {
        case .product(let gtin): ReadExport.Code(kind: .product, product: gtin.digits, refused: nil)
        case .refused(let reason): ReadExport.Code(kind: .refused, product: nil, refused: reason)
        case .link: ReadExport.Code(kind: .link, product: nil, refused: nil)
        case .otherQR: ReadExport.Code(kind: .otherQR, product: nil, refused: nil)
        }
    }

    /// The UTC calendar day, as printed dates are kept.
    static func day(_ date: Date) -> String {
        let parts = PrintedDateParser.utcCalendar.dateComponents([.year, .month, .day], from: date)
        return "\(padded(parts.year ?? 0, 4))-\(padded(parts.month ?? 0, 2))-\(padded(parts.day ?? 0, 2))"
    }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    static func label(_ label: PrintedDateLabel) -> ReadExport.DateLabel {
        switch label {
        case .useBy: .useBy
        case .bestBy: .bestBy
        case .sellBy: .sellBy
        case .freezeBy: .freezeBy
        case .packed: .packed
        case .unlabeled: .unlabeled
        }
    }

    static func date(_ proposal: DateProposal, withheld: Bool) -> ReadExport.DateRead {
        if withheld { return ReadExport.DateRead(label: nil, date: nil, monthFirst: nil, dayFirst: nil, withheld: true) }
        switch proposal {
        case .resolved(let printed):
            return ReadExport.DateRead(label: label(printed.label), date: day(printed.date), monthFirst: nil, dayFirst: nil, withheld: nil)
        case .ambiguous(let choice):
            return ReadExport.DateRead(
                label: label(choice.label), date: nil, monthFirst: day(choice.monthFirst), dayFirst: day(choice.dayFirst), withheld: nil
            )
        }
    }
}
