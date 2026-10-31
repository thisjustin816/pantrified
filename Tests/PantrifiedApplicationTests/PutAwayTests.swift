import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let space = SpaceID()
    let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
    let inventory: InMemoryInventory
    let evidence = InMemoryProductEvidence()
    let putAway: PutAway

    init(existing: [Package] = []) {
        let space = space
        let fridge = fridge
        inventory = InMemoryInventory(existing)
        putAway = PutAway(
            inventory: inventory,
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
            evidence: evidence,
            time: FixedTime(t0)
        )
    }

    func draft(_ name: String?, location: LocationID? = nil) -> PackageDraft {
        var draft = PackageDraft(spaceID: space)
        if let name { draft.name.confirm(name) }
        draft.location = location ?? fridge.id
        return draft
    }
}

@Suite("Put away")
struct PutAwayTests {
    @Test("an incomplete draft becomes a usable package with unknown quantity and no date")
    func incompleteDraft() async throws {
        let f = Fixture()
        let draft = f.draft("Leftover soup")
        let result = try await f.putAway.putAway([draft])

        #expect(result.created == [draft.id])
        let package = try #require(await f.inventory.package(draft.id))
        #expect(package.name == "Leftover soup")
        #expect(package.quantity == .unknown)
        #expect(package.printedDate == nil)
        #expect(package.addedAt == t0)
        #expect(package.location == f.fridge.id)
    }

    @Test("recognized and confirmed fields carry over, and the name is trimmed")
    func fieldsCarryOver() async throws {
        let f = Fixture()
        var draft = f.draft("  Yogurt ")
        let printed = PrintedDate(label: .useBy, date: t0)
        draft.apply(PackageProposal(quantity: .full, printedDate: printed))
        _ = try await f.putAway.putAway([draft])

        let package = try #require(await f.inventory.package(draft.id))
        #expect(package.name == "Yogurt")
        #expect(package.quantity == .full)
        #expect(package.printedDate == printed)
    }

    @Test("fields the user confirmed in review resist recognition that arrives after put-away")
    func confirmationsCarryOver() async throws {
        let f = Fixture()
        var draft = f.draft("Yogurt")
        draft.apply(PackageProposal(printedDate: PrintedDate(label: .useBy, date: t0)))
        _ = try await f.putAway.putAway([draft])

        var package = try #require(await f.inventory.package(draft.id))
        let later = PrintedDate(label: .bestBy, date: t0.addingTimeInterval(86_400))
        try package.propose(PackageProposal(name: "Greek yogurt", printedDate: later), at: t0)

        #expect(package.confirmedFields == [.name])
        #expect(package.name == "Yogurt")
        #expect(package.printedDate == later)
    }

    @Test("repeated identical products become separate packages")
    func identicalProducts() async throws {
        let f = Fixture()
        var a = f.draft("Milk")
        var b = f.draft("Milk")
        a.barcode = GTIN("036000291452")
        b.barcode = GTIN("036000291452")
        _ = try await f.putAway.putAway([a, b])

        #expect(try await f.inventory.activePackages(in: f.space).count == 2)
        #expect(try await f.evidence.barcode(of: a.id, in: f.space) == GTIN("036000291452"))
        #expect(try await f.evidence.barcode(of: b.id, in: f.space) == GTIN("036000291452"))
    }

    @Test("a batch's barcodes are kept in one write after its packages are saved")
    func barcodesKeptInOneWrite() async throws {
        let f = Fixture()
        var a = f.draft("Milk")
        var b = f.draft("Rice")
        let c = f.draft("Soup")
        a.barcode = GTIN("036000291452")
        b.barcode = GTIN("4006381333931")

        let result = try await f.putAway.putAway([a, b, c])

        #expect(result.barcodesNotKept.isEmpty)
        #expect(await f.evidence.writes == 1)
        #expect(await f.evidence.barcodes[f.space] == [a.id: GTIN("036000291452")!, b.id: GTIN("4006381333931")!])
    }

