import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

/// A wafer's front with its logo misread and no barcode, a box of oats, and the wafer's back with
/// its barcode, the maker's address and a panel. Only the lookup's name links the front and back.
private let wafer = IntakeFixture.gtin("007658018211")
private let waferName = "LOACKER CRISPY WAFERS WITH VANILLA CREAM FILLING, VANILLA"
private let readings: [String: PhotoReading] = [
    "wafer-front": PhotoReading(lines: [
        IntakeFixture.line("Toacker", row: 0.36, size: 0.04), IntakeFixture.line("Minis", row: 0.43, size: 0.05),
        IntakeFixture.line("VANILLA", row: 0.5, size: 0.016),
        IntakeFixture.line("CRISPY WAFERS WITH VANILLA CREAM FILLING", row: 0.535, size: 0.012),
    ]),
    "oats": PhotoReading(lines: [IntakeFixture.line("QUAKER", row: 0.1, size: 0.09), IntakeFixture.line("Rolled oats", row: 0.2, size: 0.1)]),
    "wafer-back": PhotoReading(lines: [
        IntakeFixture.line("I: A. LOACKER SPA, 39054 AUNA DI SOTTO (BZ), ITALY", row: 0.44, size: 0.008),
        IntakeFixture.line("Nutrition Facts", row: 0.5, size: 0.02), IntakeFixture.line("Calories 50", row: 0.55, size: 0.015),
    ], codes: [.product(wafer)]),
]

private func pipeline(_ world: IntakeWorld, _ store: StagingStore, lookup: any ProductLookupService) -> IntakePipeline {
    world.pipeline(store, recognizer: FakeRecognizer(files: world.files, readings: readings), lookup: lookup)
}

@Suite("Grouping through lookup answers")
struct LookupGroupingTests {
    @Test("an answer kept before the review joins the front and back it links, with other photos between them")
    func answerBeforeReview() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["wafer-front", "oats", "wafer-back"], in: store)
        let pipeline = pipeline(world, store, lookup: FakeLookup([wafer: .found(ProductSuggestion(name: waferName, source: "USDA FoodData Central"))]))
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()

        // The list shown while the last photos are read already holds the answer.
        let preview = try #require(await pipeline.preview(places: world.unguided))
        #expect(preview.summaries.count == 2)

        let review = try await pipeline.finish(batch, places: world.unguided)
        #expect(review.summaries.count == 2)
        #expect(review.summaries[0].photos.count == 2)
        #expect(review.summaries[0].name == "Loacker crispy wafers with vanilla cream filling, vanilla")
        #expect(review.summaries[0].signals.contains(.lookupName))
    }

    @Test("the review never waits for a lookup; an answer after it suggests the photos it links, and an undo keeps the suggestion")
    func answerAfterReview() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["wafer-front", "oats", "wafer-back"], in: store)
        let lookup = GatedLookup([wafer: .found(ProductSuggestion(name: waferName, source: "USDA FoodData Central"))])
        let pipeline = pipeline(world, store, lookup: lookup)
        let review = try await pipeline.finish(batch, places: world.unguided)
        #expect(await waitUntil { await lookup.inFlight == 1 })
        #expect(review.summaries.count == 3)
        #expect(review.summaries.allSatisfy { !$0.notes.contains { if case .mightBeSameAs = $0 { true } else { false } } })

        let (front, back) = (review.summaries[0].id, review.summaries[2].id)
        try await store.updateReview(batch) { try $0.setCount(2, for: front) }
        await lookup.gate.releaseAll()
        await pipeline.settle()

        var kept = try #require(await store.batch(batch)?.review)
        #expect(kept.summary(of: front)?.notes.contains(.mightBeSameAs([back])) == true)
        #expect(kept.summary(of: back)?.notes.contains(.mightBeSameAs([front])) == true)
        #expect(kept.summary(of: front)?.count == 2)
        let undone = kept.undo()
        #expect(undone)
        #expect(kept.summary(of: front)?.notes.contains(.mightBeSameAs([back])) == true)
        // Nothing was merged without the person.
        #expect(kept.summaries.count == 3)
    }

    @Test("a miss, or no lookup at all, leaves the front and back apart and unsuggested")
    func noAnswer() async throws {
        for lookup in [FakeLookup([wafer: .notFound]), nil] as [FakeLookup?] {
            let world = IntakeWorld()
            let store = world.launch()
            let batch = try await world.stage(["wafer-front", "oats", "wafer-back"], in: store)
            let pipeline = world.pipeline(store, recognizer: FakeRecognizer(files: world.files, readings: readings), lookup: lookup)
            await pipeline.open(batch, capturing: true)
            await pipeline.settle()
            let review = try await pipeline.finish(batch, places: world.unguided)
            await pipeline.settle()
            let kept = try #require(await store.batch(batch)?.review)
            #expect(review.summaries.count == 3)
            #expect(kept.summaries.allSatisfy { !$0.notes.contains { if case .mightBeSameAs = $0 { true } else { false } } })
        }
    }
}
