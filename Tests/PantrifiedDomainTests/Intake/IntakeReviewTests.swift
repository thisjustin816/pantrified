import Foundation
import Testing
import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
private let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
private let pantryShelf = StorageLocation(name: "Pantry", storageType: .roomTemperature)
private let space = SpaceID()

private func review(
    _ photos: [PhotoObservation], looksUp: Bool = true, places: PlaceContext = PlaceContext(locations: [fridge, freezer, pantryShelf])
) -> IntakeReview {
    IntakeReview(
        space: space, observations: photos, grouping: PhotoGrouper().group(photos), places: places, looksUp: looksUp
    )
}

/// A household that kept the yogurt's barcode in the fridge and basmati rice in the pantry before.
private let stocked = PlaceContext(locations: [fridge, freezer, pantryShelf], placements: [
    PastPlacement(package: PackageID(), name: "Yogurt", barcode: Fixture.yogurt, location: fridge.id, at: Fixture.start),
    PastPlacement(package: PackageID(), name: "Basmati rice", barcode: nil, location: pantryShelf.id, at: Fixture.start),
])

/// Yogurt front and back (one candidate with a barcode), then rice on its own, each with the place
/// the household used before.
private func yogurtAndRice() -> (IntakeReview, [PhotoObservation]) {
    let photos = [
        Fixture.photo(0, lines: Fixture.front("GREEK YOGURT", brand: "CHOBANI")),
        Fixture.photo(1, lines: Fixture.back(["Chobani greek yogurt"]) + [Fixture.line("USE BY 11/20/2026", row: 0.95, size: 0.02)],
                      codes: [.product(Fixture.yogurt)]),
        Fixture.photo(2, seconds: 300, lines: Fixture.front("Basmati rice", small: ["Best before 05/06/27"])),
    ]
    return (review(photos, places: stocked), photos)
}

@Suite("Intake review")
struct IntakeReviewTests {
    // MARK: Proposals and provenance

    @Test("a candidate proposes its name and date from the label, saying so, and is ready to add")
    func proposalsFromTheLabel() throws {
        let (review, _) = yogurtAndRice()
        let yogurt = try #require(review.summaries.first)
        #expect(yogurt.name == "Chobani greek yogurt")
        #expect(yogurt.nameOrigin == .label)
        #expect(yogurt.date == PrintedDate.onDay(.useBy, year: 2026, month: 11, day: 20))
        #expect(yogurt.dateOrigin == .label)
        #expect(yogurt.barcode == Fixture.yogurt)
        #expect(yogurt.location == fridge.id)
        #expect(yogurt.locationOrigin == .remembered)
        #expect(yogurt.notes == [.lookingUp])
        #expect(yogurt.isReady)
    }

    @Test("a date that reads two ways is held as a choice, and choosing makes it the person's")
    func ambiguousDate() throws {
        var (review, _) = yogurtAndRice()
        let rice = review.summaries[1]
        #expect(rice.date == nil)
        #expect(rice.pendingDate != nil)
        #expect(rice.notes.contains(.dateUnclear))
        #expect(rice.isReady)

        try review.chooseDateOrder(.dayFirst, for: rice.id)
        let chosen = try #require(review.summary(of: rice.id))
        #expect(chosen.date == PrintedDate.onDay(.bestBy, year: 2027, month: 6, day: 5))
        #expect(chosen.dateOrigin == .person)
        #expect(!chosen.notes.contains(.dateUnclear))
    }

    @Test("a lookup's name replaces the label's proposal and says where it came from")
    func lookupName() throws {
        var (review, _) = yogurtAndRice()
        review.record(.found(rawName: "PLAIN NONFAT GREEK YOGURT", source: "USDA FoodData Central"), for: Fixture.yogurt)
        let yogurt = try #require(review.summaries.first)
        #expect(yogurt.name == "Plain nonfat greek yogurt")
        #expect(yogurt.nameOrigin == .lookup(source: "USDA FoodData Central"))
        #expect(!yogurt.notes.contains(.lookingUp))
    }

