import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let fridge = LocationID()

private func hours(_ n: Double) -> Date { t0.addingTimeInterval(n * 3600) }

private func makePackage(confirmed: Set<PackageField> = []) -> Package {
    Package(spaceID: SpaceID(), name: "Yoghrt", location: fridge, confirmed: confirmed, addedAt: t0)
}

@Suite("Package field provenance")
struct PackageFieldProvenanceTests {
    @Test("recognition fills a field the user has not decided")
    func recognitionFillsUndecided() throws {
        var package = makePackage()
        try package.record(.recognized(.name("Greek yogurt")), at: hours(1))

        #expect(package.name == "Greek yogurt")
        #expect(package.confirmedFields.isEmpty)
    }

    @Test("a correction keeps its value against recognition recorded after it")
    func correctionBeatsLaterRecognition() throws {
        var package = makePackage()
        try package.record(.corrected(.name("Yogurt")), at: hours(1))
        try package.record(.recognized(.name("Greek yogurt")), at: hours(2))

        #expect(package.name == "Yogurt")
        #expect(package.confirmedFields == [.name])
    }

    @Test("a correction replaces recognition recorded before it")
    func correctionReplacesEarlierRecognition() throws {
        var package = makePackage()
        try package.record(.recognized(.name("Greek yogurt")), at: hours(1))
        try package.record(.corrected(.name("Yogurt")), at: hours(2))

        #expect(package.name == "Yogurt")
    }

    @Test("a later correction replaces an earlier one")
    func laterCorrectionWins() throws {
        var package = makePackage()
        try package.record(.corrected(.name("Yogurt")), at: hours(1))
        try package.record(.corrected(.name("Skyr")), at: hours(2))

        #expect(package.name == "Skyr")
    }

    @Test("fields confirmed at creation resist recognition")
    func confirmedAtCreation() throws {
        var package = makePackage(confirmed: [.name])
        try package.record(.recognized(.name("Greek yogurt")), at: hours(1))

        #expect(package.name == "Yoghrt")
    }

    @Test("a correction can clear a field, and recognition cannot refill it")
    func confirmedEmpty() throws {
        var package = Package(
            spaceID: SpaceID(), name: "Milk", location: fridge,
            printedDate: PrintedDate(label: .bestBy, date: hours(48)), addedAt: t0
        )
        try package.record(.corrected(.printedDate(nil)), at: hours(1))
        try package.record(.recognized(.printedDate(PrintedDate(label: .useBy, date: hours(24)))), at: hours(2))

        #expect(package.printedDate == nil)
    }

    @Test("undoing a correction exposes recognition recorded after it")
    func undoCorrection() throws {
        var package = makePackage()
        let correction = try package.record(.corrected(.name("Yogurt")), at: hours(1))
        try package.record(.recognized(.name("Greek yogurt")), at: hours(2))
        try package.undo(correction, at: hours(3))

        #expect(package.name == "Greek yogurt")
        #expect(package.confirmedFields.isEmpty)
    }

    @Test("each field keeps its own provenance")
    func fieldsAreIndependent() throws {
        var package = makePackage()
        let product = ProductID()
        let instruction = PackageInstruction(days: 3, anchor: .opened, storageType: nil)
        try package.record(.corrected(.name("Yogurt")), at: hours(1))
        try package.record(.recognized(.productID(product)), at: hours(2))
        try package.record(.recognized(.instruction(instruction)), at: hours(2))

        #expect(package.name == "Yogurt")
        #expect(package.productID == product)
        #expect(package.instruction == instruction)
        #expect(package.confirmedFields == [.name])
    }

    @Test("propose records recognition only for fields the user has not decided")
    func proposeSkipsConfirmed() throws {
        var package = makePackage(confirmed: [.name])
        let printed = PrintedDate(label: .useBy, date: hours(72))
        let recorded = try package.propose(
            PackageProposal(name: "Greek yogurt", quantity: .full, printedDate: printed), at: hours(1)
        )

        #expect(recorded.count == 1)
        #expect(package.name == "Yoghrt")
        #expect(package.printedDate == printed)
        #expect(package.quantity == .unknown)
    }

    @Test("a package restored from its history derives the same state")
    func restoreFromHistory() throws {
        var package = makePackage()
        try package.record(.moved(to: LocationID()), at: hours(1))
        let opened = try package.record(.opened, at: hours(2))
        try package.record(.corrected(.name("Yogurt")), at: hours(3))
        try package.undo(opened, at: hours(4))

        let restored = Package(
            id: package.id, spaceID: package.spaceID, name: package.origin.details.name,
            location: package.origin.location, addedAt: package.addedAt, events: package.events
        )

        #expect(restored.name == package.name)
        #expect(restored.location == package.location)
        #expect(restored.openedAt == nil)
        #expect(restored.events == package.events)
    }
}
