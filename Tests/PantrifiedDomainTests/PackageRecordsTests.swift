import Foundation
import Testing
import PantrifiedTestSupport
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let space = SpaceID()
private let fridge = LocationID()
private let freezer = LocationID()
private let pantry = LocationID()

private func hours(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

/// A replica's record set and clock, without any transport.
private struct Replica {
    var clock = HybridClock(replica: ReplicaID())
    var records = RecordSet()
    var skewHours: Double = 0

    @discardableResult
    mutating func stage(_ package: Package, at hour: Double) -> [SyncRecord] {
        let now = hours(hour + skewHours)
        var clock = self.clock
        let changes = PackageRecords.changes(in: package, against: records) { clock.tick(now: now) }
        self.clock = clock
        for change in changes { records.merge(change) }
        return changes
    }

    mutating func receive(_ incoming: [SyncRecord]) {
        for record in incoming {
            clock.observe(record.latestStamp)
            records.merge(record)
        }
    }

    func package(_ id: PackageID) -> Package? {
        PackageRecords.materialize(id, from: records).entity
    }
}

private func makePackage() -> Package {
    Package(spaceID: space, name: "Yoghrt", location: fridge, quantity: .full, addedAt: t0)
}

/// An unrelated record. Adding some before the records under test changes the set's internal
/// layout, and with it the order a scan of the set visits records in.
private func filler(_ stamp: HybridTimestamp) -> SyncRecord {
    SyncRecord(id: RecordID(kind: .shoppingItem, entity: UUID()), created: stamp, fields: [:])
}

/// The record a device writes for `change` on its own copy of `package`, stamped `stamp`. Devices
/// restored from one backup share a replica ID and clock, so their writes can carry equal stamps.
private func eventRecords(
    _ change: PackageChange,
    id: PackageEventID = PackageEventID(),
    on package: Package,
    against records: RecordSet,
    stamp: HybridTimestamp
) throws -> [SyncRecord] {
    var copy = package
    try copy.record(change, at: hours(1), id: id)
    return PackageRecords.changes(in: copy, against: records) { stamp }
}

/// Event IDs in the order the sync design folds them: creation stamp, then record ID.
private func foldOrder(_ records: [SyncRecord]) -> [UUID] {
    records
        .sorted { ($0.created, $0.id.entity.uuidString) < ($1.created, $1.id.entity.uuidString) }
        .map(\.id.entity)
}

@Suite("Package records")
struct PackageRecordsTests {
    @Test("a package survives the round trip through records with the same history and state")
    func roundTrip() throws {
        var package = Package(
            spaceID: space, productID: ProductID(), name: "Milk", location: fridge, quantity: .exact(1.5, unit: "l"),
            printedDate: PrintedDate(label: .useBy, date: hours(72)),
            instruction: PackageInstruction(days: 3, anchor: .opened, storageType: .refrigerated),
            confirmed: [.name], addedAt: t0
        )
        try package.record(.opened, at: hours(1))
        try package.record(.moved(to: freezer), at: hours(2))
        try package.record(.frozen, at: hours(2))
        try package.record(.thawed, at: hours(20))
        try package.record(.quantityChanged(.aboutHalf), at: hours(21))
        try package.record(.usedSome(resulting: .low), at: hours(22))
        try package.record(.confirmedPresent, at: hours(23))
        try package.record(.recognized(.printedDate(nil)), at: hours(24))
        try package.record(.corrected(.productID(nil)), at: hours(24))
        try package.record(.corrected(.instruction(nil)), at: hours(24))
        let discard = try package.record(.discarded(reason: .spoiled), at: hours(25))
        try package.undo(discard, at: hours(25.1))
        try package.record(.usedUp, at: hours(26))

        var replica = Replica()
        replica.stage(package, at: 0)
        let restored = try #require(replica.package(package.id))

        #expect(restored.events == package.events)
        #expect(restored.origin == package.origin)
        #expect(restored.status == package.status)
        #expect(restored.details == package.details)
        #expect(restored.confirmedFields == package.confirmedFields)
        #expect(restored.location == freezer)
        #expect(restored.quantity == .low)
    }

    @Test("staging writes only what the set does not hold yet")
    func incrementalChanges() throws {
        var replica = Replica()
        var package = makePackage()
        #expect(replica.stage(package, at: 0).count == 1)
        #expect(replica.stage(package, at: 0).isEmpty)

        try package.record(.opened, at: hours(1))
        let changes = replica.stage(package, at: 1)

        #expect(changes.map(\.id.kind) == [.packageEvent])
    }

    @Test("events that arrive before their package wait for it")
    func eventsBeforeHeader() throws {
        var source = Replica()
        var package = makePackage()
        try package.record(.opened, at: hours(1))
        let records = source.stage(package, at: 1)

        var target = Replica()
        target.receive(records.filter { $0.id.kind == .packageEvent })
        guard case .incomplete = PackageRecords.materialize(package.id, from: target.records) else {
            Issue.record("expected an incomplete package")
            return
        }

        target.receive(records.filter { $0.id.kind == .package })
        #expect(target.package(package.id)?.openedAt == hours(1))
    }

    @Test("an edit made concurrently with Used up stays in history but the package stays used up")
    func destructiveBeatsConcurrentEdit() throws {
        var a = Replica()
        var b = Replica()
        let original = makePackage()
        b.receive(a.stage(original, at: 0))

        var onA = try #require(a.package(original.id))
        try onA.record(.usedUp, at: hours(1))
        let fromA = a.stage(onA, at: 1)

        var onB = try #require(b.package(original.id))
        try onB.record(.moved(to: freezer), at: hours(2))
        let fromB = b.stage(onB, at: 2)

        a.receive(fromB)
        b.receive(fromA)
        let mergedA = try #require(a.package(original.id))
        let mergedB = try #require(b.package(original.id))

        #expect(mergedA.status == .usedUp(at: hours(1)))
        #expect(mergedA.events == mergedB.events)
        #expect(mergedA.events.count == 2)
    }

    @Test("undoing Used up on another replica restores the package with the concurrent edit applied")
    func undoRestoresConcurrentEdit() throws {
        var a = Replica()
        var b = Replica()
        let original = makePackage()
        b.receive(a.stage(original, at: 0))

        var onA = try #require(a.package(original.id))
        let usedUp = try onA.record(.usedUp, at: hours(1))
        let fromA = a.stage(onA, at: 1)
        var onB = try #require(b.package(original.id))
        try onB.record(.moved(to: freezer), at: hours(1))
        let fromB = b.stage(onB, at: 1)
        a.receive(fromB)
        b.receive(fromA)

        var merged = try #require(b.package(original.id))
        try merged.undo(usedUp, at: hours(2))
        a.receive(b.stage(merged, at: 2))

        let restored = try #require(a.package(original.id))
        #expect(restored.status == .active)
        #expect(restored.location == freezer)
    }

    @Test("a correction beats recognition from another replica whatever the stamps say")
    func correctionBeatsRemoteRecognition() throws {
        var a = Replica()
        var b = Replica(skewHours: -5)
        let original = makePackage()
        b.receive(a.stage(original, at: 0))

        var onB = try #require(b.package(original.id))
        try onB.record(.corrected(.name("Greek yogurt")), at: hours(1))
        let correction = b.stage(onB, at: 1)

        var onA = try #require(a.package(original.id))
        try onA.propose(PackageProposal(name: "Yogurt, plain"), at: hours(3))
        let recognition = a.stage(onA, at: 3)

        a.receive(correction)
        b.receive(recognition)

        #expect(a.package(original.id)?.name == "Greek yogurt")
        #expect(b.package(original.id)?.name == "Greek yogurt")
    }

    @Test("an event a newer version marked safe to skip is skipped")
    func ignorableUnknownEvent() throws {
        var replica = Replica()
        let package = makePackage()
        replica.stage(package, at: 0)
        let stamp = replica.clock.tick(now: hours(1))
        replica.records.merge(SyncRecord(
            id: RecordID(kind: .packageEvent, entity: UUID()),
            writing: [
                "package": .uuid(package.id.rawValue), "at": .date(hours(1)),
                "change": .map(["type": .string("labelPrinted")]),
            ],
            at: stamp
        ))

        #expect(replica.package(package.id)?.status == .active)
    }

    @Test("a record that needs a newer reader withholds the whole package")
    func newerReaderRequired() throws {
        var replica = Replica()
        let package = makePackage()
        replica.stage(package, at: 0)
        let stamp = replica.clock.tick(now: hours(1))
        var record = SyncRecord(
            id: RecordID(kind: .packageEvent, entity: UUID()),
            writing: [
                "package": .uuid(package.id.rawValue), "at": .date(hours(1)),
                "change": .map(["type": .string("composted")]),
            ],
            at: stamp
        )
        record.minimumReaderVersion = SyncFormat.version + 1
        replica.records.merge(record)

        guard case .unreadable = PackageRecords.materialize(package.id, from: replica.records) else {
            Issue.record("expected the package to be withheld")
            return
        }
        #expect(PackageRecords.materializeAll(from: replica.records)[package.id]?.entity == nil)
    }

    @Test("every delivery order of the same records builds the same package", arguments: 0..<30)
    func deliveryOrderDoesNotMatter(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var a = Replica()
        var b = Replica(skewHours: 3)
        var c = Replica(skewHours: -2)
        let original = makePackage()
        let creation = a.stage(original, at: 0)
        b.receive(creation)
        c.receive(creation)

        var onA = try #require(a.package(original.id))
        let discard = try onA.record(.discarded(reason: .spoiled), at: hours(1))
        try onA.undo(discard, at: hours(1.5))
        try onA.record(.moved(to: freezer), at: hours(2))
        var onB = try #require(b.package(original.id))
        try onB.record(.corrected(.name("Skyr")), at: hours(1))
        try onB.record(.opened, at: hours(2))
        var onC = try #require(c.package(original.id))
        try onC.propose(PackageProposal(name: "Yogurt"), at: hours(1))
        try onC.record(.usedSome(resulting: .aboutHalf), at: hours(3))

        let all = creation + a.stage(onA, at: 2) + b.stage(onB, at: 2) + c.stage(onC, at: 3)
        var first = Replica()
        first.receive(all)
        let reference = try #require(first.package(original.id))

        var shuffled = Replica()
        shuffled.receive((all + all.prefix(4)).shuffled(using: &rng))
        let package = try #require(shuffled.package(original.id))

        #expect(shuffled.records == first.records)
        #expect(package.events == reference.events)
        #expect(package.name == "Skyr")
        #expect(package.status == .active)
        #expect(package.location == freezer)
        #expect(package.quantity == .aboutHalf)
    }

    @Test("events with equal creation stamps fold in record ID order whatever order they arrive in")
    func equalStampsFoldByRecordID() throws {
        var replica = Replica()
        let original = makePackage()
        replica.stage(original, at: 0)
        let tied = replica.clock.tick(now: hours(1))
        let changes: [PackageChange] = [
            .usedUp, .discarded(reason: .spoiled), .moved(to: freezer), .moved(to: pantry), .opened,
        ]
        let events = try changes.flatMap { try eventRecords($0, on: original, against: replica.records, stamp: tied) }
        #expect(events.count == changes.count)

        var folds: Set<[UUID]> = []
        for (index, order) in events.permutations.enumerated() {
            var records = replica.records
            for _ in 0..<(index % 7) { records.merge(filler(tied)) }
            for record in order { records.merge(record) }
            let package = try #require(PackageRecords.materialize(original.id, from: records).entity)
            folds.insert(package.events.map(\.id.rawValue))
        }

        #expect(folds == [foldOrder(events)])
    }

    @Test("histories with colliding stamps build the same package in every arrival order", arguments: 0..<30)
    func collidingStampsConverge(seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var replica = Replica()
        let original = makePackage()
        replica.stage(original, at: 0)
        let pool = [replica.clock.tick(now: hours(1)), replica.clock.tick(now: hours(1))]
        let choices: [PackageChange] = [
            .usedUp, .discarded(reason: .unwanted), .discarded(reason: nil), .moved(to: freezer), .moved(to: pantry),
            .opened, .quantityChanged(.low), .corrected(.name("Skyr")), .recognized(.name("Yogurt")),
        ]

        var written: [(change: PackageChange, id: PackageEventID)] = []
        var all = replica.records
        var events: [SyncRecord] = []
        for _ in 0..<Int.random(in: 2...7, using: &rng) {
            let change = choices.randomElement(using: &rng)!
            let id = PackageEventID()
            let stamp = pool.randomElement(using: &rng)!
            events += try eventRecords(change, id: id, on: original, against: replica.records, stamp: stamp)
            written.append((change, id))
        }
        for record in events { all.merge(record) }
        for _ in 0..<Int.random(in: 0...2, using: &rng) {
            let target = written.randomElement(using: &rng)!
            var copy = original
            try copy.record(target.change, at: hours(1), id: target.id)
            try copy.undo(target.id, at: hours(2))
            let stamp = pool.randomElement(using: &rng)!
            events += PackageRecords.changes(in: copy, against: all) { stamp }
        }

        var reference = replica.records
        for record in events { reference.merge(record) }
        var shuffled = replica.records
        for _ in 0..<Int.random(in: 0..<20, using: &rng) { shuffled.merge(filler(pool[0])) }
        for record in (events + events.prefix(2)).shuffled(using: &rng) { shuffled.merge(record) }

        let expected = try #require(PackageRecords.materialize(original.id, from: reference).entity)
        let package = try #require(PackageRecords.materialize(original.id, from: shuffled).entity)
        #expect(expected.events.map(\.id.rawValue) == foldOrder(events))
        #expect(package.events == expected.events)
        #expect(package.status == expected.status)
        #expect(package.location == expected.location)
    }
}
