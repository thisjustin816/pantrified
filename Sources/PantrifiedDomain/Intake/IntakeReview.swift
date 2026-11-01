import Foundation

/// Reads what a candidate's photos propose. Pure: the same photos always give the same proposals.
public struct IntakeProposer: Sendable {
    private let dates: any PrintedDateReader

    public init(dates: any PrintedDateReader = PrintedDateRecognition()) {
        self.dates = dates
    }

    public func proposals(
        photos: [IntakePhotoID],
        shared: Set<IntakePhotoID>,
        barcode: GTIN?,
        observations: [IntakePhotoID: PhotoObservation]
    ) -> LabelProposals {
        let all = photos.compactMap { observations[$0] }
        // A photo of several products cannot say which of them a name or date belongs to.
        let own = all.filter { !shared.contains($0.photo) && $0.kind == .package }
        var result = LabelProposals()

        var best: (name: String, height: Double)?
        for observation in own {
            guard let line = LabelText.prominentLine(in: observation.lines) else { continue }
            if best == nil || line.height > best!.height { best = line }
        }
        result.name = best?.name

        let readings = own.flatMap { dates.readings(in: $0.lines, takenAt: $0.capturedAt) }
        if let preferred = PrintedDateParser.preferred(readings) {
            switch preferred.value {
            case .resolved(let date, _):
                result.date = .resolved(PrintedDate(label: preferred.label, date: date))
            case .ambiguous(let monthFirst, let dayFirst):
                result.date = .ambiguous(PendingDateChoice(label: preferred.label, monthFirst: monthFirst, dayFirst: dayFirst))
            }
        }
        var distinct: Set<Date> = []
        for reading in readings where reading.label != .packed {
            switch reading.value {
            case .resolved(let date, _): distinct.insert(date)
            case .ambiguous: continue
            }
        }
        result.datesDisagree = distinct.count > 1

        result.storage = own.lazy.compactMap { LabelText.statedStorage(in: $0.lines) }.first
        var refused: [RefusedCode] = []
        for code in all.flatMap(\.codes) {
            switch code {
            case .refused(let reason) where !refused.contains(reason): refused.append(reason)
            case .link: result.sawLink = true
            default: continue
            }
        }
        result.refusedCodes = refused
        if let barcode {
            let sequences = all.filter { $0.products.contains(barcode) }.map(\.sequence).sorted()
            result.barcodeSeenApart = zip(sequences, sequences.dropFirst()).contains { $1 - $0 > 1 }
        }
        return result
    }
}

public enum IntakeReviewError: Error, Sendable, Equatable {
    case unknownCandidate
    /// Merging needs at least two candidates still under review.
    case needsTwo
    /// Two barcodes name two products, so the candidates stay apart.
    case differentBarcodes
    /// A candidate's only photo cannot be split out of it.
    case onlyPhoto
    case tooManyCandidates
}

/// A batch under review: its candidates, the observations they were made from, and the lookups.
/// Every change the person makes can be undone, newest first. Lookup answers are not changes and
/// survive an undo.
public struct IntakeReview: Sendable, Hashable, Codable {
    public let space: SpaceID
    public private(set) var candidates: [IntakeCandidate]
    /// Not encoded: the staging store keeps each observation once, with its photo, and gives them
    /// back with `attachObservations` after decoding.
    public private(set) var observations: [IntakePhotoID: PhotoObservation] = [:]
    public private(set) var lookups: [GTIN: LookupAnswer] = [:]
    /// Whether barcodes are looked up at all, so the review can say a lookup is still running.
    public let looksUp: Bool
    /// Candidates being added, written down before their packages are saved, so an add cut off by a
    /// crash is finished on the next launch instead of half done.
    public private(set) var pendingAdd: Set<IntakeCandidateID> = []
    /// Candidates whose add is being undone, for the same reason.
    public private(set) var pendingUndo: Set<IntakeCandidateID> = []
    private var history: [[IntakeCandidate]] = []

    static let historyLimit = 40
    public static let maximumLookupAttempts = LookupAnswer.maximumAttempts

    private enum CodingKeys: String, CodingKey {
        case space, candidates, lookups, looksUp, pendingAdd, pendingUndo
    }

    /// Gives a decoded review back the observations it was made from.
    public mutating func attachObservations(_ observations: [PhotoObservation]) {
        for observation in observations where self.observations[observation.photo] == nil {
            self.observations[observation.photo] = observation
        }
    }