    @Test("a name the person typed, even an empty one, wins over a lookup that answers later")
    func personWins() throws {
        var (review, _) = yogurtAndRice()
        let yogurt = review.summaries[0].id
        try review.setName("Skyr", for: yogurt)
        review.record(.found(rawName: "Greek yogurt", source: "USDA FoodData Central"), for: Fixture.yogurt)
        #expect(review.summary(of: yogurt)?.name == "Skyr")
        #expect(review.summary(of: yogurt)?.nameOrigin == .person)

        try review.setName("   ", for: yogurt)
        let cleared = try #require(review.summary(of: yogurt))
        #expect(cleared.name == nil)
        #expect(cleared.notes.contains(.noName))
        #expect(!cleared.isReady)
        #expect(review.barcodesToLookUp.isEmpty)
    }

    @Test("no name is invented: a photo without readable words has an empty name, marked")
    func noName() throws {
        let photos = [Fixture.photo(0, lines: [Fixture.line("12345 678", size: 0.2)])]
        let summary = try #require(review(photos).summaries.first)
        #expect(summary.name == nil)
        #expect(summary.notes.contains(.noName))
        #expect(!summary.isReady)
    }

    @Test("a lookup failure never replaces a found name, and failures are tried again a few times")
    func lookupFailures() {
        var (review, _) = yogurtAndRice()
        #expect(review.barcodesToLookUp == [Fixture.yogurt])
        for _ in 0..<IntakeReview.maximumLookupAttempts - 1 {
            review.record(.failed(attempts: 1), for: Fixture.yogurt)
            #expect(review.barcodesToLookUp == [Fixture.yogurt])
        }
        #expect(review.summaries[0].notes.contains(.lookupFailed))
        review.record(.failed(attempts: 1), for: Fixture.yogurt)
        #expect(review.barcodesToLookUp.isEmpty)

        review.record(.found(rawName: "Yogurt", source: "USDA"), for: Fixture.yogurt)
        review.record(.failed(attempts: 1), for: Fixture.yogurt)
        #expect(review.summaries[0].name == "Yogurt")
    }

    @Test("two candidates with one barcode ask the lookup once, and a deferral never replaces an answer")
    func oneLookupPerBarcode() throws {
        let photos = [
            Fixture.photo(0, codes: [.product(Fixture.beans)]),
            Fixture.photo(1, codes: [.product(Fixture.beans)]),
        ]
        var review = review(photos)
        try review.split(photos[1].photo, from: review.summaries[0].id)
        #expect(review.summaries.count == 2)
        #expect(review.summaries.allSatisfy { $0.barcode == Fixture.beans })
        #expect(review.barcodesToLookUp == [Fixture.beans])

        review.record(.deferred, for: Fixture.beans)
        #expect(review.barcodesToLookUp == [Fixture.beans])
        #expect(review.summaries[0].notes.contains(.lookupPaused))
        review.record(.notFound, for: Fixture.beans)
        review.record(.deferred, for: Fixture.beans)
        #expect(review.lookups[Fixture.beans] == .notFound)
        #expect(review.barcodesToLookUp.isEmpty)
    }

    @Test("a lookup's name is untrusted: cleaned, bounded and refused when empty")
    func hostileLookup() {
        let long = LookupAnswer.found(rawName: "Yog\u{202E}urt" + String(repeating: "é", count: 500), source: "X")
        guard case .found(let name, _) = long else { Issue.record("expected a name"); return }
        let bounded = name.count <= IntakeLimits.nameCharacters && name.utf8.count <= IntakeLimits.nameBytes
        #expect(bounded)
        #expect(!name.unicodeScalars.contains("\u{202E}"))
        #expect(LookupAnswer.found(rawName: "\u{0000}\u{202E} ", source: "X") == .notFound)
    }

