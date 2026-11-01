import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
import PantrifiedTestSupport

private let source = "USDA FSIS FoodKeeper"

private func window(_ days: Int, _ anchor: WindowAnchor = .added) -> GuidanceWindow {
    GuidanceWindow(storageType: .refrigerated, anchor: anchor, days: days)
}

private let plainMilk = GuidanceRecord(
    id: 27, name: "Milk", qualifier: "plain or flavored", category: "Dairy Products & Eggs", keywords: [], windows: [window(7)]
)
private let lactoseFree = GuidanceRecord(
    id: 543, name: "Milk", qualifier: "lactose-free", category: "Dairy Products & Eggs", keywords: [], windows: [window(30)]
)
private let soyMilk = GuidanceRecord(
    id: 421, name: "Soy milk", qualifier: nil, category: "Dairy Products & Eggs", keywords: [], windows: [window(7, .opened)]
)
private let mayonnaise = GuidanceRecord(
    id: 350, name: "Mayonnaise", qualifier: "commercial", category: nil, keywords: [], windows: [window(60, .opened)]
)
private let salt = GuidanceRecord(id: 500, name: "Salt", qualifier: nil, category: nil, keywords: [], windows: [])

private func dataset(_ records: [GuidanceRecord] = [plainMilk, lactoseFree, soyMilk, mayonnaise, salt]) throws -> GuidanceDataset {
    try GuidanceDataset(
        provenance: GuidanceDataset.Provenance(source: source, sourceVersion: "test", sourceChecksum: nil, normalizationVersion: "1"),
        records: records
    )
}

private func repository(_ records: [GuidanceRecord]? = nil) throws -> BundledStorageGuidance {
    BundledStorageGuidance(dataset: try records.map(dataset) ?? dataset())
}

private func choose(_ record: GuidanceRecord) -> GuidanceChoice {
    .record(GuidanceRecordReference(record, source: source))
}

private func package(_ name: String, choice: GuidanceChoice?? = nil) throws -> Package {
    var package = Package(spaceID: SpaceID(), name: name, location: LocationID(), addedAt: syncEpoch)
    if case .some(let choice) = choice {
        try package.record(.corrected(.guidanceRecord(choice)), at: syncEpoch)
    }
    return package
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

@Suite("The question of which guidance record a food is")
struct GuidanceRecordQuestionTests {
    @Test("a choice is needed when several records or only close ones fit; none is raised when nothing fits")
    func asks() {
        #expect(GuidanceRecordQuestion(status: .unanswered, candidates: [plainMilk], source: source).prompt == .ask)
        #expect(GuidanceRecordQuestion(status: .unanswered, candidates: [], source: source).prompt == .hidden)
        let missing = GuidanceRecordReference(plainMilk, source: source)
        #expect(GuidanceRecordQuestion(status: .chosenRecordMissing(missing), candidates: [], source: source).prompt == .ask)
    }

    @Test("a food with a record, or one the person declined, shows what it uses and can be changed")
    func reviews() {
        #expect(GuidanceRecordQuestion(status: .matched(mayonnaise), candidates: [], source: source).prompt == .review)
        #expect(GuidanceRecordQuestion(status: .chosen(plainMilk), candidates: [], source: source).prompt == .review)
        #expect(GuidanceRecordQuestion(status: .declined, candidates: [], source: source).prompt == .review)
    }

    @Test("the record in use is always offered, first when the suggestions leave it out")
    func currentOffered() {
        let chosen = GuidanceRecordQuestion(status: .chosen(soyMilk), candidates: [plainMilk, lactoseFree], source: source)
        #expect(chosen.candidates == [soyMilk, plainMilk, lactoseFree])
        #expect(chosen.isCurrent(soyMilk))
        #expect(!chosen.isCurrent(plainMilk))

        let matched = GuidanceRecordQuestion(status: .matched(lactoseFree), candidates: [plainMilk, lactoseFree], source: source)
        #expect(matched.candidates == [plainMilk, lactoseFree])
        #expect(matched.isCurrent(lactoseFree))

        let open = GuidanceRecordQuestion(status: .unanswered, candidates: [plainMilk, lactoseFree], source: source)
        #expect(open.candidates == [plainMilk, lactoseFree])
        #expect(!open.isCurrent(plainMilk))
    }

    @Test("picking a record records it with its source, name and qualifier")
    func choiceForRecord() {
        let question = GuidanceRecordQuestion(status: .unanswered, candidates: [lactoseFree], source: source)

        #expect(question.choice(for: lactoseFree) == .record(
            GuidanceRecordReference(source: source, id: 543, name: "Milk", qualifier: "lactose-free")
        ))
    }

    @Test("only a choice the person made can be cleared, and only a decline reads as declined")
    func clearing() {
        let missing = GuidanceRecordReference(plainMilk, source: source)
        let cases: [(GuidanceRecordQuestion.Status, canClear: Bool, declined: Bool)] = [
            (.matched(mayonnaise), false, false),
            (.unanswered, false, false),
            (.chosen(plainMilk), true, false),
            (.declined, true, true),
            (.chosenRecordMissing(missing), true, false),
        ]
        for (status, canClear, declined) in cases {
            let question = GuidanceRecordQuestion(status: status, candidates: [plainMilk], source: source)
            #expect(question.canClear == canClear, "\(status)")
            #expect(question.isDeclined == declined, "\(status)")
        }
    }
}

