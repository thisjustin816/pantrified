import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

@Suite("Space replica sync")
struct SyncEngineTests {
    @Test("a package put away on one device appears on another")
    func basicPropagation() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: -3)
        let id = try await world.putAway("Yogurt", on: a)

        try await world.settle([a, b])

        #expect(try await b.package(id).name == "Yogurt")
        try await expectConverged([a, b], in: world)
    }

    @Test("offline changes are usable immediately and upload when the device reconnects")
    func offlineThenRejoin() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: 2)
        let c = try world.device("C", skewHours: -1)
        let id = try await world.putAway("Rice", on: a)
        try await a.shopping.add(name: "Milk", in: world.space)
        try await world.settle([a, b, c])

        b.link.faults.offline = true
        try await b.actions.apply(.move(to: world.pantry.id), to: id)
        try await b.shopping.add(name: "Eggs", in: world.space)
        await #expect(throws: Unreachable.self) { try await b.sync() }
        #expect(try await b.package(id).location == world.pantry.id)
        #expect(await b.replica.pendingCount == 2)

        try await a.actions.apply(.opened, to: id)
        let milk = try #require(try await a.replica.list(in: world.space).items.first)
        try await c.shopping.setChecked(milk.id, true, in: world.space)
        try await world.settle([a, c])

        b.link.faults.offline = false
        try await world.settle([a, b, c])

        let state = try await expectConverged([a, b, c], in: world)
        #expect(state.packages[id]?.location == world.pantry.id)
        #expect(state.packages[id]?.openedAt != nil)
        #expect(state.shopping.map(\.name) == ["Milk", "Eggs"])
        #expect(state.shopping.first?.isChecked == true)
    }

    @Test("a push that partly fails keeps only the failed records queued")
    func partialPushFailure() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B")
        try await a.shopping.add(name: "Milk", in: world.space)
        try await a.shopping.add(name: "Eggs", in: world.space)
        let eggs = try #require(try await a.replica.list(in: world.space).items.last)
        a.link.faults.failingRecords = [RecordID(kind: .shoppingItem, entity: eggs.id.rawValue)]

        let report = try await a.sync()

        #expect(report.pushed == 1)
        #expect(report.pending == 1)
        try await b.sync()
        #expect(try await b.replica.list(in: world.space).items.map(\.name) == ["Milk"])

        a.link.faults.failingRecords = []
        try await world.settle([a, b])
        try await expectConverged([a, b], in: world)
    }

    @Test("a local change made while a push is in flight is not lost when the push is confirmed")
    func changeDuringPush() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B")
        try await a.shopping.add(name: "Milk", in: world.space)
        let milk = try #require(try await a.replica.list(in: world.space).items.first)
        let space = world.space
        a.link.beforePush = {
            a.link.beforePush = nil
            try? await a.replica.update(in: space) { try $0.setChecked(milk.id, true, at: syncEpoch) }
        }

        try await a.sync()
        try await world.settle([a, b])
        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.first?.isChecked == true)
    }

    @Test("writes the server stored without confirming are retried without duplicating anything")
    func unconfirmedWritesAreIdempotent() async throws {
        let world = World()
        let a = try world.device("A", faults: CloudLink.Faults(unconfirmedWrites: 3))
        let b = try world.device("B")
        let id = try await world.putAway("Cheese", on: a)
        try await a.actions.apply(.opened, to: id)

        let first = try await a.sync()
        #expect(first.failed > 0)

        try await world.settle([a, b])

        let state = try await expectConverged([a, b], in: world)
        #expect(state.packages[id]?.events.count == 1)
        #expect(state.records.records.count == 2)
    }

    @Test("a write made without seeing the server's version is merged and retried in the same sync")
    func conflictIsMergedAndRetried() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: 1)
        try await a.shopping.add(name: "Milk", in: world.space)
        try await world.settle([a, b])
        let milk = try #require(try await a.replica.list(in: world.space).items.first)

        try await a.shopping.setChecked(milk.id, true, in: world.space)
        try await world.rename(milk.id, to: "Oat milk", on: b)
        try await a.sync()
        let report = try await b.sync()

        #expect(report.conflicts == 1)
        #expect(report.pending == 0)
        try await world.settle([a, b])
        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.first?.name == "Oat milk")
        #expect(state.shopping.first?.isChecked == true)
    }

    @Test("a pull that fails part way resumes after the last page it saved")
    func pullResumes() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", faults: CloudLink.Faults(pageSize: 1, pullPagesBeforeFailure: 2))
        for name in ["Milk", "Eggs", "Bread", "Rice", "Beans"] {
            try await a.shopping.add(name: name, in: world.space)
        }
        try await a.sync()

        await #expect(throws: Unreachable.self) { try await b.sync() }
        #expect(try await b.replica.list(in: world.space).items.count == 2)

        b.link.faults.pullPagesBeforeFailure = nil
        let resumed = try await b.sync()

        #expect(resumed.pulled == 3)
        try await expectConverged([a, b], in: world)
    }

    @Test("a sync stops at its page limit and the next sync continues where it stopped")
    func pullPageLimit() async throws {
        let world = World()
        let a = try world.device("A")
        for name in ["Milk", "Eggs", "Bread", "Rice", "Beans"] {
            try await a.shopping.add(name: name, in: world.space)
        }
        try await a.sync()
        let b = try SpaceReplica(
            space: world.space, replica: ReplicaID(),
            transport: CloudLink(world.cloud, faults: CloudLink.Faults(pageSize: 1)),
            store: InMemoryReplicaStore(), time: FixedTime(syncEpoch), maxPullPages: 2
        )

        let first = try await b.sync()
        let second = try await b.sync()
        let third = try await b.sync()

        #expect([first.pulled, second.pulled, third.pulled] as [Int] == [2, 2, 1])
        #expect(first.morePending && second.morePending && !third.morePending)
        #expect(try await b.list(in: world.space).items.count == 5)
    }

    @Test("a crash while saving sync progress resumes from the stored state", arguments: 0..<6)
    func crashMidSync(savesBeforeCrash: Int) async throws {
        let world = World()
        let a = try world.device("A")
        var b = try world.device("B", skewHours: -2, faults: CloudLink.Faults(pageSize: 2))
        let id = try await world.putAway("Yogurt", on: a)
        try await a.actions.apply(.opened, to: id)
        try await a.shopping.add(name: "Milk", in: world.space)
        try await a.sync()
        try await b.shopping.add(name: "Eggs", in: world.space)
        try await b.shopping.add(name: "Bread", in: world.space)

        b.store.crash(afterSaves: savesBeforeCrash)
        _ = try? await b.sync()
        b.store.crash(afterSaves: nil)
        b = try world.restart(b)

        try await world.settle([a, b])
        let state = try await expectConverged([a, b], in: world)
        #expect(state.packages[id]?.events.count == 1)
        #expect(state.shopping.map(\.name).sorted() == ["Bread", "Eggs", "Milk"])
    }

    @Test("a restarted replica keeps issuing stamps after the ones it already used")
    func clockSurvivesRestart() async throws {
        let world = World()
        var a = try world.device("A")
        try await a.shopping.add(name: "Milk", in: world.space)
        let before = try #require(await a.replica.records.records.values.first?.latestStamp)

        a.time.advance(hours: -10)
        a = try world.restart(a)
        try await a.shopping.add(name: "Eggs", in: world.space)

        let stamps = await a.replica.records.records.values.map(\.latestStamp)
        #expect(stamps.allSatisfy { $0 >= before })
        #expect(Set(stamps).count == 2)
    }

    @Test("two devices restored from one backup write equal stamps and still converge")
    func restoredDevicesConverge() async throws {
        let world = World()
        let a = try world.device("A")
        var ids: [PackageID] = []
        for name in ["Milk", "Eggs", "Rice", "Beans", "Bread", "Kale", "Tofu", "Feta"] {
            ids.append(try await world.putAway(name, on: a))
        }
        try await a.sync()
        let b = try world.restore(a, as: "B")

        for id in ids {
            try await a.actions.apply(.usedUp, to: id)
            try await b.actions.apply(.discard(reason: .spoiled), to: id)
        }
        let tied = await Set(a.replica.records.records.values.map(\.created))
            .intersection(b.replica.records.records.values.map(\.created))
        #expect(tied.count > ids.count)

        try await world.settle([a, b])
        let state = try await expectConverged([a, b], in: world)
        #expect(ids.allSatisfy { state.packages[$0]?.events.count == 2 })
    }

    @Test("a device that pulls writes made under its own replica ID that it never issued takes a new ID")
    func restoredDeviceTakesNewReplicaID() async throws {
        let world = World()
        let a = try world.device("A")
        try await a.shopping.add(name: "Milk", in: world.space)
        try await a.sync()
        let b = try world.restore(a, as: "B")
        let shared = await a.replica.replicaID
        #expect(await b.replica.replicaID == shared)

        a.time.advance(hours: 1)
        try await a.shopping.add(name: "Eggs", in: world.space)
        try await a.sync()
        try await b.sync()

        let renamed = await b.replica.replicaID
        #expect(renamed != shared)
        try await b.shopping.add(name: "Bread", in: world.space)
        try await world.settle([a, b])
        #expect(await a.replica.replicaID == shared)
        #expect(await b.replica.replicaID == renamed)
        let bread = try #require(await b.replica.records.records.values.first { $0.value("name") == .string("Bread") })
        #expect(bread.created.replica == renamed)
        try await expectConverged([a, b], in: world)
    }

    @Test("a replica that only sees its own writes echoed back keeps its replica ID")
    func ownEchoKeepsReplicaID() async throws {
        let world = World()
        let hostile = CloudLink.Faults(pageSize: 1, shuffleSeed: 3, duplicates: true, history: true)
        var a = try world.device("A", faults: hostile)
        let id = try await world.putAway("Milk", on: a)
        try await a.actions.apply(.opened, to: id)
        try await a.shopping.add(name: "Milk", in: world.space)
        let replica = await a.replica.replicaID
        try await a.sync()
        a.time.advance(hours: -5)
        a = try world.restart(a)
        try await a.shopping.add(name: "Eggs", in: world.space)
        try await a.sync()
        try await a.sync()

        #expect(await a.replica.replicaID == replica)
    }

    @Test("duplicated, shuffled, stale and split deliveries converge", arguments: [UInt64(1), 7, 42])
    func hostileDelivery(seed: UInt64) async throws {
        let world = World()
        let hostile = CloudLink.Faults(pageSize: 1, shuffleSeed: seed, duplicates: true, history: true)
        let a = try world.device("A")
        let b = try world.device("B", skewHours: 4, faults: hostile)
        let c = try world.device("C", skewHours: -4, faults: hostile)
        let id = try await world.putAway("Chicken", on: a)
        try await a.actions.apply(.move(to: world.freezer.id), to: id)
        try await a.sync()
        try await c.sync()
        try await c.actions.apply(.opened, to: id)
        let discard = try await c.actions.apply(.discard(reason: .spoiled), to: id)
        guard case .applied(let token) = discard else { Issue.record("discard not applied"); return }
        try await c.actions.undo(token)
        try await a.shopping.add(name: "Lemons", in: world.space)

        try await world.settle([a, b, c])

        let state = try await expectConverged([a, b, c], in: world)
        #expect(state.packages[id]?.status == .active)
        #expect(state.packages[id]?.location == world.freezer.id)
    }

    @Test("an edit made after seeing another device's edit wins even on a clock running hours behind")
    func causalOrderBeatsWallClock() async throws {
        let world = World()
        let a = try world.device("A", skewHours: 5)
        let b = try world.device("B", skewHours: -5)
        try await a.shopping.add(name: "Milk", in: world.space)
        try await world.settle([a, b])
        let milk = try #require(try await a.replica.list(in: world.space).items.first)

        try await world.rename(milk.id, to: "Whole milk", on: a)
        try await world.settle([a, b])
        try await world.rename(milk.id, to: "Oat milk", on: b)
        try await world.settle([a, b])

        let state = try await expectConverged([a, b], in: world)
        #expect(state.shopping.first?.name == "Oat milk")
    }

    @Test("a user correction survives recognition that finishes later on another device")
    func correctionSurvivesDelayedRecognition() async throws {
        let world = World()
        let a = try world.device("A", skewHours: 6)
        let b = try world.device("B", skewHours: -6)
        let id = try await world.putAway("Yoghrt", on: a, confirmedName: false)
        try await world.settle([a, b])

        var onB = try await b.package(id)
        try onB.record(.corrected(.name("Greek yogurt")), at: b.time.now())
        try await b.replica.save(onB)
        try await b.sync()

        a.time.advance(hours: 2)
        var onA = try await a.package(id)
        try onA.propose(PackageProposal(name: "Yogurt, plain"), at: a.time.now())
        try await a.replica.save(onA)
        #expect(try await a.package(id).name == "Yogurt, plain")

        try await world.settle([a, b])

        let state = try await expectConverged([a, b], in: world)
        #expect(state.packages[id]?.name == "Greek yogurt")
        #expect(state.packages[id]?.confirmed == [.name])
    }

    @Test("only approved, unflagged evidence crops reach the cloud")
    func evidenceEligibility() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B")
        let id = try await world.putAway("Milk", on: a)
        let approved = EvidenceCrop(packageID: id, region: .printedDate, asset: "date.heic", review: .approved)
        let pending = EvidenceCrop(packageID: id, region: .frontLabel, asset: "front.heic")
        let flagged = EvidenceCrop(
            packageID: id, region: .instructions, asset: "back.heic", review: .approved, sensitiveContentFlagged: true
        )

        #expect(try await a.replica.share(approved))
        #expect(try await !a.replica.share(pending))
        #expect(try await !a.replica.share(flagged))
        try await world.settle([a, b])

        #expect(await b.replica.evidence(for: id) == [approved])
        let kinds = await world.cloud.records(zone: world.space).records.keys.map(\.kind)
        #expect(kinds.filter { $0 == .evidenceCrop }.count == 1)
    }

    @Test("a package with a record from a newer version is withheld and reported, not misread")
    func newerVersionRecord() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B")
        let id = try await world.putAway("Milk", on: a)
        try await world.settle([a, b])

        let stamp = HybridTimestamp(physicalMillis: 1, counter: 0, replica: ReplicaID())
        let future = SyncRecord(
            id: RecordID(kind: .packageEvent, entity: UUID()),
            created: stamp,
            minimumReaderVersion: SyncFormat.version + 1,
            fields: [
                "package": FieldEntry(value: .uuid(id.rawValue), stamp: stamp),
                "change": FieldEntry(value: .map(["type": .string("composted")]), stamp: stamp),
            ]
        )
        _ = await world.cloud.push(
            [OutgoingRecord(record: future, knownTag: nil)], zone: world.space, failing: [], unconfirmed: 0
        )

        try await b.sync()

        #expect(await b.replica.unreadablePackages == [id])
        #expect(try await b.replica.activePackages(in: world.space).isEmpty)
        #expect(await b.replica.records[future.id] == future)
    }
}

extension World {
    /// Shopping items have no rename action yet; this edits the field the way one would.
    func rename(_ id: ShoppingItemID, to name: String, on device: Device) async throws {
        try await device.replica.update(in: space) { list in
            var items = list.items
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].name = name
            list = ShoppingList(items: items)
        }
    }
}