    public init(
        space: SpaceID,
        observations: [PhotoObservation],
        grouping: GroupingResult,
        proposer: IntakeProposer = IntakeProposer(),
        locations: [StorageLocation],
        defaultLocation: LocationID?,
        looksUp: Bool
    ) {
        self.space = space
        self.looksUp = looksUp
        var byPhoto: [IntakePhotoID: PhotoObservation] = [:]
        for observation in observations where byPhoto[observation.photo] == nil { byPhoto[observation.photo] = observation }
        self.observations = byPhoto
        let groups = grouping.groups.prefix(IntakeLimits.candidatesPerBatch)
        var made: [IntakeCandidate] = []
        for group in groups {
            let label = proposer.proposals(
                photos: group.photos, shared: Set(group.sharedPhotos), barcode: group.barcode, observations: byPhoto
            )
            let stated = label.storage.flatMap { type in locations.first { $0.storageType == type }?.id }
            made.append(IntakeCandidate(
                photos: group.photos, links: group.links, sharedPhotos: group.sharedPhotos, barcode: group.barcode,
                label: label, location: stated ?? defaultLocation, locationOrigin: stated == nil ? .standard : .label
            ))
        }
        for suggestion in grouping.suggestions where suggestion.first < made.count && suggestion.second < made.count {
            made[suggestion.first].mightBeSameAs.append(made[suggestion.second].id)
            made[suggestion.second].mightBeSameAs.append(made[suggestion.first].id)
        }
        candidates = made
    }

    // MARK: Reading

    public var canUndo: Bool { !history.isEmpty }

    public var reviewing: [IntakeCandidate] { candidates.filter { $0.status == .reviewing } }

    /// Nothing is left to review: every candidate was added or deleted.
    public var isFinished: Bool { reviewing.isEmpty }

    /// An add or an undo is on record and not finished. A review can be finished while an undo of
    /// its last add is on record, because its candidates stay added until the undo is done.
    public var hasAddOrUndoInProgress: Bool { !pendingAdd.isEmpty || !pendingUndo.isEmpty }

    public func candidate(_ id: IntakeCandidateID) -> IntakeCandidate? {
        candidates.first { $0.id == id }
    }

    public func summary(of id: IntakeCandidateID) -> CandidateSummary? {
        candidate(id).map(summary)
    }

    public var summaries: [CandidateSummary] { reviewing.map(summary) }

    public func summary(_ candidate: IntakeCandidate) -> CandidateSummary {
        let answer = candidate.barcode.flatMap { lookups[$0] }
        let name: String?
        let nameOrigin: NameOrigin?
        if candidate.nameDecided {
            name = candidate.personName
            nameOrigin = candidate.personName == nil ? nil : .person
        } else if case .found(let found, let source)? = answer {
            name = found
            nameOrigin = .lookup(source: source)
        } else if let read = candidate.label.name {
            name = read
            nameOrigin = .label
        } else {
            name = nil
            nameOrigin = nil
        }

        var date: PrintedDate?
        var dateOrigin: DateOrigin?
        var pending: PendingDateChoice?
        if candidate.dateDecided {
            date = candidate.personDate
            dateOrigin = date == nil ? nil : .person
        } else {
            switch candidate.label.date {
            case .resolved(let read)?:
                date = read
                dateOrigin = .label
            case .ambiguous(let choice)?:
                pending = choice
            case nil:
                break
            }
        }

        var notes: [CandidateNote] = []
        let others = candidate.mightBeSameAs.filter { id in self.candidate(id)?.status == .reviewing }
        if !others.isEmpty { notes.append(.mightBeSameAs(others)) }
        if (name ?? "").isEmpty { notes.append(.noName) }
        if pending != nil { notes.append(.dateUnclear) }
        if !candidate.dateDecided, candidate.label.datesDisagree { notes.append(.datesDisagree) }
        let signals = candidate.signals
        if signals.contains(.datePhotoAfter) || signals.contains(.datePhotoBefore) { notes.append(.dateMatchedByOrder) }
        if !candidate.sharedPhotos.isEmpty { notes.append(.severalProducts) }
        if signals.contains(.identicalPhoto) { notes.append(.duplicatePhotos) }
        if candidate.label.barcodeSeenApart, candidate.count == 1 { notes.append(.maybeSeveralPackages) }
        if candidate.barcode == nil, let refused = candidate.label.refusedCodes.first { notes.append(.refusedBarcode(refused)) }
        if candidate.label.sawLink { notes.append(.linkSeen) }
        if candidate.barcode != nil, !candidate.nameDecided, looksUp {
            switch answer {
            case nil: notes.append(.lookingUp)
            case .failed?: notes.append(.lookupFailed)
            case .deferred?: notes.append(.lookupPaused)
            case .notFound?: notes.append(.lookupFoundNothing)
            case .found?: break
            }
        }

        return CandidateSummary(
            id: candidate.id, photos: candidate.photos, name: name, nameOrigin: nameOrigin, date: date,
            dateOrigin: dateOrigin, pendingDate: pending, location: candidate.location,
            locationOrigin: candidate.locationOrigin, count: candidate.count, barcode: candidate.barcode,
            signals: signals, notes: notes, status: candidate.status
        )
    }

