import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private struct Fixture {
    let space = SpaceID()
    let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
    let inventory: InMemoryInventory
    let putAway: PutAway

    init(existing: [Package] = []) {
        let space = space
        let fridge = fridge
        inventory = InMemoryInventory(existing)
        putAway = PutAway(
            inventory: inventory,
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
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

    @Test("repeated identical products become separate packages")
    func identicalProducts() async throws {
        let f = Fixture()
        var a = f.draft("Milk")
        var b = f.draft("Milk")
        a.barcode = "0001"
        b.barcode = "0001"
        _ = try await f.putAway.putAway([a, b])

        #expect(try await f.inventory.activePackages(in: f.space).count == 2)
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
