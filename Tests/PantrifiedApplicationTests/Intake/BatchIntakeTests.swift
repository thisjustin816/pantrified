import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

private let day: TimeInterval = 24 * 60 * 60

/// A Space with Fridge, Freezer and Pantry, its pantry, and a staging folder that outlives any one
/// store, the way the app's folder outlives a process.
private struct IntakeWorld {
    let space = SpaceID()
    let files = MemoryStagingFiles()
    let time = FixedTime(syncEpoch)
    let inventory = InMemoryInventory()
    let evidence = InMemoryProductEvidence()
    let locations: [StorageLocation] = [
        StorageLocation(name: "Fridge", storageType: .refrigerated),
        StorageLocation(name: "Freezer", storageType: .frozen),
        StorageLocation(name: "Pantry", storageType: .roomTemperature),
    ]

    var pantry: Pantry {
        Pantry(
            space: space, inventory: inventory, locations: FixedLocationStore(locations: [space: locations]),
            evidence: evidence, guidance: FakeGuidance(), time: time
        )
    }

    /// A store as a fresh launch opens it.
    func launch() -> StagingStore { StagingStore(files: files, time: time) }

    func pipeline(_ store: StagingStore, recognizer: FakeRecognizer? = nil, lookup: (any ProductLookupService)? = nil) -> IntakePipeline {
        IntakePipeline(store: store, recognizer: recognizer ?? FakeRecognizer(files: files, readings: IntakeFixture.readings), lookup: lookup)
    }

    /// Stages photos whose bytes name their fixture reading.
    func stage(_ keys: [String], in store: StagingStore) async throws -> IntakeBatchID {
        let batch = try await store.open(in: space)
        for (offset, key) in keys.enumerated() {
            try await store.stage(Data(key.utf8), fileExtension: "jpg", source: .camera,
                                  capturedAt: time.now().addingTimeInterval(Double(offset) * 5), in: batch.id)
        }
        return batch.id
    }

    func process(_ batch: IntakeBatchID, _ store: StagingStore, lookup: (any ProductLookupService)? = nil) async throws -> IntakeReview {
        try await pipeline(store, lookup: lookup).process(batch, locations: locations, defaultLocation: locations[0].id)
    }
}

private struct FixedLocationStore: StorageLocationStore {
    let locations: [SpaceID: [StorageLocation]]
    func locations(in space: SpaceID) async throws -> [StorageLocation] { locations[space] ?? [] }
    func saveAll(_ locations: [StorageLocation], in space: SpaceID) async throws {}
}

