import Foundation
import PantrifiedApplication
import PantrifiedDomain

/// The words batch intake shows, in one place so they stay plain and consistent.
enum IntakeText {
    /// What the batch screen says about photos. Must match the camera usage description and PRIVACY.md.
    static let photosStayHere = "Photos stay on this iPhone and are never saved to your photo library. While Pantrified is open, it deletes them a day after you finish this batch, or 3 days after you last use it."

    static let expired = "An unfinished batch was deleted after 3 days without use."

    static let damagedBatch = "A batch couldn't be opened because its record was damaged. Its photos are deleted within a day."

    static let newerVersion = "These batch photos were saved by a newer version of Pantrified. Update the app to open them. You can still add food by hand."

    static func added(_ count: Int) -> String {
        count == 1 ? "Added 1 food" : "Added \(count) foods"
    }

    static func addAll(_ count: Int) -> String {
        count == 1 ? "Add 1 food" : "Add all \(count)"
    }

    static func waiting(_ count: Int) -> String {
        count == 1 ? "1 item needs a name before it can be added." : "\(count) items need a name before they can be added."
    }

    static func reading(_ progress: IntakeProgress) -> String {
        "Reading photo \(min(progress.read + 1, max(progress.total, 1))) of \(max(progress.total, 1))"
    }

    static func photoCount(_ count: Int) -> String {
        count == 1 ? "1 photo" : "\(count) photos"
    }

    static func nameOrigin(_ origin: NameOrigin?) -> String? {
        switch origin {
        case .lookup(let source)?: "From \(source)"
        case .label?: "Read from the label. Check it."
        case .person?: nil
        case nil: nil
        }
    }

    static func dateOrigin(_ origin: DateOrigin?) -> String? {
        origin == .label ? "Read from the label" : nil
    }

    static func locationOrigin(_ origin: LocationOrigin) -> String? {
        origin == .label ? "The label says how to keep it" : nil
    }

    static func date(_ date: PrintedDate) -> String {
        "\(AttentionText.label(date.label)) \(AttentionText.day(date.date))"
    }

    /// A plain line for a doubt, given a way to name other candidates.
    static func note(_ note: CandidateNote, name: (IntakeCandidateID) -> String?) -> String? {
        switch note {
        case .mightBeSameAs(let others):
            let names = others.map { name($0) ?? "an item without a name" }
            return "Might be the same as \(ListFormatter.localizedString(byJoining: names))"
        case .noName: return "No name found. Add one."
        case .dateUnclear: return "Date unclear. Which is it?"
        case .datesDisagree: return "The photos show different dates. Check the date."
        case .dateMatchedByOrder: return "A date photo was matched by the order you took the photos."
        case .severalProducts: return "One photo shows more than one product."
        case .duplicatePhotos: return "The same photo was added twice."
        case .maybeSeveralPackages: return "Its barcode is in photos taken apart. More than one?"
        case .refusedBarcode(let reason): return refused(reason)
        case .linkSeen: return "A QR code with a link was seen. It wasn't opened."
        case .lookingUp: return "Looking up the barcode…"
        case .lookupFailed: return "Couldn't look up the barcode yet. Pantrified will try again."
        case .lookupFoundNothing: return "No product found for this barcode."
        case .lookupPaused: return "Barcode lookups are paused for now. Pantrified will try again later; you can add this now."
        }
    }

    static func refused(_ reason: RefusedCode) -> String {
        switch reason {
        case .unreadable: "A barcode didn't read cleanly."
        case .notAConsumerUnit: "That barcode is for a case, not one package."
        case .storeInternal: "That's the store's own barcode, so it can't name the product."
        case .coupon: "That's a coupon barcode."
        case .publication: "That's a book or magazine barcode."
        case .refundReceipt: "That's a receipt barcode."
        }
    }

    /// Why the photos were grouped, for the edit screen and VoiceOver.
    static func signals(_ signals: [MatchSignal]) -> String? {
        let words = signals.compactMap { signal -> String? in
            switch signal {
            case .sameBarcode: "the same barcode"
            case .identicalPhoto: "the same photo"
            case .nearDuplicateImage, .similarImage: "photos that look alike"
            case .sharedLabelWords, .someLabelWords: "words on the label"
            case .takenRightAfter: "taken one after another"
            case .datePhotoAfter, .datePhotoBefore: "a date photo taken next to it"
            case .groupedByPerson: "you"
            case .differentLabelWords, .differentAmounts: nil
            }
        }
        var unique: [String] = []
        for word in words where !unique.contains(word) { unique.append(word) }
        return unique.isEmpty ? nil : "Grouped by " + ListFormatter.localizedString(byJoining: unique) + "."
    }
}
