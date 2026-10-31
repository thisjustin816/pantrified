import Foundation
import PantrifiedDomain

/// One barcode a camera reported in one frame.
public struct BarcodeRead: Sendable, Hashable {
    public var payload: String
    public var symbology: BarcodeSymbology

    public init(payload: String, symbology: BarcodeSymbology) {
        self.payload = payload
        self.symbology = symbology
    }
}

public enum BarcodeScanEvent: Sendable, Hashable {
    /// A food product's barcode, seen in enough frames to trust. The scan is over.
    case product(GTIN)
    /// A barcode that is not a food product's. Reported once while it stays in view.
    case refused(GTINRejection)
}

/// Turns what a camera reports frame after frame into at most one event per barcode, so a code
/// held in view is announced once. A product needs to be read the same way in more than one frame,
/// which keeps a single misread frame from naming the wrong product.
public struct BarcodeScan: Sendable {
    private let confirmations: Int
    private let forgetAfter: TimeInterval
    private var sightings: [GTIN: (count: Int, last: Date)] = [:]
    private var refusals: [BarcodeRead: Date] = [:]
    public private(set) var product: GTIN?

    /// `forgetAfter` is how long a barcode must be out of view before it counts as new again.
    public init(confirmations: Int = 2, forgetAfter: TimeInterval = 2) {
        self.confirmations = max(1, confirmations)
        self.forgetAfter = forgetAfter
    }

    /// The event the reads of one frame cause, if any. Nothing happens once a product is found.
    public mutating func receive(_ reads: [BarcodeRead], at time: Date) -> BarcodeScanEvent? {
        guard product == nil else { return nil }
        var refused: [(BarcodeRead, GTINRejection)] = []
        var counted: Set<GTIN> = []
        for read in reads {
            switch GTIN.scanned(read.payload, as: read.symbology) {
            case .success(let gtin):
                // A frame counts once for a product, even when it shows two of its barcodes.
                guard counted.insert(gtin).inserted else { continue }
                let previous = sightings[gtin].flatMap { time.timeIntervalSince($0.last) <= forgetAfter ? $0.count : nil } ?? 0
                sightings[gtin] = (previous + 1, time)
                if previous + 1 >= confirmations {
                    product = gtin
                    return .product(gtin)
                }
            case .failure(let reason):
                refused.append((read, reason))
            }
        }
        var event: BarcodeScanEvent?
        for (read, reason) in refused {
            let isNew = refusals[read].map { time.timeIntervalSince($0) > forgetAfter } ?? true
            refusals[read] = time
            if isNew, event == nil { event = .refused(reason) }
        }
        return event
    }
}
