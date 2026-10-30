#if canImport(FoundationModels)
import FoundationModels
import PantrifiedApplication
import PantrifiedDomain

/// The recipe a model fills in. Its own fields keep the model to the shape Make Something needs;
/// everything it returns is still checked by the deterministic validator.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct RecipePayload {
    @Guide(description: "A short recipe title")
    var title: String

    @Guide(description: "One ingredient per entry, each with an amount, for example '2 cups cooked rice'")
    var ingredientLines: [String]

    @Guide(description: "The cooking steps in order, one per entry")
    var steps: [String]
}

/// Apple's on-device language model as a generation runtime. It needs Apple Intelligence and works
/// offline. Availability is read from the system each time, never assumed from the OS version.
@available(iOS 26.0, macOS 26.0, *)
public struct OnDeviceRecipeRuntime: GenerationRuntime {
    public typealias Request = MakeSomethingRequest
    public typealias Output = GeneratedRecipe

    public let kind: GenerationRuntimeKind = .onDevice

    public init() {}

    public func availability() async -> RuntimeAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.notEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceDisabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.notEligible)
            }
        @unknown default:
            return .unavailable(.notEligible)
        }
    }

    /// A new session per request, so one recipe never carries context into the next. A generation
    /// error propagates as a hard error; it is not routed around.
    public func generate(_ request: MakeSomethingRequest) async throws -> GeneratedRecipe {
        let prompt = RecipePrompt.render(request)
        let session = LanguageModelSession(instructions: prompt.instructions)
        let response = try await session.respond(to: prompt.text, generating: RecipePayload.self)
        let payload = response.content
        return GeneratedRecipe(
            title: payload.title, ingredientLines: payload.ingredientLines, instructions: payload.steps
        )
    }
}
#endif
