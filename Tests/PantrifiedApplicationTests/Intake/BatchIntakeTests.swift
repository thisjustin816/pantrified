import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence

private let day: TimeInterval = 24 * 60 * 60

/// A Space with Fridge, Freezer and Pantry, its pantry, and a staging folder that outlives any one
/// store, the way the app's folder outlives a process.
struct IntakeWorld {
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

    func pipeline(
        _ store: StagingStore,
        recognizer: (any PhotoRecognizer)? = nil,
        lookup: (any ProductLookupService)? = nil,
        policy: ReadingPolicy = .standard,
        lookupPolicy: LookupPolicy = .standard
    ) -> IntakePipeline {
        IntakePipeline(
            store: store, recognizer: recognizer ?? FakeRecognizer(files: files, readings: IntakeFixture.readings),
            lookup: lookup, time: time, policy: policy, lookupPolicy: lookupPolicy
        )
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

struct FixedLocationStore: StorageLocationStore {
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

    @Test("a change whose save fails is undone in memory too, so the store agrees with its file")
    func failedSaveUndone() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let photo = try #require(await store.batch(batch)?.photos.first)
        world.files.failWrites(to: StagingStore.manifestName)
        await #expect(throws: StagingError.storage) { try await store.discard(batch) }
        await #expect(throws: StagingError.storage) { try await store.removePhoto(photo.id, from: batch) }
        await #expect(throws: StagingError.storage) {
            try await store.record(PhotoObservation(photo: photo.id, sequence: 0, capturedAt: photo.capturedAt), in: batch)
        }
        await #expect(throws: StagingError.storage) { try await store.beginRead(photo.id, in: batch) }
        world.files.allowWrites()
        let kept = try #require(await store.batch(batch))
        #expect(kept == (await world.launch().batch(batch)))
        #expect(kept.photos.count == 2)
        #expect(kept.photos[0].observation == nil)
        #expect(kept.photos[0].readAttempts == 0)
        #expect(world.files.photoNames.count == 2)
    }

    @Test("observations stay out of the batch list, so reading 120 full-size observations writes a bounded amount")
    func observationsStoredOnce() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        var readings: [String: PhotoReading] = [:]
        for index in 0..<IntakeLimits.photosPerBatch {
            let lines = (0..<30).map { IntakeFixture.line("Marker\(index)x line \($0) with some ingredients text", row: 0.02 * Double($0), size: 0.02) }
            let print = FeaturePrint((0..<768).map { Float(($0 * 7 + index) % 97) / 97 })
            readings["photo\(index)"] = PhotoReading(lines: lines, featurePrint: print)
        }
        let batch = try await world.stage(readings.keys.sorted(), in: store)
        let recognizer = FakeRecognizer(files: world.files, readings: readings)
        _ = try await world.pipeline(store, recognizer: recognizer).finish(batch, locations: world.locations, defaultLocation: nil)

        let manifest = String(decoding: try #require(world.files.contents(of: StagingStore.manifestName)), as: UTF8.self)
        #expect(!manifest.contains("Marker17x line 15 "))
        #expect(world.files.observationNames.count == IntakeLimits.photosPerBatch)
        let written = world.files.bytesWritten(to: StagingStore.manifestName)
        print("Batch list: \(manifest.utf8.count) bytes after 120 photos, \(written) bytes written in all")
        // With observations inline the list grew past 1.5 MB and about 180 MB was written.
        #expect(manifest.utf8.count < 200_000)
        #expect(written < 20_000_000)
        #expect(await world.launch().batch(batch)?.review?.observations.count == IntakeLimits.photosPerBatch)
    }

    @Test("what was read from a photo is kept in its own file, deleted with its batch, and read again when that file is lost")
    func observationFiles() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        _ = try await world.process(batch, store)
        #expect(world.files.observationNames.count == 2)
        let orphan = UUID().uuidString + ".read.json"
        world.files.put(orphan)
        try await store.sweep()
        #expect(!world.files.has(orphan))
        #expect(world.files.observationNames.count == 2)

