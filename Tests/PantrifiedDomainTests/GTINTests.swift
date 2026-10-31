import Foundation
import Testing
@testable import PantrifiedDomain

private func scanned(_ payload: String, _ symbology: BarcodeSymbology) -> GTIN? {
    try? GTIN.scanned(payload, as: symbology).get()
}

private func rejection(_ payload: String, _ symbology: BarcodeSymbology) -> GTINRejection? {
    if case .failure(let reason) = GTIN.scanned(payload, as: symbology) { return reason }
    return nil
}

@Suite("GTIN")
struct GTINTests {
    // MARK: One canonical form

    @Test("each symbology pads to the same 14 digits", arguments: [
        ("0036000291452", BarcodeSymbology.ean13, "00036000291452"),
        ("036000291452", .upcA, "00036000291452"),
        ("4006381333931", .ean13, "04006381333931"),
        ("96385074", .ean8, "00000096385074"),
        ("01234565", .upcE, "00012345000065"),
    ])
    func canonicalForm(payload: String, symbology: BarcodeSymbology, digits: String) {
        #expect(scanned(payload, symbology)?.digits == digits)
    }

    @Test("a UPC-A read as EAN-13 with a leading zero is the same product as the UPC-A")
    func upcAReadAsEAN13() {
        #expect(scanned("0036000291452", .ean13) == scanned("036000291452", .upcA))
        #expect(scanned("0036000291452", .ean13) == GTIN("036000291452"))
    }

    @Test("a UPC-E is the same product as the UPC-A it abbreviates")
    func upcEMatchesItsUPCA() {
        #expect(scanned("01234565", .upcE) == scanned("012345000065", .upcA))
    }

    @Test("UPC-E expands by its sixth data digit", arguments: [
        ("01234565", "012345000065"),
        ("06543217", "065100004327"),
        ("01234531", "012300000451"),
        ("01234543", "012340000053"),
        ("01234505", "012000003455"),
        ("00421001", "004000002101"),
        ("11234511", "112100003451"),
    ])
    func upcEExpansion(payload: String, upcA: String) {
        #expect(GTIN.expandUPCE(payload) == upcA)
        #expect(scanned(payload, .upcE)?.digits == "00" + upcA)
    }

    @Test("a UPC-E needs number system 0 or 1 and eight digits")
    func upcEShape() {
        #expect(GTIN.expandUPCE("21234565") == nil)
        #expect(rejection("21234565", .upcE) == .malformed)
        #expect(rejection("1234565", .upcE) == .malformed)
        #expect(rejection("012345650", .upcE) == .malformed)
    }

    @Test("the issued form is the length the code was printed in", arguments: [
        ("0036000291452", BarcodeSymbology.ean13, "036000291452"),
        ("4006381333931", .ean13, "4006381333931"),
        ("96385074", .ean8, "96385074"),
        ("01234565", .upcE, "012345000065"),
    ])
    func issuedForm(payload: String, symbology: BarcodeSymbology, issued: String) {
        #expect(scanned(payload, symbology)?.issuedForm == issued)
        #expect(scanned(payload, symbology)?.description == issued)
    }

    @Test("text of 8, 12, 13 or 14 digits parses to the same GTIN, with surrounding spaces ignored")
    func textForms() {
        let gtin = GTIN("036000291452")
        #expect(gtin != nil)
        #expect(GTIN("0036000291452") == gtin)
        #expect(GTIN("00036000291452") == gtin)
        #expect(GTIN(" 036000291452 ") == gtin)
        #expect(GTIN("96385074")?.digits == "00000096385074")
        #expect(GTIN.parse("3600029145") == .failure(.malformed))
        #expect(GTIN.parse("000036000291452") == .failure(.malformed))
    }

    // MARK: Refusals

