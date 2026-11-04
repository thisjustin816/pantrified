import Foundation
import Testing
import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
private let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
private let pantryShelf = StorageLocation(name: "Pantry", storageType: .roomTemperature)
private let household = [fridge, freezer, pantryShelf]

/// Guidance that gives fixed storage types by name and keeps every choice it is asked with.
private final class FixedGuide: UnopenedStorageGuide, @unchecked Sendable {
    private let lock = NSLock()
    private let types: [String: Set<StorageType>]
    private var asked: [GuidanceChoice?] = []

    init(_ types: [String: Set<StorageType>]) { self.types = types }

    var choices: [GuidanceChoice?] { lock.withLock { asked } }

    func unopenedStorage(of name: String, choice: GuidanceChoice?) -> Set<StorageType> {
        lock.withLock { asked.append(choice) }
        return types[name] ?? []
    }
}

private func placement(
    _ name: String, _ barcode: GTIN? = nil, in location: StorageLocation, minutes: Double = 0, choice: GuidanceChoice? = nil
) -> PastPlacement {
    PastPlacement(
        package: PackageID(), name: name, barcode: barcode, location: location.id,
        at: Fixture.start.addingTimeInterval(minutes * 60), guidanceChoice: choice
    )
}

private func review(_ photos: [PhotoObservation], places: PlaceContext = PlaceContext(locations: household)) -> IntakeReview {
    IntakeReview(space: SpaceID(), observations: photos, grouping: PhotoGrouper().group(photos), places: places, looksUp: false)
}

/// Yogurt with its barcode, rice, and a photo with no name, taken far apart so each is its own candidate.
private func threeFoods() -> [PhotoObservation] {
    [
        Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani"), codes: [.product(Fixture.yogurt)]),
        Fixture.photo(1, seconds: 300, lines: Fixture.front("Basmati rice")),
        Fixture.photo(2, seconds: 600),
    ]
}

@Suite("Place proposals")
struct PlaceProposalTests {
    // MARK: Order

    @Test("where the household last put the same barcode wins over its name, the label and the guidance")
    func barcodeFirst() {
        let guide = FixedGuide(["Greek yogurt": [.refrigerated]])
        let places = PlaceContext(locations: household, placements: [
            placement("Something else", Fixture.yogurt, in: freezer),
            placement("Greek yogurt", in: pantryShelf, minutes: 10),
        ], guide: guide)
        let proposal = places.proposal(barcode: Fixture.yogurt, name: "Greek yogurt", labelStorage: .refrigerated)
        #expect(proposal == PlaceProposal(location: freezer.id, origin: .remembered))
    }

    @Test("without the barcode, a past food with the same name gives the place, read as an ingredient name")
    func sameName() {
        let places = PlaceContext(locations: household, placements: [placement("basmati RICES", in: pantryShelf)])
        #expect(places.proposal(barcode: nil, name: "Basmati rice", labelStorage: .frozen) == PlaceProposal(location: pantryShelf.id, origin: .remembered))
        #expect(places.proposal(barcode: Fixture.beans, name: "Basmati rice", labelStorage: nil).origin == .remembered)
        #expect(places.proposal(barcode: nil, name: "Brown rice", labelStorage: nil).origin == .unplaced)
        #expect(places.proposal(barcode: nil, name: nil, labelStorage: nil).origin == .unplaced)
    }

    @Test("the newest placement of a product wins, and two at the same moment always give the same answer")
    func newestWins() {
        let older = placement("Milk", Fixture.yogurt, in: freezer, minutes: 0)
        let newer = placement("Milk", Fixture.yogurt, in: fridge, minutes: 5)
        for order in [[older, newer], [newer, older]] {
            let places = PlaceContext(locations: household, placements: order)
            #expect(places.proposal(barcode: Fixture.yogurt, name: nil, labelStorage: nil).location == fridge.id)
            #expect(places.proposal(barcode: nil, name: "milk", labelStorage: nil).location == fridge.id)
        }
        let tied = [placement("Milk", in: freezer), placement("Milk", in: pantryShelf)]
        let answers = Set([tied, tied.reversed()].map {
            PlaceContext(locations: household, placements: $0).proposal(barcode: nil, name: "Milk", labelStorage: nil).location
        })
        #expect(answers.count == 1)
    }

