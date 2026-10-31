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