@Suite("Storage guidance follows the person's choice")
struct ChosenGuidanceTests {
    @Test("an ambiguous name gets the chosen record's windows")
    func chosenRecordGivesGuidance() async throws {
        let guidance = try repository()

        #expect(try await guidance.guidance(for: package("Milk")) == nil)
        let chosen = try #require(try await guidance.guidance(for: package("Milk", choice: choose(lactoseFree))))
        #expect(chosen.windows == lactoseFree.windows)
        #expect(chosen.provenance.source == source)
    }

    @Test("a choice overrides a name that matches one record, and None of these removes its guidance")
    func choiceOverridesName() async throws {
        let guidance = try repository()

        #expect(try await guidance.guidance(for: package("Mayonnaise"))?.windows == mayonnaise.windows)
        #expect(try await guidance.guidance(for: package("Mayonnaise", choice: choose(soyMilk)))?.windows == soyMilk.windows)
        #expect(try await guidance.guidance(for: package("Mayonnaise", choice: .noneOfThese)) == nil)
    }

    @Test("clearing the choice matches by name again")
    func clearedChoice() async throws {
        var mayo = try package("Mayonnaise", choice: .noneOfThese)
        try mayo.record(.corrected(.guidanceRecord(nil)), at: syncEpoch)

        #expect(try await repository().guidance(for: mayo)?.windows == mayonnaise.windows)
    }

    @Test("a renamed food keeps the record the person chose")
    func renameKeepsGuidance() async throws {
        var milk = try package("Milk", choice: choose(lactoseFree))
        try milk.record(.corrected(.name("Mayonnaise")), at: syncEpoch)

        #expect(try await repository().guidance(for: milk)?.windows == lactoseFree.windows)
    }

    @Test(
        "a chosen record a newer snapshot dropped or gave to another food gives no guidance and asks again",
        arguments: [
            [mayonnaise, plainMilk],
            [mayonnaise, plainMilk, GuidanceRecord(id: 543, name: "Milk", qualifier: "goat", category: nil, keywords: [], windows: [window(3)])],
            [mayonnaise, plainMilk, GuidanceRecord(id: 543, name: "Buttermilk", qualifier: "lactose-free", category: nil, keywords: [], windows: [window(3)])],
        ]
    )
    func missingRecord(records: [GuidanceRecord]) async throws {
        let guidance = try repository(records)
        let milk = try package("Milk", choice: choose(lactoseFree))

        #expect(try await guidance.guidance(for: milk) == nil)
        let question = try #require(try await guidance.recordQuestion(for: milk))
        #expect(question.status == .chosenRecordMissing(GuidanceRecordReference(lactoseFree, source: source)))
        #expect(question.prompt == .ask)
        #expect(question.canClear)
    }

