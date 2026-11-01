import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let cola = BarcodeRead(payload: "0036000291452", symbology: .ean13)
private let colaAsUPCE = BarcodeRead(payload: "01234565", symbology: .upcE)
private let pencils = BarcodeRead(payload: "4006381333931", symbology: .ean13)
private let book = BarcodeRead(payload: "9780306406157", symbology: .ean13)
private let weighedMeat = BarcodeRead(payload: "212345678909", symbology: .upcA)
private let misread = BarcodeRead(payload: "0036000291453", symbology: .ean13)

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

@Suite("Barcode scan")
struct BarcodeScanTests {
    @Test("a product read in two frames is reported once, and the scan then ignores everything")
    func productNeedsTwoFrames() {
        var scan = BarcodeScan()

        #expect(scan.receive([cola], at: at(0)) == nil)
        #expect(scan.product == nil)
        #expect(scan.receive([cola], at: at(0.03)) == .product(GTIN("036000291452")!))
        #expect(scan.product == GTIN("036000291452"))
        #expect(scan.receive([cola], at: at(0.06)) == nil)
        #expect(scan.receive([pencils], at: at(0.1)) == nil)
        #expect(scan.receive([pencils], at: at(0.2)) == nil)
        #expect(scan.receive([book], at: at(0.3)) == nil)
    }

    @Test("one frame showing a barcode twice counts as one frame")
    func oneFrameCountsOnce() {
        var scan = BarcodeScan()

        #expect(scan.receive([cola, cola], at: at(0)) == nil)
        #expect(scan.receive([cola], at: at(0.03)) == .product(GTIN("036000291452")!))
    }

    @Test("the UPC-A and EAN-13 forms of one product confirm each other")
    func formsConfirmEachOther() {
        var scan = BarcodeScan()

        #expect(scan.receive([BarcodeRead(payload: "036000291452", symbology: .upcA)], at: at(0)) == nil)
        #expect(scan.receive([cola], at: at(0.03)) == .product(GTIN("036000291452")!))
    }

    @Test("two products in view are counted apart; the first read twice wins")
    func productsCountedApart() {
        var scan = BarcodeScan()

        #expect(scan.receive([cola, pencils], at: at(0)) == nil)
        #expect(scan.receive([pencils], at: at(0.03)) == .product(GTIN("4006381333931")!))
    }

    @Test("a misread frame between two good ones does not name a product of its own")
    func misreadIsIgnored() {
        var scan = BarcodeScan()

        #expect(scan.receive([colaAsUPCE], at: at(0)) == nil)
        #expect(scan.receive([misread], at: at(0.03)) == .refused(.checkDigit))
        #expect(scan.receive([colaAsUPCE], at: at(0.06)) == .product(GTIN("012345000065")!))
    }

    @Test("a sighting older than the forget window does not count toward confirmation")
    func staleSightingForgotten() {
        var scan = BarcodeScan(confirmations: 2, forgetAfter: 2)

        #expect(scan.receive([cola], at: at(0)) == nil)
        #expect(scan.receive([cola], at: at(2.5)) == nil)
        #expect(scan.receive([cola], at: at(4.5)) == .product(GTIN("036000291452")!))
    }

    @Test("a sighting at exactly the forget window still counts")
    func sightingAtWindowCounts() {
        var scan = BarcodeScan(confirmations: 2, forgetAfter: 2)

        #expect(scan.receive([cola], at: at(0)) == nil)
        #expect(scan.receive([cola], at: at(2)) == .product(GTIN("036000291452")!))
    }

    @Test("a barcode that is not food is reported once while in view, and again after it leaves")
    func refusalReportedOnce() {
        var scan = BarcodeScan(forgetAfter: 2)

        #expect(scan.receive([book], at: at(0)) == .refused(.publication))
        #expect(scan.receive([book], at: at(1)) == nil)
        #expect(scan.receive([book], at: at(2.9)) == nil)
        #expect(scan.receive([], at: at(3)) == nil)
        #expect(scan.receive([book], at: at(5)) == .refused(.publication))
    }

    @Test("a second refused barcode is reported on its own")
    func eachRefusalReported() {
        var scan = BarcodeScan()

        #expect(scan.receive([book], at: at(0)) == .refused(.publication))
        #expect(scan.receive([book, weighedMeat], at: at(0.1)) == .refused(.storeInternal))
        #expect(scan.receive([book, weighedMeat], at: at(0.2)) == nil)
    }

    @Test("a product beats a refusal in the same frame")
    func productBeatsRefusal() {
        var scan = BarcodeScan()

        #expect(scan.receive([book, cola], at: at(0)) == .refused(.publication))
        #expect(scan.receive([book, cola], at: at(0.03)) == .product(GTIN("036000291452")!))
        #expect(scan.receive([weighedMeat], at: at(0.06)) == nil)
    }

    @Test("asking for one confirmation reports a product on its first read; zero is taken as one")
    func confirmationCount() {
        var once = BarcodeScan(confirmations: 1)
        var zero = BarcodeScan(confirmations: 0)

        #expect(once.receive([cola], at: at(0)) == .product(GTIN("036000291452")!))
        #expect(zero.receive([cola], at: at(0)) == .product(GTIN("036000291452")!))
    }
}

