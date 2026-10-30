import Foundation

public enum GenerationRuntimeKind: Sendable, Hashable {
    case privateCloudCompute
    case onDevice
}

public enum RuntimeUnavailability: Sendable, Hashable {
    case osVersion
    case notEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case networkUnavailable
    case dailyLimitReached
}

public enum RuntimeAvailability: Sendable, Hashable {
    case available
    case unavailable(RuntimeUnavailability)
}

/// Thrown by a runtime when a request failed in a way another approved runtime may be able to serve.
/// Any other error is a hard failure and is never routed around.
public enum RuntimeFailure: Error, Sendable, Equatable {
    case unavailable(RuntimeUnavailability)
}

/// An approved model runtime. Adapters own framework types, availability checks, and error mapping.
public protocol GenerationRuntime<Request, Output>: Sendable {
    associatedtype Request: Sendable
    associatedtype Output: Sendable

    var kind: GenerationRuntimeKind { get }
    func availability() async -> RuntimeAvailability
    func generate(_ request: Request) async throws -> Output
}

public struct SkippedRuntime: Sendable, Hashable {
    public let kind: GenerationRuntimeKind
    public let reason: RuntimeUnavailability

    public init(kind: GenerationRuntimeKind, reason: RuntimeUnavailability) {
        self.kind = kind
        self.reason = reason
    }
}

public enum GenerationOutcome<Output: Sendable>: Sendable {
    /// `skipped` lists runtimes passed over first, so the caller can explain a capability difference.
    case generated(Output, on: GenerationRuntimeKind, skipped: [SkippedRuntime])
    case unavailable([SkippedRuntime])
}

extension GenerationOutcome: Equatable where Output: Equatable {}

/// Tries approved runtimes in preference order. Only unavailability moves on to the next runtime;
/// a hard error propagates. There is no runtime outside the list to fall back to.
public struct GenerationRouter<Request: Sendable, Output: Sendable>: Sendable {
    private let runtimes: [any GenerationRuntime<Request, Output>]

    public init(runtimes: [any GenerationRuntime<Request, Output>]) {
        self.runtimes = runtimes
    }

    public func generate(_ request: Request) async throws -> GenerationOutcome<Output> {
        var skipped: [SkippedRuntime] = []
        for runtime in runtimes {
            if case .unavailable(let reason) = await runtime.availability() {
                skipped.append(SkippedRuntime(kind: runtime.kind, reason: reason))
                continue
            }
            do {
                let output = try await runtime.generate(request)
                return .generated(output, on: runtime.kind, skipped: skipped)
            } catch RuntimeFailure.unavailable(let reason) {
                skipped.append(SkippedRuntime(kind: runtime.kind, reason: reason))
            }
        }
        return .unavailable(skipped)
    }
}
