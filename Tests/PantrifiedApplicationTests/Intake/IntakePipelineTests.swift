import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

/// Readings for photos with their own barcodes, keyed `p0`, `p1` and so on.
private func products(_ count: Int) -> (readings: [String: PhotoReading], barcodes: [GTIN]) {
    var readings: [String: PhotoReading] = [:]
    var barcodes: [GTIN] = []
    for index in 0..<count {
        let barcode = IntakeFixture.gtin(String(format: "7012345%05d", index))
        barcodes.append(barcode)
        readings["p\(index)"] = PhotoReading(lines: [IntakeFixture.line("Product number \(index)")], codes: [.product(barcode)])
    }
    return (readings, barcodes)
}

private func found(_ name: String) -> ProductLookupResult {
    .found(ProductSuggestion(name: name, source: "USDA FoodData Central"))
}

private extension IntakeWorld {
    func observed(_ store: StagingStore, _ batch: IntakeBatchID) async -> Int {
        await store.observations(in: batch).count
    }
}

@Suite("Reading and looking up as photos are taken")
struct IntakePipelineTests {
    // MARK: Reading as you go

    @Test("photos are read while the camera is open, one at a time, and the batch stays in capture")
    func readsWhileCapturing() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice", "beans"], in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        await pipeline.open(batch, capturing: true)