        // A lost observation file leaves its photo unread, so it is read again.
        let photo = try #require(await store.batch(batch)?.photos[0])
        try world.files.remove(StagingStore.observationName(photo.id))
        let relaunched = world.launch()
        #expect(await relaunched.photosToRecognize(in: batch).map(\.id) == [photo.id])
        #expect(await relaunched.batch(batch)?.review?.observations[photo.id] == nil)

        try await relaunched.discard(batch)
        #expect(world.files.observationNames.isEmpty)
        #expect(world.files.photoNames.isEmpty)
    }

    /// Rewrites the batch list as version 1 wrote it: each observation inside its photo's record and
    /// no observation files.
    private func rewriteAsVersion1(_ world: IntakeWorld) throws {
        let data = try #require(world.files.contents(of: StagingStore.manifestName))
        var list = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var batches = try #require(list["batches"] as? [[String: Any]])
        for b in batches.indices {
            var photos = try #require(batches[b]["photos"] as? [[String: Any]])
            for p in photos.indices {
                // A photo's file is named after its identity.
                let stem = try #require((photos[p]["fileName"] as? String)?.split(separator: ".").first)
                let name = StagingStore.observationName(IntakePhotoID(try #require(UUID(uuidString: String(stem)))))
                photos[p]["observation"] = try JSONSerialization.jsonObject(with: try #require(world.files.contents(of: name)))
                photos[p]["read"] = nil
                try world.files.remove(name)
            }
            batches[b]["photos"] = photos
        }
        list["batches"] = batches
        list["version"] = 1
        try world.files.write(try JSONSerialization.data(withJSONObject: list), to: StagingStore.manifestName)
    }

    @Test("a version 1 batch list keeps what was read from its photos through its first save and a relaunch")
    func version1Observations() async throws {
        let world = IntakeWorld()
        let batch: IntakeBatchID
        do {
            let store = world.launch()
            batch = try await world.stage(["yogurt-front", "yogurt-back", "rice"], in: store)
            _ = try await world.process(batch, store)
        }
        try rewriteAsVersion1(world)
        #expect(world.files.observationNames.isEmpty)

        let store = world.launch()
        try await store.updateReview(batch) { review in try review.setName("Skyr", for: review.summaries[0].id) }
        let relaunched = world.launch()
        #expect(await relaunched.photosToRecognize(in: batch).isEmpty)
        #expect(await relaunched.batch(batch)?.review?.observations.count == 3)
        #expect(world.files.observationNames.count == 3)
        let manifest = String(decoding: try #require(world.files.contents(of: StagingStore.manifestName)), as: UTF8.self)
        #expect(!manifest.contains("\"observation\""))
    }

    @Test("an observation from a version 1 list whose file cannot be written stays in the list until it can")
    func version1ObservationWriteFails() async throws {
        let world = IntakeWorld()
        let batch: IntakeBatchID
        do {
            let store = world.launch()
            batch = try await world.stage(["rice", "beans"], in: store)
            _ = try await world.process(batch, store)
        }
        let photo = try #require(await world.launch().batch(batch)?.photos[0])
        try rewriteAsVersion1(world)
        world.files.failWrites(to: StagingStore.observationName(photo.id))

        let store = world.launch()
        try await store.updateReview(batch) { review in try review.setName("Rice", for: review.summaries[0].id) }
        #expect(world.files.observationNames.count == 1)
        world.files.allowWrites()

        let relaunched = world.launch()
        #expect(await relaunched.batch(batch)?.photos[0].observation == photo.observation)
        try await relaunched.updateReview(batch) { review in try review.setName("Basmati", for: review.summaries[0].id) }
        let again = world.launch()
        #expect(await again.photosToRecognize(in: batch).isEmpty)
        #expect(await again.batch(batch)?.review?.observations.count == 2)
        #expect(world.files.observationNames.count == 2)
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

    @Test("an unfinished batch is deleted entirely three days after it was last used, and kept until then")
    func unfinishedExpiry() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        _ = try await world.process(batch, store)

        world.time.advance(hours: 71)
        #expect(try await store.sweep() == 0)
        #expect(world.files.photoNames.count == 2)
        #expect(await world.launch().batch(batch)?.review != nil)

        world.time.advance(hours: 1)
        #expect(try await store.sweep() == 2)
        #expect(world.files.photoNames.isEmpty)
        #expect(await store.batch(batch) == nil)
        #expect(await world.launch().all.isEmpty)
        // The next open says so once and starts a new, empty batch.
        #expect(await store.takeExpiryNotice())
        #expect(await world.launch().takeExpiryNotice() == false)
        let fresh = try await store.open(in: world.space)
        #expect(fresh.id != batch)
        #expect(fresh.photos.isEmpty)
    }

    @Test("using a batch starts its three days again: opening it, taking a photo, removing one or changing the review")
    func activityResetsExpiry() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        func survivesTwoDaysAfter(_ use: () async throws -> Void) async throws {
            world.time.advance(hours: 48)
            try await use()
            world.time.advance(hours: 48)
            try await store.sweep()
            #expect(await store.batch(batch) != nil)
        }
        try await survivesTwoDaysAfter { _ = try await store.open(in: world.space) }
        try await survivesTwoDaysAfter { try await store.stage(Data("rice".utf8), fileExtension: "jpg", source: .camera, in: batch) }
        try await survivesTwoDaysAfter {
            let photo = try #require(await store.batch(batch)?.photos.last)
            try await store.removePhoto(photo.id, from: batch)
        }
        let review = try await world.process(batch, store)
        try await survivesTwoDaysAfter { try await store.updateReview(batch) { try $0.setName("Rice", for: review.summaries[0].id) } }

        // Reading on its own is not use: launch resume reads without the person.
        world.time.advance(hours: 72)
        try await store.sweep()
        #expect(await store.batch(batch) == nil)
    }

    @Test("a finished batch keeps its photos for a day after it finished, then it is removed with them")
    func finishedBatch() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        try await store.updateReview(batch) { $0.delete(Set(review.summaries.map(\.id))) }
        #expect(await store.batch(batch)?.phase == .finished)
        world.time.advance(hours: 23)
        #expect(try await store.sweep() == 0)
        #expect(world.files.photoNames.count == 1)
        world.time.advance(hours: 2)
        #expect(try await store.sweep() == 1)
        #expect(world.files.photoNames.isEmpty)
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

    @Test("a photo's first observation is the one kept, and a batch is grouped only once")
    func recordOnce() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let photo = try #require(await store.batch(batch)?.photos.first)
        let first = PhotoObservation(photo: photo.id, sequence: 0, capturedAt: photo.capturedAt, lines: [IntakeFixture.line("Basmati rice")])
        let second = PhotoObservation(photo: photo.id, sequence: 0, capturedAt: photo.capturedAt, lines: [IntakeFixture.line("Black beans")])
        #expect(try await store.record(first, in: batch))
        #expect(try await store.record(second, in: batch) == false)
        #expect(await world.launch().observations(in: batch) == [first])

        let review = try await world.process(batch, store)
        try await store.updateReview(batch) { try $0.setName("Rice", for: review.summaries[0].id) }
        let regrouped = IntakeReview(
            space: world.space, observations: [second], grouping: PhotoGrouper().group([second]),
            locations: world.locations, defaultLocation: nil, looksUp: false
        )
        let kept = try await store.finishRecognition(batch, review: regrouped)
        #expect(kept.summaries.map(\.name) == ["Rice"])
    }

    @Test("a damaged batch list is set aside, the person is told, and its photos stay until the copy goes")
    func damagedManifest() async throws {
        let world = IntakeWorld()
        _ = try await world.stage(["rice", "beans"], in: world.launch())
        let whole = try #require(world.files.contents(of: StagingStore.manifestName))
        world.files.put(StagingStore.manifestName, whole.prefix(whole.count / 2))

        let store = world.launch()
        #expect(await store.all.isEmpty)
        #expect(await store.takeLoadProblem() == .damaged)
        #expect(await store.takeLoadProblem() == nil)
        #expect(world.files.contents(of: StagingStore.setAsideName) == whole.prefix(whole.count / 2))
        #expect(try await store.sweep() == 0)
        #expect(world.files.photoNames.filter { $0.hasSuffix(".jpg") }.count == 2)
        // A new batch can start meanwhile, and saving it does not delete the lost batch's photos.
        _ = try await world.stage(["rice"], in: store)
        #expect(try await store.sweep() == 0)

        world.time.advance(hours: 24)
        #expect(try await store.sweep() == 2)
        #expect(!world.files.has(StagingStore.setAsideName))
        #expect(world.files.photoNames.filter { $0.hasSuffix(".jpg") }.count == 1)
    }

    @Test("one batch that cannot be understood is set aside without losing the others")
    func oneDamagedBatch() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let kept = try await world.stage(["rice"], in: store)
        try await store.startProcessing(kept)
        _ = try await store.open(in: SpaceID())
        let data = try #require(world.files.contents(of: StagingStore.manifestName))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var batches = try #require(json["batches"] as? [[String: Any]])
        batches[1]["phase"] = "somethingNewer"
        json["batches"] = batches
        world.files.put(StagingStore.manifestName, try JSONSerialization.data(withJSONObject: json))

        let relaunched = world.launch()
        #expect(await relaunched.all.map(\.id) == [kept])
        #expect(await relaunched.takeLoadProblem() == .damaged)
        #expect(world.files.has(StagingStore.setAsideName))
    }

    @Test("a batch list that cannot be read now is tried again later, and nothing is written or deleted meanwhile")
    func unreadableManifest() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["rice", "beans"], in: world.launch())
        let before = world.files.contents(of: StagingStore.manifestName)
        world.files.failReads(true)

        let store = world.launch()
        #expect(await store.all.isEmpty)
        #expect(await store.takeLoadProblem() == .unreadable)
        #expect(try await store.sweep() == 0)
        await #expect(throws: StagingError.unavailable) { try await store.open(in: world.space) }
        #expect(world.files.contents(of: StagingStore.manifestName) == before)
        #expect(!world.files.has(StagingStore.setAsideName))
        #expect(world.files.removed.isEmpty)

        world.files.failReads(false)
        #expect(await store.batch(batch)?.photos.count == 2)
        #expect(await store.takeLoadProblem() == nil)
        #expect(try await store.open(in: world.space).id == batch)
    }

    @Test("a batch list a newer version wrote is opened read only and never rewritten or swept")
    func newerManifest() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["rice"], in: world.launch())
        let data = try #require(world.files.contents(of: StagingStore.manifestName))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = 99
        json["somethingNew"] = ["kept": true]
        let newer = try JSONSerialization.data(withJSONObject: json)
        world.files.put(StagingStore.manifestName, newer)
        world.files.put(UUID().uuidString + ".jpg")

        let store = world.launch()
        #expect(await store.batch(batch) != nil)
        #expect(await store.takeLoadProblem() == .newerVersion)
        await #expect(throws: StagingError.unavailable) {
            try await store.stage(Data([1]), fileExtension: "jpg", source: .camera, in: batch)
        }
        await #expect(throws: StagingError.unavailable) { try await store.discard(batch) }
        world.time.advance(hours: 24 * 30)
        #expect(try await store.sweep() == 0)
        #expect(world.files.contents(of: StagingStore.manifestName) == newer)
        #expect(world.files.removed.isEmpty)
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
        #expect(StagingDirectory.writeOptions(for: StagingStore.manifestName).contains(.atomic))
        #expect(StagingDirectory.writeOptions(for: StagingStore.setAsideName).contains(.atomic))
        #expect(!StagingDirectory.writeOptions(for: UUID().uuidString + ".jpg").contains(.atomic))
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

    @Test("reading stopped by a storage error ends the run after one read, and Try Again reads it again in the same session")
    func tryAgainAfterStorageError() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let photo = try #require(await store.batch(batch)?.photos.first)
        let recognizer = FakeRecognizer(files: world.files, readings: IntakeFixture.readings)
        let pipeline = world.pipeline(store, recognizer: recognizer)
        world.files.failWrites(to: StagingStore.observationName(photo.id))
        await #expect(throws: StagingError.notRecognized) {
            _ = try await pipeline.finish(batch, locations: world.locations, defaultLocation: world.locations[0].id)
        }
        #expect(await recognizer.reads == 1)

        world.files.allowWrites()
        let review = try await pipeline.finish(batch, locations: world.locations, defaultLocation: world.locations[0].id)
        #expect(review.summaries.map(\.name) == ["Basmati rice"])
        #expect(await recognizer.reads == 2)
    }

    @Test("a photo that crashes the reader is counted before each read, and after two crashes it is kept as unreadable", .timeLimit(.minutes(1)))
    func crashingPhoto() async throws {
        let world = IntakeWorld()
        let batch = try await world.stage(["rice", "crash", "beans"], in: world.launch())
        try await world.launch().startProcessing(batch)
        var serial = ReadingPolicy()
        serial.afterDone = 1

        for launch in 1...2 {
            let store = world.launch()
            let recognizer = CrashingRecognizer(files: world.files)
            let pipeline = world.pipeline(store, recognizer: recognizer, policy: serial)
            let run = Task { try await pipeline.process(batch, locations: world.locations, defaultLocation: nil) }
            #expect(await waitUntil { await recognizer.crashes == 1 })
            _ = run  // Never finishes: the process died here.
            #expect(await world.launch().batch(batch)?.photos[1].readAttempts == launch)
        }

        let store = world.launch()
        let recognizer = CrashingRecognizer(files: world.files)
        let review = try await world.pipeline(store, recognizer: recognizer, policy: serial)
            .process(batch, locations: world.locations, defaultLocation: nil)
        #expect(await recognizer.reads == ["beans"])
        #expect(review.summaries.count == 3)
        #expect(await store.batch(batch)?.photos[1].couldNotRead == true)
        #expect(await store.batch(batch)?.photos[0].couldNotRead == false)
    }

    @Test("closing while a photo is being read does not count against it")
    func cancelledReadNotCounted() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let interrupted = FakeRecognizer(files: world.files, readings: IntakeFixture.readings, cancelAfter: 0)
        await #expect(throws: CancellationError.self) {
            _ = try await world.pipeline(store, recognizer: interrupted).process(batch, locations: world.locations, defaultLocation: nil)
        }
        #expect(await store.batch(batch)?.photos[0].readAttempts == 0)
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

    @Test("the review's Undo cannot bring an added candidate back while its package stays in the pantry")
    func undoAfterAdd() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        let id = review.summaries[0].id
        try await store.updateReview(batch) { try $0.setName("Rice", for: id) }
        _ = try await IntakeAdding(pantry: world.pantry, store: store).add([id], in: batch)

        #expect(try await store.updateReview(batch) { $0.undo() } == false)
        #expect(await store.batch(batch)?.review?.summaries.isEmpty == true)
        #expect(try await world.pantry.snapshot().entries.map(\.package.name) == ["Rice"])
    }

    @Test("after Undo Add, the review's Undo cannot restore an added status, and adding again makes a package")
    func undoAddThenReviewUndo() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let (rice, beans) = (review.summaries[0].id, review.summaries[1].id)
        let adding = IntakeAdding(pantry: world.pantry, store: store)
        try await store.updateReview(batch) { try $0.setName("Rice", for: rice) }
        let addition = try await adding.add([rice], in: batch)
        // An edit while the add stands records a snapshot in which the rice is added.
        try await store.updateReview(batch) { try $0.setName("Frijoles", for: beans) }
        try await adding.undo(addition)

        _ = try await store.updateReview(batch) { $0.undo() }
        #expect(await store.batch(batch)?.review?.summaries.map(\.id).contains(rice) == true)
        let again = try await adding.add([rice], in: batch)
        #expect(again.packages.count == 1)
        #expect(try await world.pantry.snapshot().entries.map(\.package.name) == ["Rice"])
    }

    @Test("a candidate whose package identity is already in the inventory gets a new package when added")
    func staleIdentity() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        // A package with the candidate's identity, already discarded, as an undo leaves it.
        let old = try #require(review.drafts(for: review.readyToAdd).first)
        _ = try await world.pantry.putAway([old])
        _ = try await world.pantry.perform(.discard(reason: nil), on: old.id)

        let addition = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        #expect(addition.packages.count == 1)
        #expect(addition.packages != [old.id])
        #expect(try await world.pantry.snapshot().entries.map(\.package.name) == ["Basmati rice"])
    }

    @Test("an add whose candidates cannot be marked after the packages were saved still reports them, and never adds them twice")
    func markFailsAfterSave() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        let adding = IntakeAdding(pantry: world.pantry, store: store)
        world.files.failWrites(after: 1)
        let addition = try await adding.add(review.readyToAdd, in: batch)
        #expect(addition.packages.count == 1)
        #expect(try await world.pantry.snapshot().entries.count == 1)

        let again = try await adding.add(review.readyToAdd, in: batch)
        #expect(again.packages.isEmpty)
        world.files.allowWrites()
        try await IntakeAdding(pantry: world.pantry, store: world.launch()).resume(batch)
        #expect(try await world.pantry.snapshot().entries.count == 1)
        #expect(await world.launch().batch(batch)?.review?.isFinished == true)
    }

    @Test("undoing an add whose candidates could not be marked takes it back for good, and the candidate can be added again")
    func undoAfterMarkFails() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        let adding = IntakeAdding(pantry: world.pantry, store: store)
        world.files.failWrites(after: 1)
        let addition = try await adding.add(review.readyToAdd, in: batch)
        world.files.allowWrites()
        #expect(try await world.pantry.snapshot().entries.count == 1)

        try await adding.undo(addition)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        #expect(await store.batch(batch)?.review?.readyToAdd.count == 1)
        try await IntakeAdding(pantry: world.pantry, store: world.launch()).resume(batch)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
    }

    @Test("an undo cut off part way, of an add whose candidates could not be marked, is finished on relaunch and adds nothing")
    func killDuringUndoAfterMarkFails() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice"], in: store)
        let review = try await world.process(batch, store)
        world.files.failWrites(after: 1)
        let addition = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        world.files.allowWrites()
        // What `undo` does, stopped before the packages are discarded.
        try await store.updateReview(batch) { $0.beginUndo(addition.candidates) }

        let relaunched = world.launch()
        try await IntakeAdding(pantry: world.pantry, store: relaunched).resume(batch)
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        let back = try #require(await relaunched.batch(batch)?.review)
        #expect(back.summaries.map(\.id) == Array(addition.candidates))
        #expect(back.pendingAdd.isEmpty)
        #expect(back.pendingUndo.isEmpty)
    }

    @Test("a second add begun while an earlier one is unfinished keeps both on record")
    func pendingAddsMerge() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let (rice, beans) = (review.summaries[0].id, review.summaries[1].id)
        try await store.updateReview(batch) { $0.beginAdd([rice]) }
        try await store.updateReview(batch) { $0.beginAdd([beans]) }
        #expect(await store.batch(batch)?.review?.pendingAdd == [rice, beans])
        try await IntakeAdding(pantry: world.pantry, store: world.launch()).resume(batch)
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

    @Test("an unfinished batch with an add cut off is kept past three days, finished on relaunch, and then expires as usual")
    func pendingAddOutlivesExpiry() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        // What `add` does for the rice, stopped before its package is saved.
        try await store.updateReview(batch) { $0.beginAdd([review.summaries[0].id]) }

        world.time.advance(hours: 24 * 4)
        let relaunched = world.launch()
        #expect(try await relaunched.sweep() == 0)
        #expect(await relaunched.takeExpiryNotice() == false)
        try await IntakeAdding(pantry: world.pantry, store: relaunched).resume(batch)
        #expect(try await world.pantry.snapshot().entries.map(\.package.name) == ["Basmati rice"])

        world.time.advance(hours: 72)
        #expect(try await relaunched.sweep() == 2)
        #expect(await relaunched.batch(batch) == nil)
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

    /// Adds every candidate of a two-photo batch, then does what `undo` does up to a kill: the undo
    /// is on record and no package is discarded yet. The batch is still finished.
    private func undoCutOffAfterAddAll(_ world: IntakeWorld) async throws -> IntakeBatchID {
        let store = world.launch()
        let batch = try await world.stage(["rice", "beans"], in: store)
        let review = try await world.process(batch, store)
        let addition = try await IntakeAdding(pantry: world.pantry, store: store).add(review.readyToAdd, in: batch)
        try await store.updateReview(batch) { $0.beginUndo(addition.candidates) }
        #expect(await store.batch(batch)?.phase == .finished)
        #expect(try await world.pantry.snapshot().entries.count == 2)
        return batch
    }

    @Test("launch finishes an undo of Add all that a kill cut off, although the batch is finished")
    func killDuringUndoOfAddAll() async throws {
        let world = IntakeWorld()
        let batch = try await undoCutOffAfterAddAll(world)

        let relaunched = world.launch()
        await IntakeAdding(pantry: world.pantry, store: relaunched).resumeAll()
        #expect(try await world.pantry.snapshot().entries.isEmpty)
        let back = try #require(await relaunched.batch(batch))
        #expect(back.phase == .reviewing)
        #expect(back.review?.summaries.count == 2)
        #expect(back.review?.hasAddOrUndoInProgress == false)
    }

    @Test("a finished batch with an undo cut off is kept past every expiry, finished at launch, and then expires as usual")
    func pendingUndoOutlivesExpiry() async throws {
        let world = IntakeWorld()
        let batch = try await undoCutOffAfterAddAll(world)

        world.time.advance(hours: 24 * 4)
        let relaunched = world.launch()
        // The sweep when the app becomes active can run before launch resume does.
        #expect(try await relaunched.sweep() == 0)
        #expect(await relaunched.batch(batch) != nil)
        await IntakeAdding(pantry: world.pantry, store: relaunched).resumeAll()
        #expect(try await world.pantry.snapshot().entries.isEmpty)

        world.time.advance(hours: 71)
        #expect(try await relaunched.sweep() == 0)
        world.time.advance(hours: 1)
        #expect(try await relaunched.sweep() == 2)
        #expect(await relaunched.batch(batch) == nil)
    }

    @Test("once a cut-off undo is finished and the batch is added again, it expires a recovery window after it finished")
    func resolvedUndoThenFinishedExpires() async throws {
        let world = IntakeWorld()
        let batch = try await undoCutOffAfterAddAll(world)
        let relaunched = world.launch()
        let adding = IntakeAdding(pantry: world.pantry, store: relaunched)
        await adding.resumeAll()
        let back = try #require(await relaunched.batch(batch)?.review)
        _ = try await adding.add(back.readyToAdd, in: batch)
        #expect(await relaunched.batch(batch)?.phase == .finished)

        world.time.advance(hours: 23)
        #expect(try await relaunched.sweep() == 0)
        world.time.advance(hours: 1)
        #expect(try await relaunched.sweep() == 2)
        #expect(try await world.pantry.snapshot().entries.count == 2)
    }

    @Test("launch resume never adds a second time: not a finished add, and not a cut-off add resumed twice")
    func resumeAllAddsOnce() async throws {
        let world = IntakeWorld()
        let store = world.launch()
        let added = try await world.stage(["rice"], in: store)
        let first = try await world.process(added, store)
        _ = try await IntakeAdding(pantry: world.pantry, store: store).add(first.readyToAdd, in: added)
        #expect(await store.batch(added)?.phase == .finished)
        let cutOff = try await world.stage(["beans"], in: store)
        let second = try await world.process(cutOff, store)
        // What `add` does for the beans, stopped after the package is saved.
        try await store.updateReview(cutOff) { $0.beginAdd(Set(second.readyToAdd)) }
        _ = try await world.pantry.putAway(second.drafts(for: second.readyToAdd))

        let relaunched = world.launch()
        let adding = IntakeAdding(pantry: world.pantry, store: relaunched)
        await adding.resumeAll()
        await adding.resumeAll()
        #expect(try await world.pantry.snapshot().entries.count == 2)
        #expect(await relaunched.withAddOrUndoInProgress(in: world.space).isEmpty)
        #expect(await relaunched.batch(cutOff)?.phase == .finished)
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