    @Test("a batch with no barcodes writes no evidence")
    func noBarcodesNoWrite() async throws {
        let f = Fixture()
        _ = try await f.putAway.putAway([f.draft("Soup")])

        #expect(await f.evidence.writes == 0)
    }

    @Test("a barcode that cannot be kept is reported, and the packages stay saved")
    func barcodeFailureIsReported() async throws {
        let f = Fixture()
        await f.evidence.setFailWrites(true)
        var draft = f.draft("Milk")
        draft.barcode = GTIN("036000291452")

        let result = try await f.putAway.putAway([draft])

        #expect(result.created == [draft.id])
        #expect(result.barcodesNotKept == [draft.id])
        #expect(try await f.inventory.package(draft.id) != nil)
    }

    @Test("a retry keeps a barcode an earlier attempt could not")
    func retryKeepsBarcode() async throws {
        let f = Fixture()
        await f.evidence.setFailWrites(true)
        var draft = f.draft("Milk")
        draft.barcode = GTIN("036000291452")
        _ = try await f.putAway.putAway([draft])
        await f.evidence.setFailWrites(false)

        let retry = try await f.putAway.putAway([draft])

        #expect(retry.alreadyPresent == [draft.id])
        #expect(retry.barcodesNotKept.isEmpty)
        #expect(try await f.evidence.barcode(of: draft.id, in: f.space) == GTIN("036000291452"))
    }

    @Test("when the packages fail to save, no barcode is kept")
    func failedSaveKeepsNoBarcode() async throws {
        let f = Fixture()
        await f.inventory.setFailOnSave(true)
        var draft = f.draft("Milk")
        draft.barcode = GTIN("036000291452")

        await #expect(throws: FakeFailure.self) { try await f.putAway.putAway([draft]) }

        #expect(await f.evidence.writes == 0)
    }

    @Test("one unready draft saves nothing and names the drafts that need work")
    func unreadyDraftBlocksBatch() async throws {
        let f = Fixture()
        let good = f.draft("Rice")
        let unnamed = f.draft(nil)

        await #expect(throws: PutAwayError.notReady([unnamed.id])) {
            try await f.putAway.putAway([good, unnamed])
        }
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("a location outside the draft's space blocks the batch")
    func unknownLocation() async throws {
        let f = Fixture()
        let draft = f.draft("Rice", location: LocationID())

        await #expect(throws: PutAwayError.unknownLocation(draft.id)) {
            try await f.putAway.putAway([draft])
        }
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("a failed save leaves the inventory unchanged")
    func saveFailure() async throws {
        let f = Fixture()
        await f.inventory.setFailOnSave(true)

        await #expect(throws: FakeFailure.self) {
            try await f.putAway.putAway([f.draft("Rice"), f.draft("Beans")])
        }
        #expect(try await f.inventory.activePackages(in: f.space).isEmpty)
    }

    @Test("retrying a completed put-away does not overwrite later changes")
    func retryIsIdempotent() async throws {
        let f = Fixture()
        let draft = f.draft("Rice")
        _ = try await f.putAway.putAway([draft])

        var package = try #require(await f.inventory.package(draft.id))
        try package.record(.usedUp, at: t0.addingTimeInterval(3600))
        try await f.inventory.save(package)

        let retry = try await f.putAway.putAway([draft])

        #expect(retry.created.isEmpty)
        #expect(retry.alreadyPresent == [draft.id])
        #expect(try await f.inventory.package(draft.id)?.status == .usedUp(at: t0.addingTimeInterval(3600)))
    }

    @Test("an empty batch succeeds without touching storage")
    func emptyBatch() async throws {
        let f = Fixture()
        let result = try await f.putAway.putAway([])

        #expect(result.created.isEmpty)
        #expect(await f.inventory.saveCount == 0)
    }
}
