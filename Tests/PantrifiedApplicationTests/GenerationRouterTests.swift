import Foundation
import Testing
import PantrifiedApplication

private struct Prompt: Sendable, Equatable { let text: String }
private struct Recipe: Sendable, Equatable { let title: String }

private struct HardError: Error, Equatable {}

private final class FakeRuntime: GenerationRuntime, @unchecked Sendable {
    typealias Request = Prompt
    typealias Output = Recipe

    let kind: GenerationRuntimeKind
    private let availabilityResult: RuntimeAvailability
    private let outcome: Result<Recipe, Error>
    private let lock = NSLock()
    private var calls = 0

    init(_ kind: GenerationRuntimeKind, availability: RuntimeAvailability = .available, outcome: Result<Recipe, Error>) {
        self.kind = kind
        self.availabilityResult = availability
        self.outcome = outcome
    }

    var generateCalls: Int { lock.withLock { calls } }

    func availability() async -> RuntimeAvailability { availabilityResult }

    func generate(_ request: Prompt) async throws -> Recipe {
        lock.withLock { calls += 1 }
        return try outcome.get()
    }
}

private func router(_ runtimes: [FakeRuntime]) -> GenerationRouter<Prompt, Recipe> {
    GenerationRouter(runtimes: runtimes)
}

@Suite("Generation routing")
struct GenerationRouterTests {
    @Test("the preferred runtime is used when it is available")
    func preferred() async throws {
        let pcc = FakeRuntime(.privateCloudCompute, outcome: .success(Recipe(title: "Cloud")))
        let device = FakeRuntime(.onDevice, outcome: .success(Recipe(title: "Device")))
        let outcome = try await router([pcc, device]).generate(Prompt(text: "x"))

        #expect(outcome == .generated(Recipe(title: "Cloud"), on: .privateCloudCompute, skipped: []))
        #expect(device.generateCalls == 0)
    }

    @Test("an unavailable preferred runtime falls back and says why")
    func unavailableFallsBack() async throws {
        let pcc = FakeRuntime(
            .privateCloudCompute, availability: .unavailable(.osVersion),
            outcome: .success(Recipe(title: "Cloud"))
        )
        let device = FakeRuntime(.onDevice, outcome: .success(Recipe(title: "Device")))
        let outcome = try await router([pcc, device]).generate(Prompt(text: "x"))

        #expect(outcome == .generated(
            Recipe(title: "Device"), on: .onDevice,
            skipped: [SkippedRuntime(kind: .privateCloudCompute, reason: .osVersion)]
        ))
        #expect(pcc.generateCalls == 0)
    }

    @Test("a fallback-eligible failure during generation falls back")
    func midRequestFailure() async throws {
        let pcc = FakeRuntime(.privateCloudCompute, outcome: .failure(RuntimeFailure.unavailable(.networkUnavailable)))
        let device = FakeRuntime(.onDevice, outcome: .success(Recipe(title: "Device")))
        let outcome = try await router([pcc, device]).generate(Prompt(text: "x"))

        #expect(outcome == .generated(
            Recipe(title: "Device"), on: .onDevice,
            skipped: [SkippedRuntime(kind: .privateCloudCompute, reason: .networkUnavailable)]
        ))
    }

    @Test("a hard error is surfaced, never hidden by a fallback")
    func hardError() async {
        let pcc = FakeRuntime(.privateCloudCompute, outcome: .failure(HardError()))
        let device = FakeRuntime(.onDevice, outcome: .success(Recipe(title: "Device")))

        await #expect(throws: HardError.self) {
            try await router([pcc, device]).generate(Prompt(text: "x"))
        }
        #expect(device.generateCalls == 0)
    }

    @Test("when nothing is available the outcome lists every reason")
    func noneAvailable() async throws {
        let pcc = FakeRuntime(.privateCloudCompute, availability: .unavailable(.dailyLimitReached), outcome: .failure(HardError()))
        let device = FakeRuntime(.onDevice, availability: .unavailable(.appleIntelligenceDisabled), outcome: .failure(HardError()))
        let outcome = try await router([pcc, device]).generate(Prompt(text: "x"))

        #expect(outcome == .unavailable([
            SkippedRuntime(kind: .privateCloudCompute, reason: .dailyLimitReached),
            SkippedRuntime(kind: .onDevice, reason: .appleIntelligenceDisabled),
        ]))
    }

    @Test("with no runtimes configured generation is unavailable")
    func noRuntimes() async throws {
        let outcome = try await router([]).generate(Prompt(text: "x"))

        #expect(outcome == .unavailable([]))
    }

    @Test("if every runtime fails in a fallback-eligible way the outcome is unavailable")
    func allFailEligibly() async throws {
        let pcc = FakeRuntime(.privateCloudCompute, outcome: .failure(RuntimeFailure.unavailable(.dailyLimitReached)))
        let device = FakeRuntime(.onDevice, outcome: .failure(RuntimeFailure.unavailable(.modelNotReady)))
        let outcome = try await router([pcc, device]).generate(Prompt(text: "x"))

        #expect(outcome == .unavailable([
            SkippedRuntime(kind: .privateCloudCompute, reason: .dailyLimitReached),
            SkippedRuntime(kind: .onDevice, reason: .modelNotReady),
        ]))
    }
}
