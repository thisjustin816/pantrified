import Foundation
import PantrifiedDomain

public struct WordCount: Sendable, Hashable, Codable {
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}

public struct EvaluationSummary: Sendable, Hashable, Codable {
    public let total: Int
    public let ready: Int
    public let withheld: Int
    public let unavailable: Int
    public let failed: Int
    /// Ready recipes over recipes the model produced; nil when it produced none.
    public let readyRate: Double?
    /// How many records carried each reason kind, counting a record once per kind.
    public let withheldByReason: [String: Int]
    public let unrecognizedWords: [WordCount]
    public let unknownIngredients: [WordCount]
    /// Over runs where a model produced a recipe.
    public let medianSeconds: Double?
    public let p95Seconds: Double?
    public let maxSeconds: Double?

    public init(records: [EvaluationRecord], rankedWords: Int = 25) {
        total = records.count
        ready = records.count { $0.outcome == .ready }
        withheld = records.count { $0.outcome == .withheld }
        unavailable = records.count { $0.outcome == .unavailable }
        failed = records.count { $0.outcome == .failed }
        readyRate = ready + withheld == 0 ? nil : Double(ready) / Double(ready + withheld)

        var byReason: [String: Int] = [:]
        for record in records {
            for kind in Set(record.reasonKinds) { byReason[kind, default: 0] += 1 }
        }
        withheldByReason = byReason
        unrecognizedWords = Self.rank(records.flatMap(\.unrecognizedWords), limit: rankedWords)
        unknownIngredients = Self.rank(records.flatMap(\.unknownIngredients), limit: rankedWords)

        let durations = records.filter { $0.outcome == .ready || $0.outcome == .withheld }.map(\.seconds).sorted()
        medianSeconds = Self.median(durations)
        p95Seconds = Self.nearestRank(durations, 0.95)
        maxSeconds = durations.last
    }

    private static func rank(_ words: [String], limit: Int) -> [WordCount] {
        var counts: [String: Int] = [:]
        for word in words { counts[word, default: 0] += 1 }
        return counts
            .map { WordCount(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
            .prefix(limit)
            .map { $0 }
    }

    private static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func nearestRank(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// The result of an evaluation run, written so a person can read it and a script can compare runs.
public struct EvaluationReport: Sendable, Hashable, Codable {
    public struct Environment: Sendable, Hashable, Codable {
        public let device: String
        public let systemVersion: String
        /// The runtimes the run was set up with, in preference order.
        public let runtimes: [String]

        public init(device: String, systemVersion: String, runtimes: [String]) {
            self.device = device
            self.systemVersion = systemVersion
            self.runtimes = runtimes
        }
    }

    public let environment: Environment
    public let startedAt: Date
    public let finishedAt: Date
    public let classificationDataVersion: String
    public let trialsPerCase: Int
    public let records: [EvaluationRecord]
    public let summary: EvaluationSummary

    public init(
        environment: Environment,
        startedAt: Date,
        finishedAt: Date,
        trialsPerCase: Int,
        records: [EvaluationRecord],
        classificationDataVersion: String = DietaryValidator().data.provenance.version
    ) {
        self.environment = environment
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.classificationDataVersion = classificationDataVersion
        self.trialsPerCase = trialsPerCase
        self.records = records
        self.summary = EvaluationSummary(records: records)
    }

    public func json() throws -> String {
        String(decoding: try JSONEncoder.evaluation.encode(self), as: UTF8.self)
    }
}

extension JSONEncoder {
    public static var evaluation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var evaluation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
