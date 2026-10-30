import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

/// One run of a scenario: a fresh Space with a package and a shopping item every device has seen.
final class Run: @unchecked Sendable {
    let world = World()
    let devices: [Device]
    var package = PackageID()
    var milk = ShoppingItemID()
    /// Operations that took effect. One can be refused, for example opening a package another
    /// device already used up, and the invariants depend on which.
    var applied: Set<String> = []
    var discardToken: UndoToken?

    init(skews: [Double]) throws {
        let world = world
        devices = try skews.enumerated().map { index, skew in
            try world.device(["A", "B", "C"][index], skewHours: skew)
        }
    }

    func prepare(recognizedName: Bool = false) async throws {
        package = try await world.putAway("Yoghrt", on: devices[0], confirmedName: !recognizedName)
        try await devices[0].shopping.add(name: "Milk", in: world.space)
        milk = try #require(try await devices[0].replica.list(in: world.space).items.first).id
        try await world.settle(devices)
    }

    /// Runs `body` on device `index` a little later than its previous step, noting it as applied
    /// unless it was refused.
    func op(_ index: Int, _ label: String, _ body: (Device) async throws -> Bool) async {
        let device = devices[index]
        device.time.advance(hours: 0.25)
        if (try? await body(device)) == true { applied.insert(label) }
    }
}

typealias Step = @Sendable (Run) async -> Void

func sync(_ index: Int) -> Step {
    { run in await run.devices[index].trySync() }
}

/// Every order of the given per-device step counts, as sequences of device indices.
func interleavings(_ counts: [Int]) -> [[Int]] {
    guard counts.contains(where: { $0 > 0 }) else { return [[]] }
    return counts.indices.filter { counts[$0] > 0 }.flatMap { index -> [[Int]] in
        var rest = counts
        rest[index] -= 1
        return interleavings(rest).map { [index] + $0 }
    }
}

/// Runs every interleaving of `steps`, settles, and checks convergence plus `check`.
func everySchedule(
    skews: [Double],
    recognizedName: Bool = false,
    steps: [[Step]],
    check: (Run, ReplicaSnapshot) throws -> Void
) async throws -> Int {
    let schedules = interleavings(steps.map(\.count))
    for schedule in schedules {
        let run = try Run(skews: skews)
        try await run.prepare(recognizedName: recognizedName)
        var next = Array(repeating: 0, count: steps.count)
        for device in schedule {
            await steps[device][next[device]](run)
            next[device] += 1
        }
        try await run.world.settle(run.devices)
        let state = try await expectConverged(run.devices, in: run.world)
        try check(run, state)
    }
    return schedules.count
}

@Suite("Sync convergence")
struct SyncConvergenceTests {
    @Test("interleavings are enumerated completely")
    func enumeration() {
        #expect(interleavings([2, 1]) == [[0, 0, 1], [0, 1, 0], [1, 0, 0]])
        #expect(interleavings([2, 3, 4]).count == 1260)
    }

    @Test("an edit concurrent with Used up never brings the package back, and is kept for undo")
    func editVersusUsedUp() async throws {
        let count = try await everySchedule(
            skews: [3, -3],
            steps: [
                [
                    { run in await run.op(0, "move") { d in
                        try await d.actions.apply(.move(to: run.world.freezer.id), to: run.package) != .unchanged
                    } },
                    sync(0),
                    { run in await run.op(0, "usedSome") { d in
                        try await d.markCooked.reconcile([IngredientUse(packageID: run.package, outcome: .usedSome)])
                            .tokens.count == 1
                    } },
                    sync(0),
                ],
                [
                    sync(1),
                    { run in await run.op(1, "usedUp") { d in
                        try await d.actions.apply(.usedUp, to: run.package) != .unchanged
                    } },
                    sync(1),
                ],
            ]
        ) { run, state in
            let package = try #require(state.packages[run.package])
            #expect(run.applied.contains("usedUp"))
            guard case .usedUp = package.status else {
                Issue.record("expected used up, got \(package.status)")
                return
            }
            #expect(package.location == (run.applied.contains("move") ? run.world.freezer.id : run.world.fridge.id))
            #expect(package.quantity == (run.applied.contains("usedSome") ? .aboutHalf : .full))
            #expect(package.events.count == run.applied.count)
        }
        #expect(count == 35)
    }