@Suite("Staging store")
struct StagingStoreTests {
    @Test("a staged photo is written, recorded and still there after a relaunch mid-capture")
    func killDuringCapture() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["rice", "beans"], in: world.launch())

        let relaunched = world.launch()
        let resumed = try #require(await relaunched.unfinished(in: world.space))
        #expect(resumed.id == batch)
        #expect(resumed.phase == .capturing)
        #expect(resumed.photos.map(\.sequence) == [0, 1])
        #expect(world.files.photoNames.count == 2)
        // Opening again carries on with the same batch rather than starting another.
        #expect(try await relaunched.open(in: world.space).id == batch)
        try await relaunched.stage(Data("yogurt-front".utf8), fileExtension: "heic", source: .imported, in: batch)
        #expect(await relaunched.batch(batch)?.photos.map(\.sequence) == [0, 1, 2])
    }

    @Test("a photo taken back before reading is deleted with its file")
    func removePhoto() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let photo = try #require(await store.batch(batch)?.photos.first)
        try await store.removePhoto(photo.id, from: batch)
        #expect(!world.files.has(photo.fileName))
        #expect(await store.batch(batch)?.photos.count == 1)
    }

    @Test("a batch is bounded in photos and in bytes per photo")
    func bounds() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await store.open(in: world.space).id
        await #expect(throws: StagingError.photoTooLarge) {
            try await store.stage(Data(count: StagingStore.maximumPhotoBytes + 1), fileExtension: "jpg", source: .camera, in: batch)
        }
        await #expect(throws: StagingError.photoTooLarge) {
            try await store.stage(Data(), fileExtension: "jpg", source: .camera, in: batch)
        }
        for _ in 0..<IntakeLimits.photosPerBatch {
            try await store.stage(Data([1]), fileExtension: "jpg", source: .camera, in: batch)
        }
        await #expect(throws: StagingError.batchFull) {
            try await store.stage(Data([1]), fileExtension: "jpg", source: .camera, in: batch)
        }
    }

    @Test("a photo whose record cannot be written is not kept, and its file is removed")
    func failedRecord() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await store.open(in: world.space).id
        world.files.failWrites(to: StagingStore.manifestName)
        await #expect(throws: StagingError.storage) {
            try await store.stage(Data([1]), fileExtension: "jpg", source: .camera, in: batch)
        }
        world.files.allowWrites()
        #expect(world.files.photoNames.isEmpty)
        #expect(await store.batch(batch)?.photos.isEmpty == true)
    }

    @Test("photo files are deleted a day after reading, but the review stays until the batch is done")
    func recoveryWindow() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        _ = try await world.process(batch, store)

        world.time.advance(hours: 23)
        #expect(try await store.sweep() == 0)
        #expect(world.files.photoNames.count == 2)

        world.time.advance(hours: 1)
        #expect(try await store.sweep() == 2)
        #expect(world.files.photoNames.isEmpty)
        let kept = try #require(await store.batch(batch))
        #expect(kept.photos.allSatisfy { $0.fileRemoved })
        #expect(kept.review?.summaries.count == 2)

        // Days later, an unreviewed batch is still there to finish.
        world.time.advance(hours: 24 * 6)
        try await store.sweep()
        #expect(await world.launch().unfinished(in: world.space)?.id == batch)
    }

    @Test("a finished batch is removed a day after it finished")
    func finishedBatch() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        try await store.updateReview(batch) { $0.delete(Set(review.summaries.map(\.id))) }
        #expect(await store.batch(batch)?.phase == .finished)
        world.time.advance(hours: 25)
        try await store.sweep()
        #expect(await store.batch(batch) == nil)
        #expect(await world.launch().all.isEmpty)
    }

    @Test("discarding deletes the photos and the batch at once")
    func discard() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        try await store.discard(batch)
        #expect(world.files.photoNames.isEmpty)
        #expect(await world.launch().all.isEmpty)
    }

    @Test("a capture left alone for a day is moved on to reading, so its photos do not stay indefinitely")
    func abandonedCapture() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        world.time.advance(hours: 25)
        try await store.sweep()
        #expect(await store.batch(batch)?.phase == .processing)
        #expect(world.files.photoNames.count == 1)
    }

    @Test("sweeping removes photo files no batch names, and never a file the store did not make")
    func orphansOnly() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        _ = try await world.stage(["rice"], in: store)
        let orphan = UUID().uuidString + ".jpg"
        world.files.put(orphan)
        let foreign = ["IMG_0001.HEIC", "photo.jpg", UUID().uuidString.lowercased() + ".jpg", UUID().uuidString + ".mov", "notes.txt"]
        for name in foreign { world.files.put(name) }

        #expect(try await store.sweep() == 1)
        #expect(!world.files.has(orphan))
        for name in foreign { #expect(world.files.has(name)) }
        #expect(world.files.has(StagingStore.manifestName))
        #expect(!world.files.removed.contains(where: foreign.contains))
    }

    @Test("an unreadable batch list is set aside, not overwritten")
    func unreadableManifest() async throws {
        let world = IntakeWorld()
        world.files.put(StagingStore.manifestName, Data("{not json".utf8))
        let store = world.launch()
        #expect(await store.all.isEmpty)
        #expect(world.files.has("batches.unreadable.json"))
    }

    @Test("the staging directory writes, lists and removes plain names in its folder, and refuses paths")
    func directory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = StagingDirectory(directory: root.appendingPathComponent("Intake", isDirectory: true))
        try folder.write(Data("x".utf8), to: "A.jpg")
        #expect(try folder.read("A.jpg") == Data("x".utf8))
        #expect(try folder.names() == ["A.jpg"])
        try folder.remove("A.jpg")
        try folder.remove("A.jpg")
        #expect(try folder.read("A.jpg") == nil)
        for name in ["../escape.jpg", "a/b.jpg", ".hidden", "", "..", "a\\b"] {
            #expect(throws: StagingDirectory.UnsafeName.self) { try folder.write(Data(), to: name) }
            #expect(throws: StagingDirectory.UnsafeName.self) { try folder.remove(name) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.jpg").path))
    }
}

