import Foundation
import PantrifiedDomain

public struct EvaluationCase: Sendable, Hashable, Identifiable {
    public let id: String
    public let summary: String
    public let request: MakeSomethingRequest

    public init(id: String, summary: String, request: MakeSomethingRequest) {
        self.id = id
        self.summary = summary
        self.request = request
    }
}

public struct RecipeText: Sendable, Hashable, Codable {
    public let title: String
    public let ingredientLines: [String]
    public let instructions: [String]

    public init(_ recipe: GeneratedRecipe) {
        title = recipe.title
        ingredientLines = recipe.ingredientLines
        instructions = recipe.instructions
    }
}

/// One run of one case. Everything a person needs to judge it is kept, because the point of a run
/// is to learn what a model did, including when it failed or was withheld.
public struct EvaluationRecord: Sendable, Hashable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Codable {
        case ready, withheld, unavailable, failed
    }

    public let caseID: String
    public let trial: Int
    public let outcome: Outcome
    /// The runtime that produced the recipe; nil when none did.
    public let runtime: String?
    /// The kinds of review reason, and "violation" when a food broke a restriction.
    public let reasonKinds: [String]
    public let unrecognizedWords: [String]
    public let unknownIngredients: [String]
    /// Full reasons, a skipped runtime's cause, or a failure's description.
    public let notes: [String]
    public let seconds: Double
    public let recipe: RecipeText?

    public var id: String { "\(caseID)#\(trial)" }

    public init(
        caseID: String, trial: Int, outcome: Outcome, runtime: String?, reasonKinds: [String],
        unrecognizedWords: [String], unknownIngredients: [String], notes: [String], seconds: Double,
        recipe: RecipeText?
    ) {
        self.caseID = caseID
        self.trial = trial
        self.outcome = outcome
        self.runtime = runtime
        self.reasonKinds = reasonKinds
        self.unrecognizedWords = unrecognizedWords
        self.unknownIngredients = unknownIngredients
        self.notes = notes
        self.seconds = seconds
        self.recipe = recipe
    }
}

/// Runs evaluation cases through Make Something and records every outcome. A hard error from a
/// runtime is a result to record, not a reason to stop.
public struct EvaluationRunner: Sendable {
    private let makeSomething: MakeSomething

    public init(makeSomething: MakeSomething) {
        self.makeSomething = makeSomething
    }

    /// Returns the records of every run that finished. Cancelling the task ends the run early.
    public func run(
        _ cases: [EvaluationCase],
        trials: Int,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) async -> [EvaluationRecord] {
        let total = cases.count * max(trials, 0)
        var records: [EvaluationRecord] = []
        for evaluationCase in cases {
            for trial in stride(from: 1, through: trials, by: 1) {
                if Task.isCancelled { return records }
                guard let record = await runOnce(evaluationCase, trial: trial) else { return records }
                records.append(record)
                progress?(records.count, total)
            }
        }
        return records
    }

    /// Nil when the task was cancelled during the run.
    private func runOnce(_ evaluationCase: EvaluationCase, trial: Int) async -> EvaluationRecord? {
        let clock = ContinuousClock()
        let start = clock.now
        func seconds() -> Double {
            let elapsed = start.duration(to: clock.now)
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }
        func record(
            _ outcome: EvaluationRecord.Outcome, runtime: GenerationRuntimeKind? = nil,
            details: Details = Details(), recipe: GeneratedRecipe? = nil
        ) -> EvaluationRecord {
            EvaluationRecord(
                caseID: evaluationCase.id, trial: trial, outcome: outcome,
                runtime: runtime.map { String(describing: $0) }, reasonKinds: details.kinds,
                unrecognizedWords: details.unrecognizedWords, unknownIngredients: details.unknownIngredients,
                notes: details.notes, seconds: seconds(), recipe: recipe.map(RecipeText.init)
            )
        }

        do {
            let evaluation = try await makeSomething.evaluate(evaluationCase.request)
            switch evaluation.outcome {
            case .ready(_, let assessment, let runtime):
                return record(.ready, runtime: runtime, details: Details(assessment.verdict), recipe: evaluation.generated)
            case .withheld(let assessment, let runtime):
                return record(.withheld, runtime: runtime, details: Details(assessment.verdict), recipe: evaluation.generated)
            case .unavailable(let skipped):
                var details = Details()
                details.notes = skipped.map { "\($0.kind): \($0.reason)" }
                return record(.unavailable, details: details)
            }
        } catch is CancellationError {
            return nil
        } catch {
            var details = Details()
            details.notes = [String(describing: error)]
            return record(.failed, details: details)
        }
    }

    private struct Details {
        var kinds: [String] = []
        var unrecognizedWords: [String] = []
        var unknownIngredients: [String] = []
        var notes: [String] = []

        init() {}

        init(_ verdict: DietaryVerdict) {
            switch verdict {
            case .noRestrictions, .safe:
                break
            case .needsReview(let reasons):
                add(reasons)
            case .violation(let violations, let alsoNeedsReview):
                kinds.append("violation")
                notes.append(contentsOf: violations.map { "violation: \($0)" })
                add(alsoNeedsReview)
            }
        }

        private mutating func add(_ reasons: [ReviewReason]) {
            for reason in reasons {
                kinds.append(String(describing: reason.kind))
                notes.append(String(describing: reason))
                switch reason {
                case .unrecognizedWord(let word): unrecognizedWords.append(word)
                case .unknownIngredient(_, let ingredient): unknownIngredients.append(ingredient.text)
                default: break
                }
            }
        }
    }
}
