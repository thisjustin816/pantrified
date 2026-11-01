import Foundation
import Testing
import PantrifiedDomain

@Suite("The record of how a batch was grouped")
struct GroupingTraceTests {
    let grouper = PhotoGrouper()

    private func pair(_ trace: GroupingTrace, _ photos: [PhotoObservation], _ a: Int, _ b: Int) -> PairTrace? {
        trace.pairs.first { $0.first == photos[a].photo && $0.second == photos[b].photo }
    }

    @Test("the trace's grouping is the batch's grouping")
    func sameGrouping() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
            Fixture.photo(1, lines: Fixture.back(["Chobani greek yogurt"]), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(2, seconds: 300, lines: Fixture.front("Baking soda", brand: "Arm Hammer")),
            Fixture.photo(3, seconds: 310, lines: Fixture.front("Baking powder", brand: "Clabber Girl")),
        ]
        #expect(grouper.trace(photos).result == grouper.group(photos))
        #expect(grouper.trace(photos.reversed()).result == grouper.group(photos))
    }

    @Test("each signal carries the points it added, and the points add up to the score")
    func pointsPerSignal() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Minis", brand: "Toacker")),
            Fixture.photo(1, lines: [Fixture.line("Nutrition Facts", row: 0.5), Fixture.line("Calories 50", row: 0.55)],
                          codes: [.product(Fixture.beans)]),
            Fixture.photo(2, seconds: 200, lines: Fixture.front("Greek yogurt", brand: "Chobani"), codes: [.product(Fixture.yogurt)]),
            Fixture.photo(3, seconds: 900, lines: Fixture.back(["Chobani greek yogurt plain"]), codes: [.product(Fixture.yogurt)]),
        ]
        let trace = grouper.trace(photos)
        let backAfterFront = try #require(pair(trace, photos, 0, 1))
        #expect(backAfterFront.signals == [SignalPoints(signal: .takenRightAfter, points: 15)])
        #expect(backAfterFront.shotOrderPoints == 45)
        #expect(backAfterFront.score == 60)

        let sameBarcode = try #require(pair(trace, photos, 2, 3))
        #expect(sameBarcode.signals.first == SignalPoints(signal: .sameBarcode, points: 100))
        #expect(sameBarcode.signals.contains(SignalPoints(signal: .sharedLabelWords, points: 50)))
        #expect(sameBarcode.shotOrderPoints == 0)
        for evidence in trace.pairs {
            #expect(evidence.signals.map(\.points).reduce(0, +) + evidence.oneLetterOffPoints + evidence.shotOrderPoints == evidence.score)
        }
    }

    @Test("a name word read one letter off adds its points apart from the label words signal, which adds none")
    func oneLetterOff() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Sparkling water", brand: "Polar")),
            Fixture.photo(1, seconds: 900, lines: [Fixture.line("Polar sparking water", row: 0.05, size: 0.04)] + Fixture.back([])),
        ]
        let evidence = try #require(pair(grouper.trace(photos), photos, 0, 1))
        #expect(evidence.oneLetterOffPoints == 20)
        #expect(evidence.signals.map(\.signal).contains(.someLabelWords))
        #expect(evidence.score == evidence.signals.map(\.points).reduce(0, +) + 20)
    }

    @Test("a signal against the pair adds no points")
    func separatingSignal() throws {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Baking soda", brand: "Arm Hammer")),
            Fixture.photo(1, seconds: 300, lines: Fixture.front("Baking powder", brand: "Arm Hammer")),
        ]
        let evidence = try #require(pair(grouper.trace(photos), photos, 0, 1))
        #expect(evidence.signals.contains(SignalPoints(signal: .differentLabelWords, points: 0)))
    }

    @Test("a pair with no signal is kept for its distance up to twice the similar distance, and not beyond")
    func distances() throws {
        let photos = [
            Fixture.photo(0, seconds: 0, print: Fixture.print(0)),
            Fixture.photo(1, seconds: 500, print: Fixture.print(0, offset: 0.2)),
            Fixture.photo(2, seconds: 1_000, print: Fixture.print(0, offset: 0.9)),
            Fixture.photo(3, seconds: 1_500, print: Fixture.print(0, offset: 1.1)),
            Fixture.photo(4, seconds: 2_000),
        ]
        let trace = grouper.trace(photos)
        #expect(trace.distanceKeptUpTo == 1.0)
        let near = try #require(pair(trace, photos, 0, 1))
        #expect(abs((near.distance ?? 0) - 0.2) < 0.0001)
        #expect(near.signals == [SignalPoints(signal: .nearDuplicateImage, points: 50)])
        let kept = try #require(pair(trace, photos, 0, 2))
        #expect(kept.signals.isEmpty)
        #expect(kept.score == 0)
        #expect(abs((kept.distance ?? 0) - 0.9) < 0.0001)
        #expect(pair(trace, photos, 0, 3) == nil)
        #expect(!trace.pairs.contains { $0.first == photos[4].photo || $0.second == photos[4].photo })
    }

    @Test("each photo's role and panel are recorded")
    func roles() {
        let photos = [
            Fixture.photo(0, lines: Fixture.front("Greek yogurt", brand: "Chobani")),
            Fixture.photo(1, lines: [Fixture.line("Nutrition Facts", row: 0.5), Fixture.line("Calories 50", row: 0.55)]),
            Fixture.photo(2, seconds: 300, lines: [Fixture.line("BEST BY 05/2027")]),
            Fixture.photo(3, seconds: 600),
        ]
        let trace = grouper.trace(photos)
        #expect(trace.photos.map(\.role) == [.front, .back, .dateOnly, .other])
        #expect(trace.photos.map(\.showsPanel) == [false, true, false, false])
        #expect(trace.photos.map(\.photo) == photos.map(\.photo))
    }
}
