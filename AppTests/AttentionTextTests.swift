import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import Pantrified

@Suite("Attention text")
struct AttentionTextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func assess(
        printed: PrintedDate? = nil,
        instruction: PackageInstruction? = nil,
        guidance: StorageGuidance? = nil,
        storage: StorageType = .refrigerated
    ) -> AttentionAssessment {
        let package = Package(
            spaceID: SpaceID(), name: "Milk", location: LocationID(),
            printedDate: printed, instruction: instruction, addedAt: now
        )
        return AttentionPolicy(calendar: utc).assess(package, storageType: storage, guidance: guidance, now: now)
    }

    private func guidance(days: Int) -> StorageGuidance {
        StorageGuidance(
            provenance: GuidanceProvenance(source: "USDA FoodKeeper", version: "1"),
            windows: [GuidanceWindow(storageType: .refrigerated, anchor: .added, days: days)]
        )
    }

    private func printed(_ label: PrintedDateLabel, daysFromNow days: Int) -> PrintedDate {
        PrintedDate(label: label, date: now.addingTimeInterval(Double(days) * 86_400))
    }

    @Test("the badge names the two states that need attention and nothing else")
    func badges() {
        #expect(AttentionText.badge(.pastGuidance) == "Past guidance")
        #expect(AttentionText.badge(.useSoon) == "Use soon")
        #expect(AttentionText.badge(.fine) == nil)
        #expect(AttentionText.badge(.unknown) == nil)
    }

    @Test("every date label has its own words")
    func labels() {
        let words = [PrintedDateLabel.useBy, .bestBy, .sellBy, .freezeBy, .packed, .unlabeled].map(AttentionText.label)

        #expect(words == ["Use by", "Best by", "Sell by", "Freeze by", "Packed", "Dated"])
    }

    @Test("a printed date is the reason when it is the earliest date")
    func printedDateIsTheReason() {
        let assessment = assess(printed: printed(.useBy, daysFromNow: 1), guidance: guidance(days: 5))

        #expect(AttentionText.reason(for: assessment) == "Use by \(AttentionText.day(now.addingTimeInterval(86_400)))")
    }

    @Test("sourced guidance is the reason when it comes before the printed date")
    func guidanceIsTheReason() {
        let assessment = assess(printed: printed(.bestBy, daysFromNow: 20), guidance: guidance(days: 2))

        #expect(AttentionText.reason(for: assessment) == "USDA FoodKeeper: about 2 days after adding it")
    }

    @Test("a single day is not pluralised")
    func singularDay() {
        #expect(AttentionText.reason(for: assess(guidance: guidance(days: 1))) == "USDA FoodKeeper: about 1 day after adding it")
    }

    @Test("a package's own instruction is the reason, in its own words")
    func instructionIsTheReason() {
        let assessment = assess(instruction: PackageInstruction(days: 3, anchor: .added, storageType: nil))

        #expect(AttentionText.reason(for: assessment) == "Package says use within 3 days of adding it")
    }

    @Test("food with no date and no guidance has no reason")
    func noReason() {
        #expect(AttentionText.reason(for: assess()) == nil)
    }

    @Test("the line under a name is the place, then the reason")
    func detail() {
        let entry = PantryEntry(
            package: Package(spaceID: SpaceID(), name: "Milk", location: LocationID(), addedAt: now),
            locationName: "Fridge",
            assessment: assess(guidance: guidance(days: 2))
        )

        #expect(AttentionText.detail(for: entry, showsLocation: true) == "Fridge · USDA FoodKeeper: about 2 days after adding it")
        #expect(AttentionText.detail(for: entry, showsLocation: false) == "USDA FoodKeeper: about 2 days after adding it")
    }

    @Test("a package whose place is unknown says so, and a plain one has no detail line")
    func detailEdges() {
        let package = Package(spaceID: SpaceID(), name: "Rice", location: LocationID(), addedAt: now)
        let entry = PantryEntry(package: package, locationName: nil, assessment: assess())

        #expect(AttentionText.detail(for: entry, showsLocation: true) == "Somewhere else")
        #expect(AttentionText.detail(for: entry, showsLocation: false) == "")
    }

    @Test("a printed date shows the same day whatever the device's time zone")
    func dayIsInUTC() throws {
        let printed = try #require(PrintedDate.onDay(.useBy, year: 2027, month: 3, day: 9))
        // The same instant, formatted for UTC, must name the 9th.
        let expected = printed.date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))

        #expect(AttentionText.day(printed.date) == expected)
        #expect(AttentionText.day(printed.date).contains("9"))
    }
}