    @Test("a snapshot from another source does not take a choice made against the first")
    func otherSource() async throws {
        let other = BundledStorageGuidance(dataset: try GuidanceDataset(
            provenance: GuidanceDataset.Provenance(source: "Another source", sourceVersion: nil, sourceChecksum: nil, normalizationVersion: "1"),
            records: [plainMilk, lactoseFree]
        ))

        #expect(try await other.guidance(for: package("Milk", choice: choose(lactoseFree))) == nil)
    }

    @Test("the question reports what the food uses now and offers the candidates for its name")
    func questions() async throws {
        let guidance = try repository()

        let ambiguous = try #require(try await guidance.recordQuestion(for: package("Milk")))
        #expect(ambiguous.status == .unanswered)
        #expect(ambiguous.candidates == [plainMilk, lactoseFree, soyMilk])
        #expect(ambiguous.prompt == .ask)

        let close = try #require(try await guidance.recordQuestion(for: package("Oat milk")))
        #expect(close.status == .unanswered)
        #expect(close.prompt == .ask)

        let matched = try #require(try await guidance.recordQuestion(for: package("Mayonnaise")))
        #expect(matched.status == .matched(mayonnaise))
        #expect(matched.prompt == .review)

        let chosen = try #require(try await guidance.recordQuestion(for: package("Milk", choice: choose(lactoseFree))))
        #expect(chosen.status == .chosen(lactoseFree))
        #expect(chosen.isCurrent(lactoseFree))

        let declined = try #require(try await guidance.recordQuestion(for: package("Mayonnaise", choice: .noneOfThese)))
        #expect(declined.status == .declined)

        let unknown = try #require(try await guidance.recordQuestion(for: package("Saffron")))
        #expect(unknown.prompt == .hidden)
    }

    @Test("a record chosen for a name that would never suggest it is still offered as the current one")
    func chosenOutsideSuggestions() async throws {
        let question = try #require(try await repository().recordQuestion(for: package("Saffron", choice: choose(salt))))

        #expect(question.status == .chosen(salt))
        #expect(question.candidates == [salt])
    }

    @Test("a chosen record changes what the use-soon list reports")
    func useSoonFollowsChoice() async throws {
        let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)
        let space = SpaceID()
        let undecided = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: syncEpoch)
        var decided = Package(spaceID: space, name: "Milk", location: fridge.id, addedAt: syncEpoch)
        try decided.record(.corrected(.guidanceRecord(choose(plainMilk))), at: syncEpoch)
        let useSoon = UseSoon(
            inventory: InMemoryInventory([undecided, decided]),
            locations: InMemoryLocations(locationsBySpace: [space: [fridge]]),
            guidance: try repository(),
            time: FixedTime(syncEpoch.addingTimeInterval(10 * 86_400)),
            policy: AttentionPolicy(calendar: utc)
        )

        let items = try await useSoon.items(in: space)

        #expect(items.map(\.package.id) == [decided.id])
        #expect(items.first?.assessment.state == .pastGuidance)
    }
}

@Suite("Choosing a guidance record")
struct ChoosingGuidanceRecordTests {
    private func setup(_ store: InventoryStore) async throws -> (editor: PackageEditor, inventory: any InventoryRepository, id: PackageID) {
        let world = World()
        let milk = Package(spaceID: world.space, name: "Milk", location: world.fridge.id, addedAt: syncEpoch)
        let inventory = try await store.make(world, holding: [milk])
        return (PackageEditor(inventory: inventory, time: FixedTime(syncEpoch)), inventory, milk.id)
    }

