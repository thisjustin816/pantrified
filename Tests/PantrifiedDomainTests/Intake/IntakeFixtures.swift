import Foundation
import PantrifiedDomain

/// Synthetic photo observations. Nothing here comes from a real photo: these fixtures test the rules,
/// not recognition quality.
enum Fixture {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A valid EAN-13 product barcode built from 12 digits, with its check digit.
    static func gtin(_ twelve: String) -> GTIN {
        let digits = twelve.compactMap(\.wholeNumberValue)
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        let check = (10 - sum % 10) % 10
        guard case .success(let gtin) = GTIN.scanned(twelve + String(check), as: .ean13) else {
            fatalError("fixture barcode is not a product barcode")
        }
        return gtin
    }

    static let yogurt = gtin("400638133393")
    static let otherYogurt = gtin("400638133394")
    static let beans = gtin("501234567890")
    static let soup = gtin("761234567890")

    /// A line of text; `size` is its height as a share of the photo, so a bigger size is more prominent.
    static func line(_ text: String, row: Double = 0.1, size: Double = 0.04, x: Double = 0.1, confidence: Double? = 0.9) -> RecognizedTextLine {
        RecognizedTextLine(text: text, box: NormalizedBox(x: x, y: row, width: 0.6, height: size), confidence: confidence)!
    }

    /// A front label: a big name, optionally a brand above it, and some small print.
    static func front(_ name: String, brand: String? = nil, small: [String] = []) -> [RecognizedTextLine] {
        var lines: [RecognizedTextLine] = []
        if let brand { lines.append(line(brand, row: 0.08, size: 0.09)) }
        lines.append(line(name, row: 0.2, size: 0.1))
        for (offset, text) in small.enumerated() { lines.append(line(text, row: 0.6 + Double(offset) * 0.04, size: 0.025)) }
        return lines
    }

    /// A back panel: small print only, including a nutrition panel full of numbers and percentages.
    static func back(_ text: [String]) -> [RecognizedTextLine] {
        let panel = ["Nutrition Facts", "Serving size 1 cup (227g)", "Total Fat 0g 0%", "Sodium 65mg 3%", "Protein 15g 30%"]
        return (text + panel).enumerated().map { line($1, row: 0.05 + Double($0) * 0.05, size: 0.025) }
    }

    static func photo(
        _ sequence: Int,
        seconds: Double? = nil,
        lines: [RecognizedTextLine] = [],
        codes: [CodeMeaning] = [],
        print: [Float]? = nil,
        digest: String? = nil,
        id: IntakePhotoID = IntakePhotoID()
    ) -> PhotoObservation {
        PhotoObservation(
            photo: id, sequence: sequence, capturedAt: start.addingTimeInterval(seconds ?? Double(sequence) * 6),
            lines: lines, codes: codes, featurePrint: print.flatMap(FeaturePrint.init), contentDigest: digest
        )
    }

    /// A feature print `distance` away from `base` along one axis.
    static func print(_ base: Int, offset distance: Float = 0) -> [Float] {
        var values = [Float](repeating: 0, count: 16)
        values[base % 16] = 1
        values[(base + 1) % 16] += distance
        return values
    }
}

extension GroupingResult {
    /// The groups as lists of sequence numbers, for readable expectations.
    func sequences(_ photos: [PhotoObservation]) -> [[Int]] {
        let byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.photo, $0.sequence) })
        return groups.map { $0.photos.compactMap { byID[$0] } }
    }
}
