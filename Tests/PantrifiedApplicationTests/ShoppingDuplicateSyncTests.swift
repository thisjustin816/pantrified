import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

@Suite("Shopping duplicates across devices")
struct ShoppingDuplicateSyncTests {
    /// Two devices add the same item while apart, then sync.
    private func twoDevicesWithEggs() async throws -> (World, Device, Device) {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: 2)
        a.link.faults.offline = true
        b.link.faults.offline = true
        try await a.shopping.add(name: "Eggs", quantity: "1 dozen", in: world.space)
        try await b.shopping.add(name: "Eggs", category: "Dairy", in: world.space)
        a.link.faults.offline = false
        b.link.faults.offline = false
        try await world.settle([a, b])
        return (world, a, b)
    }

    @Test("an item added on two devices while apart shows as a duplicate on both")
    func flaggedOnBoth() async throws {
        let (world, a, b) = try await twoDevicesWithEggs()

        for device in [a, b] {
            let groups = try await device.shopping.duplicateGroups(in: world.space)
            #expect(groups.count == 1)
            #expect(groups[0].items.count == 2)
        }
        _ = try await expectConverged([a, b], in: world)
    }

    @Test("merging on one device removes the duplicate everywhere")
    func mergeConverges() async throws {
        let (world, a, b) = try await twoDevicesWithEggs()
        let keeper = try #require(try await a.shopping.duplicateGroups(in: world.space).first?.keeper)

        try await a.shopping.mergeDuplicates(of: keeper.id, in: world.space)
        try await world.settle([a, b])

        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.map(\.name) == ["Eggs"])
        #expect(state.shopping.first?.id == keeper.id)
        #expect(try await b.shopping.duplicateGroups(in: world.space).isEmpty)
    }

    @Test("both devices merging at once keep the same item")
    func concurrentMerges() async throws {
        let (world, a, b) = try await twoDevicesWithEggs()
        let keeperOnA = try #require(try await a.shopping.duplicateGroups(in: world.space).first?.keeper)

        a.link.faults.offline = true
        b.link.faults.offline = true
        try await a.shopping.mergeDuplicates(of: keeperOnA.id, in: world.space)
        let keeperOnB = try #require(try await b.shopping.duplicateGroups(in: world.space).first?.keeper)
        try await b.shopping.mergeDuplicates(of: keeperOnB.id, in: world.space)
        a.link.faults.offline = false
        b.link.faults.offline = false
        try await world.settle([a, b])

        #expect(keeperOnA.id == keeperOnB.id)
        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.map(\.id) == [keeperOnA.id])
    }

    @Test("a merge undone on one device and merged again on another still converges")
    func undoAgainstMerge() async throws {
        let (world, a, b) = try await twoDevicesWithEggs()
        let keeper = try #require(try await a.shopping.duplicateGroups(in: world.space).first?.keeper)

        let merge = try await a.shopping.mergeDuplicates(of: keeper.id, in: world.space)
        try await world.settle([a, b])
        try await a.shopping.undoMerge(merge, in: world.space)
        try await b.shopping.add(name: "Milk", in: world.space)
        try await world.settle([a, b])

        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.map(\.name).sorted() == ["Eggs", "Eggs", "Milk"])
    }
}