    @Test("a label that says Keep frozen proposes the freezer, saying why")
    func statedStorage() throws {
        let photos = [Fixture.photo(0, lines: Fixture.front("Frozen peas", brand: "Birds Eye", small: ["KEEP FROZEN"]))]
        let summary = try #require(review(photos).summaries.first)
        #expect(summary.location == freezer.id)
        #expect(summary.locationOrigin == .label)
    }

    // MARK: Changes and undo

    @Test("merging keeps the person's decisions, reads the labels again, and undoes in one step")
    func mergeAndUndo() throws {
        // The back taken before the front: only a suggestion.
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        let (back, front) = (review.summaries[0].id, review.summaries[1].id)
        #expect(review.summaries[0].notes.contains(.mightBeSameAs([front])))
        review.assignLocation(freezer.id, to: [front])
        try review.setDate(PrintedDate.onDay(.bestBy, year: 2027, month: 1, day: 2), for: front)
        let before = review.candidates

        let merged = try review.merge([front, back])
        #expect(merged == back)
        let summary = try #require(review.summary(of: back))
        #expect(review.summaries.count == 1)
        #expect(summary.photos.count == 2)
        #expect(summary.barcode == Fixture.yogurt)
        #expect(summary.location == freezer.id)
        #expect(summary.dateOrigin == .person)
        #expect(summary.signals.contains(.groupedByPerson))
        #expect(!summary.notes.contains { if case .mightBeSameAs = $0 { true } else { false } })

        let undone = review.undo()
        #expect(undone)
        #expect(review.candidates == before)
    }

    @Test("candidates with two different barcodes cannot be merged")
    func mergeRefusesTwoBarcodes() throws {
        let photos = [
            Fixture.photo(0, codes: [.product(Fixture.beans)]),
            Fixture.photo(1, codes: [.product(Fixture.soup)]),
        ]
        let review = review(photos)
        #expect(throws: IntakeReviewError.differentBarcodes) { var copy = review; try copy.merge(review.summaries.map(\.id)) }
        #expect(throws: IntakeReviewError.needsTwo) { var copy = review; try copy.merge([review.summaries[0].id]) }
        #expect(!review.canUndo)
    }

    @Test("splitting a photo out makes a new candidate after the old one, each reading its own photos")
    func splitAndUndo() throws {
        var (review, photos) = yogurtAndRice()
        let yogurt = review.summaries[0].id
        try review.setName("Skyr", for: yogurt)
        let before = review.candidates

        let split = try review.split(photos[0].photo, from: yogurt)
        #expect(review.summaries.map(\.id) == [yogurt, split, review.summaries[2].id])
        let kept = try #require(review.summary(of: yogurt))
        #expect(kept.name == "Skyr")
        #expect(kept.barcode == Fixture.yogurt)
        let new = try #require(review.summary(of: split))
        #expect(new.name == "Chobani greek yogurt")
        #expect(new.nameOrigin == .label)
        #expect(new.barcode == nil)

        #expect(throws: IntakeReviewError.onlyPhoto) { var copy = review; try copy.split(photos[0].photo, from: split) }
        let undone = review.undo()
        #expect(undone)
        #expect(review.candidates == before)
    }

    @Test("bulk location assignment is one change, undone together")
    func bulkLocation() throws {
        var (review, _) = yogurtAndRice()
        let ids = Set(review.summaries.map(\.id))
        let before = review.candidates
        review.assignLocation(freezer.id, to: ids)
        #expect(review.summaries.allSatisfy { $0.location == freezer.id && $0.locationOrigin == .person })
        let undone = review.undo()
        #expect(undone)
        #expect(review.candidates == before)
        let undoneAgain = review.undo()
        #expect(!undoneAgain)
    }

