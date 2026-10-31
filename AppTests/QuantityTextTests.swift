import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import Pantrified

@Suite("Quantity text")
struct QuantityTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(quantity: Quantity, location: String? = "Fridge", printed: PrintedDate? = nil) -> PantryEntry {
        let package = Package(
            spaceID: SpaceID(), name: "Milk", location: LocationID(), quantity: quantity,
            printedDate: printed, addedAt: now
        )
        let assessment = AttentionPolicy().assess(package, storageType: .refrigerated, guidance: nil, now: now)
        return PantryEntry(package: package, locationName: location, assessment: assessment)
    }

    @Test("each rough amount has its own words, and unknown has none")
    func roughAmounts() {
        #expect(QuantityText.label(.unknown) == nil)
        #expect(QuantityText.label(.full) == "Full")
        #expect(QuantityText.label(.aboutHalf) == "About half")
        #expect(QuantityText.label(.low) == "Almost gone")
    }

    @Test("an exact amount shows its number and unit, without trailing zeros")
    func exactAmounts() {
        #expect(QuantityText.label(.exact(2, unit: "lb")) == "2 lb")
        #expect(QuantityText.label(.exact(12, unit: "oz")) == "12 oz")
        let half = QuantityText.label(.exact(1.5, unit: "lb"))
        #expect(half?.hasSuffix(" lb") == true)
        #expect(half?.contains("00") == false)
        #expect(QuantityText.label(.exact(3, unit: "")) == "3")
    }

    @Test("the amount sits between the place and the reason")
    func inTheDetailLine() {
        let dated = PrintedDate(label: .useBy, date: now.addingTimeInterval(86_400))
        let line = AttentionText.detail(for: entry(quantity: .aboutHalf, printed: dated), showsLocation: true)

        #expect(line == "Fridge · About half · Use by \(AttentionText.day(dated.date))")
    }

    @Test("a list that names the place in its heading still shows the amount")
    func withoutThePlace() {
        #expect(AttentionText.detail(for: entry(quantity: .full), showsLocation: false) == "Full")
    }

    @Test("an unknown amount adds nothing to the line")
    func unknownAddsNothing() {
        #expect(AttentionText.detail(for: entry(quantity: .unknown), showsLocation: true) == "Fridge")
        #expect(AttentionText.detail(for: entry(quantity: .unknown), showsLocation: false) == "")
    }
}
