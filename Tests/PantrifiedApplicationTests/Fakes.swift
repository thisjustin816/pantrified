import Foundation
import PantrifiedApplication
import PantrifiedDomain

struct FakeFailure: Error, Equatable {}

final class FixedTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    func now() -> Date { lock.withLock { current } }
    func advance(hours: Double) { lock.withLock { current = current.addingTimeInterval(hours * 3600) } }
}

actor InMemoryInventory: InventoryRepository {
    private var packages: [PackageID: Package] = [:]
    private(set) var saveCount = 0
    var failOnSave = false
    var failOnRead = false

    init(_ initial: [Package] = []) {
        for package in initial { packages[package.id] = package }
    }

    func setFailOnSave(_ value: Bool) { failOnSave = value }
    func setFailOnRead(_ value: Bool) { failOnRead = value }

    func package(_ id: PackageID) async throws -> Package? {
        if failOnRead { throw FakeFailure() }
        return packages[id]
    }

    func activePackages(in space: SpaceID) async throws -> [Package] {
        if failOnRead { throw FakeFailure() }
        return packages.values.filter { $0.spaceID == space && $0.status == .active }
    }

    func save(_ package: Package) async throws {
        if failOnSave { throw FakeFailure() }
        packages[package.id] = package
        saveCount += 1
    }
}

struct InMemoryLocations: StorageLocationRepository {
    let locationsBySpace: [SpaceID: [StorageLocation]]

    func locations(in space: SpaceID) async throws -> [StorageLocation] {
        locationsBySpace[space] ?? []
    }
}

struct FakeGuidance: StorageGuidanceRepository {
    var result: StorageGuidance?
    var fails = false

    func guidance(for package: Package) async throws -> StorageGuidance? {
        if fails { throw FakeFailure() }
        return result
    }
}