private func qr(_ payload: String) -> BarcodeRead { BarcodeRead(payload: payload, symbology: .qr) }
private let digitalLink = qr("https://id.gs1.org/01/09506000134352")
private let colaLink = qr("https://brand.example/product/01/00036000291452?17=271231")
private let pencilsLink = qr("https://id.gs1.org/01/04006381333931")
private let webLink = qr("https://example.com/menu")
private let note = qr("Fresh basil from the garden")

/// Every string stored anywhere inside `value`, found by reflection.
private func storedStrings(_ value: Any) -> [String] {
    if let string = value as? String { return [string] }
    return Mirror(reflecting: value).children.flatMap { storedStrings($0.value) }
}

@Suite("Barcode scan: QR codes")
struct BarcodeScanQRTests {
    @Test("a QR code holding a GS1 Digital Link is read like that product's barcode, and ends the scan")
    func digitalLinkIsProduct() {
        var scan = BarcodeScan()

        #expect(scan.receive([digitalLink], at: at(0)) == nil)
        #expect(scan.receive([digitalLink], at: at(0.03)) == .product(GTIN("09506000134352")!))
        #expect(scan.receive([webLink], at: at(0.06)) == nil)
        #expect(scan.receive([digitalLink], at: at(0.09)) == nil)
    }

    @Test("a product's Digital Link and its barcode confirm each other")
    func linkAndBarcodeConfirm() {
        var scan = BarcodeScan()

        #expect(scan.receive([colaLink], at: at(0)) == nil)
        #expect(scan.receive([cola], at: at(0.03)) == .product(GTIN("036000291452")!))
    }

    @Test("any other QR code is reported as unusable once, names no product, and the scan goes on", arguments: [
        "https://example.com/menu",
        "http://192.168.1.1/admin",
        "Fresh basil from the garden",
        "BEGIN:VCARD\nVERSION:3.0\nFN:Sam\nTEL:+15551234567\nEND:VCARD",
        "WIFI:S:home;T:WPA;P:secret;;",
        "09506000134352",
        "",
        // Digital Links whose number is refused by the GTIN rules.
        "https://id.gs1.org/01/09506000134353",
        "https://id.gs1.org/01/19506000134359",
        "https://id.gs1.org/01/00212345678909",
        "https://id.gs1.org/01/12345",
        // Percent-encoding in the key or the number.
        "https://id.gs1.org/%30%31/09506000134352",
        "https://id.gs1.org/01/%30%39506000134352",
        "https://id.gs1.org/01/0950600013435%32",
        // Digits that only look like ASCII digits, and direction marks.
        "https://id.gs1.org/01/０９５０６０００１３４３５２",
        "https://id.gs1.org/01/\u{202E}25343100605590",
        "https://id.gs1.org/01/\u{200F}09506000134352",
        "\u{202E}https://id.gs1.org/01/09506000134352",
        // Control characters, NULs and white space in the number.
        "https://id.gs1.org/01/0950600\u{0}0134352",
        "https://id.gs1.org/01/09506000134352\u{0}",
        "https://id.gs1.org/01/09506000134352\n",
        "https://id.gs1.org/01/09506000134352\t",
        "https://id.gs1.org/01/ 09506000134352",
        " https://id.gs1.org/01/09506000134352",
        // What AVFoundation hands over for bytes that are not valid UTF-8.
        "https://id.gs1.org/01/09506000134352\u{FFFD}",
        "\u{FFFD}\u{FFFD}\u{FFFD}",
        // The number hidden where a Digital Link has none.
        "https://evil.example/?/01/09506000134352",
        "https://evil.example/#/01/09506000134352",
        "https:///01/09506000134352",
        "javascript:alert(1)//https://id.gs1.org/01/09506000134352",
        "file:///01/09506000134352",
        "data:text/html,https://id.gs1.org/01/09506000134352",
    ])
    func unusable(payload: String) {
        var scan = BarcodeScan()

        #expect(scan.receive([qr(payload)], at: at(0)) == .unusableQRCode)
        #expect(scan.receive([qr(payload)], at: at(0.03)) == nil)
        #expect(scan.receive([qr(payload)], at: at(0.06)) == nil)
        #expect(scan.product == nil)
        #expect(scan.receive([cola], at: at(0.1)) == nil)
        #expect(scan.receive([cola], at: at(0.13)) == .product(GTIN("036000291452")!))
    }

    @Test("ASCII control characters away from the number leave the number as it is, since nothing else is used")
    func controlCharactersElsewhere() {
        var scan = BarcodeScan()
        let link = qr("https://id.gs1.org\u{0}\u{7}/01/09506000134352?x=\u{1B}[31m")

        #expect(scan.receive([link], at: at(0)) == nil)
        #expect(scan.receive([link], at: at(0.03)) == .product(GTIN("09506000134352")!))
    }