    @Test("deleting removes a candidate and its suggestions, and undo brings it back")
    func deleteAndUndo() throws {
        // The back taken before the front: only a suggestion.
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        let front = review.summaries[1].id
        review.delete([front])
        #expect(review.summaries.count == 1)
        #expect(review.summaries[0].notes.allSatisfy { if case .mightBeSameAs = $0 { false } else { true } })
        let undone = review.undo()
        #expect(undone)
        #expect(review.summaries.count == 2)
    }

    @Test("keeping two candidates apart removes the suggestion both ways")
    func keepApart() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        #expect(review.summaries[0].notes.contains(.mightBeSameAs([review.summaries[1].id])))
        try review.keepApart(review.summaries[0].id, review.summaries[1].id)
        #expect(review.summaries.allSatisfy { $0.notes.allSatisfy { if case .mightBeSameAs = $0 { false } else { true } } })
    }

    // MARK: Drafts

    @Test("drafts carry the barcode, the date and one package per count, with proposals left as proposals")
    func drafts() throws {
        var (review, _) = yogurtAndRice()
        let (yogurt, rice) = (review.summaries[0].id, review.summaries[1].id)
        try review.setCount(3, for: yogurt)
        try review.setName("Rice", for: rice)

        let drafts = review.drafts(for: [yogurt, rice])
        try #require(drafts.count == 4)
        #expect(Set(drafts.map(\.id)).count == 4)
        let first = drafts[0]
        #expect(first.barcode == Fixture.yogurt)
        #expect(first.name.source == .recognized)
        #expect(first.printedDate.value == PrintedDate.onDay(.useBy, year: 2026, month: 11, day: 20))
        #expect(first.confirmedFields.isEmpty)
        #expect(drafts[3].confirmedFields == [.name])
        #expect(drafts[3].printedDate.value == nil)
        #expect(review.drafts(for: [yogurt, rice]).map(\.id) == drafts.map(\.id))

        try review.setCount(1, for: yogurt)
        #expect(review.drafts(for: [yogurt]).map(\.id) == [first.id])
    }

    @Test("a candidate that is not ready gives no draft, and added candidates leave the review")
    func addingStates() throws {
        var (review, _) = yogurtAndRice()
        let yogurt = review.summaries[0].id
        try review.setName(nil, for: yogurt)
        #expect(review.drafts(for: [yogurt]).isEmpty)
        #expect(review.readyToAdd == [review.summaries[1].id])

        review.beginAdd([review.summaries[1].id])
        #expect(review.pendingAdd.count == 1)
        review.markAdded([review.summaries[1].id])
        #expect(review.pendingAdd.isEmpty)
        #expect(review.summaries.map(\.id) == [yogurt])
        #expect(!review.isFinished)
    }

    @Test("putting added candidates back gives them new package identities")
    func reviewingAgain() throws {
        var (review, _) = yogurtAndRice()
        let rice = review.summaries[1].id
        let before = review.drafts(for: [rice]).map(\.id)
        review.markAdded([rice])
        review.markReviewing([rice])
        let after = review.drafts(for: [rice]).map(\.id)
        #expect(after.count == 1)
        #expect(after != before)
    }

    // MARK: Persistence

    @Test("a review survives encoding with every edit and lookup, but not its undo history or its observations")
    func coding() throws {
        var (review, _) = yogurtAndRice()
        try review.setName("Skyr", for: review.summaries[0].id)
        review.record(.notFound, for: Fixture.yogurt)
        review.beginAdd([review.summaries[1].id])

        var decoded = try JSONDecoder().decode(IntakeReview.self, from: JSONEncoder().encode(review))
        #expect(decoded.observations.isEmpty)
        decoded.attachObservations(Array(review.observations.values))
        #expect(decoded.candidates == review.candidates)
        #expect(decoded.lookups == review.lookups)
        #expect(decoded.pendingAdd == review.pendingAdd)
        #expect(decoded.summaries == review.summaries)
        #expect(!decoded.canUndo)
    }
}
