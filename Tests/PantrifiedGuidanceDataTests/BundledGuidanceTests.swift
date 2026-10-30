import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedGuidanceData

private let space = SpaceID()

@Suite("Bundled FoodKeeper snapshot")
struct BundledGuidanceTests {
    @Test("the snapshot loads, validates, and names its source and checksum")
    func loads() throws {
        let dataset = try BundledGuidance.dataset()

        #expect(dataset.records.count == 661)
        #expect(dataset.provenance.source == "USDA FSIS FoodKeeper")
        #expect(dataset.provenance.sourceVersion == "128.0 (modified 2018-09-06)")
        #expect(dataset.provenance.sourceChecksum == "037df0d301126acd8a48824506f04d49d8be1a1144b81fa69e4170228dc2e91a")
        #expect(dataset.provenance.normalizationVersion == "1")
    }

    @Test("butter keeps the shorter end of its range in each storage")
    func butter() throws {
        let butter = try #require(try BundledGuidance.dataset().records.first { $0.id == 1 })

        #expect(butter.name == "Butter")
        #expect(butter.windows.contains(GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 30)))
        #expect(butter.windows.contains(GuidanceWindow(storageType: .frozen, anchor: .added, days: 180)))
    }

    @Test("records with nothing to say are kept, so a shared name stays ambiguous")
    func windowlessRecordsKept() throws {
        let records = try BundledGuidance.dataset().records

        #expect(records.filter { $0.windows.isEmpty }.count == 15)
        #expect(records.filter { $0.name == "Milk" }.count == 5)
    }

    @Test("every window in the snapshot is a positive number of days")
    func positiveDays() throws {
        let days = try BundledGuidance.dataset().records.flatMap(\.windows).map(\.days)

        #expect(!days.isEmpty)
        #expect(days.allSatisfy { $0 > 0 })
    }
}

@Suite("Storage guidance from the snapshot")
struct BundledStorageGuidanceTests {
    private func package(_ name: String, daysAgo: Int = 0) -> Package {
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        return Package(spaceID: space, name: name, location: LocationID(), addedAt: added)
    }

    private func repository() throws -> BundledStorageGuidance {
        BundledStorageGuidance(dataset: try BundledGuidance.dataset())
    }

    @Test("a food that matches exactly gets its windows and the snapshot's provenance")
    func matched() async throws {
        let guidance = try #require(try await repository().guidance(for: package("Butter")))

        #expect(guidance.windows.contains(GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 30)))
        #expect(guidance.provenance.source == "USDA FSIS FoodKeeper")
        #expect(guidance.provenance.version.contains("128.0"))
    }

    @Test("a name shared by several records gets no guidance until the person chooses one")
    func ambiguousIsNil() async throws {
        #expect(try await repository().guidance(for: package("Milk")) == nil)
        #expect(try await repository().guidance(for: package("Eggs")) == nil)
    }

    @Test("a confirmed link picks the record and gives its windows")
    func confirmed() async throws {
        let dataset = try BundledGuidance.dataset()
        let shell = try #require(dataset.records.first { $0.id == 21 })
        let repository = BundledStorageGuidance(dataset: dataset, confirmedLinks: [IngredientName("eggs"): 21])

        let guidance = try #require(try await repository.guidance(for: package("Eggs")))

        #expect(guidance.windows == shell.windows)
    }

    @Test("an unknown food gets no guidance")
    func unknown() async throws {
        #expect(try await repository().guidance(for: package("Unobtainium paste")) == nil)
    }

    @Test("a matched record with no window gives no guidance")
    func noWindows() async throws {
        let record = GuidanceRecord(id: 1, name: "Salt", qualifier: nil, category: nil, keywords: [], windows: [])
        let dataset = try GuidanceDataset(
            provenance: GuidanceDataset.Provenance(source: "test", sourceVersion: nil, sourceChecksum: nil, normalizationVersion: "1"),
            records: [record]
        )

        #expect(try await BundledStorageGuidance(dataset: dataset).guidance(for: package("Salt")) == nil)
    }

    @Test("the use-soon list reports an old package from the snapshot, with its source")
    func endToEnd() async throws {
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        var butter = Package(spaceID: space, name: "Butter", location: fridge.id, addedAt: added)
        try butter.record(.quantityChanged(.low), at: added)
        let inventory = FixedInventory([butter])
        let useSoon = UseSoon(
            inventory: inventory,
            locations: FixedLocations([space: [fridge]]),
            guidance: try repository(),
            time: FixedClock(added.addingTimeInterval(40 * 86_400)),
            policy: AttentionPolicy()
        )

        let items = try await useSoon.items(in: space)

        #expect(items.count == 1)
        #expect(items.first?.assessment.state == .pastGuidance)
        guard case .guidance(let provenance, let days, _)? = items.first?.assessment.basis.first else {
            Issue.record("expected guidance as the basis")
            return
        }
        #expect(days == 30)
        #expect(provenance.source == "USDA FSIS FoodKeeper")
    }
}

private struct FixedClock: TimeSource {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

private struct FixedLocations: StorageLocationRepository {
    let bySpace: [SpaceID: [StorageLocation]]
    init(_ bySpace: [SpaceID: [StorageLocation]]) { self.bySpace = bySpace }
    func locations(in space: SpaceID) async throws -> [StorageLocation] { bySpace[space] ?? [] }
}

private actor FixedInventory: InventoryRepository {
    private var packages: [PackageID: Package]
    init(_ packages: [Package]) { self.packages = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) }) }
    func package(_ id: PackageID) async throws -> Package? { packages[id] }
    func activePackages(in space: SpaceID) async throws -> [Package] {
        packages.values.filter { $0.spaceID == space && $0.status == .active }
    }
    func save(_ package: Package) async throws { packages[package.id] = package }
    func saveAll(_ batch: [Package]) async throws { for package in batch { packages[package.id] = package } }
}
