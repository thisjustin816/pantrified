#if DEBUG || EVALUATION
import Foundation
import Observation
import PantrifiedApplication
import PantrifiedDomain
#if canImport(FoundationModels)
import PantrifiedFoundationModels
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Runs the evaluation corpus through the on-device model and holds the result for the screen.
@MainActor
@Observable
final class EvaluationModel {
    enum State {
        case idle
        case running(done: Int, total: Int)
        case finished(EvaluationReport)
    }

    private(set) var state: State = .idle
    private(set) var availability = "Checking"
    var trials = 3
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    func refreshAvailability() async {
        let runtimes = Self.runtimes()
        guard let first = runtimes.first else {
            availability = "Not supported on this OS"
            return
        }
        switch await first.availability() {
        case .available: availability = "Available"
        case .unavailable(let reason): availability = "Unavailable: \(reason)"
        }
    }

    func start() {
        guard !isRunning else { return }
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    private func run() async {
        let runtimes = Self.runtimes()
        let runner = EvaluationRunner(
            makeSomething: MakeSomething(router: GenerationRouter(runtimes: runtimes))
        )
        let cases = EvaluationCorpus.cases
        let trials = trials
        let started = Date()
        state = .running(done: 0, total: cases.count * trials)

        let records = await runner.run(cases, trials: trials) { [weak self] done, total in
            Task { @MainActor in self?.state = .running(done: done, total: total) }
        }

        state = .finished(EvaluationReport(
            environment: EvaluationReport.Environment(
                device: Self.deviceIdentifier,
                systemVersion: Self.systemVersion,
                runtimes: runtimes.map { String(describing: $0.kind) }
            ),
            startedAt: started,
            finishedAt: Date(),
            trialsPerCase: trials,
            records: records
        ))
    }

    private static func runtimes() -> [any GenerationRuntime<MakeSomethingRequest, GeneratedRecipe>] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return [OnDeviceRecipeRuntime()]
        }
        #endif
        return []
    }

    private static var deviceIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static var systemVersion: String {
        #if canImport(UIKit)
        UIDevice.current.systemVersion
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
#endif