    @Test("a Discard and its undo concurrent with Used up elsewhere leave the package used up")
    func discardUndoVersusUsedUp() async throws {
        let count = try await everySchedule(
            skews: [-2, 2],
            steps: [
                [
                    { run in await run.op(0, "discard") { d in
                        guard case .applied(let token) = try await d.actions.apply(.discard(reason: .spoiled), to: run.package)
                        else { return false }
                        run.discardToken = token
                        return true
                    } },
                    sync(0),
                    { run in await run.op(0, "undoDiscard") { d in
                        guard let token = run.discardToken else { return false }
                        try await d.actions.undo(token)
                        return true
                    } },
                    sync(0),
                ],
                [
                    sync(1),
                    { run in await run.op(1, "usedUp") { d in
                        try await d.actions.apply(.usedUp, to: run.package) != .unchanged
                    } },
                    sync(1),
                ],
            ]
        ) { run, state in
            let package = try #require(state.packages[run.package])
            #expect(run.applied.isSuperset(of: ["discard", "undoDiscard"]))
            if run.applied.contains("usedUp") {
                guard case .usedUp = package.status else {
                    Issue.record("expected used up, got \(package.status)")
                    return
                }
            } else {
                #expect(package.status == .active)
            }
            #expect(package.events.contains { $0.kind == .change(.discarded(reason: .spoiled)) })
        }
        #expect(count == 35)
    }

    @Test("two devices undoing the same Discard concurrently restore it once")
    func concurrentUndo() async throws {
        let count = try await everySchedule(
            skews: [1, -1],
            steps: [
                [
                    { run in await run.op(0, "discard") { d in
                        guard case .applied(let token) = try await d.actions.apply(.discard(reason: nil), to: run.package)
                        else { return false }
                        run.discardToken = token
                        return true
                    } },
                    sync(0),
                    { run in await run.op(0, "undoA") { d in
                        guard let token = run.discardToken else { return false }
                        try await d.actions.undo(token)
                        return true
                    } },
                    sync(0),
                ],
                [
                    sync(1),
                    { run in await run.op(1, "undoB") { d in
                        guard let token = run.discardToken else { return false }
                        try await d.actions.undo(token)
                        return true
                    } },
                    sync(1),
                ],
            ]
        ) { run, state in
            let package = try #require(state.packages[run.package])
            #expect(package.status == .active)
            #expect(run.applied.contains("undoA") || run.applied.contains("undoB"))
            let undos = package.events.filter { if case .undone = $0.kind { true } else { false } }
            #expect(undos.count == ["undoA", "undoB"].filter(run.applied.contains).count)
        }
        #expect(count == 35)
    }

    @Test("three devices: a correction beats recognition, and list edits merge field by field")
    func threeDevices() async throws {
        let count = try await everySchedule(
            // The recognizing device's clock runs ahead, so concurrent recognition carries the later
            // stamp and only correction precedence can keep the user's value.
            skews: [-4, 4, 0],
            recognizedName: true,
            steps: [
                [
                    { run in await run.op(0, "correct") { d in
                        var package = try await d.package(run.package)
                        try package.record(.corrected(.name("Greek yogurt")), at: d.time.now())
                        try await d.replica.save(package)
                        return true
                    } },
                    sync(0),
                ],
                [
                    { run in await run.op(1, "recognize") { d in
                        var package = try await d.package(run.package)
                        let recorded = try package.propose(PackageProposal(name: "Yogurt, plain"), at: d.time.now())
                        try await d.replica.save(package)
                        return !recorded.isEmpty
                    } },
                    { run in await run.op(1, "check") { d in
                        try await d.shopping.setChecked(run.milk, true, in: run.world.space)
                        return true
                    } },
                    sync(1),
                ],
                [
                    { run in await run.op(2, "open") { d in
                        try await d.actions.apply(.opened, to: run.package) != .unchanged
                    } },
                    sync(2),
                    { run in await run.op(2, "rename") { d in
                        try await run.world.rename(run.milk, to: "Oat milk", on: d)
                        return true
                    } },
                    sync(2),
                ],
            ]
        ) { run, state in
            let package = try #require(state.packages[run.package])
            #expect(package.name == "Greek yogurt")
            #expect(package.confirmed == [.name])
            #expect(package.openedAt != nil)
            #expect(state.shopping.map(\.name) == ["Oat milk"])
            #expect(state.shopping.first?.isChecked == true)
        }
        #expect(count == 1260)
    }

