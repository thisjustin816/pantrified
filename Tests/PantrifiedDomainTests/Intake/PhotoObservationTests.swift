import Foundation
import Testing
import PantrifiedDomain

@Suite("Photo observations")
struct PhotoObservationTests {
    // MARK: Codes

    @Test("a retail barcode is a product, and a store code is refused with its reason")
    func retailCodes() {
        #expect(CodeMeaning.classify(payload: "0036000291452", symbology: .ean13) == .product(GTIN("036000291452")!))
        #expect(CodeMeaning.classify(payload: "0212345678909", symbology: .ean13) == .refused(.storeInternal))
        #expect(CodeMeaning.classify(payload: "0036000291453", symbology: .ean13) == .refused(.unreadable))
        #expect(CodeMeaning.classify(payload: "٠٠٣٦٠٠٠٢٩١٤٥٢", symbology: .ean13) == .refused(.unreadable))
    }

    @Test("a QR code holding a GS1 Digital Link gives its GTIN, on any host, with or without more path", arguments: [
        "https://id.gs1.org/01/09506000134352",
        "HTTPS://ID.GS1.ORG/01/09506000134352",
        "https://example.com/01/09506000134352/10/ABC123?17=271231",
        "http://brand.example/product/01/9506000134352#top",
    ])
    func digitalLink(payload: String) {
        #expect(CodeMeaning.classify(payload: payload, symbology: .qr) == .product(GTIN("09506000134352")!))
    }

    @Test("any other QR link is only noted as a link, and other QR text is not a link", arguments: [
        ("https://example.com/recipes?id=01", CodeMeaning.link),
        ("https://example.com/01/12345", .link),
        ("https://example.com/01/0950600013435x", .link),
        ("https:///01/09506000134352", .link),
        ("https://exämple.com/01/09506000134352", .link),
        ("ftp://example.com/01/09506000134352", .otherQR),
        ("WIFI:S:home;T:WPA;P:secret;;", .otherQR),
        ("09506000134352", .otherQR),
    ])
    func otherQR(payload: String, expected: CodeMeaning) {
        #expect(CodeMeaning.classify(payload: payload, symbology: .qr) == expected)
    }

    @Test("a code longer than the byte limit is not read, counting bytes rather than characters")
    func oversizedCodes() {
        let link = "https://id.gs1.org/01/09506000134352/"
        let long = link + String(repeating: "a", count: IntakeLimits.codePayloadBytes - link.utf8.count + 1)
        #expect(CodeMeaning.classify(payload: long, symbology: .qr) == .otherQR)
        // 200 characters but 800 bytes.
        let wide = link + String(repeating: "🥫", count: 200)
        #expect(wide.count < IntakeLimits.codePayloadBytes)
        #expect(CodeMeaning.classify(payload: wide, symbology: .qr) == .otherQR)
        #expect(CodeMeaning.classify(payload: String(repeating: "1", count: 600), symbology: .ean13) == .refused(.unreadable))
    }

    // MARK: Text

    @Test("recognized text loses control and direction-override characters and keeps its words")
    func hostileText() {
        let line = RecognizedTextLine(text: "Bak\u{202E}ing\u{0000} soda\n\tPLAIN\u{200B}", box: .whole)
        #expect(line?.text == "Bak ing soda PLAIN")
        #expect(RecognizedTextLine(text: "\u{202E}\u{0007}  \n", box: .whole) == nil)
    }

    @Test("a line is cut between characters to both its character and its byte limit")
    func lineLimits() throws {
        let long = try #require(RecognizedTextLine(text: String(repeating: "a", count: 1_000), box: .whole))
        #expect(long.text.count == IntakeLimits.charactersPerLine)
        // Each family emoji is 18 bytes, so the byte limit cuts first, and never inside one.
        let emoji = try #require(RecognizedTextLine(text: String(repeating: "👨‍👩‍👧", count: 100), box: .whole))
        let withinBytes = emoji.text.utf8.count <= IntakeLimits.bytesPerLine
        let wholeCharacters = emoji.text.allSatisfy { $0 == "👨‍👩‍👧" }
        #expect(withinBytes)
        #expect(wholeCharacters)
        #expect(emoji.text.count == IntakeLimits.bytesPerLine / 18)
    }

    @Test("a photo keeps at most its limits of lines, text bytes and codes")
    func photoLimits() {
        let many = (0..<500).map { Fixture.line("Line \($0)", row: 0.5) }
        #expect(Fixture.photo(0, lines: many).lines.count == IntakeLimits.linesPerPhoto)
        let heavy = (0..<100).map { _ in Fixture.line(String(repeating: "é", count: 150)) }
        let bytes = Fixture.photo(0, lines: heavy).lines.reduce(0) { $0 + $1.text.utf8.count }
        #expect(bytes <= IntakeLimits.bytesOfTextPerPhoto)
        let codes = Array(repeating: CodeMeaning.link, count: 100)
        #expect(Fixture.photo(0, codes: codes).codes.count == IntakeLimits.codesPerPhoto)
    }

    @Test("boxes are clamped into the photo, and numbers that are not numbers become zero")
    func boxes() {
        let box = NormalizedBox(x: -1, y: .nan, width: 5, height: .infinity)
        #expect(box == NormalizedBox(x: 0, y: 0, width: 1, height: 0))
        #expect(NormalizedBox(x: 0.9, y: 0.9, width: 0.5, height: 0.5).width == 0.09999999999999998)
        #expect(RecognizedTextLine(text: "a", box: .whole, confidence: .nan)?.confidence == nil)
        #expect(RecognizedTextLine(text: "a", box: .whole, confidence: 7)?.confidence == 1)
    }