@Suite("Batch intake")
struct BatchIntakeTests {
    // MARK: Reading and grouping

    @Test("a batch is read and grouped into candidates, with the barcode, date and names proposed")
    func process() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: store)
        let review = try await world.process(batch, store)
        #expect(review.summaries.count == 2)
        let yogurt = review.summaries[0]
        #expect(yogurt.photos.count == 2)
        #expect(yogurt.barcode == IntakeFixture.yogurt)
        #expect(yogurt.name == "Chobani greek yogurt")
        #expect(yogurt.date?.label == .useBy)
        #expect(await store.batch(batch)?.phase == .reviewing)
    }

    @Test("processing again reads nothing again and keeps the person's edits")
    func idempotent() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: store)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        let first = try await pipeline.process(batch, locations: world.locations, defaultLocation: nil)
        try await store.updateReview(batch) { try $0.setName("Skyr", for: first.summaries[0].id) }

        let again = try await pipeline.process(batch, locations: world.locations, defaultLocation: nil)
        #expect(await recognizer.reads == 3)
        #expect(again.summaries[0].name == "Skyr")
        #expect(again.summaries.map(\.id) == first.summaries.map(\.id))
    }

    @Test("a kill while reading keeps what was read, and the next launch reads only the rest")
    func killDuringProcessing() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice", "beans"], in: world.launch())
        let interrupted = FakeRecognizer(files: world.files, readings: IntakeFixture.readings, cancelAfter: 2)
        let store = world.launch()
        await #expect(throws: CancellationError.self) {
            _ = try await world.pipeline(store, recognizer: interrupted).process(batch, locations: world.locations, defaultLocation: nil)
        }
        let readBefore = await store.observations(in: batch).count
        #expect((1...2).contains(readBefore))

        let relaunched = world.launch()
        #expect(await relaunched.batch(batch)?.phase == .processing)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let review = try await world.pipeline(relaunched, recognizer: recognizer).process(batch, locations: world.locations, defaultLocation: nil)
        #expect(await recognizer.reads == 4 - readBefore)
        #expect(review.summaries.count == 3)
    }

    @Test("reading runs at most two photos at once")
    func boundedConcurrency() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(Array(repeating: "rice", count: 9), in: store)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        _ = try await world.pipeline(store, recognizer: recognizer).process(batch, locations: world.locations, defaultLocation: nil)
        #expect(await recognizer.mostInFlight <= 2)
        #expect(await recognizer.reads == 9)
    }

    @Test("a photo that cannot be read is tried again, then kept with nothing read, so the batch finishes")
    func unreadablePhoto() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings, failures: ["beans": 5])
        let review = try await world.pipeline(store, recognizer: recognizer).process(batch, locations: world.locations, defaultLocation: nil)
        #expect(review.summaries.count == 2)
        #expect(review.summaries[1].name == nil)
        #expect(review.summaries[1].notes.contains(.noName))
    }

    // MARK: Lookups

    @Test("lookups fill names, a miss is final, and offline defers the pass to later")
    func lookups() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "beans"], in: store)
        let lookup = FakeLookup([
            IntakeFixture.yogurt: .failed(.offline),
            IntakeFixture.beans: .found(ProductSuggestion(name: "BLACK BEANS", source: "USDA FoodData Central")),
        ])
        _ = try await world.process(batch, store, lookup: lookup)
        let pipeline = world.pipeline(store, lookup: lookup)

        // Offline defers the whole pass; nothing blocks adding meanwhile.
        #expect(await pipeline.lookUpNames(batch) == 0)
        var review = try #require(await store.batch(batch)?.review)
        #expect(review.summaries.allSatisfy { $0.notes.contains(.lookupPaused) })
        #expect(review.readyToAdd.count == 2)
        #expect(await lookup.calls == [IntakeFixture.yogurt])

        await lookup.set(.notFound, for: IntakeFixture.yogurt)
        await pipeline.lookUpNames(batch)
        review = try #require(await store.batch(batch)?.review)
        #expect(review.summaries[0].notes.contains(.lookupFoundNothing))
        #expect(review.summaries[0].nameOrigin == .label)
        #expect(review.summaries[1].name == "Black beans")
        #expect(review.summaries[1].nameOrigin == .lookup(source: "USDA FoodData Central"))
        #expect(review.barcodesToLookUp.isEmpty)
    }

    @Test("a rate limit defers lookups without failing them, and each barcode is asked once when they resume")
    func rateLimited() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-back", "beans", "rice"], in: store)
        let lookup = FakeLookup([IntakeFixture.yogurt: .failed(.rateLimited), IntakeFixture.beans: .failed(.rateLimited)])
        let review = try await world.process(batch, store, lookup: lookup)
        let pipeline = world.pipeline(store, lookup: lookup)
        for _ in 0..<5 { await pipeline.lookUpNames(batch) }
        var current = try #require(await store.batch(batch)?.review)
        #expect(current.summaries[0].notes.contains(.lookupPaused))
        #expect(current.summaries[1].notes.contains(.lookupPaused))
        #expect(current.barcodesToLookUp == [IntakeFixture.yogurt, IntakeFixture.beans])
        #expect(current.readyToAdd.count == review.readyToAdd.count)

        await lookup.set(.found(ProductSuggestion(name: "Greek yogurt", source: "USDA")), for: IntakeFixture.yogurt)
        await lookup.set(.notFound, for: IntakeFixture.beans)
        let callsBefore = await lookup.calls.count
        await pipeline.lookUpNames(batch)
        await pipeline.lookUpNames(batch)
        #expect(await lookup.calls.count == callsBefore + 2)
        current = try #require(await store.batch(batch)?.review)
        #expect(current.summaries[0].name == "Greek yogurt")
        #expect(current.barcodesToLookUp.isEmpty)
    }

    @Test("a lookup that answers after the person named the food changes nothing")
    func lateLookup() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["beans"], in: store)
        let review = try await world.process(batch, store, lookup: FakeLookup([:]))
        try await store.updateReview(batch) { try $0.setName("Frijoles", for: review.summaries[0].id) }
        #expect(review.barcodesToLookUp == [IntakeFixture.beans])
        let lookup = FakeLookup([IntakeFixture.beans: .found(ProductSuggestion(name: "Beans", source: "USDA"))])
        await world.pipeline(store, lookup: lookup).lookUpNames(batch)
        #expect(await lookup.calls.isEmpty)
        #expect(await store.batch(batch)?.review?.summaries[0].name == "Frijoles")
    }

    // MARK: Adding

    @Test("Add all puts packages away at once with barcode and date, and the review is finished")
    func addAll() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: store)
        let review = try await world.process(batch, store)
        let adding = IntakeAdding(pantry: world.pantry, store: store)

        let addition = try await adding.add(review.readyToAdd, in: batch)
        #expect(addition.packages.count == 2)
        #expect(addition.notReady == 0)
        let snapshot = try await world.pantry.snapshot()
        #expect(snapshot.entries.map(\.package.name).sorted() == ["Basmati rice", "Chobani greek yogurt"])
        let yogurt = try #require(snapshot.entries.first { $0.package.name == "Chobani greek yogurt" })
        #expect(yogurt.package.printedDate?.label == .useBy)
        #expect(yogurt.package.confirmedFields.isEmpty)
        #expect(try await world.evidence.barcode(of: yogurt.id, in: world.space) == IntakeFixture.yogurt)
        #expect(await store.batch(batch)?.phase == .finished)
    }

    @Test("undoing Add all takes the packages out and puts the candidates back, and adding again works")
    func undoAdd() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let adding = IntakeAdding(pantry: world.pantry, store: store)
        let addition = try await adding.add(review.readyToAdd, in: batch)

        try await adding.undo(addition)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        let back = try #require(await store.batch(batch)?.review)
        #expect(back.summaries.count == 2)
        #expect(await store.batch(batch)?.phase == .reviewing)

        let again = try await adding.add(back.readyToAdd, in: batch)
        #expect(again.packages.count == 2)
        #expect(Set(again.packages).isDisjoint(with: addition.packages))
        #expect(try await world.pantry.snapshot().entries.count == 2)
    }

    @Test("candidates without a name stay in review; the rest are added")
    func partialAdd() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        try await store.updateReview(batch) { try $0.setName(nil, for: review.summaries[0].id) }
        let addition = try await IntakeAdding(pantry: world.pantry, store: store).add(review.summaries.map(\.id), in: batch)
        #expect(addition.packages.count == 1)
        #expect(addition.notReady == 1)
        #expect(await store.batch(batch)?.review?.summaries.count == 1)
    }

    // MARK: Kill and resume

    @Test("edits made in review survive a kill and relaunch")
    func killDuringReview() async throws {
        let world = IntakeWorld()
        let batch: IntakeBatchID
        do {
            let store = world.launch()
            batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: store)
            _ = try await world.process(batch, store)
            try await store.updateReview(batch) { review in
                try review.setName("Skyr", for: review.summaries[0].id)
                review.assignLocation(world.locations[2].id, to: [review.summaries[1].id])
                try review.split(review.summaries[0].photos[0], from: review.summaries[0].id)
            }
        }
        let relaunched = try #require(await world.launch().unfinished(in: world.space)?.review)
        #expect(relaunched.summaries.count == 3)
        #expect(relaunched.summaries[0].name == "Skyr")
        #expect(relaunched.summaries[2].location == world.locations[2].id)
    }

    @Test("an add cut off after the packages were saved is finished on relaunch without adding twice")
    func killDuringAdd() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let ids = Set(review.readyToAdd)
        // What `add` does, stopped before the candidates are marked added.
        try await store.updateReview(batch) { $0.beginAdd(ids) }
        _ = try await world.pantry.putAway(review.drafts(for: review.readyToAdd))

        let relaunched = world.launch()
        try await IntakeAdding(pantry: world.pantry, store: relaunched).resume(batch)
        #expect(try await world.pantry.snapshot().entries.count == 2)
        #expect(await relaunched.batch(batch)?.review?.isFinished == true)
        #expect(await relaunched.batch(batch)?.review?.pendingAdd.isEmpty == true)
    }

    @Test("an add cut off before the packages were saved is finished on relaunch")
    func killBeforeSave() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        try await store.updateReview(batch) { $0.beginAdd(Set(review.readyToAdd)) }

        try await IntakeAdding(pantry: world.pantry, store: world.launch()).resume(batch)
        #expect(try await world.pantry.snapshot().entries.map(\.package.name) == ["Basmati rice"])
    }

    @Test("an undo cut off part way is finished on relaunch")
    func killDuringUndo() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let addition = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        try await store.updateReview(batch) { $0.beginUndo(addition.candidates) }
        _ = try await world.pantry.perform(.discard(reason: nil), on: addition.packages[0])

        let relaunched = world.launch()
        try await IntakeAdding(pantry: world.pantry, store: relaunched).resume(batch)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        #expect(await relaunched.batch(batch)?.review?.summaries.count == 2)
    }

    @Test("a failed save adds nothing and leaves every candidate in review")
    func failedSave() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        await world.inventory.setFailOnSave(true)
        await #expect(throws: FakeFailure.self) {
            _ = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        }
        await world.inventory.setFailOnSave(false)
        #expect(await store.batch(batch)?.review?.summaries.count == 1)
        #expect(await store.batch(batch)?.review?.pendingAdd.isEmpty == true)
        // Nothing is added behind the person's back on the next launch; adding again works.
        try await IntakeAdding(pantry: world.pantry, store: store).resume(batch)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        _ = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        #expect(try await world.pantry.snapshot().entries.count == 1)
    }
}