    /// Candidates still under review that can be added as they are.
    public var readyToAdd: [IntakeCandidateID] {
        reviewing.filter { !pendingAdd.contains($0.id) }.map(summary).filter(\.isReady).map(\.id)
    }

    /// The drafts that adding these candidates puts away: one per package, with the name and date
    /// as proposals unless the person set them. Candidates that are not ready are left out.
    public func drafts(for ids: [IntakeCandidateID]) -> [PackageDraft] {
        var drafts: [PackageDraft] = []
        for id in ids {
            guard let candidate = candidate(id), candidate.status == .reviewing else { continue }
            let shown = summary(candidate)
            guard shown.isReady else { continue }
            for packageID in candidate.packagesToAdd {
                var draft = PackageDraft(id: packageID, spaceID: space, barcode: candidate.barcode)
                if candidate.nameDecided { draft.name.confirm(candidate.personName) } else if let name = shown.name { draft.name.propose(name) }
                if candidate.dateDecided {
                    draft.printedDate.confirm(candidate.personDate)
                } else if let date = shown.date {
                    draft.printedDate.propose(date)
                }
                draft.location = candidate.location
                drafts.append(draft)
            }
        }
        return drafts
    }

    /// Barcodes still without an answer, or whose lookup failed fewer than the allowed times, in
    /// the order of their candidates. A miss is final; a failure is tried again later.
    public var barcodesToLookUp: [GTIN] {
        var seen: Set<GTIN> = []
        return reviewing.compactMap { candidate -> GTIN? in
            guard let barcode = candidate.barcode, !candidate.nameDecided, seen.insert(barcode).inserted else { return nil }
            return LookupAnswer.needsAsking(lookups[barcode]) ? barcode : nil
        }
    }

    // MARK: Recognition results

    /// Keeps a lookup's answer. A failure or a deferral never replaces an answer already found.
    public mutating func record(_ answer: LookupAnswer, for barcode: GTIN) {
        lookups[barcode] = LookupAnswer.combining(lookups[barcode], with: answer)
    }

    /// Takes the answers already kept for the batch, which were combined as they arrived.
    public mutating func useLookups(_ answers: [GTIN: LookupAnswer]) {
        lookups.merge(answers) { _, kept in kept }
    }

    // MARK: The person's changes, each undoable

    public mutating func undo() -> Bool {
        guard let previous = history.popLast() else { return false }
        candidates = previous
        return true
    }

    public mutating func setName(_ name: String?, for id: IntakeCandidateID) throws(IntakeReviewError) {
        try change(id) { candidate in
            let cleaned = name.map { BoundedText.clean($0, characters: IntakeLimits.nameCharacters, bytes: IntakeLimits.nameBytes) }
            candidate.personName = (cleaned?.isEmpty ?? true) ? nil : cleaned
            candidate.nameDecided = true
        }
    }

    /// Sets or clears the date. Either way the person decided it, so no reading replaces it.
    public mutating func setDate(_ date: PrintedDate?, for id: IntakeCandidateID) throws(IntakeReviewError) {
        try change(id) { candidate in
            candidate.personDate = date
            candidate.dateDecided = true
        }
    }

    /// Picks one reading of a date that reads two ways. An unknown order changes nothing.
    public mutating func chooseDateOrder(_ order: DateOrderHint, for id: IntakeCandidateID) throws(IntakeReviewError) {
        guard let candidate = candidate(id) else { throw .unknownCandidate }
        guard case .ambiguous(let choice)? = candidate.label.date, !candidate.dateDecided, order != .unknown else { return }
        let day = order == .monthFirst ? choice.monthFirst : choice.dayFirst
        try setDate(PrintedDate(label: choice.label, date: day), for: id)
    }

    public mutating func setCount(_ count: Int, for id: IntakeCandidateID) throws(IntakeReviewError) {
        try change(id) { candidate in
            candidate.count = min(max(count, 1), IntakeLimits.packagesPerCandidate)
            while candidate.packageIDs.count < candidate.count { candidate.packageIDs.append(PackageID()) }
        }
    }