    @Test("a QR code longer than the byte limit is not read, counting bytes rather than characters")
    func lengthCap() {
        let base = "https://id.gs1.org/01/09506000134352/"
        let fits = base + String(repeating: "a", count: IntakeLimits.codePayloadBytes - base.utf8.count)
        #expect(fits.utf8.count == IntakeLimits.codePayloadBytes)
        var atLimit = BarcodeScan()
        #expect(atLimit.receive([qr(fits)], at: at(0)) == nil)
        #expect(atLimit.receive([qr(fits)], at: at(0.03)) == .product(GTIN("09506000134352")!))

        // 200 characters of 4 bytes each, under the limit in characters and over it in bytes.
        let wide = base + String(repeating: "🥫", count: 200)
        #expect(wide.count < IntakeLimits.codePayloadBytes)
        for payload in [fits + "a", wide, base + String(repeating: "9", count: 100_000)] {
            var scan = BarcodeScan()
            #expect(scan.receive([qr(payload)], at: at(0)) == .unusableQRCode)
            #expect(scan.receive([qr(payload)], at: at(0.03)) == nil)
            #expect(scan.product == nil)
        }
    }

    @Test("unusable QR codes are reported once while any stays in view, and again after two seconds without one")
    func unusableReportedOnce() {
        var scan = BarcodeScan(forgetAfter: 2)

        #expect(scan.receive([webLink], at: at(0)) == .unusableQRCode)
        #expect(scan.receive([webLink], at: at(1)) == nil)
        // A different unusable code says the same thing, so it is not reported again.
        #expect(scan.receive([note], at: at(1.5)) == nil)
        #expect(scan.receive([note, webLink], at: at(3.4)) == nil)
        #expect(scan.receive([], at: at(4)) == nil)
        #expect(scan.receive([note], at: at(5.4)) == nil)
        #expect(scan.receive([note], at: at(7.5)) == .unusableQRCode)
    }

    @Test("a refused barcode is still reported while an unusable QR code is in view")
    func refusalBesideUnusableQR() {
        var scan = BarcodeScan()

        #expect(scan.receive([webLink], at: at(0)) == .unusableQRCode)
        #expect(scan.receive([webLink, book], at: at(0.1)) == .refused(.publication))
        #expect(scan.receive([webLink, book], at: at(0.2)) == nil)
    }

    @Test("Digital Links naming different products in one frame name none, and are unusable")
    func differentLinksAreAmbiguous() {
        var scan = BarcodeScan()

        #expect(scan.receive([digitalLink, pencilsLink], at: at(0)) == .unusableQRCode)
        for frame in 1...5 {
            #expect(scan.receive([digitalLink, pencilsLink, colaLink], at: at(Double(frame) * 0.03)) == nil)
        }
        #expect(scan.product == nil)
    }

    @Test("a Digital Link beside another product's barcode is unusable, and the barcode is read as before")
    func linkBesideOtherBarcode() {
        var scan = BarcodeScan()

        #expect(scan.receive([pencilsLink, cola], at: at(0)) == .unusableQRCode)
        #expect(scan.receive([pencilsLink, cola], at: at(0.03)) == .product(GTIN("036000291452")!))
    }

    @Test("one frame showing a Digital Link twice, or with its product's barcode, counts as one frame")
    func sameProductCountsOnce() {
        var twice = BarcodeScan()
        #expect(twice.receive([digitalLink, digitalLink], at: at(0)) == nil)
        #expect(twice.receive([digitalLink], at: at(0.03)) == .product(GTIN("09506000134352")!))

        var withBarcode = BarcodeScan()
        #expect(withBarcode.receive([colaLink, cola], at: at(0)) == nil)
        #expect(withBarcode.receive([colaLink, cola], at: at(0.03)) == .product(GTIN("036000291452")!))
    }

    @Test("a Digital Link is still read beside any number of unusable QR codes, which are reported first")
    func linkAmongUnusable() {
        var scan = BarcodeScan()
        let frame = (0..<300).map { qr("https://example.com/\($0)") } + [digitalLink]

        #expect(scan.receive(frame, at: at(0)) == .unusableQRCode)
        #expect(scan.receive(frame, at: at(0.03)) == .product(GTIN("09506000134352")!))
    }

    @Test("no text from a QR code is kept, only the product number taken from it")
    func qrTextNotKept() {
        let marker = "private-7f3a"
        var unusable = BarcodeScan()
        _ = unusable.receive([qr("https://example.com/\(marker)")], at: at(0))
        _ = unusable.receive([qr("WIFI:S:\(marker);;"), book], at: at(0.03))
        _ = unusable.receive([qr("https://id.gs1.org/01/09506000134352?\(marker)")], at: at(0.06))
        _ = unusable.receive([qr("https://id.gs1.org/01/09506000134352?\(marker)"), pencilsLink], at: at(0.09))
        let kept = storedStrings(unusable)

        #expect(unusable.product == nil)
        #expect(kept.contains("9780306406157"), "the reflection reaches stored reads")
        #expect(!kept.contains { $0.contains(marker) })
    }
}
