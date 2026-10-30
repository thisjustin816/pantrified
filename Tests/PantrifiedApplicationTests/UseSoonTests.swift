import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ offset: Int) -> Date {
    let base = DateComponents(calendar: utc, year: 2026, month: 11, day: 1, hour: 12).date!
    return utc.date(byAdding: .day, value: offset, to: base)!
}

private let space = SpaceID()
private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
private let freezer = StorageLocation(name: "Freezer", storageType: .frozen)
private let guidanceSource = GuidanceProvenance(source: "USDA FoodKeeper", version: "test-1")

private func package(
    _ name: String,
    in location: StorageLocation? = fridge,
    printed: PrintedDate? = nil,
    space: SpaceID = space
) -> Package {
    Package(
        spaceID: space,
        name: name,
        location: location?.id ?? LocationID(),
        printedDate: printed,
        addedAt: day(0)
    )
}

private func useSoon(
    _ packages: [Package],
    guidance: FakeGuidance = FakeGuidance(),
    inventory: InMemoryInventory? = nil
) -> UseSoon {
    UseSoon(
        inventory: inventory ?? InMemoryInventory(packages),
        locations: InMemoryLocations(locationsBySpace: [space: [fridge, freezer]]),
        guidance: guidance,
        time: FixedTime(day(0)),
        policy: AttentionPolicy(calendar: utc, useSoonWithinDays: 3)
    )
}

@Suite("Use soon")
struct UseSoonTests {
    @Test("lists only packages that need attention, earliest date first")
    func filtersAndSorts() async throws {
        let soon = package("Spinach", printed: PrintedDate(label: .useBy, date: day(2)))
        let later = package("Rice", printed: PrintedDate(label: .bestBy, date: day(60)))
        let past = package("Yogurt", printed: PrintedDate(label: .useBy, date: day(-2)))
        let unknown = package("Mystery jar")

        let items = try await useSoon([soon, later, past, unknown]).items(in: space)

        #expect(items.map(\.package.name) == ["Yogurt", "Spinach"])
        #expect(items.map(\.assessment.state) == [.pastGuidance, .useSoon])
    }

    @Test("ties on date sort by name so the list is stable")
    func stableTies() async throws {
        let date = PrintedDate(label: .useBy, date: day(1))
        let items = try await useSoon([
            package("Bread", printed: date),
            package("Apples", printed: date),
        ]).items(in: space)

        #expect(items.map(\.package.name) == ["Apples", "Bread"])
    }

    @Test("sourced guidance is applied using the package's storage location")
    func usesGuidanceAndLocation() async throws {
        let guidance = FakeGuidance(result: StorageGuidance(
            provenance: guidanceSource,
            windows: [
                GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 2),
                GuidanceWindow(storageType: .frozen, anchor: .added, days: 180),
            ]
        ))
        let items = try await useSoon(
            [package("Chicken", in: fridge), package("Peas", in: freezer)],
            guidance: guidance
        ).items(in: space)

        #expect(items.map(\.package.name) == ["Chicken"])
        #expect(items.first?.assessment.basis == [.guidance(provenance: guidanceSource, days: 2, anchor: .added)])
    }

    @Test("a package in a deleted location keeps its printed-date attention without guidance")
    func missingLocation() async throws {
        let guidance = FakeGuidance(result: StorageGuidance(
            provenance: guidanceSource,
            windows: [GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 1)]
        ))
        let orphan = package("Cheese", in: nil, printed: PrintedDate(label: .useBy, date: day(1)))
        let items = try await useSoon([orphan], guidance: guidance).items(in: space)

        #expect(items.first?.assessment.basis == [.printedDate(label: .useBy, date: day(1))])
    }

    @Test("other spaces are not included")
    func spaceScoped() async throws {
        let other = package("Elsewhere", printed: PrintedDate(label: .useBy, date: day(1)), space: SpaceID())
        let items = try await useSoon([other]).items(in: space)

        #expect(items.isEmpty)
    }

    @Test("an inventory failure surfaces")
    func inventoryFailure() async {
        let inventory = InMemoryInventory()
        await inventory.setFailOnRead(true)

        await #expect(throws: FakeFailure.self) {
            try await useSoon([], inventory: inventory).items(in: space)
        }
    }

    @Test("a guidance failure surfaces rather than silently under-reporting")
    func guidanceFailure() async {
        let soon = package("Spinach", printed: PrintedDate(label: .useBy, date: day(2)))

        await #expect(throws: FakeFailure.self) {
            try await useSoon([soon], guidance: FakeGuidance(fails: true)).items(in: space)
        }
    }
}
