import Foundation

/// The lifecycle fact a storage window counts from.
public enum WindowAnchor: Sendable, Hashable, Codable {
    case added
    case opened
    case thawed
}

public struct GuidanceProvenance: Sendable, Hashable, Codable {
    public var source: String
    public var version: String

    public init(source: String, version: String) {
        self.source = source
        self.version = version
    }
}

public struct GuidanceWindow: Sendable, Hashable {
    public var storageType: StorageType
    public var anchor: WindowAnchor
    public var days: Int

    public init(storageType: StorageType, anchor: WindowAnchor, days: Int) {
        self.storageType = storageType
        self.anchor = anchor
        self.days = days
    }
}

/// Sourced storage guidance matched to a package. Guidance, not a safety rule.
public struct StorageGuidance: Sendable, Hashable, Codable {
    public var provenance: GuidanceProvenance
    public var windows: [GuidanceWindow]

    public init(provenance: GuidanceProvenance, windows: [GuidanceWindow]) {
        self.provenance = provenance
        self.windows = windows
    }
}

/// A storage instruction read from the package itself, such as "use within 3 days of opening".
/// `storageType` is nil when the instruction does not name a storage condition.
public struct PackageInstruction: Sendable, Hashable, Codable {
    public var days: Int
    public var anchor: WindowAnchor
    public var storageType: StorageType?

    public init(days: Int, anchor: WindowAnchor, storageType: StorageType?) {
        self.days = days
        self.anchor = anchor
        self.storageType = storageType
    }
}

public enum AttentionState: Sendable, Hashable {
    /// No date, instruction, or guidance applies. Absence of evidence, not a clean bill of health.
    case unknown
    case fine
    case useSoon
    case pastGuidance
}

public enum AttentionBasis: Sendable, Hashable {
    case printedDate(label: PrintedDateLabel, date: Date)
    case packageInstruction(days: Int, anchor: WindowAnchor)
    case guidance(provenance: GuidanceProvenance, days: Int, anchor: WindowAnchor)
}

public struct AttentionAssessment: Sendable, Hashable {
    public var state: AttentionState
    /// The earliest date among the evidence in `basis`. Not an expiration date.
    public var attentionDate: Date?
    public var basis: [AttentionBasis]
}

/// Combines separate evidence into an explainable attention state without merging it into one
/// fictitious expiration date.
public struct AttentionPolicy: Sendable {
    public var calendar: Calendar
    public var useSoonWithinDays: Int

    public init(calendar: Calendar = .current, useSoonWithinDays: Int = 3) {
        self.calendar = calendar
        self.useSoonWithinDays = useSoonWithinDays
    }

    /// `storageType` is nil when the package's location is unknown; sourced guidance then has no
    /// window to apply, and only instructions that name no storage condition do.
    public func assess(
        _ package: Package,
        storageType: StorageType?,
        guidance: StorageGuidance?,
        now: Date
    ) -> AttentionAssessment {
        var candidates: [(date: Date, basis: AttentionBasis)] = []

        if let printed = package.printedDate, printed.label == .useBy || printed.label == .bestBy {
            candidates.append((printed.date, .printedDate(label: printed.label, date: printed.date)))
        }

        if let candidate = instructionCandidate(for: package, storageType: storageType)
            ?? guidanceCandidate(for: package, storageType: storageType, guidance: guidance) {
            candidates.append(candidate)
        }

        guard let earliest = candidates.map(\.date).min() else {
            return AttentionAssessment(state: .unknown, attentionDate: nil, basis: [])
        }
        return AttentionAssessment(
            state: state(for: earliest, now: now),
            attentionDate: earliest,
            basis: candidates.map(\.basis)
        )
    }

    private func state(for date: Date, now: Date) -> AttentionState {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days < 0 { return .pastGuidance }
        return days <= useSoonWithinDays ? .useSoon : .fine
    }

    private func instructionCandidate(
        for package: Package,
        storageType: StorageType?
    ) -> (date: Date, basis: AttentionBasis)? {
        guard let instruction = package.instruction,
              instruction.storageType == nil || instruction.storageType == storageType,
              let start = anchorDate(instruction.anchor, of: package),
              let end = calendar.date(byAdding: .day, value: instruction.days, to: start)
        else { return nil }
        return (end, .packageInstruction(days: instruction.days, anchor: instruction.anchor))
    }

    /// Among windows whose anchor has happened, the most recently anchored one applies, so opening a
    /// package moves from the unopened window to the opened one. Ties take the shorter window.
    private func guidanceCandidate(
        for package: Package,
        storageType: StorageType?,
        guidance: StorageGuidance?
    ) -> (date: Date, basis: AttentionBasis)? {
        guard let guidance, let storageType else { return nil }
        let applicable = guidance.windows.compactMap { window -> (window: GuidanceWindow, start: Date)? in
            guard window.storageType == storageType,
                  let start = anchorDate(window.anchor, of: package) else { return nil }
            return (window, start)
        }
        guard let chosen = applicable.min(by: { a, b in
            a.start != b.start ? a.start > b.start : a.window.days < b.window.days
        }), let end = calendar.date(byAdding: .day, value: chosen.window.days, to: chosen.start)
        else { return nil }
        return (end, .guidance(
            provenance: guidance.provenance, days: chosen.window.days, anchor: chosen.window.anchor
        ))
    }

    private func anchorDate(_ anchor: WindowAnchor, of package: Package) -> Date? {
        switch anchor {
        case .added: package.addedAt
        case .opened: package.openedAt
        case .thawed: package.thawedAt
        }
    }
}