    @Test("a package counts from its last move still in effect, so an undone move counts from when it was added")
    func movedPackages() throws {
        var moved = Package(spaceID: SpaceID(), name: "Peas", location: pantryShelf.id, addedAt: Fixture.start)
        let other = Package(spaceID: SpaceID(), name: "Peas", location: fridge.id, addedAt: Fixture.start.addingTimeInterval(60))
        let move = try moved.record(.moved(to: freezer.id), at: Fixture.start.addingTimeInterval(120))
        #expect(moved.placedAt == Fixture.start.addingTimeInterval(120))

        var places = PlaceContext(locations: household, placements: [PastPlacement(moved, barcode: nil), PastPlacement(other, barcode: nil)])
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: nil).location == freezer.id)

        try moved.undo(move, at: Fixture.start.addingTimeInterval(180))
        #expect(moved.placedAt == Fixture.start)
        places = PlaceContext(locations: household, placements: [PastPlacement(moved, barcode: nil), PastPlacement(other, barcode: nil)])
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: nil).location == fridge.id)
    }

    @Test("a past place the household no longer has is skipped for an older one it has, then for the label")
    func unknownPlace() {
        let gone = StorageLocation(name: "Garage", storageType: .roomTemperature)
        var places = PlaceContext(locations: household, placements: [
            placement("Peas", in: gone, minutes: 10), placement("Peas", in: fridge, minutes: 0),
        ])
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: .frozen).location == fridge.id)
        places = PlaceContext(locations: household, placements: [placement("Peas", in: gone)])
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: .frozen) == PlaceProposal(location: freezer.id, origin: .label))
    }

    @Test("the label's stated storage comes before the guidance")
    func labelBeforeGuidance() {
        let places = PlaceContext(locations: household, guide: FixedGuide(["Peas": [.roomTemperature]]))
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: .frozen) == PlaceProposal(location: freezer.id, origin: .label))
        #expect(places.proposal(barcode: nil, name: "Peas", labelStorage: nil) == PlaceProposal(location: pantryShelf.id, origin: .foodKeeper))
    }

    @Test("with nothing to go on there is no place, never the first location")
    func nothingProposed() {
        let places = PlaceContext(locations: household, guide: FixedGuide([:]))
        #expect(places.proposal(barcode: Fixture.yogurt, name: "Greek yogurt", labelStorage: nil) == PlaceProposal(location: nil, origin: .unplaced))
        // A stated storage the household has no location for proposes nothing either.
        let fridgeOnly = PlaceContext(locations: [fridge])
        #expect(fridgeOnly.proposal(barcode: nil, name: "Peas", labelStorage: .frozen) == PlaceProposal(location: nil, origin: .unplaced))
    }

    // MARK: Guidance

    @Test("guidance proposes its only unopened storage, leaves the freezer out beside another, and nothing for two others")
    func unopenedPlace() {
        #expect(PlaceContext.unopenedPlace([.refrigerated]) == .refrigerated)
        #expect(PlaceContext.unopenedPlace([.frozen]) == .frozen)
        #expect(PlaceContext.unopenedPlace([.frozen, .refrigerated]) == .refrigerated)
        #expect(PlaceContext.unopenedPlace([.frozen, .roomTemperature]) == .roomTemperature)
        #expect(PlaceContext.unopenedPlace([.refrigerated, .roomTemperature]) == nil)
        #expect(PlaceContext.unopenedPlace([.frozen, .refrigerated, .roomTemperature]) == nil)
        #expect(PlaceContext.unopenedPlace([]) == nil)

        let guide = FixedGuide(["Butter": [.frozen, .refrigerated], "Apples": [.refrigerated, .roomTemperature]])
        let places = PlaceContext(locations: household, guide: guide)
        #expect(places.proposal(barcode: nil, name: "Butter", labelStorage: nil) == PlaceProposal(location: fridge.id, origin: .foodKeeper))
        #expect(places.proposal(barcode: nil, name: "Apples", labelStorage: nil).origin == .unplaced)
        // Guidance for a storage the household has no location for proposes nothing.
        #expect(PlaceContext(locations: [freezer], guide: guide).proposal(barcode: nil, name: "Butter", labelStorage: nil).origin == .unplaced)
    }

    @Test("the FoodKeeper food the person chose for the same product before is used, even from a place now gone")
    func rememberedChoice() {
        let chosen = GuidanceChoice.record(GuidanceRecordReference(source: "FoodKeeper", id: 7, name: "Butter", qualifier: nil))
        let gone = StorageLocation(name: "Garage", storageType: .roomTemperature)
        let guide = FixedGuide([:])
        let places = PlaceContext(locations: household, placements: [placement("Kerrygold", Fixture.yogurt, in: gone, choice: chosen)], guide: guide)
        _ = places.proposal(barcode: Fixture.yogurt, name: "Irish butter", labelStorage: nil)
        _ = places.proposal(barcode: nil, name: "kerrygold", labelStorage: nil)
        _ = places.proposal(barcode: nil, name: "Lard", labelStorage: nil)
        #expect(guide.choices == [chosen, chosen, nil])
    }

    @Test("the matcher gives the unopened storage of the one record a name matches, or of the record chosen")
    func matcherStorage() throws {
        func window(_ type: StorageType, _ anchor: WindowAnchor) -> GuidanceWindow { GuidanceWindow(storageType: type, anchor: anchor, days: 10) }
        let records = [
            GuidanceRecord(id: 1, name: "Butter", qualifier: nil, category: nil, keywords: [],
                           windows: [window(.frozen, .added), window(.refrigerated, .added), window(.roomTemperature, .opened)]),
            GuidanceRecord(id: 2, name: "Milk", qualifier: "plain", category: nil, keywords: [], windows: [window(.frozen, .added)]),
            GuidanceRecord(id: 3, name: "Milk", qualifier: "shelf-stable", category: nil, keywords: [], windows: [window(.roomTemperature, .added)]),
            GuidanceRecord(id: 4, name: "Ketchup", qualifier: nil, category: nil, keywords: [], windows: [window(.refrigerated, .opened)]),
        ]
        let provenance = GuidanceDataset.Provenance(source: "FoodKeeper", sourceVersion: nil, sourceChecksum: nil, normalizationVersion: "1")
        let matcher = GuidanceMatcher(dataset: try GuidanceDataset(provenance: provenance, records: records))
        #expect(matcher.unopenedStorage(of: "butter", choice: nil) == [.frozen, .refrigerated])
        #expect(matcher.unopenedStorage(of: "Milk", choice: nil) == [])
        #expect(matcher.unopenedStorage(of: "Ketchup", choice: nil) == [])
        #expect(matcher.unopenedStorage(of: "Bread", choice: nil) == [])
        let shelfStable = GuidanceChoice.record(GuidanceRecordReference(records[2], source: "FoodKeeper"))
        #expect(matcher.unopenedStorage(of: "Milk", choice: shelfStable) == [.roomTemperature])
        #expect(matcher.unopenedStorage(of: "Butter", choice: .noneOfThese) == [])
    }

    // MARK: The review

    @Test("each candidate keeps where its place came from, and one with no place waits outside Add all")
    func reviewProposals() throws {
        let places = PlaceContext(locations: household, placements: [placement("Yogurt", Fixture.yogurt, in: fridge)],
                                  guide: FixedGuide(["Basmati rice": [.roomTemperature]]))
        let proposed = review(threeFoods(), places: places)
        let summaries = proposed.summaries
        try #require(summaries.count == 3)
        #expect(summaries.map(\.location) == [fridge.id, pantryShelf.id, nil])
        #expect(summaries.map(\.locationOrigin) == [.remembered, .foodKeeper, .unplaced])

        let named = review(Array(threeFoods().prefix(2)), places: PlaceContext(locations: household))
        #expect(named.summaries.allSatisfy { $0.location == nil && !$0.isReady })
        #expect(named.readyToAdd.isEmpty)
        #expect(named.readyToAdd(in: household).isEmpty)
        #expect(named.drafts(for: named.summaries.map(\.id)).isEmpty)
    }

    @Test("sections: no place first when there is any, then every household location in order, each in review order")
    func sections() throws {
        let places = PlaceContext(locations: household, placements: [placement("Yogurt", Fixture.yogurt, in: pantryShelf)])
        var review = review(threeFoods() + [Fixture.photo(3, seconds: 900, lines: Fixture.front("Oat milk"))], places: places)
        let ids = review.summaries.map(\.id)
        try #require(ids.count == 4)

        var sections = review.sections(in: household)
        #expect(sections.map(\.place) == [nil, fridge.id, freezer.id, pantryShelf.id])
        #expect(sections.map { $0.candidates.map(\.id) } == [[ids[1], ids[2], ids[3]], [], [], [ids[0]]])
        #expect(Set(sections.map(\.id)).count == 4)
        #expect(review.unplaced(in: household) == [ids[1], ids[2], ids[3]])

        review.assignLocation(pantryShelf.id, to: [ids[3], ids[1]])
        sections = review.sections(in: household)
        #expect(sections.map { $0.candidates.map(\.id) } == [[ids[2]], [], [], [ids[0], ids[1], ids[3]]])

        review.assignLocation(fridge.id, to: [ids[2]])
        #expect(review.sections(in: household).map(\.place) == [fridge.id, freezer.id, pantryShelf.id])
        #expect(review.unplaced(in: household).isEmpty)
    }

    @Test("a candidate in a place the household no longer has shows with those that have none, and Add all leaves it")
    func placeGone() throws {
        let gone = StorageLocation(name: "Garage", storageType: .roomTemperature)
        var review = review(Array(threeFoods().prefix(2)))
        let ids = review.summaries.map(\.id)
        review.assignLocation(gone.id, to: [ids[0]])
        review.assignLocation(fridge.id, to: [ids[1]])
        #expect(review.readyToAdd == ids)
        #expect(review.readyToAdd(in: household) == [ids[1]])
        #expect(review.unplaced(in: household) == [ids[0]])
        #expect(review.sections(in: household).first?.place == nil)
        #expect(review.sections(in: household).first?.candidates.map(\.id) == [ids[0]])
    }

    @Test("a move ignores unknown candidates, leaves those already there as they were, and records nothing when nothing moves")
    func moves() throws {
        let places = PlaceContext(locations: household, placements: [placement("Yogurt", Fixture.yogurt, in: fridge)])
        var review = review(Array(threeFoods().prefix(2)), places: places)
        let (yogurt, rice) = (review.summaries[0].id, review.summaries[1].id)

        #expect(review.assignLocation(fridge.id, to: [yogurt, IntakeCandidateID()]).isEmpty)
        #expect(!review.canUndo)
        #expect(review.summary(of: yogurt)?.locationOrigin == .remembered)

        let before = review.candidates
        #expect(review.assignLocation(fridge.id, to: [yogurt, rice, IntakeCandidateID()]) == [rice])
        #expect(review.summary(of: yogurt)?.locationOrigin == .remembered)
        #expect(review.summary(of: rice)?.locationOrigin == .person)
        let undone = review.undo()
        #expect(undone)
        #expect(review.candidates == before)

        review.markAdded([rice])
        #expect(review.assignLocation(freezer.id, to: [rice]).isEmpty)
        #expect(!review.canUndo)
    }

    @Test("merging a candidate with no place into one with a proposed place keeps that place")
    func mergeTakesAPlace() throws {
        // The back taken before the front: a suggestion, two candidates.
        let photos = [
            Fixture.photo(0, lines: Fixture.back(["Distributed by Chobani"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(1, lines: Fixture.front("Greek yogurt", brand: "Chobani", small: ["KEEP REFRIGERATED"])),
        ]
        var review = review(photos)
        try #require(review.summaries.count == 2)
        let (back, front) = (review.summaries[0].id, review.summaries[1].id)
        #expect(review.summary(of: back)?.location == nil)
        #expect(review.summary(of: front)?.locationOrigin == .label)
        let merged = try review.merge([back, front])
        #expect(review.summary(of: merged)?.location == fridge.id)
        #expect(review.summary(of: merged)?.locationOrigin == .label)
    }

    @Test("dragging a selected card carries the whole selection in review order; any other card goes alone")
    func carried() {
        let order = (0..<4).map { _ in IntakeCandidateID() }
        let selection: Set = [order[3], order[1]]
        #expect(PlaceDrag.carried(dragging: order[3], selection: selection, order: order) == [order[1], order[3]])
        #expect(PlaceDrag.carried(dragging: order[0], selection: selection, order: order) == [order[0]])
        #expect(PlaceDrag.carried(dragging: order[2], selection: [], order: order) == [order[2]])
        // A selected card that left the review is not carried.
        #expect(PlaceDrag.carried(dragging: order[1], selection: selection.union([IntakeCandidateID()]), order: order) == [order[1], order[3]])
    }

    @Test("a drop moves only candidates under review, each once, in the order named")
    func dropValidation() throws {
        var review = review(threeFoods())
        let ids = review.summaries.map(\.id)
        try #require(ids.count == 3)
        review.markAdded([ids[1]])
        let stranger = IntakeCandidateID()
        #expect(review.underReview([ids[2], stranger, ids[0], ids[2], ids[1]]) == [ids[2], ids[0]])
        #expect(review.underReview([]).isEmpty)
        let flood = Array(repeating: stranger, count: IntakeLimits.candidatesPerBatch) + [ids[0]]
        #expect(review.underReview(flood).isEmpty)
    }

    @Test("a review saved with the first location as its default still decodes")
    func standardOriginDecodes() throws {
        #expect(try JSONDecoder().decode(LocationOrigin.self, from: Data("\"standard\"".utf8)) == .standard)
        for origin in [LocationOrigin.remembered, .label, .foodKeeper, .person, .unplaced] {
            #expect(try JSONDecoder().decode(LocationOrigin.self, from: JSONEncoder().encode(origin)) == origin)
        }
    }
}