    @Test("a feature print must be finite and bounded, and a digest must be hex")
    func featurePrintsAndDigests() {
        #expect(FeaturePrint([]) == nil)
        #expect(FeaturePrint([1, .nan]) == nil)
        #expect(FeaturePrint([Float](repeating: 0, count: IntakeLimits.featurePrintValues + 1)) == nil)
        #expect(Fixture.photo(0, digest: "ABCDEF01").contentDigest == "abcdef01")
        #expect(Fixture.photo(0, digest: "../../etc").contentDigest == nil)
    }

    @Test("an observation survives encoding, and decoding applies the limits again")
    func coding() throws {
        let photo = Fixture.photo(3, lines: Fixture.front("Greek yogurt"), codes: [.product(Fixture.yogurt), .link], print: [0.5, 0.25], digest: "ab")
        let decoded = try JSONDecoder().decode(PhotoObservation.self, from: JSONEncoder().encode(photo))
        #expect(decoded == photo)
        #expect(decoded.kind == .package)

        let hostile = """
        {"photo":{"rawValue":"\(UUID().uuidString)"},"sequence":-4,"capturedAt":0,"codes":[],
         "lines":[{"text":"\(String(repeating: "x", count: 5_000))","box":{"x":2,"y":0,"width":1,"height":1}}]}
        """
        let bounded = try JSONDecoder().decode(PhotoObservation.self, from: Data(hostile.utf8))
        #expect(bounded.sequence == 0)
        #expect(bounded.kind == .package)
        #expect(bounded.lines.first?.text.count == IntakeLimits.charactersPerLine)
        #expect(bounded.lines.first?.box.x == 1)
    }
}

@Suite("Label text")
struct LabelTextTests {
    @Test("significant words drop numbers, short words and boilerplate, and fold case and accents")
    func tokens() {
        #expect(LabelText.significantTokens("NET WT 16 OZ (454g)") == [])
        #expect(LabelText.significantTokens("Trader Joe's Crème Fraîche 2%") == ["trader", "joes", "creme", "fraiche"])
        #expect(LabelText.significantTokens("Nutrition Facts Total Fat 0g") == [])
    }

    @Test("the name is the tallest wordy line, joined to a brand printed right above it, in sentence case")
    func prominentName() {
        #expect(LabelText.prominentName(in: Fixture.front("GREEK YOGURT", brand: "CHOBANI", small: ["Keep refrigerated"])) == "Chobani greek yogurt")
        #expect(LabelText.prominentName(in: [Fixture.line("Baking soda", size: 0.1), Fixture.line("Pure", row: 0.9, size: 0.02)]) == "Baking soda")
        #expect(LabelText.prominentName(in: [Fixture.line("12/05/2026", size: 0.2), Fixture.line("Rolled oats", row: 0.5, size: 0.05)]) == "Rolled oats")
        #expect(LabelText.prominentName(in: [Fixture.line("123 456", size: 0.2)]) == nil)
        #expect(LabelText.prominentName(in: []) == nil)
    }

    @Test("a line the recognizer was unsure of never becomes a name")
    func unsureName() {
        #expect(LabelText.prominentName(in: [Fixture.line("Bakng powdr", size: 0.1, confidence: 0.1)]) == nil)
    }

    @Test("a stated storage is read only from a plain instruction")
    func storage() {
        #expect(LabelText.statedStorage(in: [Fixture.line("KEEP FROZEN")]) == .frozen)
        #expect(LabelText.statedStorage(in: [Fixture.line("Keep refrigerated")]) == .refrigerated)
        #expect(LabelText.statedStorage(in: [Fixture.line("Refrigerate after opening")]) == nil)
    }

    @Test("prominent percentages and net contents are read, nutrition panel percentages are not")
    func amounts() {
        let milk = Fixture.photo(0, lines: [
            Fixture.line("2% Reduced Fat Milk", size: 0.1),
            Fixture.line("Total Fat 5g 6%", row: 0.7, size: 0.02),
            Fixture.line("NET 1 GAL (3.78 L)", row: 0.9, size: 0.02),
        ])
        let found = LabelText.variantAmounts(of: milk)
        #expect(found.percents == ["2%"])
        #expect(found.sizes == ["3.78 l"])
        let panel = Fixture.photo(0, lines: Fixture.back(["Ingredients: milk"]))
        #expect(LabelText.variantAmounts(of: panel).percents.isEmpty)
        let size = Fixture.photo(0, lines: [Fixture.line("NET WT 16oz (1 LB) 454g")])
        #expect(LabelText.variantAmounts(of: size).sizes == ["16 oz", "1 lb", "454 g"])
        #expect(LabelText.variantAmounts(of: Fixture.photo(0, lines: [Fixture.line("Net 12 fl. oz")])).sizes == ["12 fl oz"])
    }

    @Test("a date label on the line above its date is read with the date")
    func labelAbove() {
        let readings = LineDateReader().readings(in: [Fixture.line("BEST BY", row: 0.1), Fixture.line("12/25/2026", row: 0.16)])
        let preferred = PrintedDateParser.preferred(readings)
        #expect(preferred?.label == .bestBy)
    }
}
