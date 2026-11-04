import Foundation
import Testing
@testable import PantrifiedApplication
import PantrifiedDomain

@Suite("Copy what the app read: the export")
struct ReadExportTests {
    typealias Sample = ReadExportSample

    private func sequence(_ review: IntakeReview, _ number: Int) -> IntakePhotoID {
        review.observations.values.first { $0.sequence == number }!.photo
    }

    private func json(_ export: ReadExport) throws -> String {
        String(decoding: try export.encoded(), as: UTF8.self)
    }

    // MARK: Format

    @Test("an export encodes to readable JSON with sorted keys, the same bytes every time, and decodes to itself")
    func encoding() throws {
        let export = ReadExportDraft(source: Sample.source()).export()
        let data = try export.encoded()
        #expect(try export.encoded() == data)
        #expect(try ReadExport.decode(data) == export)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n"))
        #expect(text.contains("\"format\" : \"pantrified.read-export\""))
        #expect(text.contains("\"version\" : 1"))
        let topLevel = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { $0.split(separator: "\"")[1] }
        #expect(topLevel == topLevel.sorted())
        #expect(topLevel.count == 12)
    }

    @Test("decoding refuses a file that is not an export, and a newer version")
    func decodingRefuses() throws {
        #expect(throws: ReadExportError.notAnExport) { try ReadExport.decode(Data("{\"format\":\"other\",\"version\":1}".utf8)) }
        #expect(throws: ReadExportError.notAnExport) { try ReadExport.decode(Data("[]".utf8)) }
        var export = ReadExportDraft(source: Sample.source()).export()
        export.version = ReadExport.currentVersion + 1
        #expect(throws: ReadExportError.unsupportedVersion(ReadExport.currentVersion + 1)) { try ReadExport.decode(export.encoded()) }
    }

    @Test("the file holds no photo identity, digest, feature print, place name or absolute time")
    func nothingIdentifying() throws {
        let review = Sample.review()
        let text = try json(ReadExportDraft(source: Sample.source(review)).export())
        for observation in review.observations.values {
            #expect(!text.contains(observation.photo.rawValue.uuidString))
            #expect(!text.lowercased().contains(observation.photo.rawValue.uuidString.lowercased()))
        }
        for candidate in review.candidates {
            #expect(!text.contains(candidate.id.rawValue.uuidString))
        }
        #expect(!text.contains(Sample.space.rawValue.uuidString))
        #expect(!text.contains("ab12"))
        for location in Sample.locations {
            #expect(!text.contains(location.name))
            #expect(!text.contains(location.id.rawValue.uuidString))
        }
        // The feature prints hold 0.3 and 0.7 off one axis; only their distances may appear.
        #expect(!text.contains("\"values\""))
        #expect(!text.contains("featurePrint\""))
        #expect(!text.contains("1800000000"))
        #expect(!text.contains("2027-01-15T"))
        #expect(!text.contains("capturedAt"))
    }

    // MARK: Photos, codes and pairs

