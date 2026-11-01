import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import Pantrified

@Suite("Edit food draft")
struct EditFoodDraftTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func package(
        name: String = "Mayonnaise", quantity: Quantity = .aboutHalf, printed: PrintedDate? = nil
    ) -> Package {
        Package(spaceID: SpaceID(), name: name, location: LocationID(), quantity: quantity, printedDate: printed, addedAt: now)
    }

    private func printed(_ label: PrintedDateLabel = .useBy, _ month: Int, _ day: Int) throws -> PrintedDate {
        try #require(PrintedDate.onDay(label, year: 2027, month: month, day: day))
    }

    @Test("an untouched form edits nothing and cannot be saved")
    func untouched() throws {
        let draft = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: calendar("UTC"))

        #expect(draft.edit(calendar: calendar("UTC")) == PackageEdit())
        #expect(!draft.canSave(calendar: calendar("UTC")))
    }

    @Test("the day on the package comes back unchanged in any time zone", arguments: ["UTC", "America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati"])
    func dayRoundTrips(zone: String) throws {
        let cal = calendar(zone)
        let draft = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: cal)

        #expect(cal.dateComponents([.year, .month, .day], from: draft.day) == DateComponents(year: 2027, month: 3, day: 9))
        #expect(draft.edit(calendar: cal) == PackageEdit())
    }

    @Test("spaces around the name are not a change, and a different name is")
    func nameChange() {
        var draft = EditFoodDraft(package: package(), now: now, calendar: calendar("UTC"))

        draft.name = "  Mayonnaise \n"
        #expect(draft.edit(calendar: calendar("UTC")) == PackageEdit())
        #expect(!draft.canSave(calendar: calendar("UTC")))

        draft.name = "Light mayo"
        #expect(draft.edit(calendar: calendar("UTC")) == PackageEdit(name: .set("Light mayo")))
        #expect(draft.canSave(calendar: calendar("UTC")))
    }

    @Test("an empty name cannot be saved, even with another field changed")
    func emptyName() {
        var draft = EditFoodDraft(package: package(), now: now, calendar: calendar("UTC"))
        draft.name = "   "
        draft.quantity = .low

        #expect(!draft.canSave(calendar: calendar("UTC")))
    }

    @Test("an exact amount stays a choice, so opening the form does not lose it")
    func exactQuantity() {
        let draft = EditFoodDraft(package: package(quantity: .exact(2, unit: "lb")), now: now, calendar: calendar("UTC"))

        #expect(draft.quantityChoices.contains(.exact(2, unit: "lb")))
        #expect(draft.quantityChoices.prefix(4) == [.unknown, .full, .aboutHalf, .low])
        #expect(draft.edit(calendar: calendar("UTC")) == PackageEdit())
    }

    @Test("a new amount is the only thing set")
    func quantityChange() {
        var draft = EditFoodDraft(package: package(), now: now, calendar: calendar("UTC"))
        draft.quantity = .low

        #expect(draft.edit(calendar: calendar("UTC")) == PackageEdit(quantity: .set(.low)))
    }

    @Test("changing, clearing and adding a date")
    func dates() throws {
        let cal = calendar("America/Los_Angeles")
        var changed = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: cal)
        changed.day = try #require(cal.date(from: DateComponents(year: 2027, month: 4, day: 9, hour: 12)))
        #expect(changed.edit(calendar: cal) == PackageEdit(printedDate: .set(try printed(4, 9))))

        var relabeled = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: cal)
        relabeled.label = .bestBy
        #expect(relabeled.edit(calendar: cal) == PackageEdit(printedDate: .set(try printed(.bestBy, 3, 9))))

        var cleared = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: cal)
        cleared.hasDate = false
        #expect(cleared.edit(calendar: cal) == PackageEdit(printedDate: .set(nil)))

        var added = EditFoodDraft(package: package(), now: now, calendar: cal)
        added.hasDate = true
        added.day = try #require(cal.date(from: DateComponents(year: 2027, month: 5, day: 1, hour: 12)))
        #expect(added.edit(calendar: cal) == PackageEdit(printedDate: .set(try printed(5, 1))))
    }

    @Test("a day the form cannot read as a real date leaves the date as it was")
    func unreadableDayKeepsDate() throws {
        let cal = calendar("UTC")
        var draft = EditFoodDraft(package: package(printed: try printed(3, 9)), now: now, calendar: cal)
        draft.day = Date(timeIntervalSince1970: 0)   // 1970, outside the days a printed date can name

        #expect(draft.edit(calendar: cal) == PackageEdit())
    }

    @Test("a food's own date label is offered even when it is not a usual one")
    func ownLabelOffered() throws {
        let draft = EditFoodDraft(package: package(printed: try printed(.unlabeled, 3, 9)), now: now, calendar: calendar("UTC"))

        #expect(draft.labelChoices.contains(.unlabeled))
        #expect(EditFoodDraft(package: package(), now: now, calendar: calendar("UTC")).labelChoices == [.useBy, .bestBy, .sellBy, .freezeBy, .packed])
    }
}