    @Test("the same operations reach the same final state in every sync order and delivery", arguments: 0..<40)
    func randomOrders(seed: UInt64) async throws {
        let reference = try await OfflineEdits.shared.finalRecords(seed: nil)
        let shuffled = try await OfflineEdits.shared.finalRecords(seed: seed)

        #expect(shuffled == reference, "\(differences(shuffled, reference))")
    }
}

/// Three devices that each made overlapping edits while offline, captured once so every seed
/// replays exactly the same operations, stamps and identifiers.
actor OfflineEdits {
    static let shared = OfflineEdits()

    struct Captured: Sendable {
        let world: World
        let states: [ReplicaState]
        let package: PackageID
    }

    /// A task rather than a value: parameterized cases call in concurrently, and the actor would
    /// otherwise start a second capture while the first is suspended.
    private var capturing: Task<Captured, any Error>?

    private func capture() async throws -> Captured {
        if capturing == nil { capturing = Task { try await Self.makeCapture() } }
        return try await capturing!.value
    }

    private static func makeCapture() async throws -> Captured {
        let run = try Run(skews: [2, -5, 0])
        try await run.prepare(recognizedName: true)
        for device in run.devices { device.link.faults.offline = true }
        let (a, b, c) = (run.devices[0], run.devices[1], run.devices[2])
        let space = run.world.space

        _ = try await a.actions.apply(.move(to: run.world.freezer.id), to: run.package)
        try await a.shopping.setChecked(run.milk, true, in: space)
        try await a.shopping.add(name: "Eggs", in: space)

        _ = try await b.actions.apply(.usedUp, to: run.package)
        try await run.world.rename(run.milk, to: "Oat milk", on: b)
        _ = try await b.shopping.remove([run.milk], in: space)

        var onC = try await c.package(run.package)
        try onC.record(.corrected(.name("Skyr")), at: c.time.now())
        try onC.propose(PackageProposal(name: "Yogurt"), at: c.time.now())
        try await c.replica.save(onC)
        _ = try await c.actions.apply(.opened, to: run.package)
        try await c.shopping.add(name: "Bread", in: space)

        var states: [ReplicaState] = []
        for device in run.devices { states.append(try #require(device.store.state)) }
        return Captured(world: run.world, states: states, package: run.package)
    }

    /// Replays the captured devices against an empty server. With a seed, devices sync in a random
    /// order through links that shuffle, duplicate, replay history, page small, and lose
    /// confirmations. The server holds nothing yet, so every device uploads everything it has.
    func finalRecords(seed: UInt64?) async throws -> RecordSet {
        let captured = try await capture()
        var rng = SeededGenerator(seed: seed ?? 0)
        let world = captured.world.withEmptyCloud()
        var devices: [Device] = []
        for (index, state) in captured.states.enumerated() {
            var fresh = state
            fresh.changeToken = nil
            fresh.serverTags = [:]
            fresh.outbox = Set(state.records.records.keys)
            var faults = CloudLink.Faults()
            if seed != nil {
                faults = CloudLink.Faults(
                    pageSize: Int.random(in: 1...3, using: &rng),
                    shuffleSeed: rng.next(),
                    duplicates: Bool.random(using: &rng),
                    history: Bool.random(using: &rng),
                    unconfirmedWrites: Int.random(in: 0...3, using: &rng)
                )
            }
            devices.append(try world.device(
                "\(index)", faults: faults, store: InMemoryReplicaStore(fresh)
            ))
        }

        if seed != nil {
            for _ in 0..<6 { await devices.randomElement(using: &rng)!.trySync() }
        }
        try await world.settle(devices.shuffled(using: &rng), rounds: 12)
        let state = try await expectConverged(devices, in: world)

        let package = try #require(state.packages[captured.package])
        #expect(package.name == "Skyr")
        guard case .usedUp = package.status else {
            Issue.record("expected used up, got \(package.status)")
            return state.records
        }
        #expect(package.location == world.freezer.id)
        #expect(Set(state.shopping.map(\.name)) == ["Bread", "Eggs"])
        return state.records
    }
}
