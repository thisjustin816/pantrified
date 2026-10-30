import Foundation
import PantrifiedDomain

/// A recipe as a model returned it. It has no dietary labels: suitability comes only from the
/// deterministic validator.
public struct GeneratedRecipe: Sendable, Hashable {
    public var title: String
    public var ingredientLines: [String]
    public var instructions: [String]

    public init(title: String, ingredientLines: [String], instructions: [String]) {
        self.title = title
        self.ingredientLines = ingredientLines
        self.instructions = instructions
    }
}

public enum MakeSomethingOutcome: Sendable, Hashable {
    /// Safe for every restriction in the request, or the request had none.
    case ready(GeneratedRecipe, DietaryAssessment, on: GenerationRuntimeKind)
    /// Failed validation and must not be presented. The assessment explains why, so the person
    /// can be told or the request retried.
    case withheld(DietaryAssessment, on: GenerationRuntimeKind)
    case unavailable([SkippedRuntime])
}

/// Make Something and adaptations. Every generated recipe passes hard-restriction validation
/// against the request's own restrictions before it can be presented.
public struct MakeSomething: Sendable {
    private let router: GenerationRouter<MakeSomethingRequest, GeneratedRecipe>
    private let validator: DietaryValidator

    public init(
        router: GenerationRouter<MakeSomethingRequest, GeneratedRecipe>,
        validator: DietaryValidator = DietaryValidator()
    ) {
        self.router = router
        self.validator = validator
    }

    public func run(_ request: MakeSomethingRequest) async throws -> MakeSomethingOutcome {
        switch try await router.generate(request) {
        case .unavailable(let skipped):
            return .unavailable(skipped)
        case .generated(let recipe, let runtime, _):
            // The list is taken as complete only because generated text is checked word by word:
            // a title or instruction word that is not a listed food, a known food or cooking
            // vocabulary makes the recipe need review, so it is withheld.
            let assessment = validator.assess(
                RecipeUnderReview(
                    title: recipe.title,
                    ingredientLines: recipe.ingredientLines,
                    instructions: recipe.instructions,
                    completeness: .complete,
                    origin: .generated
                ),
                against: request.context.restrictions
            )
            switch assessment.verdict {
            case .safe, .noRestrictions:
                return .ready(recipe, assessment, on: runtime)
            case .needsReview, .violation:
                return .withheld(assessment, on: runtime)
            }
        }
    }
}

/// Builds the minimum context for a generative request from the foods and diners the person
/// selected. Nothing else from inventory is read into it.
public struct PrepareMakeSomething: Sendable {
    private let useSoon: UseSoon

    public init(useSoon: UseSoon) {
        self.useSoon = useSoon
    }

    public func context(
        selecting packages: Set<PackageID>,
        diners: [ConsumerProfile],
        in space: SpaceID
    ) async throws -> MakeSomethingContext {
        let ingredients = try await useSoon.assessments(in: space)
            .filter { packages.contains($0.package.id) }
            .sorted { $0.needsAttention != $1.needsAttention ? $0.needsAttention : $0.package.name < $1.package.name }
            .map { MealContextIngredient(name: $0.package.name, useSoon: $0.needsAttention, quantity: $0.package.quantity) }
        return MakeSomethingContext(ingredients: ingredients, diners: diners)
    }
}