        #expect(await waitUntil { await recognizer.inFlight == 1 })
        for _ in 0..<200 { await Task.yield() }
        #expect(await recognizer.reads.count == 1)
        await recognizer.gate.releaseAll()
        await pipeline.settle()
        #expect(await world.observed(store, batch) == 4)
        #expect(await recognizer.mostInFlight == 1)
        #expect(await store.batch(batch)?.phase == .capturing)
        #expect(await store.batch(batch)?.review == nil)
    }

    @Test("after Done, two photos are read at once")
    func twoAfterDone() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(Array(repeating: "rice", count: 6), in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        let done = Task { try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil) }

        #expect(await waitUntil { await recognizer.inFlight == 2 })
        for _ in 0..<200 { await Task.yield() }
        #expect(await recognizer.inFlight == 2)
        await recognizer.gate.releaseAll()
        _ = try await done.value
        #expect(await recognizer.mostInFlight == 2)
        #expect(await recognizer.reads.count == 6)
    }

    @Test("reading waits while the camera is open and the device is warm or in Low Power Mode, and carries on after")
    func pausesWhileCapturing() async throws {
        for paused in [DeviceConditions(thermal: .serious), DeviceConditions(thermal: .critical), DeviceConditions(lowPowerMode: true)] {
            let world = IntakeWorld()
            let store = world.launch()
            let batch = try await world.stage(["rice", "beans"], in: store)
            let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
            let pipeline = world.pipeline(store, recognizer: recognizer)
            await pipeline.setConditions(paused)
            await pipeline.open(batch, capturing: true)
            await pipeline.settle()
            #expect(await recognizer.reads == 0)

            await pipeline.setConditions(DeviceConditions())
            await pipeline.settle()
            #expect(await recognizer.reads == 2)
        }
    }

    @Test("Done reads what is left even in Low Power Mode, and one at a time while the device is warm")
    func doneUnderPressure() async throws {
        for (conditions, most) in [(DeviceConditions(lowPowerMode: true), 2), (DeviceConditions(thermal: .serious), 1)] {
            let world = IntakeWorld()
            let store = world.launch()
            let batch = try await world.stage(Array(repeating: "rice", count: 4), in: store)
            let recognizer = GatedRecognizer(files: world.files)
            let pipeline = world.pipeline(store, recognizer: recognizer)
            await pipeline.setConditions(conditions)
            let done = Task { try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil) }
            #expect(await waitUntil { await recognizer.inFlight == most })
            for _ in 0..<200 { await Task.yield() }
            await recognizer.gate.releaseAll()
            _ = try await done.value
            #expect(await recognizer.mostInFlight == most)
        }
    }

    @Test("a photo read before is not read again when the batch opens again or after a relaunch")
    func idempotentReread() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "rice"], in: store)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()
        await pipeline.leave(batch)
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()
        #expect(await recognizer.reads == 2)

        let relaunched = world.launch()
        let again = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        _ = try await world.pipeline(relaunched, recognizer: again).finish(batch, locations: world.locations, defaultLocation: nil)
        #expect(await again.reads == 0)
    }

    // MARK: Kill and resume

    @Test("a kill during a read while taking photos keeps what was read, and opening again reads only the rest")
    func killDuringCaptureRead() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: world.launch())
        do {
            let store = world.launch()
            let recognizer = GatedRecognizer(files: world.files)
            let pipeline = world.pipeline(store, recognizer: recognizer)
            await pipeline.open(batch, capturing: true)
            await recognizer.gate.release("yogurt-front")
            #expect(await waitUntil { await recognizer.reads == ["yogurt-front", "yogurt-back"] })
            // The app dies here, inside the second read: nothing more is written.
        }

        let relaunched = world.launch()
        #expect(await relaunched.batch(batch)?.phase == .capturing)
        #expect(await world.observed(relaunched, batch) == 1)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let pipeline = world.pipeline(relaunched, recognizer: recognizer)
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()
        #expect(await recognizer.reads == 2)
        let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        let observations = await relaunched.observations(in: batch)
        #expect(review.candidates.map(\.photos) == PhotoGrouper().group(observations).groups.map(\.photos))
    }

    @Test("a kill during a lookup asks that barcode again when the batch opens, without reading the photo again")
    func killDuringLookup() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["yogurt-back"], in: world.launch())
        do {
            let store = world.launch()
            let lookup = GatedLookup([IntakeFixture.yogurt: found("Greek yogurt")])
            let pipeline = world.pipeline(store, lookup: lookup)
            await pipeline.open(batch, capturing: true)
            #expect(await waitUntil { await lookup.inFlight == 1 })
            // The app dies with the lookup in flight.
        }

        let relaunched = world.launch()
        #expect(await relaunched.batch(batch)?.lookups.isEmpty == true)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let lookup = FakeLookup([IntakeFixture.yogurt: found("Greek yogurt")])
        let pipeline = world.pipeline(relaunched, recognizer: recognizer, lookup: lookup)
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()
        #expect(await recognizer.reads == 0)
        #expect(await lookup.calls == [IntakeFixture.yogurt])
        let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        let kept = await relaunched.batch(batch)?.lookups ?? [:]
        #expect(review.summaries[0].name == "Greek yogurt", "\(kept) \(review.lookups)")
    }

    // MARK: Cancelling

    @Test("discarding cancels the read and the lookup in flight, and nothing starts after")
    func discardCancels() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "rice", "beans"], in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let lookup = GatedLookup()
        let pipeline = world.pipeline(store, recognizer: recognizer, lookup: lookup)
        await pipeline.open(batch, capturing: true)
        await recognizer.gate.release("yogurt-back")
        #expect(await waitUntil {
            let looking = await lookup.inFlight == 1
            let reading = await recognizer.inFlight == 1
            return looking && reading
        })

        await pipeline.discard(batch)
        try await store.discard(batch)
        #expect(await waitUntil {
            let read = await recognizer.gate.cancellations == 1
            let looked = await lookup.gate.cancellations == 1
            return read && looked
        })
        await pipeline.settle()
        #expect(await recognizer.reads == ["yogurt-back", "rice"])
        #expect(await lookup.calls == [IntakeFixture.yogurt])
        #expect(await store.batch(batch) == nil)
    }

    @Test("closing the camera without Done stops reading and lookups; what was read is kept")
    func leaveCancels() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "rice"], in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let lookup = GatedLookup()
        let pipeline = world.pipeline(store, recognizer: recognizer, lookup: lookup)
        await pipeline.open(batch, capturing: true)
        await recognizer.gate.release("yogurt-back")
        #expect(await waitUntil {
            let looking = await lookup.inFlight == 1
            let reading = await recognizer.inFlight == 1
            return looking && reading
        })

        await pipeline.leave(batch)
        #expect(await waitUntil {
            let read = await recognizer.gate.cancellations == 1
            let looked = await lookup.gate.cancellations == 1
            return read && looked
        })
        await pipeline.settle()
        #expect(await world.observed(store, batch) == 1)
        #expect(await store.batch(batch)?.photos[1].readAttempts == 0)
        #expect(await store.batch(batch)?.lookups.isEmpty == true)
    }

    // MARK: Lookups

    @Test("each barcode is looked up once, as soon as a photo showing it is read, before Done")
    func lookupEarlyAndOnce() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "yogurt-front", "beans", "yogurt-back"], in: store)
        let lookup = FakeLookup([IntakeFixture.yogurt: found("GREEK YOGURT"), IntakeFixture.beans: found("BLACK BEANS")])
        let pipeline = world.pipeline(store, lookup: lookup)
        await pipeline.open(batch, capturing: true)
        await pipeline.settle()
        #expect(await store.batch(batch)?.review == nil)
        #expect(await lookup.calls == [IntakeFixture.yogurt, IntakeFixture.beans])
        #expect(await store.batch(batch)?.lookups[IntakeFixture.beans] == .found(name: "Black beans", source: "USDA FoodData Central"))

        let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        await pipeline.lookUpNames(batch)
        await world.pipeline(world.launch(), lookup: lookup).lookUpNames(batch)
        #expect(await lookup.calls == [IntakeFixture.yogurt, IntakeFixture.beans])
        #expect(review.summaries.map(\.name) == ["Greek yogurt", "Black beans"])
        #expect(review.summaries.allSatisfy { $0.nameOrigin == .lookup(source: "USDA FoodData Central") })
    }

    @Test("at most two lookups run at once, and a pass asks at most its budget")
    func lookupLimits() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let (readings, barcodes) = products(5)
        let batch = try await world.stage(readings.keys.sorted(), in: store)
        let lookup = GatedLookup()
        var budget = LookupPolicy()
        budget.perPass = 4
        let pipeline = world.pipeline(store, recognizer: FakeRecognizer(files: world.files, readings: readings), lookup: lookup, lookupPolicy: budget)
        await pipeline.open(batch, capturing: true)
        #expect(await waitUntil { await lookup.inFlight == 2 })
        for _ in 0..<300 { await Task.yield() }
        #expect(await lookup.inFlight == 2)
        await lookup.gate.releaseAll()
        await pipeline.settle()
        #expect(await lookup.mostInFlight == 2)
        #expect(await lookup.calls == Array(barcodes.prefix(4)))

        await pipeline.lookUpNames(batch)
        let calls = await lookup.calls
        #expect(calls == barcodes, "\(calls.map(\.digits))")
    }

    @Test("offline or rate limited defers the rest of the pass, and Done asks again")
    func deferredThenRetried() async throws {
        for failure in [ProductLookupFailure.offline, .rateLimited(resumesAt: nil)] {
            let world = IntakeWorld()
            let store = world.launch()
            let batch = try await world.stage(["yogurt-back", "rice", "beans"], in: store)
            let lookup = FakeLookup([IntakeFixture.yogurt: .failed(failure), IntakeFixture.beans: found("BLACK BEANS")])
            let recognizer = GatedRecognizer(files: world.files)
            let pipeline = world.pipeline(store, recognizer: recognizer, lookup: lookup)
            await pipeline.open(batch, capturing: true)
            // The yogurt's answer arrives before the beans photo is read.
            await recognizer.gate.release("yogurt-back")
            #expect(await waitUntil { await store.batch(batch)?.lookups[IntakeFixture.yogurt] == .deferred })
            await recognizer.gate.releaseAll()
            await pipeline.settle()
            #expect(await lookup.calls == [IntakeFixture.yogurt])
            #expect(await store.batch(batch)?.lookups == [IntakeFixture.yogurt: .deferred, IntakeFixture.beans: .deferred])

            await lookup.set(found("GREEK YOGURT"), for: IntakeFixture.yogurt)
            let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: world.locations[0].id)
            #expect(review.readyToAdd.count == 3)
            await pipeline.settle()
            #expect(await lookup.calls == [IntakeFixture.yogurt, IntakeFixture.yogurt, IntakeFixture.beans])
            let current = try #require(await store.batch(batch)?.review)
            #expect(current.summaries.map(\.name) == ["Greek yogurt", "Basmati rice", "Black beans"])
            #expect(current.barcodesToLookUp.isEmpty, "\(current.lookups) \(failure)")
        }
    }

    @Test("a miss is final, and a failure is tried again on later passes up to the limit")
    func missAndFailure() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "beans"], in: store)
        let lookup = FakeLookup([IntakeFixture.yogurt: .notFound, IntakeFixture.beans: .failed(.timedOut)])
        let pipeline = world.pipeline(store, lookup: lookup)
        _ = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        for _ in 0..<5 { await pipeline.lookUpNames(batch) }
        let calls = await lookup.calls
        #expect(calls.filter { $0 == IntakeFixture.yogurt }.count == 1)
        #expect(calls.filter { $0 == IntakeFixture.beans }.count == LookupAnswer.maximumAttempts)
        let review = try #require(await store.batch(batch)?.review)
        #expect(review.summaries[0].notes.contains(.lookupFoundNothing))
        #expect(review.summaries[1].notes.contains(.lookupFailed))
    }

    @Test("a lookup that answers after the person named the food changes nothing, and is not asked again")
    func lateLookup() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["beans"], in: store)
        let lookup = GatedLookup([IntakeFixture.beans: found("BEANS")])
        let pipeline = world.pipeline(store, lookup: lookup)
        let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        #expect(await waitUntil { await lookup.inFlight == 1 })
        try await store.updateReview(batch) { try $0.setName("Frijoles", for: review.summaries[0].id) }
        await lookup.gate.releaseAll()
        await pipeline.settle()
        await pipeline.lookUpNames(batch)
        #expect(await lookup.calls == [IntakeFixture.beans])
        #expect(await store.batch(batch)?.review?.summaries[0].name == "Frijoles")
    }

    // MARK: Done and the last photos

    @Test("at Done the review waits for the last reads, edits are refused until it exists, and none is lost after")
    func stragglersAndEdits() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice", "beans"], in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let pipeline = world.pipeline(store, recognizer: recognizer, lookup: FakeLookup([IntakeFixture.beans: found("BLACK BEANS")]))
        await pipeline.open(batch, capturing: true)
        await recognizer.gate.release("yogurt-front")
        await recognizer.gate.release("yogurt-back")
        #expect(await waitUntil { await world.observed(store, batch) == 2 })

        let done = Task { try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil) }
        #expect(await waitUntil { await recognizer.inFlight == 2 })
        for _ in 0..<200 { await Task.yield() }
        #expect(await store.batch(batch)?.review == nil)
        await #expect(throws: StagingError.notRecognized) { try await store.updateReview(batch) { $0.delete([]) } }
        let preview = try #require(await pipeline.preview(locations: world.locations, defaultLocation: nil))
        #expect(preview.summaries.count == 1)

        await recognizer.gate.releaseAll()
        let review = try await done.value
        let observations = await store.observations(in: batch)
        #expect(observations.count == 4)
        #expect(review.candidates.map(\.photos) == PhotoGrouper().group(observations).groups.map(\.photos))

        try await store.updateReview(batch) { try $0.setName("Skyr", for: review.summaries[0].id) }
        await pipeline.settle()
        _ = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
        let relaunched = try await world.pipeline(world.launch()).process(batch, locations: world.locations, defaultLocation: nil)
        #expect(relaunched.summaries.map(\.name) == ["Skyr", "Basmati rice", "Black beans"])
    }

    @Test("closing after Done does not stop the reading; the review is made")
    func leaveAfterDone() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let recognizer = GatedRecognizer(files: world.files)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        let done = Task { try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil) }
        #expect(await waitUntil { await recognizer.inFlight == 2 })
        await pipeline.leave(batch)
        await recognizer.gate.releaseAll()
        _ = try await done.value
        #expect(await store.batch(batch)?.review?.summaries.count == 2)
        #expect(await recognizer.gate.cancellations == 0)
    }

    // MARK: Grouping as photos arrive

    /// Front, barcode and date photos of one product, near-identical products, a photo of two
    /// products and a repeated barcode.
    static let mixed: [String: PhotoReading] = [
        "y-front": PhotoReading(lines: [IntakeFixture.line("CHOBANI", row: 0.1, size: 0.09), IntakeFixture.line("GREEK YOGURT")]),
        "y-back": PhotoReading(lines: [IntakeFixture.line("Chobani greek yogurt", row: 0.1, size: 0.03)], codes: [.product(IntakeFixture.yogurt)]),
        "y-date": PhotoReading(lines: [IntakeFixture.line("USE BY 2026-11-20", row: 0.5, size: 0.05)]),
        "soda": PhotoReading(lines: [IntakeFixture.line("ARM HAMMER", row: 0.08, size: 0.09), IntakeFixture.line("BAKING SODA")]),
        "powder": PhotoReading(lines: [IntakeFixture.line("CLABBER GIRL", row: 0.08, size: 0.09), IntakeFixture.line("BAKING POWDER")]),
        "beans": PhotoReading(lines: [IntakeFixture.line("Black beans")], codes: [.product(IntakeFixture.beans)]),
        "shelf": PhotoReading(lines: [IntakeFixture.line("Groceries")], codes: [.product(IntakeFixture.yogurt), .product(IntakeFixture.beans)]),
        "beans-again": PhotoReading(lines: [IntakeFixture.line("Black beans in water")], codes: [.product(IntakeFixture.beans)]),
    ]

    @Test("the review after readings arrive in any order is the one-shot grouping, and no step mixes two barcodes")
    func arrivalOrder() async throws {
        let keys = ["y-front", "y-back", "y-date", "soda", "powder", "beans", "shelf", "beans-again"]
        var generator = SeededGenerator(seed: 27)
        var everyRead = ReadingPolicy()
        everyRead.whileCapturing = keys.count
        var expected: [[Int]]?
        for _ in 0..<12 {
            let order = keys.shuffled(using: &generator)
            let world = IntakeWorld()
            let store = world.launch()
            let batch = try await world.stage(keys, in: store)
            let recognizer = GatedRecognizer(files: world.files, readings: Self.mixed)
            let pipeline = world.pipeline(store, recognizer: recognizer, policy: everyRead)
            await pipeline.open(batch, capturing: true)
            #expect(await waitUntil { await recognizer.inFlight == keys.count })
            for (index, key) in order.enumerated() {
                await recognizer.gate.release(key)
                #expect(await waitUntil { await world.observed(store, batch) == index + 1 })
                let preview = try #require(await pipeline.preview(locations: world.locations, defaultLocation: nil))
                for candidate in preview.candidates {
                    let own = candidate.photos.filter { !candidate.sharedPhotos.contains($0) }
                    let barcodes = Set(own.compactMap { preview.observations[$0] }.flatMap(\.products))
                    #expect(barcodes.count <= 1)
                }
            }
            let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: nil)
            let observations = await store.observations(in: batch)
            let oneShot = PhotoGrouper().group(observations)
            #expect(review.candidates.map(\.photos) == oneShot.groups.map(\.photos))
            let sequence = Dictionary(uniqueKeysWithValues: observations.map { ($0.photo, $0.sequence) })
            let shape = review.candidates.map { $0.photos.compactMap { sequence[$0] } }
            if let expected { #expect(shape == expected) } else { expected = shape }
        }
    }
}
