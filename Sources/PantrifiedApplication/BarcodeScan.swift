import Foundation
import PantrifiedDomain

/// One code a camera reported in one frame. A QR code's payload is read once, in the frame that
/// carries it, and only a product number taken from it is kept.
public struct BarcodeRead: Sendable, Hashable {
    public var payload: String
    public var symbology: CodeSymbology

    public init(payload: String, symbology: CodeSymbology) {
        self.payload = payload
        self.symbology = symbology
    }
}

public enum BarcodeScanEvent: Sendable, Hashable {
    /// A food product's barcode, seen in enough frames to trust. The scan is over.
    case product(GTIN)
    /// A barcode that is not a food product's. Reported once while it stays in view.
    case refused(GTINRejection)
    /// A QR code that does not name one food product. Reported once while any such code stays in
    /// view.
    case unusableQRCode
}

/// Turns what a camera reports frame after frame into at most one event per barcode, so a code
/// held in view is announced once. A product needs to be read the same way in more than one frame,
/// which keeps a single misread frame from naming the wrong product.
///
/// A QR code names a product only when it holds a GS1 Digital Link with an accepted GTIN, read by
/// the same rules as a batch photo's codes (`CodeMeaning`), and only when that GTIN is the one
/// product the frame shows. Every other QR code is unusable. Its text is never kept, so unusable
/// QR codes are suppressed together rather than one by one.
public struct BarcodeScan: Sendable {
    private let confirmations: Int
    private let forgetAfter: TimeInterval
    private var sightings: [GTIN: (count: Int, last: Date)] = [:]
    private var refusals: [BarcodeRead: Date] = [:]
    private var unusableQRSeen: Date?
    public private(set) var product: GTIN?

    /// `forgetAfter` is how long a barcode must be out of view before it counts as new again.
    public init(confirmations: Int = 2, forgetAfter: TimeInterval = 2) {
        self.confirmations = max(1, confirmations)
        self.forgetAfter = forgetAfter
    }

    /// The event the reads of one frame cause, if any. Nothing happens once a product is found.
    public mutating func receive(_ reads: [BarcodeRead], at time: Date) -> BarcodeScanEvent? {
        guard product == nil else { return nil }
        var products: [GTIN] = []
        var qrProducts: [GTIN] = []
        var refused: [(BarcodeRead, GTINRejection)] = []
        var unusableQR = false
        for read in reads {
            guard let retail = Self.retail(read.symbology) else {
                if case .product(let gtin) = CodeMeaning.classify(payload: read.payload, symbology: .qr) {
                    if !qrProducts.contains(gtin) { qrProducts.append(gtin) }
                } else {
                    unusableQR = true
                }
                continue
            }
            switch GTIN.scanned(read.payload, as: retail) {
            case .success(let gtin):
                // A frame counts once for a product, even when it shows two of its barcodes.
                if !products.contains(gtin) { products.append(gtin) }
            case .failure(let reason):
                refused.append((read, reason))
            }
        }
        // A QR code could be a sticker on something else, so a frame showing another product
        // beside it, by barcode or by QR code, leaves the QR codes unused.
        if qrProducts.count == 1, products.allSatisfy({ $0 == qrProducts[0] }) {
            if products.isEmpty { products = qrProducts }
        } else if !qrProducts.isEmpty {
            unusableQR = true
        }
        for gtin in products {
            let previous = sightings[gtin].flatMap { time.timeIntervalSince($0.last) <= forgetAfter ? $0.count : nil } ?? 0
            sightings[gtin] = (previous + 1, time)
            if previous + 1 >= confirmations {
                product = gtin
                return .product(gtin)
            }
        }
        var event: BarcodeScanEvent?
        for (read, reason) in refused {
            let isNew = refusals[read].map { time.timeIntervalSince($0) > forgetAfter } ?? true
            refusals[read] = time
            if isNew, event == nil { event = .refused(reason) }
        }
        if unusableQR {
            let isNew = unusableQRSeen.map { time.timeIntervalSince($0) > forgetAfter } ?? true
            unusableQRSeen = time
            if isNew, event == nil { event = .unusableQRCode }
        }
        return event
    }

    private static func retail(_ symbology: CodeSymbology) -> BarcodeSymbology? {
        switch symbology {
        case .ean13: .ean13
        case .ean8: .ean8
        case .upcA: .upcA
        case .upcE: .upcE
        case .qr: nil
        }
    }
}
