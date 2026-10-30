import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

@Suite("Evaluation corpus")
struct EvaluationCorpusTests {
    @Test("every case builds, so none is silently dropped")
    func noneDropped() {
        #expect(EvaluationCorpus.cases.count == EvaluationCorpus.expectedCount)
    }

    @Test("case ids are unique and summaries are filled in")
    func uniqueIDs() {
        let ids = EvaluationCorpus.cases.map(\.id)

        #expect(Set(ids).count == ids.count)
        #expect(EvaluationCorpus.cases.allSatisfy { !$0.summary.isEmpty })
    }

    @Test("the corpus covers new recipes, adaptations, allergens, diets and both exclusion severities")
    func coverage() {
        let requests = EvaluationCorpus.cases.map(\.request)
        let restrictions = requests.flatMap { $0.context.restrictions }

        #expect(requests.contains { if case .newRecipe = $0 { true } else { false } })
        #expect(requests.contains { if case .adaptation = $0 { true } else { false } })
        #expect(restrictions.contains { if case .allergen = $0 { true } else { false } })
        #expect(restrictions.contains { if case .diet = $0 { true } else { false } })
        #expect(restrictions.contains { if case .excluded(_, .justAvoid) = $0 { true } else { false } })
        #expect(restrictions.contains { if case .excluded(_, .allergyOrIntolerance) = $0 { true } else { false } })
        #expect(requests.contains { $0.context.restrictions.isEmpty })
    }

    @Test("some case lists a food that breaks the diner's restriction, to see whether the model leaves it out")
    func includesTemptation() {
        let tempting = EvaluationCorpus.cases.contains { evaluationCase in
            let context = evaluationCase.request.context
            let names = Set(context.ingredients.map { IngredientName($0.name) })
            return context.restrictions.contains(.allergen(.peanut)) && names.contains(IngredientName("peanut butter"))
        }

        #expect(tempting)
    }

    @Test("every case has at least one diner and some food on hand")
    func wellFormed() {
        for evaluationCase in EvaluationCorpus.cases {
            #expect(evaluationCase.request.context.dinerCount >= 1)
            #expect(!evaluationCase.request.context.ingredients.isEmpty)
        }
    }
}