    @Test("a choice is one correction with one undo token, and undo takes it back", arguments: InventoryStore.allCases)
    func chooseAndUndo(store: InventoryStore) async throws {
        let s = try await setup(store)

        let outcome = try await s.editor.apply(PackageEdit(guidanceRecord: .set(choose(lactoseFree))), to: s.id)

        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }
        #expect(tokens.count == 1)
        let chosen = try #require(try await s.inventory.package(s.id))
        #expect(chosen.guidanceChoice == choose(lactoseFree))
        #expect(chosen.confirmedFields == [.guidanceRecord])

        try await s.editor.undo(tokens)

        #expect(try await s.inventory.package(s.id)?.guidanceChoice == nil)
    }

    @Test("choosing what the food already has writes nothing", arguments: InventoryStore.allCases)
    func unchanged(store: InventoryStore) async throws {
        let s = try await setup(store)
        #expect(try await s.editor.apply(PackageEdit(guidanceRecord: .set(nil)), to: s.id) == .unchanged)

        _ = try await s.editor.apply(PackageEdit(guidanceRecord: .set(.noneOfThese)), to: s.id)
        let events = try #require(try await s.inventory.package(s.id)).events.count

        #expect(try await s.editor.apply(PackageEdit(guidanceRecord: .set(.noneOfThese)), to: s.id) == .unchanged)
        #expect(try await s.inventory.package(s.id)?.events.count == events)
    }

    @Test("a choice can be changed and cleared, each undone on its own", arguments: InventoryStore.allCases)
    func changeAndClear(store: InventoryStore) async throws {
        let s = try await setup(store)
        _ = try await s.editor.apply(PackageEdit(guidanceRecord: .set(choose(plainMilk))), to: s.id)
        _ = try await s.editor.apply(PackageEdit(guidanceRecord: .set(choose(lactoseFree))), to: s.id)

        guard case .applied(let clear) = try await s.editor.apply(PackageEdit(guidanceRecord: .set(nil)), to: s.id) else {
            Issue.record("not applied")
            return
        }
        #expect(try await s.inventory.package(s.id)?.guidanceChoice == nil)

        try await s.editor.undo(clear)
        #expect(try await s.inventory.package(s.id)?.guidanceChoice == choose(lactoseFree))
    }

    @Test("a food that is used up refuses a choice", arguments: InventoryStore.allCases)
    func inactiveRefused(store: InventoryStore) async throws {
        let s = try await setup(store)
        var package = try #require(try await s.inventory.package(s.id))
        try package.record(.usedUp, at: syncEpoch)
        try await s.inventory.save(package)

        await #expect(throws: PackageError.notActive) {
            try await s.editor.apply(PackageEdit(guidanceRecord: .set(.noneOfThese)), to: s.id)
        }
    }
}

@Suite("A guidance choice in the pantry")
struct PantryGuidanceChoiceTests {
    private func pantry(_ local: LocalStore, _ world: World) throws -> Pantry {
        let replica = try local.replica(for: world.space, transport: CloudLink(world.cloud), time: FixedTime(syncEpoch))
        return Pantry(
            space: world.space, inventory: replica, locations: local.locations, evidence: local.productEvidence,
            guidance: try repository(), time: FixedTime(syncEpoch),
            policy: AttentionPolicy(calendar: utc)
        )
    }

    @Test("the snapshot asks about an ambiguous food, then shows the chosen record's guidance until undo", arguments: TestStorage.allCases)
    func snapshotFollowsChoice(storage: TestStorage) async throws {
        let world = World()
        let pantry = try pantry(LocalStore(backend: try storage.makeBackend()), world)
        try await pantry.prepare()
        let fridge = try #require(try await pantry.snapshot().locations.first)
        let id = try await pantry.add(NewFood(name: "Milk", location: fridge.id))

        let before = try #require(try await pantry.snapshot().entries.first)
        #expect(before.guidance == nil)
        #expect(before.assessment.state == .unknown)
        let question = try #require(before.recordQuestion)
        #expect(question.prompt == .ask)

        let outcome = try await pantry.edit(PackageEdit(guidanceRecord: .set(question.choice(for: plainMilk))), on: id)

        let after = try #require(try await pantry.snapshot().entries.first)
        #expect(after.guidance?.windows == plainMilk.windows)
        #expect(after.assessment.state == .fine)
        #expect(after.recordQuestion?.status == .chosen(plainMilk))

        guard case .applied(let tokens) = outcome else { Issue.record("not applied"); return }
        try await pantry.undo(tokens)

        let undone = try #require(try await pantry.snapshot().entries.first)
        #expect(undone.guidance == nil)
        #expect(undone.assessment.state == .unknown)
        #expect(undone.recordQuestion?.status == .unanswered)
    }

