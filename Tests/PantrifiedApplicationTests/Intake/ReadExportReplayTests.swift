import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedTestSupport

@Suite("Copy what the app read: replaying an export")
struct ReadExportReplayTests {
    typealias Sample = ReadExportSample

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ReadExportFixtures", isDirectory: true)

    /// Fixtures recording a grouping the app still gets wrong. Each stays here until grouping is fixed,
    /// when its test starts to pass and the known issue has to be removed from this list.
    static let knownFailures: Set<String> = ["front-then-unrelated-back.json"]

    static var fixtureNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    }

    /// Replays an export through its JSON and checks the replay gives what was recorded.
    private func expectRoundTrip(_ export: ReadExport) throws {
        let replay = try ReadExportReplay(json: export.encoded())
        let report = replay.run()
        #expect(report.groups.map(\.photos) == export.groups.map(\.photos))
        #expect(report.groups.map(\.barcode) == export.groups.map(\.barcode))
        #expect(report.groups.map(\.links) == export.groups.map(\.links))
        #expect(report.groups.map(\.labelName) == export.groups.map { $0.proposals.labelName?.text })
        #expect(report.suggestions == export.suggestions)
        #expect(report.pairs == export.pairs)
    }

    @Test("an export as shared replays to the same groups, suggestions, signals and label names")
    func roundTrip() throws {
        try expectRoundTrip(ReadExportDraft(source: Sample.source()).export())
    }

    @Test("an export with every line included replays the same")
    func roundTripEverything() throws {
        var draft = ReadExportDraft(source: Sample.source())
        for line in draft.photos.flatMap(\.lines) { draft.setIncluded(true, line: line.id) }
        try expectRoundTrip(draft.export())
    }

    @Test("a replay of a batch with photos taken close together, look-alikes and a date photo groups the same")
    func roundTripCloseShots() throws {
        let photos = [
            Sample.photo(0, 0, [Sample.line("Minis", row: 0.2, size: 0.1), Sample.line("Toacker", row: 0.08, size: 0.09)], print: Sample.print(0)),
            Sample.photo(1, 4, [Sample.line("Nutrition Facts", row: 0.5), Sample.line("LOACKER", row: 0.1, size: 0.02)],
                         codes: [.product(IntakeFixture.yogurt)], print: Sample.print(0, offset: 0.2)),
            Sample.photo(2, 9, [Sample.line("BEST BY 05/2027", row: 0.5)]),
            Sample.photo(3, 60, [Sample.line("Sparkling water", row: 0.2, size: 0.1), Sample.line("Polar", row: 0.08, size: 0.09)]),
            Sample.photo(4, 900, [Sample.line("Polar sparking water", row: 0.05, size: 0.04), Sample.line("Nutrition Facts", row: 0.3)]),
        ]
        try expectRoundTrip(ReadExportDraft(source: Sample.source(Sample.review(photos))).export())
    }

    @Test("replayed photos have stable identities, the batch's times, stand-in prints and shared digests")
    func observations() throws {
        let export = ReadExportDraft(source: Sample.source()).export()
        let replay = ReadExportReplay(export)
        let observations = replay.observations
        #expect(observations.map(\.photo) == (0...8).map(ReadExportReplay.photoID))
        #expect(ReadExportReplay.photoID(3) == ReadExportReplay.photoID(3))
        #expect(observations[1].capturedAt.timeIntervalSince(observations[0].capturedAt) == 5)
        #expect(observations[0].capturedAt == PrintedDateParser.utcCalendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 12)))
        #expect(observations[0].featurePrint == FeaturePrint([0]))
        #expect(observations[4].featurePrint == nil)
        #expect(observations[7].contentDigest == observations[8].contentDigest)
        #expect(observations[6].contentDigest != observations[7].contentDigest)
        #expect(observations[6].codes == [.product(IntakeFixture.beans), .refused(.coupon)])
        #expect(observations[5].codes == [.link])
    }

    @Test("a replay with another policy shows how a change would group the same photos")
    func otherPolicy() throws {
        let replay = ReadExportReplay(ReadExportDraft(source: Sample.source()).export())
        var cautious = GroupingPolicy()
        cautious.mergeAt = 200
        #expect(replay.run(policy: cautious).groups.map(\.photos) == [[0], [1], [2], [3], [4], [5], [6], [7, 8]])
        #expect(!replay.run(policy: cautious).summary.isEmpty)
    }

    @Test("the fixture folder holds the committed exports")
    func fixturesExist() {
        #expect(Self.fixtureNames.contains("sample-batch.json"))
        #expect(Self.fixtureNames.contains("front-then-unrelated-back.json"))
    }

    @Test("each committed export decodes, holds nothing the check flags, and groups as the person did", arguments: fixtureNames)
    func fixture(name: String) throws {
        let replay = try ReadExportReplay(contentsOf: Self.fixtures.appendingPathComponent(name))
        let export = replay.export
        var texts = export.photos.flatMap(\.lines).map(\.text)
        texts += export.groups.compactMap { $0.proposals.labelName?.text }
        texts += export.lookups.compactMap { $0.name?.text }
        texts += export.corrections.packages.compactMap { $0.name?.text }
        #expect(texts.allSatisfy { SensitiveText.flag($0) == nil }, "\(name) holds text that looks personal")

        let groups = replay.run().groups.map(\.photos)
        if Self.knownFailures.contains(name) {
            withKnownIssue("\(name) records a grouping the app still gets wrong") {
                #expect(groups == replay.personGroups)
            }
        } else {
            #expect(groups == replay.personGroups, "\(name)\n\(replay.run().summary)")
        }
    }
}
