import Foundation
import Testing
import PantrifiedApplication

private func record(
    _ outcome: EvaluationRecord.Outcome,
    seconds: Double = 1,
    kinds: [String] = [],
    words: [String] = [],
    unknown: [String] = [],
    id: String = "a"
) -> EvaluationRecord {
    EvaluationRecord(
        caseID: id, trial: 1, outcome: outcome, runtime: outcome == .unavailable ? nil : "onDevice",
        reasonKinds: kinds, unrecognizedWords: words, unknownIngredients: unknown, notes: [],
        seconds: seconds, recipe: nil
    )
}

@Suite("Evaluation summary")
struct EvaluationSummaryTests {
    @Test("counts each outcome and the ready rate among generated recipes")
    func counts() {
        let summary = EvaluationSummary(records: [
            record(.ready), record(.ready), record(.withheld, kinds: ["unrecognizedWord"]),
            record(.unavailable), record(.failed),
        ])

        #expect(summary.total == 5)
        #expect(summary.ready == 2)
        #expect(summary.withheld == 1)
        #expect(summary.unavailable == 1)
        #expect(summary.failed == 1)
        #expect(summary.readyRate == 2.0 / 3.0)
    }

    @Test("the ready rate is absent when nothing was generated")
    func noRate() {
        #expect(EvaluationSummary(records: [record(.unavailable)]).readyRate == nil)
        #expect(EvaluationSummary(records: []).readyRate == nil)
    }

    @Test("each reason kind counts once per record")
    func reasonKinds() {
        let summary = EvaluationSummary(records: [
            record(.withheld, kinds: ["unrecognizedWord", "unrecognizedWord", "unknownIngredient"]),
            record(.withheld, kinds: ["unrecognizedWord"]),
        ])

        #expect(summary.withheldByReason == ["unrecognizedWord": 2, "unknownIngredient": 1])
    }

    @Test("unrecognized words and unknown ingredients are ranked by how often they occur")
    func wordRanking() {
        let summary = EvaluationSummary(records: [
            record(.withheld, words: ["saute", "drizzle"], unknown: ["saffron"]),
            record(.withheld, words: ["saute"], unknown: ["saffron", "miso"]),
            record(.withheld, words: ["saute", "zest"]),
        ])

        #expect(summary.unrecognizedWords.first == WordCount(word: "saute", count: 3))
        #expect(summary.unrecognizedWords.map(\.word) == ["saute", "drizzle", "zest"])
        #expect(summary.unknownIngredients.map(\.word) == ["saffron", "miso"])
    }

    @Test("latency covers only runs that reached a model")
    func latency() {
        let summary = EvaluationSummary(records: [
            record(.ready, seconds: 1), record(.ready, seconds: 2), record(.withheld, seconds: 3),
            record(.ready, seconds: 4), record(.unavailable, seconds: 99),
        ])

        #expect(summary.medianSeconds == 2.5)
        #expect(summary.maxSeconds == 4)
        #expect(summary.p95Seconds == 4)
    }

    @Test("latency is absent when no run reached a model")
    func noLatency() {
        let summary = EvaluationSummary(records: [record(.unavailable)])

        #expect(summary.medianSeconds == nil)
        #expect(summary.maxSeconds == nil)
    }
}

@Suite("Evaluation report")
struct EvaluationReportTests {
    @Test("a report survives a JSON round trip and states what it was run on")
    func jsonRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let report = EvaluationReport(
            environment: EvaluationReport.Environment(device: "iPhone17,2", systemVersion: "27.0", runtimes: ["onDevice"]),
            startedAt: start,
            finishedAt: start.addingTimeInterval(60),
            trialsPerCase: 3,
            records: [record(.ready), record(.withheld, kinds: ["unrecognizedWord"], words: ["saute"])]
        )

        let decoded = try JSONDecoder.evaluation.decode(EvaluationReport.self, from: Data(report.json().utf8))

        #expect(decoded == report)
        #expect(decoded.environment.device == "iPhone17,2")
        #expect(!decoded.classificationDataVersion.isEmpty)
    }

    @Test("the JSON is stable and readable")
    func jsonIsSorted() throws {
        let report = EvaluationReport(
            environment: EvaluationReport.Environment(device: "d", systemVersion: "v", runtimes: []),
            startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 0),
            trialsPerCase: 1, records: []
        )
        let json = try report.json()

        #expect(json.contains("\n"))
        #expect(try report.json() == json)
    }
}
