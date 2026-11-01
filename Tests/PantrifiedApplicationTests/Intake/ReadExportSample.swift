import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// A synthetic batch for the export tests. Nothing here comes from a real photo.
enum ReadExportSample {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let space = SpaceID()
    static let fridge = StorageLocation(name: "Kitchen fridge", storageType: .refrigerated)
    static let freezer = StorageLocation(name: "Garage freezer", storageType: .frozen)
    static let shelf = StorageLocation(name: "Pantry shelf", storageType: .roomTemperature)
    static let locations = [fridge, freezer, shelf]
    static let app = ReadExport.AppInfo(version: "0.1", build: "57", system: "iOS 27.0", device: "iPhone17,1")
    static let soup = IntakeFixture.gtin("761234567890")

    static func line(_ text: String, row: Double, size: Double = 0.03, confidence: Double? = 0.9) -> RecognizedTextLine {
        RecognizedTextLine(text: text, box: NormalizedBox(x: 0.1, y: row, width: 0.7, height: size), confidence: confidence)!
    }

    /// A unit vector along `axis`, moved `offset` along the next axis.
    static func print(_ axis: Int, offset: Float = 0) -> FeaturePrint {
        var values = [Float](repeating: 0, count: 8)
        values[axis] = 1
        values[axis + 1] += offset
        return FeaturePrint(values)!
    }

    /// One photo: its lines, codes and print, taken `seconds` after the first.
    static func photo(
        _ sequence: Int,
        _ seconds: Double,
        _ lines: [RecognizedTextLine],
        codes: [CodeMeaning] = [],
        print: FeaturePrint? = nil,
        digest: String? = nil
    ) -> PhotoObservation {
        PhotoObservation(
            photo: IntakePhotoID(), sequence: sequence, capturedAt: start.addingTimeInterval(seconds), lines: lines, codes: codes,
            featurePrint: print, contentDigest: digest
        )
    }

    /// A front and back of yogurt, baking soda and baking powder kept apart, rice with a date that
    /// reads two ways, frozen peas, a can of beans whose back gives a phone number, a soup photographed
    /// twice with the same bytes, and a QR code with a link.
    static var photos: [PhotoObservation] {
        [
            photo(0, 0, [line("CHOBANI", row: 0.08, size: 0.09), line("GREEK YOGURT", row: 0.2, size: 0.1), line("Plain nonfat", row: 0.6)],
                  print: print(0)),
            photo(1, 5, [line("Chobani greek yogurt", row: 0.1), line("Plain nonfat", row: 0.2), line("USE BY 2027-02-01", row: 0.8, size: 0.02)],
                  codes: [.product(IntakeFixture.yogurt)], print: print(0, offset: 0.3)),
            photo(2, 45, [line("ARM & HAMMER", row: 0.08, size: 0.09), line("BAKING SODA", row: 0.2, size: 0.1)], print: print(2)),
            photo(3, 57, [line("CLABBER GIRL", row: 0.08, size: 0.09), line("BAKING POWDER", row: 0.2, size: 0.1)],
                  print: print(2, offset: 0.7)),
            photo(4, 97, [line("Basmati rice", row: 0.2, size: 0.1), line("BEST BEFORE 05/06/28", row: 0.85, size: 0.02)]),
            photo(5, 137, [line("Birds Eye", row: 0.08, size: 0.08), line("Sweet peas", row: 0.2, size: 0.1),
                           line("KEEP FROZEN", row: 0.9, size: 0.02)], codes: [.link]),
            photo(6, 177, [line("Ingredients: black beans, water, salt", row: 0.5, size: 0.02),
                           line("Questions? Call 1-800-555-0199", row: 0.9, size: 0.02)],
                  codes: [.product(IntakeFixture.beans), .refused(.coupon)]),
            photo(7, 217, [line("Tomato soup", row: 0.2, size: 0.1)], codes: [.product(soup)], digest: "ab12"),
            photo(8, 222, [line("Tomato soup", row: 0.2, size: 0.1)], codes: [.product(soup)], digest: "ab12"),
        ]
    }

    static func review(_ photos: [PhotoObservation] = photos) -> IntakeReview {
        var review = IntakeReview(
            space: space, observations: photos, grouping: PhotoGrouper().group(photos), locations: locations,
            defaultLocation: fridge.id, looksUp: true
        )
        review.record(.found(rawName: "Black beans", source: "USDA FoodData Central"), for: IntakeFixture.beans)
        review.record(.notFound, for: IntakeFixture.yogurt)
        review.record(.failed(attempts: 1), for: soup)
        return review
    }

    static func source(_ review: IntakeReview = review()) -> ReadExportSource {
        ReadExportSource(app: app, review: review, locations: locations)
    }

    /// The candidate whose photos include the photo at `sequence`.
    static func candidate(_ review: IntakeReview, showing sequence: Int) -> IntakeCandidate? {
        let photo = review.observations.values.first { $0.sequence == sequence }?.photo
        return review.candidates.first { candidate in photo.map(candidate.photos.contains) ?? false }
    }
}
