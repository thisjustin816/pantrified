import Testing
@testable import PantrifiedDomain

private func result(_ quantity: Quantity) -> UsedSomeResult {
    UsedSomeResult(quantity: quantity, needsCorrection: false)
}

@Suite("Quantity after using some")
struct QuantityStepDownTests {
    @Test("approximate quantities step down one level and stop at Low")
    func stepsDown() {
        #expect(Quantity.full.afterUsingSome == result(.aboutHalf))
        #expect(Quantity.aboutHalf.afterUsingSome == result(.low))
        #expect(Quantity.low.afterUsingSome == result(.low))
    }

    @Test("unknown stays unknown and needs no correction")
    func unknownStays() {
        #expect(Quantity.unknown.afterUsingSome == result(.unknown))
    }

    @Test("an exact amount is left alone and flagged for the user to correct")
    func exactFlagged() {
        let exact = Quantity.exact(500, unit: "g")

        #expect(exact.afterUsingSome == UsedSomeResult(quantity: exact, needsCorrection: true))
    }
}
