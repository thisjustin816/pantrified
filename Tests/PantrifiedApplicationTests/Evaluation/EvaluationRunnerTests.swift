import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private struct ScriptFailure: Error, Equatable {}

private final class ScriptedRuntime: GenerationRuntime, @unchecked Sendable {
    typealias Request = MakeSomethingRequest
    typealias Output = GeneratedRecipe

    let kind: GenerationRuntimeKind = .onDevice
    private let state: RuntimeAvailability
    private let script: @Sendable (Int) throws -> GeneratedRecipe
    private let lock = NSLock()
    private var calls = 0

    init(
        availability: RuntimeAvailability = .available,
        script: @escaping @Sendable (Int) throws -> GeneratedRecipe
    ) {
        self.state = availability
        self.script = script
    }

    func availability() async -> RuntimeAvailability { state }

    func generate(_ request: MakeSomethingRequest) async throws -> GeneratedRecipe {
        let index = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        return try script(index)
    }
}

private func makeRunner(_ runtime: ScriptedRuntime) -> EvaluationRunner {
    EvaluationRunner(makeSomething: MakeSomething(router: GenerationRouter(runtimes: [runtime])))
}

private func request(restrictions: Set<DietaryRestriction> = []) -> MakeSomethingRequest {
    let context = try! MakeSomethingContext(
        ingredients: [MealContextIngredient(name: "rice", useSoon: false, quantity: .unknown)],
        diners: [ConsumerProfile(name: "Ana", restrictions: .known(restrictions))]
    )
    return .newRecipe(context)
}

private func testCase(_ id: String, restrictions: Set<DietaryRestriction> = []) -> EvaluationCase {
    EvaluationCase(id: id, summary: id, request: request(restrictions: restrictions))
}

private let simple = GeneratedRecipe(title: "Rice", ingredientLines: ["1 cup rice"], instructions: ["Serve."])

@Suite("Evaluation runner")
struct EvaluationRunnerTests {
    @Test("every case runs once per trial")
    func recordCount() async {
        let runner = makeRunner(ScriptedRuntime { _ in simple })
        let records = await runner.run([testCase("a"), testCase("b")], trials: 3)

        #expect(records.count == 6)
        #expect(records.map(\.id) == ["a#1", "a#2", "a#3", "b#1", "b#2", "b#3"])
    }

    @Test("a presented recipe records its runtime, text and duration")
    func ready() async throws {
        let runner = makeRunner(ScriptedRuntime { _ in simple })
        let record = try #require(await runner.run([testCase("a")], trials: 1).first)

        #expect(record.outcome == .ready)
        #expect(record.runtime == "onDevice")
        #expect(record.recipe?.title == "Rice")
        #expect(record.reasonKinds.isEmpty)
        #expect(record.seconds >= 0)
    }

    @Test("a withheld recipe keeps its text, the reason kinds and the unrecognized words")
    func withheld() async throws {
        let odd = GeneratedRecipe(title: "Rice", ingredientLines: ["1 cup rice"], instructions: ["Serve the flibbertigibbet."])
        let runner = makeRunner(ScriptedRuntime { _ in odd })
        let record = try #require(await runner.run([testCase("a", restrictions: [.allergen(.peanut)])], trials: 1).first)

        #expect(record.outcome == .withheld)
        #expect(record.reasonKinds.contains("unrecognizedWord"))
        #expect(record.unrecognizedWords.contains("flibbertigibbet"))
        #expect(record.recipe?.instructions == ["Serve the flibbertigibbet."])
    }

    @Test("an unavailable runtime is recorded with why")
    func unavailable() async throws {
        let runner = makeRunner(ScriptedRuntime(availability: .unavailable(.modelNotReady)) { _ in simple })
        let record = try #require(await runner.run([testCase("a")], trials: 1).first)

        #expect(record.outcome == .unavailable)
        #expect(record.notes == ["onDevice: modelNotReady"])
        #expect(record.recipe == nil)
    }

    @Test("a hard error is recorded and the run continues")
    func failureContinues() async {
        let runner = makeRunner(ScriptedRuntime { call in
            if call == 1 { throw ScriptFailure() }
            return simple
        })
        let records = await runner.run([testCase("a")], trials: 2)

        #expect(records.map(\.outcome) == [.failed, .ready])
        #expect(records.first?.notes.first?.contains("ScriptFailure") == true)
    }

    @Test("progress is reported after every run")
    func progress() async {
        let counter = Counter()
        let runner = makeRunner(ScriptedRuntime { _ in simple })
        _ = await runner.run([testCase("a"), testCase("b")], trials: 2, progress: { done, total in
            counter.add((done, total))
        })

        #expect(counter.values.map(\.0) == [1, 2, 3, 4])
        #expect(counter.values.allSatisfy { $0.1 == 4 })
    }

    @Test("cancelling stops the run and keeps what finished")
    func cancellation() async {
        let runner = makeRunner(ScriptedRuntime { _ in simple })
        let records = await runner.run([testCase("a"), testCase("b")], trials: 2, progress: { done, _ in
            if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        })

        #expect(records.count == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []

    func add(_ value: (Int, Int)) { lock.withLock { storage.append(value) } }
    var values: [(Int, Int)] { lock.withLock { storage } }
}
