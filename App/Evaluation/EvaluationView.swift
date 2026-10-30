#if DEBUG || EVALUATION
import PantrifiedApplication
import SwiftUI

/// Runs recipe generation on this device against the dietary validator and shows how often a
/// generated recipe is presented or withheld, and why. Compiled only for Debug and Evaluation
/// builds.
struct EvaluationView: View {
    @State private var model = EvaluationModel()

    var body: some View {
        NavigationStack {
            List {
                Section("On-device model") {
                    LabeledContent("Status", value: model.availability)
                }
                Section {
                    Stepper("Runs per case: \(model.trials)", value: $model.trials, in: 1...10)
                        .disabled(model.isRunning)
                    if model.isRunning {
                        Button("Stop", role: .destructive) { model.cancel() }
                    } else {
                        Button("Run evaluation") { model.start() }
                    }
                }
                switch model.state {
                case .idle:
                    EmptyView()
                case .running(let done, let total):
                    Section("Progress") {
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                        Text("\(done) of \(total) runs")
                    }
                case .finished(let report):
                    ReportSections(report: report)
                }
            }
            .navigationTitle("Evaluation")
            .task { await model.refreshAvailability() }
        }
    }
}

private struct ReportSections: View {
    let report: EvaluationReport

    var body: some View {
        let summary = report.summary
        Section("Summary") {
            LabeledContent("Runs", value: "\(summary.total)")
            LabeledContent("Presented", value: "\(summary.ready)")
            LabeledContent("Withheld", value: "\(summary.withheld)")
            LabeledContent("Unavailable", value: "\(summary.unavailable)")
            LabeledContent("Failed", value: "\(summary.failed)")
            if let rate = summary.readyRate {
                LabeledContent("Presented rate", value: rate.formatted(.percent.precision(.fractionLength(0))))
            }
            if let median = summary.medianSeconds, let p95 = summary.p95Seconds {
                LabeledContent("Median / p95", value: "\(seconds(median)) / \(seconds(p95))")
            }
        }
        if !summary.withheldByReason.isEmpty {
            Section("Why recipes were withheld") {
                ForEach(reasonCounts(summary), id: \.word) { entry in
                    LabeledContent(entry.word, value: "\(entry.count)")
                }
            }
        }
        if !summary.unrecognizedWords.isEmpty {
            Section("Words the validator did not recognize") {
                ForEach(summary.unrecognizedWords.prefix(15), id: \.word) { entry in
                    LabeledContent(entry.word, value: "\(entry.count)")
                }
            }
        }
        Section("Share") {
            if let json = try? report.json() {
                ShareLink(item: json, subject: Text("Pantrified evaluation")) {
                    Label("Share report (JSON)", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("The report could not be written.")
            }
        }
        Section("Runs") {
            ForEach(report.records) { record in
                DisclosureGroup("\(record.caseID) #\(record.trial): \(record.outcome.rawValue)") {
                    if let recipe = record.recipe {
                        Text(recipe.title).font(.headline)
                        ForEach(Array(recipe.ingredientLines.enumerated()), id: \.offset) { Text("- \($0.element)") }
                        ForEach(Array(recipe.instructions.enumerated()), id: \.offset) { Text("\($0.offset + 1). \($0.element)") }
                    }
                    if !record.notes.isEmpty {
                        Text(record.notes.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reasonCounts(_ summary: EvaluationSummary) -> [WordCount] {
        summary.withheldByReason
            .map { WordCount(word: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}
#endif