    /// Puts every listed candidate in one place, as one change to undo.
    public mutating func assignLocation(_ location: LocationID, to ids: Set<IntakeCandidateID>) {
        guard candidates.contains(where: { ids.contains($0.id) && $0.status == .reviewing }) else { return }
        remember()
        for index in candidates.indices where ids.contains(candidates[index].id) && candidates[index].status == .reviewing {
            candidates[index].location = location
            candidates[index].locationOrigin = .person
        }
    }

    public mutating func delete(_ ids: Set<IntakeCandidateID>) {
        guard candidates.contains(where: { ids.contains($0.id) && $0.status == .reviewing }) else { return }
        remember()
        candidates.removeAll { ids.contains($0.id) && $0.status == .reviewing }
        let remaining = Set(candidates.map(\.id))
        for index in candidates.indices { candidates[index].mightBeSameAs.removeAll { !remaining.contains($0) } }
    }

    /// Says two candidates are different packages, so neither suggests the other again.
    public mutating func keepApart(_ a: IntakeCandidateID, _ b: IntakeCandidateID) throws(IntakeReviewError) {
        guard let i = index(a), let j = index(b) else { throw .unknownCandidate }
        remember()
        candidates[i].mightBeSameAs.removeAll { $0 == b }
        candidates[j].mightBeSameAs.removeAll { $0 == a }
    }

    /// Merges candidates into the first of them in review order. The person's own decisions on any
    /// of them are kept, the first candidate's winning; label proposals are read again from all the
    /// photos. Candidates with two different barcodes are two products and are refused.
    @discardableResult
    public mutating func merge(_ ids: [IntakeCandidateID], proposer: IntakeProposer = IntakeProposer()) throws(IntakeReviewError) -> IntakeCandidateID {
        let wanted = Set(ids)
        let ordered = candidates.filter { wanted.contains($0.id) }
        guard ordered.count == wanted.count else { throw .unknownCandidate }
        guard ordered.count >= 2, ordered.allSatisfy({ $0.status == .reviewing }) else { throw .needsTwo }
        guard Set(ordered.compactMap(\.barcode)).count <= 1 else { throw .differentBarcodes }

        var merged = ordered[0]
        let others = ordered.dropFirst()
        for other in others {
            for photo in other.photos where !merged.photos.contains(photo) { merged.photos.append(photo) }
            merged.links += other.links
            merged.links.append(GroupLink(photo: other.photos[0], matchedWith: merged.photos[0], signals: [.groupedByPerson], score: 0))
            for photo in other.sharedPhotos where !merged.sharedPhotos.contains(photo) { merged.sharedPhotos.append(photo) }
            merged.barcode = merged.barcode ?? other.barcode
            if !merged.nameDecided, other.nameDecided {
                merged.nameDecided = true
                merged.personName = other.personName
            }
            if !merged.dateDecided, other.dateDecided {
                merged.dateDecided = true
                merged.personDate = other.personDate
            }
            if merged.locationOrigin != .person, other.locationOrigin == .person {
                merged.location = other.location
                merged.locationOrigin = .person
            }
            merged.count = max(merged.count, other.count)
            merged.packageIDs += other.packageIDs
            merged.mightBeSameAs += other.mightBeSameAs
        }
        merged.photos = sortedBySequence(merged.photos)
        var seenMatches: Set<IntakeCandidateID> = []
        merged.mightBeSameAs = merged.mightBeSameAs.filter { !wanted.contains($0) && seenMatches.insert($0).inserted }
        merged.label = proposer.proposals(
            photos: merged.photos, shared: Set(merged.sharedPhotos), barcode: merged.barcode, observations: observations
        )

        remember()
        let absorbed = Set(others.map(\.id))
        candidates.removeAll { absorbed.contains($0.id) }
        for index in candidates.indices {
            if candidates[index].id == merged.id {
                candidates[index] = merged
                continue
            }
            var replaced: [IntakeCandidateID] = []
            for id in candidates[index].mightBeSameAs {
                let target = absorbed.contains(id) ? merged.id : id
                if !replaced.contains(target) { replaced.append(target) }
            }
            candidates[index].mightBeSameAs = replaced
        }
        return merged.id
    }