    @Test("a choice is there after the app is opened again", arguments: TestStorage.allCases)
    func survivesRelaunch(storage: TestStorage) async throws {
        let backend = try storage.makeBackend()
        let world = World()
        let first = try pantry(LocalStore(backend: backend), world)
        try await first.prepare()
        let fridge = try #require(try await first.snapshot().locations.first)
        let id = try await first.add(NewFood(name: "Milk", location: fridge.id))
        _ = try await first.edit(PackageEdit(guidanceRecord: .set(choose(lactoseFree))), on: id)

        let second = try pantry(LocalStore(backend: backend), world)
        let entry = try #require(try await second.snapshot().entries.first)

        #expect(entry.package.guidanceChoice == choose(lactoseFree))
        #expect(entry.guidance?.windows == lactoseFree.windows)
        #expect(entry.recordQuestion?.status == .chosen(lactoseFree))
    }

    @Test("an entry carries no question when the guidance has no records to choose from")
    func noRecords() async throws {
        let world = World()
        let local = LocalStore(backend: InMemoryStorageBackend())
        let replica = try local.replica(for: world.space, transport: CloudLink(world.cloud), time: FixedTime(syncEpoch))
        let pantry = Pantry(
            space: world.space, inventory: replica, locations: local.locations, evidence: local.productEvidence,
            guidance: FakeGuidance(result: nil), time: FixedTime(syncEpoch)
        )
        try await pantry.prepare()
        let fridge = try #require(try await pantry.snapshot().locations.first)
        try await pantry.add(NewFood(name: "Milk", location: fridge.id))

        #expect(try await pantry.snapshot().entries.first?.recordQuestion == nil)
    }
}

@Suite("A guidance choice across devices")
struct GuidanceChoiceSyncTests {
    @Test("a choice made on one device and a rename made on another both reach every device")
    func choiceAndRenameConverge() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: -2)
        let id = try await world.putAway("Milk", on: a)
        try await world.settle([a, b])

        _ = try await PackageEditor(inventory: a.replica, time: a.time)
            .apply(PackageEdit(guidanceRecord: .set(choose(lactoseFree))), to: id)
        _ = try await PackageEditor(inventory: b.replica, time: b.time)
            .apply(PackageEdit(name: .set("Lactose-free milk")), to: id)
        try await world.settle([a, b])

        for device in [a, b] {
            let package = try await device.package(id)
            #expect(package.name == "Lactose-free milk")
            #expect(package.guidanceChoice == choose(lactoseFree))
        }
        try await expectConverged([a, b], in: world)
    }

    @Test("two devices choosing at once settle on the same record")
    func concurrentChoicesConverge() async throws {
        let world = World()
        let a = try world.device("A")
        let b = try world.device("B", skewHours: 3)
        let id = try await world.putAway("Milk", on: a)
        try await world.settle([a, b])

        _ = try await PackageEditor(inventory: a.replica, time: a.time)
            .apply(PackageEdit(guidanceRecord: .set(choose(plainMilk))), to: id)
        _ = try await PackageEditor(inventory: b.replica, time: b.time)
            .apply(PackageEdit(guidanceRecord: .set(.noneOfThese)), to: id)
        try await world.settle([a, b])

        let onA = try await a.package(id).guidanceChoice
        #expect(onA != nil)
        #expect(try await b.package(id).guidanceChoice == onA)
    }
}
