import Foundation
import Testing
@testable import PantrifiedDomain

private let fridge = StorageLocation(name: "Fridge", storageType: .refrigerated)

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ offset: Int) -> Date {
    let base = DateComponents(calendar: utc, year: 2026, month: 11, day: 1, hour: 12).date!
    return utc.date(byAdding: .day, value: offset, to: base)!
}

private func makePackage(printed: PrintedDate? = nil, addedDay: Int = 0) -> Package {
    Package(
        spaceID: SpaceID(),
        name: "Chicken",
        location: fridge.id,
        printedDate: printed,
        addedAt: day(addedDay)
    )
}

private let provenance = GuidanceProvenance(source: "USDA FoodKeeper", version: "test-1")
private let policy = AttentionPolicy(calendar: utc, useSoonWithinDays: 3)

@Suite("Attention without evidence")
struct AttentionNoEvidenceTests {
    @Test("a package with no date, instruction, or guidance is unknown, not fine")
    func unknown() {
        let assessment = policy.assess(makePackage(), storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .unknown)
        #expect(assessment.attentionDate == nil)
        #expect(assessment.basis.isEmpty)
    }
}

@Suite("Attention from printed dates")
struct AttentionPrintedDateTests {
    @Test("a use-by date well in the future is fine")
    func fine() {
        let package = makePackage(printed: PrintedDate(label: .useBy, date: day(10)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .fine)
        #expect(assessment.attentionDate == day(10))
    }

    @Test("a date inside the use-soon window is use soon, including the boundary")
    func useSoon() {
        let package = makePackage(printed: PrintedDate(label: .bestBy, date: day(3)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .useSoon)
    }

    @Test("the day after the use-soon window is still fine")
    func justOutsideWindow() {
        let package = makePackage(printed: PrintedDate(label: .bestBy, date: day(4)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .fine)
    }

    @Test("the printed day itself is use soon, not past")
    func printedDayIsNotPast() {
        let package = makePackage(printed: PrintedDate(label: .useBy, date: day(0)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .useSoon)
    }

    @Test("a passed date is past guidance")
    func past() {
        let package = makePackage(printed: PrintedDate(label: .useBy, date: day(-1)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.state == .pastGuidance)
    }

    @Test("sell-by, packed, freeze-by, and unlabeled dates are not consumer deadlines")
    func nonDeadlineLabels() {
        for label in [PrintedDateLabel.sellBy, .packed, .freezeBy, .unlabeled] {
            let package = makePackage(printed: PrintedDate(label: label, date: day(-5)))
            let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

            #expect(assessment.state == .unknown)
        }
    }

    @Test("the assessment explains which printed date it used")
    func explainsPrintedDate() {
        let package = makePackage(printed: PrintedDate(label: .useBy, date: day(2)))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: nil, now: day(0))

        #expect(assessment.basis == [.printedDate(label: .useBy, date: day(2))])
    }
}

@Suite("Attention from guidance and instructions")
struct AttentionGuidanceTests {
    private let guidance = StorageGuidance(
        provenance: provenance,
        windows: [
            GuidanceWindow(storageType: .refrigerated, anchor: .added, days: 2),
            GuidanceWindow(storageType: .refrigerated, anchor: .opened, days: 5),
            GuidanceWindow(storageType: .frozen, anchor: .added, days: 180),
            GuidanceWindow(storageType: .refrigerated, anchor: .thawed, days: 1),
        ]
    )

    @Test("guidance counts from when the package was added when nothing else is known")
    func guidanceFromAdded() {
        let package = makePackage(addedDay: 0)
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(0))

        #expect(assessment.state == .useSoon)
        #expect(assessment.attentionDate == day(2))
        #expect(assessment.basis == [.guidance(provenance: provenance, days: 2, anchor: .added)])
    }

    @Test("opening switches to the opened window")
    func guidanceFromOpened() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.opened, at: day(1))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(1))

        #expect(assessment.attentionDate == day(6))
    }

    @Test("windows anchored at the same moment take the shorter one")
    func tieTakesShorterWindow() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.opened, at: day(0))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(0))

        #expect(assessment.attentionDate == day(2))
    }

    @Test("a window whose anchor has not happened does not apply")
    func missingAnchorSkipped() {
        let assessment = policy.assess(makePackage(), storageType: .refrigerated, guidance: guidance, now: day(0))

        #expect(assessment.basis.count == 1)
        #expect(assessment.attentionDate == day(2))
    }

    @Test("guidance for another storage type is ignored")
    func otherStorageTypeIgnored() {
        let guidanceForFrozenOnly = StorageGuidance(
            provenance: provenance,
            windows: [GuidanceWindow(storageType: .frozen, anchor: .added, days: 180)]
        )
        let assessment = policy.assess(
            makePackage(), storageType: .refrigerated, guidance: guidanceForFrozenOnly, now: day(0)
        )

        #expect(assessment.state == .unknown)
    }

    @Test("a clearly applicable package instruction outranks generic guidance")
    func instructionOutranksGuidance() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.opened, at: day(1))
        try package.record(.corrected(.instruction(PackageInstruction(days: 3, anchor: .opened, storageType: nil))), at: day(1))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(1))

        #expect(assessment.attentionDate == day(4))
        #expect(assessment.basis == [.packageInstruction(days: 3, anchor: .opened)])
    }

    @Test("with no known storage type, guidance does not apply but printed dates still do")
    func unknownStorageType() {
        let package = makePackage(printed: PrintedDate(label: .useBy, date: day(1)))
        let assessment = policy.assess(package, storageType: nil, guidance: guidance, now: day(0))

        #expect(assessment.basis == [.printedDate(label: .useBy, date: day(1))])
        #expect(assessment.state == .useSoon)
    }

    @Test("with no known storage type, only an instruction that names none applies")
    func unknownStorageTypeInstructions() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.corrected(.instruction(PackageInstruction(days: 4, anchor: .added, storageType: .refrigerated))), at: day(0))
        #expect(policy.assess(package, storageType: nil, guidance: nil, now: day(0)).state == .unknown)

        try package.record(.corrected(.instruction(PackageInstruction(days: 4, anchor: .added, storageType: nil))), at: day(0))
        #expect(policy.assess(package, storageType: nil, guidance: nil, now: day(0)).attentionDate == day(4))
    }

    @Test("an instruction for a different storage type does not apply")
    func instructionStorageTypeMismatch() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.corrected(.instruction(PackageInstruction(days: 30, anchor: .added, storageType: .frozen))), at: day(0))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(0))

        #expect(assessment.basis == [.guidance(provenance: provenance, days: 2, anchor: .added)])
    }

    @Test("the earliest of printed date and guidance drives the state, and both are explained")
    func earliestWins() {
        let package = makePackage(printed: PrintedDate(label: .bestBy, date: day(10)), addedDay: 0)
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(0))

        #expect(assessment.attentionDate == day(2))
        #expect(assessment.basis.count == 2)
    }

    @Test("still-have-it confirmation does not move the guidance window")
    func confirmationDoesNotReset() throws {
        var package = makePackage(addedDay: 0)
        try package.record(.confirmedPresent, at: day(1))
        let assessment = policy.assess(package, storageType: .refrigerated, guidance: guidance, now: day(1))

        #expect(assessment.attentionDate == day(2))
    }
}