    @Test("a wrong check digit is refused in every symbology", arguments: [
        ("0036000291453", BarcodeSymbology.ean13),
        ("036000291450", .upcA),
        ("96385075", .ean8),
        ("01234564", .upcE),
    ])
    func checkDigit(payload: String, symbology: BarcodeSymbology) {
        #expect(rejection(payload, symbology) == .checkDigit)
    }

    @Test("each position's weight counts: changing any one digit is caught")
    func everyDigitWeighs() {
        let valid = Array("4006381333931")
        for index in valid.indices.dropLast() {
            var changed = valid
            changed[index] = changed[index] == "9" ? "0" : Character(String(changed[index].wholeNumberValue! + 1))
            #expect(rejection(String(changed), .ean13) == .checkDigit, "digit \(index)")
        }
    }

    @Test("the wrong length or anything but ASCII digits is malformed", arguments: [
        ("036000291452", BarcodeSymbology.ean13),
        ("00036000291452", .ean13),
        ("0036000291452", .upcA),
        ("963850740", .ean8),
        ("", .ean13),
        ("003600029145A", .ean13),
        ("003600029145 ", .ean13),
        ("٠٠٣٦٠٠٠٢٩١٤٥٢", .ean13),
    ])
    func malformed(payload: String, symbology: BarcodeSymbology) {
        #expect(rejection(payload, symbology) == .malformed)
    }

    @Test("a store's own codes, including weighed items, are refused", arguments: [
        ("212345678909", BarcodeSymbology.upcA),
        ("412345678903", .upcA),
        ("2012345678903", .ean13),
        ("20123451", .ean8),
        ("00123457", .ean8),
        ("0000000000000", .ean13),
    ])
    func storeInternal(payload: String, symbology: BarcodeSymbology) {
        #expect(rejection(payload, symbology) == .storeInternal)
    }

    @Test("coupons, publications and refund receipts are refused", arguments: [
        ("512345678900", BarcodeSymbology.upcA, GTINRejection.coupon),
        ("9811234567891", .ean13, .coupon),
        ("9912345678992", .ean13, .coupon),
        ("9780306406157", .ean13, .publication),
        ("9771234567003", .ean13, .publication),
        ("9791234567896", .ean13, .publication),
        ("9801234567892", .ean13, .refundReceipt),
    ])
    func notFood(payload: String, symbology: BarcodeSymbology, reason: GTINRejection) {
        #expect(rejection(payload, symbology) == reason)
    }

    @Test("a GTIN-14 for a case or pack is refused; a consumer unit is not")
    func packagingIndicator() {
        #expect(GTIN.parse("14006381333938") == .failure(.notAConsumerUnit))
        #expect(GTIN("04006381333931") != nil)
    }

    @Test("ordinary prefixes next to the refused ranges are accepted", arguments: [
        ("030000000007", BarcodeSymbology.upcA),
        ("021234567893", .upcA),
        ("041234567822", .upcA),
        ("012345000065", .upcA),
        ("3000000000007", .ean13),
        ("1900000000002", .ean13),
        ("9761234567899", .ean13),
        ("9851234567897", .ean13),
        ("10123454", .ean8),
    ])
    func neighborsAccepted(payload: String, symbology: BarcodeSymbology) {
        #expect(scanned(payload, symbology) != nil, "\(payload)")
    }

    // MARK: Storage

    @Test("a GTIN encodes as its 14 digits and decodes only from 14 valid digits")
    func coding() throws {
        let gtin = try #require(GTIN("036000291452"))
        let encoded = try JSONEncoder().encode([gtin])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"00036000291452\"]")
        #expect(try JSONDecoder().decode([GTIN].self, from: encoded) == [gtin])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([GTIN].self, from: Data("[\"036000291452\"]".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([GTIN].self, from: Data("[\"00036000291453\"]".utf8)) }
        for padded in [" 0036000291452", "0036000291452 ", "\t0036000291452"] {
            #expect(padded.count == 14)
            #expect(throws: DecodingError.self, "\(padded)") { try JSONDecoder().decode([GTIN].self, from: JSONEncoder().encode([padded])) }
        }
    }
}