    /// Moves one photo out of a candidate into a new candidate of its own, placed right after it.
    /// The person's decisions stay with the original; the new one keeps only its location.
    @discardableResult
    public mutating func split(
        _ photo: IntakePhotoID,
        from id: IntakeCandidateID,
        proposer: IntakeProposer = IntakeProposer()
    ) throws(IntakeReviewError) -> IntakeCandidateID {
        guard let index = index(id), candidates[index].status == .reviewing, candidates[index].photos.contains(photo) else {
            throw .unknownCandidate
        }
        guard candidates[index].photos.count >= 2 else { throw .onlyPhoto }
        guard candidates.count < IntakeLimits.candidatesPerBatch else { throw .tooManyCandidates }

        var source = candidates[index]
        let wasShared = source.sharedPhotos.contains(photo)
        source.photos.removeAll { $0 == photo }
        source.sharedPhotos.removeAll { $0 == photo }
        source.links.removeAll { $0.photo == photo || $0.matchedWith == photo }
        source.barcode = barcode(of: source.photos, preferring: source.barcode)
        source.label = proposer.proposals(
            photos: source.photos, shared: Set(source.sharedPhotos), barcode: source.barcode, observations: observations
        )

        let barcode = barcode(of: [photo], preferring: candidates[index].barcode)
        let label = proposer.proposals(photos: [photo], shared: wasShared ? [photo] : [], barcode: barcode, observations: observations)
        let split = IntakeCandidate(
            photos: [photo], sharedPhotos: wasShared ? [photo] : [], barcode: barcode, label: label,
            location: source.location, locationOrigin: source.locationOrigin
        )

        remember()
        candidates[index] = source
        candidates.insert(split, at: index + 1)
        return split.id
    }

    // MARK: Adding

    /// Records that these candidates are about to be added. Adding is not an undoable review
    /// change: it is undone through the inventory, with `beginUndo` and `markReviewing`. Adding and
    /// undoing an add each clear the review's undo history, because an older snapshot holds an
    /// older status and older package identities: restoring it would put an added candidate back
    /// in review while its package stays in the pantry, or reuse a discarded package's identity.
    public mutating func beginAdd(_ ids: Set<IntakeCandidateID>) {
        pendingAdd.formUnion(ids)
    }

    /// The add failed and nothing was saved; these candidates simply stay in review.
    public mutating func cancelAdd(_ ids: Set<IntakeCandidateID>) {
        pendingAdd.subtract(ids)
    }

    public mutating func markAdded(_ ids: Set<IntakeCandidateID>) {
        for index in candidates.indices where ids.contains(candidates[index].id) { candidates[index].status = .added }
        pendingAdd.subtract(ids)
        history = []
    }

    public mutating func beginUndo(_ ids: Set<IntakeCandidateID>) {
        pendingUndo.formUnion(ids)
    }

    /// Puts added candidates back under review with new package identities, because the packages
    /// they made stay in the inventory's history as discarded. An add still on record for them is
    /// over too: its packages are the ones the undo discarded, and finishing it on the next launch
    /// would put the food away again.
    public mutating func markReviewing(_ ids: Set<IntakeCandidateID>) {
        for index in candidates.indices where ids.contains(candidates[index].id) {
            candidates[index].status = .reviewing
            candidates[index].packageIDs = candidates[index].packageIDs.map { _ in PackageID() }
        }
        pendingAdd.subtract(ids)
        pendingUndo.subtract(ids)
        history = []
    }

    /// Gives these candidates new package identities. For a candidate whose package identity is
    /// already in the inventory although the candidate is not added, so adding it makes a package
    /// instead of finding the old one. Not an undoable change.
    public mutating func renewPackages(_ ids: Set<IntakeCandidateID>) {
        for index in candidates.indices where ids.contains(candidates[index].id) && candidates[index].status == .reviewing {
            candidates[index].packageIDs = candidates[index].packageIDs.map { _ in PackageID() }
        }
    }

    // MARK: Helpers

    private func index(_ id: IntakeCandidateID) -> Int? {
        candidates.firstIndex { $0.id == id }
    }

    private mutating func remember() {
        history.append(candidates)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    private mutating func change(_ id: IntakeCandidateID, _ body: (inout IntakeCandidate) -> Void) throws(IntakeReviewError) {
        guard let index = index(id), candidates[index].status == .reviewing else { throw .unknownCandidate }
        remember()
        body(&candidates[index])
    }

    private func sortedBySequence(_ photos: [IntakePhotoID]) -> [IntakePhotoID] {
        photos.enumerated().sorted { a, b in
            let (sa, sb) = (observations[a.element]?.sequence ?? Int.max, observations[b.element]?.sequence ?? Int.max)
            return sa != sb ? sa < sb : a.offset < b.offset
        }
        .map(\.element)
    }

    /// The barcode a set of photos shows: the preferred one while any photo still shows it, or the
    /// first product a photo of one product shows.
    private func barcode(of photos: [IntakePhotoID], preferring preferred: GTIN?) -> GTIN? {
        let shown = photos.compactMap { observations[$0] }
        if let preferred, shown.contains(where: { $0.products.contains(preferred) }) { return preferred }
        return shown.lazy.compactMap { $0.products.count == 1 ? $0.products[0] : nil }.first
    }
}
