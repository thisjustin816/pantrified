import CoreGraphics
import CoreVideo
import Foundation
import Testing
import UIKit
import PantrifiedDomain
@testable import Pantrified

/// Vision runs here on the simulator against text drawn by the test, not on a camera photo of a
/// real package.
@Suite("Text recognizer")
struct TextRecognizerTests {
    /// When the drawn package was "photographed", so its date is plausible.
    private let takenAt = PrintedDateParser.utcCalendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
    private let expected = PrintedDateParser.utcCalendar.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: 12))!

    /// Black text on white, the way a label looks when it is in focus and well lit.
    private func label(_ lines: [String]) throws -> CGImage {
        let size = CGSize(width: 1200, height: 160 * lines.count + 80)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 40, y: 40 + 160 * index), withAttributes: attributes)
            }
        }
        return try #require(image.cgImage)
    }

    private func pixelBuffer(_ image: CGImage) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let options = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, options, &made)
        let buffer = try #require(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = try #require(CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private func proposal(_ text: RecognizedLines) -> PrintedDate? {
        guard let reading = PrintedDateRecognition().proposal(in: [text], at: takenAt),
              case .resolved(let date, _) = reading.value else { return nil }
        return PrintedDate(label: reading.label, date: date)
    }

    @Test("a printed date in an image is read and proposed with its label")
    func readsDateFromImage() throws {
        let text = try TextRecognizer.text(in: try label(["BEST BY", "DEC 05 2026"]))

        #expect(!text.lines.isEmpty)
        #expect(proposal(text) == PrintedDate(label: .bestBy, date: expected))
    }

    @Test("a pixel buffer the caller owns is read the same way")
    func readsDateFromPixelBuffer() throws {
        let text = try TextRecognizer.text(in: try pixelBuffer(try label(["BEST BY DEC 05 2026"])))

        #expect(proposal(text) == PrintedDate(label: .bestBy, date: expected))
    }

    @Test("an image with no text gives no lines")
    func blankImage() throws {
        let text = try TextRecognizer.text(in: try label([]))

        #expect(text.lines.isEmpty)
    }
}