    @Test("each photo has its sequence, seconds after the first, role, panel, print and copy, and its lines and codes")
    func photos() throws {
        let export = ReadExportDraft(source: Sample.source()).export()
        #expect(export.batchDay == "2027-01-15")
        #expect(export.app == Sample.app)
        #expect(export.photos.map(\.sequence) == Array(0...8))
        #expect(export.photos.map(\.secondsAfterFirst) == [0, 5, 45, 57, 97, 137, 177, 217, 222])
        #expect(export.photos.map(\.role) == [.front, .other, .front, .front, .other, .front, .back, .other, .other])
        #expect(export.photos.map(\.showsPanel) == [false, false, false, false, false, false, true, false, false])
        #expect(export.photos.map(\.hasFeaturePrint) == [true, true, true, true, false, false, false, false, false])
        #expect(export.photos.map(\.sameBytesAs) == [nil, nil, nil, nil, nil, nil, nil, nil, 7])
        let first = try #require(export.photos.first?.lines.first)
        #expect(first == ReadExport.Line(text: "CHOBANI", box: .init(x: 0.1, y: 0.08, width: 0.7, height: 0.09), confidence: 0.9))
        #expect(export.photos[5].codes == [ReadExport.Code(kind: .link, product: nil, refused: nil)])
        #expect(export.photos[6].codes == [
            ReadExport.Code(kind: .product, product: IntakeFixture.beans.digits, refused: nil),
            ReadExport.Code(kind: .refused, product: nil, refused: .coupon),
        ])
    }

    @Test("times, boxes and confidences are rounded")
    func rounding() throws {
        let photos = [
            Sample.photo(0, 0, [Sample.line("Greek yogurt", row: 0.123456, size: 0.0987654, confidence: 0.876543)]),
            Sample.photo(1, 3.14159, [Sample.line("Basmati rice", row: 0.2)]),
        ]
        let export = ReadExportDraft(source: Sample.source(Sample.review(photos))).export()
        #expect(export.photos[1].secondsAfterFirst == 3.1)
        let line = try #require(export.photos[0].lines.first)
        #expect(line.box.y == 0.123)
        #expect(line.box.height == 0.099)
        #expect(line.confidence == 0.877)
    }

    @Test("each pair has its photos by sequence, its distance, each signal's points, and its score")
    func pairs() throws {
        let export = ReadExportDraft(source: Sample.source()).export()
        let yogurt = try #require(export.pairs.first { $0.first == 0 && $0.second == 1 })
        #expect(yogurt.distance == 0.3)
        #expect(yogurt.signals == [
            SignalPoints(signal: .similarImage, points: 25), SignalPoints(signal: .sharedLabelWords, points: 50),
            SignalPoints(signal: .takenRightAfter, points: 15),
        ])
        #expect(yogurt.score == 90)
        let soup = try #require(export.pairs.first { $0.first == 7 && $0.second == 8 })
        #expect(soup.distance == nil)
        #expect(soup.signals.map(\.signal).contains(.identicalPhoto))
        let baking = try #require(export.pairs.first { $0.first == 2 && $0.second == 3 })
        #expect(baking.distance == 0.7)
        #expect(baking.signals.last == SignalPoints(signal: .differentLabelWords, points: 0))
        #expect(export.distanceKeptUpTo == 1.0)
    }

    // MARK: Groups, proposals and lookups

    @Test("groups and suggestions are the batch's grouping, by photo sequence and group index")
    func groups() throws {
        let review = Sample.review()
        let export = ReadExportDraft(source: Sample.source(review)).export()
        #expect(export.groups.map(\.photos) == [[0, 1], [2], [3], [4], [5], [6], [7, 8]])
        #expect(export.groups[0].barcode == IntakeFixture.yogurt.digits)
        #expect(export.groups[0].links == [
            ReadExport.Link(photo: 1, matchedWith: 0, signals: [.similarImage, .sharedLabelWords, .takenRightAfter], score: 90),
        ])
        #expect(export.suggestions == [
            ReadExport.Suggestion(first: 1, second: 2, signals: [.someLabelWords, .takenRightAfter, .differentLabelWords], score: 40),
        ])
    }

    @Test("each group's proposals say where they came from: label name, lookup, date, place by kind and position")
    func proposals() throws {
        let export = ReadExportDraft(source: Sample.source()).export()
        let yogurt = export.groups[0].proposals
        #expect(yogurt.labelName == ReadExport.Name(text: "Chobani greek yogurt", withheld: nil))
        #expect(yogurt.nameSource == .label)
        #expect(yogurt.date == ReadExport.DateRead(label: .useBy, date: "2027-02-01", monthFirst: nil, dayFirst: nil, withheld: nil))
        #expect(yogurt.place == ReadExport.Place(kind: .fridge, position: 1, source: .standard))
        let rice = export.groups[3].proposals
        #expect(rice.date == ReadExport.DateRead(label: .bestBy, date: nil, monthFirst: "2028-05-06", dayFirst: "2028-06-05", withheld: nil))
        let peas = export.groups[4].proposals
        #expect(peas.place == ReadExport.Place(kind: .freezer, position: 2, source: .label))
        #expect(peas.sawLink)
        let beans = export.groups[5].proposals
        #expect(beans.nameSource == .lookup)
        #expect(beans.refusedCodes == [.coupon])
        #expect(export.groups[6].proposals.nameSource == .label)
    }

    @Test("lookups are kept by barcode with the name as returned, the service, and failed attempts")
    func lookups() {
        let export = ReadExportDraft(source: Sample.source()).export()
        #expect(export.lookups == [
            ReadExport.Lookup(barcode: IntakeFixture.yogurt.digits, answer: .notFound, name: nil, service: nil, attempts: nil),
            ReadExport.Lookup(
                barcode: IntakeFixture.beans.digits, answer: .found, name: .init(text: "Black beans", withheld: nil),
                service: "USDA FoodData Central", attempts: nil
            ),
            ReadExport.Lookup(barcode: Sample.soup.digits, answer: .failed, name: nil, service: nil, attempts: 1),
        ])
    }

    // MARK: Corrections

    @Test("an untouched review records each group as its own package, with nothing decided by the person")
    func untouched() {
        let export = ReadExportDraft(source: Sample.source()).export()
        #expect(export.corrections.packages.map(\.photos) == export.groups.map(\.photos))
        #expect(export.corrections.packages.map(\.fromGroups) == export.groups.indices.map { [$0] })
        #expect(export.corrections.packages.allSatisfy { !$0.mergedByPerson && !$0.nameDecided && !$0.dateDecided })
        #expect(export.corrections.packages[1].suggestedWith == [2])
        #expect(export.corrections.splitGroups.isEmpty)
        #expect(export.corrections.deletedPhotos.isEmpty)
    }

    @Test("the person's merges, splits, names, dates, places, deletions and adds are recorded as ground truth")
    func corrections() throws {
        var review = Sample.review()
        let soda = try #require(Sample.candidate(review, showing: 2)).id
        let powder = try #require(Sample.candidate(review, showing: 3)).id
        let yogurt = try #require(Sample.candidate(review, showing: 0)).id
        let rice = try #require(Sample.candidate(review, showing: 4)).id
        let peas = try #require(Sample.candidate(review, showing: 5)).id
        let beans = try #require(Sample.candidate(review, showing: 6)).id
        let merged = try review.merge([soda, powder])
        try review.split(sequence(review, 1), from: yogurt)
        try review.setName("Baking things", for: merged)
        try review.setDate(PrintedDate.onDay(.bestBy, year: 2028, month: 6, day: 5), for: rice)
        review.assignLocation(Sample.shelf.id, to: [rice])
        review.delete([peas])
        review.beginAdd([beans])
        review.markAdded([beans])

        let export = ReadExportDraft(source: Sample.source(review)).export()
        let packages = export.corrections.packages
        #expect(packages.map(\.photos) == [[0], [1], [2, 3], [4], [6], [7, 8]])
        #expect(packages[2].fromGroups == [1, 2])
        #expect(packages[2].mergedByPerson)
        #expect(packages[2].nameDecided)
        #expect(packages[2].name == ReadExport.Name(text: "Baking things", withheld: nil))
        #expect(packages[3].dateDecided)
        #expect(packages[3].date?.date == "2028-06-05")
        #expect(packages[3].place == ReadExport.Place(kind: .pantry, position: 3, source: .person))
        #expect(packages[4].status == .added)
        #expect(export.corrections.splitGroups == [0])
        #expect(export.corrections.deletedPhotos == [5])
        // The groups still record what the app did before the person's changes.
        #expect(export.groups.map(\.photos) == [[0, 1], [2], [3], [4], [5], [6], [7, 8]])
    }

    // MARK: Leaving things out

    @Test("a line the check flags starts left out, can be put back, and any line can be left out")
    func lines() throws {
        var draft = ReadExportDraft(source: Sample.source())
        let phone = ReadExportDraft.LineKey(photo: 6, index: 1)
        #expect(draft.photos[6].lines[1].flag == .phone)
        #expect(!draft.includes(phone))
        var export = draft.export()
        #expect(export.photos[6].lines.map(\.text) == ["Ingredients: black beans, water, salt"])
        #expect(export.withheld.lines == 1)
        #expect(export.withheld.linesByCheck == 1)

        draft.setIncluded(true, line: phone)
        export = draft.export()
        #expect(export.photos[6].lines.count == 2)
        #expect(export.withheld.lines == 0)
        #expect(export.withheld.linesByCheck == 0)

        draft.setIncluded(false, line: .init(photo: 0, index: 2))
        export = draft.export()
        #expect(export.photos[0].lines.map(\.text) == ["CHOBANI", "GREEK YOGURT"])
        #expect(export.withheld.lines == 1)
        #expect(export.withheld.linesByCheck == 0)
        // Photo 1 shows the same words, so they appear once.
        #expect(try json(export).components(separatedBy: "\"Plain nonfat\"").count == 2)
    }

    @Test("a photo left out keeps its place in the batch but loses its lines and codes")
    func photoLeftOut() throws {
        var draft = ReadExportDraft(source: Sample.source())
        draft.setIncluded(false, photo: 6)
        let export = draft.export()
        #expect(!draft.includes(.init(photo: 6, index: 0)))
        #expect(export.photos[6].removed)
        #expect(export.photos[6].lines.isEmpty)
        #expect(export.photos[6].codes.isEmpty)
        #expect(export.withheld.photos == [6])
        // Lines of a removed photo are not counted again as lines left out.
        #expect(export.withheld.lines == 0)
        #expect(export.groups[5].photos == [6])
        let text = try json(export)
        #expect(!text.contains("black beans"))
    }

    @Test("a barcode shown only on photos left out is left out everywhere, with its lookup")
    func barcodeLeftOut() throws {
        var draft = ReadExportDraft(source: Sample.source())
        draft.setIncluded(false, photo: 6)
        let export = draft.export()
        #expect(export.groups[5].barcode == nil)
        #expect(!export.lookups.contains { $0.barcode == IntakeFixture.beans.digits })
        #expect(export.withheld.barcodes == 1)
        #expect(!draft.includes(.lookup(barcode: IntakeFixture.beans.digits)))
        let text = try json(export)
        #expect(!text.contains(IntakeFixture.beans.digits))
        #expect(!text.contains("Black beans"))
    }

    @Test("a barcode another included photo shows stays")
    func barcodeKept() {
        var draft = ReadExportDraft(source: Sample.source())
        draft.setIncluded(false, photo: 8)
        let export = draft.export()
        #expect(export.groups[6].barcode == Sample.soup.digits)
        #expect(export.lookups.contains { $0.barcode == Sample.soup.digits })
        #expect(export.withheld.barcodes == 0)
    }

    @Test("a label name from a line left out is left out too; one from other lines stays")
    func labelNameFromLine() throws {
        var draft = ReadExportDraft(source: Sample.source())
        draft.setIncluded(false, line: .init(photo: 2, index: 1))
        #expect(!draft.includes(.label(group: 1)))
        #expect(draft.includes(.label(group: 0)))
        let export = draft.export()
        #expect(export.groups[1].proposals.labelName == ReadExport.Name(text: nil, withheld: true))
        #expect(export.groups[1].proposals.nameSource == .label)
        #expect(export.withheld.names == 1)

        draft.setIncluded(true, line: .init(photo: 2, index: 1))
        draft.setIncluded(false, line: .init(photo: 0, index: 2))
        #expect(draft.export().groups[0].proposals.labelName?.text == "Chobani greek yogurt")
        #expect(draft.export().withheld.names == 0)
    }

    @Test("a date read from a line left out is left out too")
    func dateFromLine() {
        var draft = ReadExportDraft(source: Sample.source())
        draft.setIncluded(false, line: .init(photo: 1, index: 2))
        #expect(draft.export().groups[0].proposals.date == ReadExport.DateRead(
            label: nil, date: nil, monthFirst: nil, dayFirst: nil, withheld: true
        ))
    }

    @Test("names are listed for the preview, and any of them can be left out")
    func names() throws {
        var review = Sample.review()
        let rice = try #require(Sample.candidate(review, showing: 4)).id
        try review.setName("Rice from Dr. Smith", for: rice)
        var draft = ReadExportDraft(source: Sample.source(review))
        #expect(draft.names.map(\.id) == [
            .label(group: 0), .label(group: 1), .label(group: 2), .label(group: 3), .label(group: 4), .label(group: 6),
            .lookup(barcode: IntakeFixture.beans.digits), .person(package: 3),
        ])
        let person = try #require(draft.names.last)
        #expect(person.text == "Rice from Dr. Smith")
        #expect(person.flag == .personName)
        #expect(person.photos == [4])
        #expect(!draft.includes(person.id))
        #expect(draft.export().corrections.packages[3].name == ReadExport.Name(text: nil, withheld: true))
        #expect(draft.export().corrections.packages[3].nameDecided)

        draft.setIncluded(true, name: person.id)
        #expect(draft.export().corrections.packages[3].name?.text == "Rice from Dr. Smith")

        draft.setIncluded(false, name: .lookup(barcode: IntakeFixture.beans.digits))
        draft.setIncluded(false, name: .label(group: 0))
        let export = draft.export()
        #expect(export.lookups[1].name == ReadExport.Name(text: nil, withheld: true))
        #expect(export.lookups[1].answer == .found)
        #expect(export.groups[0].proposals.labelName == ReadExport.Name(text: nil, withheld: true))
        #expect(export.withheld.names == 2)
        #expect(!(try json(export)).contains("Black beans"))
    }
}
