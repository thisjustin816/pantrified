import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import PantrifiedFoodDataCentral

/// Answers every request with one fixed result and remembers the requests.
private final class FixedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<HTTPReply, HTTPFailure>
    /// Guarded by `lock`.
    private var received: [URLRequest] = []

    init(_ answer: Result<HTTPReply, HTTPFailure>) { self.answer = answer }

    convenience init(status: Int = 200, json: String) {
        self.init(.success(HTTPReply(status: status, body: Data(json.utf8))))
    }

    var requests: [URLRequest] { lock.withLock { received } }

    func get(_ request: URLRequest) async -> Result<HTTPReply, HTTPFailure> {
        lock.withLock { received.append(request) }
        return answer
    }
}

private let cola = GTIN("036000291452")!

private func lookUp(_ transport: FixedTransport, _ barcode: GTIN = cola) async throws -> ProductLookupResult {
    let lookup = try #require(FoodDataCentralLookup(apiKey: "test-key", transport: transport))
    return await lookup.lookUp(barcode)
}

private func found(_ name: String) -> ProductLookupResult {
    .found(ProductSuggestion(name: name, source: "USDA FoodData Central"))
}

@Suite("FoodData Central lookup")
struct FoodDataCentralLookupTests {
    // MARK: The request

    @Test("a request sends only the barcode, fixed search options and the key in a header, over HTTPS")
    func requestShape() async throws {
        let transport = FixedTransport(json: #"{"foods": []}"#)
        _ = try await lookUp(transport)

        let request = try #require(transport.requests.first)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(transport.requests.count == 1)
        #expect(components.scheme == "https")
        #expect(components.host == "api.nal.usda.gov")
        #expect(components.path == "/fdc/v1/foods/search")
        #expect(components.queryItems == [
            URLQueryItem(name: "query", value: "036000291452"),
            URLQueryItem(name: "dataType", value: "Branded"),
            URLQueryItem(name: "pageSize", value: "10"),
        ])
        #expect(!url.absoluteString.contains("test-key"))
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Pantrified")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.allHTTPHeaderFields?.count == 4)
    }

    @Test("the barcode is searched in the length it was issued as", arguments: [
        ("4006381333931", "4006381333931"),
        ("96385074", "96385074"),
        ("0036000291452", "036000291452"),
    ])
    func searchedForm(text: String, query: String) async throws {
        let transport = FixedTransport(json: #"{"foods": []}"#)
        _ = try await lookUp(transport, try #require(GTIN(text)))

        let url = try #require(transport.requests.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first == URLQueryItem(name: "query", value: query))
    }

    @Test("an empty key turns lookup off")
    func emptyKey() {
        #expect(FoodDataCentralLookup(apiKey: "", transport: FixedTransport(json: "{}")) == nil)
        #expect(FoodDataCentralLookup(apiKey: " \n", transport: FixedTransport(json: "{}")) == nil)
        #expect(FoodDataCentralLookup(apiKey: " key ", transport: FixedTransport(json: "{}")) != nil)
    }

    @Test("a key with spaces around it is sent without them")
    func keyTrimmed() async throws {
        let transport = FixedTransport(json: #"{"foods": []}"#)
        let lookup = try #require(FoodDataCentralLookup(apiKey: " key\n", transport: transport))
        _ = await lookup.lookUp(cola)

        #expect(transport.requests.first?.value(forHTTPHeaderField: "X-Api-Key") == "key")
    }

    @Test("a cancelled lookup sends nothing")
    func cancelledSendsNothing() async throws {
        let transport = FixedTransport(json: #"{"foods": []}"#)
        let lookup = try #require(FoodDataCentralLookup(apiKey: "key", transport: transport))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await lookup.lookUp(cola)
        }

        #expect(await task.value == .failed(.cancelled))
        #expect(transport.requests.isEmpty)
    }

    // MARK: Answers

    @Test("a record whose own barcode matches gives its name")
    func match() async throws {
        let json = #"{"totalHits": 1, "foods": [{"fdcId": 1, "description": "Cola", "dataType": "Branded", "gtinUpc": "036000291452", "brandOwner": "A"}]}"#
        #expect(try await lookUp(FixedTransport(json: json)) == found("Cola"))
    }

    @Test("the record's barcode matches in any length it is stored in", arguments: ["036000291452", "0036000291452", "00036000291452"])
    func matchAnyLength(stored: String) async throws {
        let json = #"{"foods": [{"description": "Cola", "gtinUpc": "\#(stored)"}]}"#
        #expect(try await lookUp(FixedTransport(json: json)) == found("Cola"))
    }

    @Test("records whose barcode differs, is missing or is not a GTIN are not a match")
    func noMatchIsNotFound() async throws {
        let json = #"""
        {"foods": [
          {"description": "Other", "gtinUpc": "4006381333931"},
          {"description": "No barcode"},
          {"description": "Broken", "gtinUpc": "036000291453"},
          {"description": "Words", "gtinUpc": "cola"}
        ]}
        """#
        #expect(try await lookUp(FixedTransport(json: json)) == .notFound)
    }

    @Test("the first matching record with a usable name wins")
    func firstUsableMatch() async throws {
        let json = #"""
        {"foods": [
          {"description": "Other", "gtinUpc": "4006381333931"},
          {"description": "  ", "gtinUpc": "036000291452"},
          {"gtinUpc": "036000291452"},
          {"description": "Cola", "gtinUpc": "036000291452"},
          {"description": "Cola again", "gtinUpc": "036000291452"}
        ]}
        """#
        #expect(try await lookUp(FixedTransport(json: json)) == found("Cola"))
    }

    @Test("no results is a normal miss")
    func emptyResult() async throws {
        #expect(try await lookUp(FixedTransport(json: #"{"totalHits": 0, "foods": []}"#)) == .notFound)
    }

    @Test("an answer that cannot be read is a provider error", arguments: [
        "",
        "not json",
        #"{"foods": [{"description": "Cola", "gtinUpc": "036000291452""#,
        #"{"totalHits": 0}"#,
        #"{"foods": {}}"#,
        #"{"foods": [{"description": 7, "gtinUpc": "036000291452"}]}"#,
        #"[]"#,
    ])
    func malformed(json: String) async throws {
        #expect(try await lookUp(FixedTransport(json: json)) == .failed(.providerError))
    }

    @Test("an answer larger than any ten-result page is not read")
    func oversized() async throws {
        let filler = String(repeating: "x", count: FoodDataCentralLookup.largestBody)
        let json = #"{"foods": [{"description": "Cola", "gtinUpc": "036000291452", "pad": "\#(filler)"}]}"#
        #expect(try await lookUp(FixedTransport(json: json)) == .failed(.providerError))
        let exact = #"{"foods": [{"description": "Cola", "gtinUpc": "036000291452"}]}"#
        let padded = exact + String(repeating: " ", count: FoodDataCentralLookup.largestBody - exact.utf8.count)
        #expect(try await lookUp(FixedTransport(json: padded)) == found("Cola"))
    }

    @Test("each status maps to what the person is told", arguments: [
        (401, ProductLookupResult.failed(.keyRejected)),
        (403, .failed(.keyRejected)),
        (429, .failed(.rateLimited)),
        (400, .failed(.providerError)),
        (404, .failed(.providerError)),
        (500, .failed(.providerError)),
        (503, .failed(.providerError)),
        (302, .failed(.providerError)),
    ])
    func statuses(status: Int, result: ProductLookupResult) async throws {
        let json = #"{"foods": [{"description": "Cola", "gtinUpc": "036000291452"}]}"#
        #expect(try await lookUp(FixedTransport(status: status, json: json)) == result)
    }

    @Test("a 2xx status other than 200 is read like 200", arguments: [200, 203, 299])
    func success(status: Int) async throws {
        let json = #"{"foods": [{"description": "Cola", "gtinUpc": "036000291452"}]}"#
        #expect(try await lookUp(FixedTransport(status: status, json: json)) == found("Cola"))
    }

    @Test("api.data.gov's own error answers map to a refused key and a rate limit")
    func providerErrorBodies() async throws {
        let invalid = #"{"error": {"code": "API_KEY_INVALID", "message": "An invalid api_key was supplied."}}"#
        let limited = #"{"error": {"code": "OVER_RATE_LIMIT", "message": "You have exceeded your rate limit."}}"#
        #expect(try await lookUp(FixedTransport(status: 403, json: invalid)) == .failed(.keyRejected))
        #expect(try await lookUp(FixedTransport(status: 429, json: limited)) == .failed(.rateLimited))
    }

    @Test("transport failures map to offline, timed out, cancelled or a provider error", arguments: [
        (HTTPFailure.offline, ProductLookupFailure.offline),
        (.timedOut, .timedOut),
        (.cancelled, .cancelled),
        (.other, .providerError),
    ])
    func transportFailures(failure: HTTPFailure, expected: ProductLookupFailure) async throws {
        #expect(try await lookUp(FixedTransport(.failure(failure))) == .failed(expected))
    }

    @Test("URL loading errors are grouped by what they mean to the person", arguments: [
        (URLError.Code.notConnectedToInternet, HTTPFailure.offline),
        (.networkConnectionLost, .offline),
        (.dataNotAllowed, .offline),
        (.internationalRoamingOff, .offline),
        (.cannotFindHost, .offline),
        (.cannotConnectToHost, .offline),
        (.dnsLookupFailed, .offline),
        (.callIsActive, .offline),
        (.timedOut, .timedOut),
        (.cancelled, .cancelled),
        (.badServerResponse, .other),
        (.serverCertificateUntrusted, .other),
        (.secureConnectionFailed, .other),
    ])
    func urlErrors(code: URLError.Code, failure: HTTPFailure) {
        #expect(HTTPFailure(URLError(code)) == failure)
    }

    @Test("the session transport refuses anything but HTTPS without sending it")
    func httpsOnly() async throws {
        let request = URLRequest(url: try #require(URL(string: "http://api.nal.usda.gov/fdc/v1/foods/search")))
        #expect(await URLSessionTransport().get(request) == .failure(.other))
    }

    // MARK: Names

    @Test("a description becomes a name a person would type", arguments: [
        ("Cola", "Cola"),
        ("GREEK NONFAT YOGURT, VANILLA", "Greek nonfat yogurt, vanilla"),
        ("  Whole   milk \n", "Whole milk"),
        ("Tab\tseparated\u{0}name", "Tab separated name"),
        ("Mixed CASE Name", "Mixed CASE Name"),
        ("100% JUICE", "100% juice"),
        ("ÉCLAIRS", "Éclairs"),
        ("12345", "12345"),
    ])
    func names(description: String, name: String) {
        #expect(FoodDataCentralLookup.suggestedName(description) == name)
    }

    @Test("an empty or blank description gives no name", arguments: ["", "   ", "\u{0}\u{1}\n"])
    func blankNames(description: String) {
        #expect(FoodDataCentralLookup.suggestedName(description) == nil)
    }

    @Test("a long description is cut back to a word boundary and ends in an ellipsis")
    func longNames() throws {
        let words = String(repeating: "Abc ", count: 40)
        let name = try #require(FoodDataCentralLookup.suggestedName(words))
        #expect(name == String(repeating: "Abc ", count: 14) + "Abc…")
        #expect(name.count <= FoodDataCentralLookup.shortName)

        let sentence = "Whole grain oat cereal with honey, almonds, dried cranberries and a little cinnamon"
        #expect(FoodDataCentralLookup.suggestedName(sentence) == "Whole grain oat cereal with honey, almonds, dried…")
        #expect(FoodDataCentralLookup.suggestedName("Salted butter with sea salt & fresh cream from grass fed cows, unsalted") == "Salted butter with sea salt & fresh cream from grass fed…")
        #expect(FoodDataCentralLookup.suggestedName(String(repeating: "Abcd ", count: 11) + "& cream cheese") == String(repeating: "Abcd ", count: 10) + "Abcd…")
        #expect(FoodDataCentralLookup.suggestedName(String(repeating: "Abcd ", count: 11) + "Ab, cream cheese") == String(repeating: "Abcd ", count: 11) + "Ab…")

        let exact = String(repeating: "a", count: FoodDataCentralLookup.shortName)
        #expect(FoodDataCentralLookup.suggestedName(exact) == exact)
    }

    @Test("a single word too long for a name is cut between characters, scalars and UTF-16 units", arguments: [
        ("a", 200, 59),
        ("😀", 100, 59),
        ("👍🏽", 100, 49),
        ("é", 100, 59),
        ("e\u{0301}", 100, 59),
        ("🇺🇸", 100, 49),
        ("-", 100, 59),
    ])
    func hugeWord(character: String, repeats: Int, kept: Int) throws {
        let text = String(repeating: character, count: repeats)
        let name = try #require(FoodDataCentralLookup.suggestedName(text))
        #expect(name == String(repeating: character, count: kept) + "…")
        #expect(name.utf8.count <= FoodDataCentralLookup.longestNameBytes)
        #expect(name.count <= FoodDataCentralLookup.shortName)
        #expect(String(decoding: Array(name.utf16), as: UTF16.self) == name)
        #expect(text.unicodeScalars.starts(with: name.dropLast().unicodeScalars))
    }

    @Test("a name that fits both limits exactly is kept whole", arguments: [
        ("👍🏽", 50),
        ("a", 60),
    ])
    func exactFit(character: String, repeats: Int) {
        let text = String(repeating: character, count: repeats)
        #expect(FoodDataCentralLookup.suggestedName(text) == text)
    }

    @Test("a name is also cut by its UTF-8 bytes, so combining marks cannot make it huge")
    func nameBytes() throws {
        let marks = String(repeating: "\u{0301}", count: 5_000)
        let bomb = String(repeating: "a" + marks, count: 150)
        #expect(bomb.count == 150)
        #expect(FoodDataCentralLookup.suggestedName(bomb) == nil)

        let accented = "Cola " + String(repeating: "a" + String(repeating: "\u{0301}", count: 5), count: 150)
        #expect(FoodDataCentralLookup.suggestedName(accented) == "Cola…")

        let word = String(repeating: "a" + String(repeating: "\u{0301}", count: 5), count: 150)
        let cut = try #require(FoodDataCentralLookup.suggestedName(word))
        #expect(cut.utf8.count <= FoodDataCentralLookup.longestNameBytes)
        #expect(cut.utf8.count > FoodDataCentralLookup.longestNameBytes - 11)
        #expect(cut.hasSuffix("…"))
        #expect(word.hasPrefix(String(cut.dropLast())))
    }

    @Test("the last guard holds the hard limits by itself")
    func finalGuard() throws {
        let long = try #require(FoodDataCentralLookup.capped(String(repeating: "a", count: 150)))
        #expect(long == String(repeating: "a", count: FoodDataCentralLookup.longestName))
        let heavy = try #require(FoodDataCentralLookup.capped(String(repeating: "a\u{0301}\u{0301}", count: 90)))
        #expect(heavy.utf8.count <= FoodDataCentralLookup.longestNameBytes)
        #expect(heavy.utf8.count > FoodDataCentralLookup.longestNameBytes - 5)
        #expect(FoodDataCentralLookup.capped(" ") == nil)
    }

    // MARK: Brands

    @Test("a long ingredient-style description with its brand gives the brand first and no cut word")
    func lunchables() async throws {
        let json = #"""
        {"foods": [{"description": "EXTRA CHEESY PIZZA MOZZARELLA PASTEURIZED PREPARED CHEESE PRODUCT & PASTEURIZED PREPARED CHEESE PRODUCT, PIZZA SAUCE, CRUST",
          "gtinUpc": "036000291452", "brandName": "LUNCHABLES", "brandOwner": "Kraft Heinz Foods Company"}]}
        """#
        let name = "Lunchables extra cheesy pizza mozzarella pasteurized…"
        #expect(try await lookUp(FixedTransport(json: json)) == found(name))
    }

    @Test("the brand comes first unless the description already names it as words", arguments: [
        ("CLASSIC SODA", "COCA-COLA", "Coca-Cola classic soda"),
        ("LUNCHABLES EXTRA CHEESY PIZZA", "LUNCHABLES", "Lunchables extra cheesy pizza"),
        ("Honey Nut Cheerios", "CHEERIOS", "Honey Nut Cheerios"),
        ("COCA COLA CLASSIC", "COCA-COLA", "Coca cola classic"),
        ("ORIGINAL ICE CREAM BY BEN & JERRY'S", "BEN & JERRY'S", "Original ice cream by ben & jerry's"),
        ("KINDNESS BAR", "KIND", "Kind kindness bar"),
        ("Pure Maple Syrup", "McCormick", "McCormick Pure Maple Syrup"),
        ("MILK CHOCOLATE CANDIES", "M&M'S", "M&M's milk chocolate candies"),
        ("PEANUT BUTTER", "J.M. SMUCKER", "J.M. Smucker peanut butter"),
        ("GREEK YOGURT", "365 EVERYDAY VALUE", "365 Everyday Value greek yogurt"),
    ])
    func brandFirst(description: String, brand: String, name: String) {
        #expect(FoodDataCentralLookup.suggestedName(description, brandName: brand) == name)
    }

    @Test("the brand is kept when the description is cut")
    func brandSurvivesCut() throws {
        let description = String(repeating: "word ", count: 30)
        let name = try #require(FoodDataCentralLookup.suggestedName(description, brandName: "TILLAMOOK"))
        #expect(name == "Tillamook " + String(repeating: "word ", count: 9) + "word…")
        #expect(name.count <= FoodDataCentralLookup.shortName)

        let longest = String(repeating: "B", count: FoodDataCentralLookup.longestBrand)
        let huge = String(repeating: "x", count: 500)
        let withLongBrand = try #require(FoodDataCentralLookup.suggestedName(huge, brandName: longest))
        #expect(withLongBrand == "B" + String(repeating: "b", count: FoodDataCentralLookup.longestBrand - 1) + " " + String(repeating: "x", count: 28) + "…")
    }

    @Test("missing, null or non-text brand fields leave the description's name", arguments: [
        #"{"foods": [{"description": "COLA", "gtinUpc": "036000291452"}]}"#,
        #"{"foods": [{"description": "COLA", "gtinUpc": "036000291452", "brandName": null, "brandOwner": null}]}"#,
        #"{"foods": [{"description": "COLA", "gtinUpc": "036000291452", "brandName": 7, "brandOwner": {"name": "X"}}]}"#,
        #"{"foods": [{"description": "COLA", "gtinUpc": "036000291452", "brandName": ["A"], "brandOwner": false}]}"#,
        #"{"foods": [{"description": "COLA", "gtinUpc": "036000291452", "brandName": " \u0000 ", "brandOwner": "Supervalu, Inc."}]}"#,
    ])
    func noBrand(json: String) async throws {
        #expect(try await lookUp(FixedTransport(json: json)) == found("Cola"))
    }

    @Test("brandOwner stands in for brandName only when it is short and not a company name", arguments: [
        (nil, "TILLAMOOK", "Tillamook cheddar"),
        ("", "TILLAMOOK", "Tillamook cheddar"),
        ("CABOT", "TILLAMOOK", "Cabot cheddar"),
        (nil, "Kraft Heinz Foods Company", "Cheddar"),
        (nil, "Supervalu, Inc.", "Cheddar"),
        (nil, "General Mills Sales LLC", "Cheddar"),
        (nil, "Bob's Red Mill Natural", "Cheddar"),
        (nil, "Very Long Brand Owner Name", "Cheddar"),
        (nil, "A", "Cheddar"),
        (nil, "1234", "Cheddar"),
    ] as [(String?, String, String)])
    func ownerFallback(brandName: String?, owner: String, name: String) {
        #expect(FoodDataCentralLookup.suggestedName("CHEDDAR", brandName: brandName, brandOwner: owner) == name)
    }

    @Test("a hostile brand cannot pass the byte limit or bring in control, format or bidi characters", arguments: [
        "\u{202E}EVIL\u{200B}\u{7}BRAND\u{2066}\u{FEFF}",
        "a" + String(repeating: "\u{0301}", count: 5_000),
        String(repeating: "\u{0301}", count: 5_000),
        String(repeating: "PAD ", count: 200_000),
        String(repeating: "\u{200B}", count: 10_000) + "X",
        "\u{0}\u{1F}\u{7F}\u{85}\u{2028}\u{2029}",
    ])
    func hostileBrand(brand: String) throws {
        let description = String(repeating: "ab" + String(repeating: "\u{0301}", count: 3) + " ", count: 200)
        for text in ["COLA", description] {
            let name = try #require(FoodDataCentralLookup.suggestedName(text, brandName: brand, brandOwner: brand))
            #expect(name.utf8.count <= FoodDataCentralLookup.longestNameBytes)
            #expect(name.count <= FoodDataCentralLookup.longestName)
            #expect(!name.unicodeScalars.contains { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) })
        }
        #expect(FoodDataCentralLookup.suggestedName("COLA", brandName: "\u{202E}EVIL\u{200B}\u{7}BRAND") == "Evil Brand cola")
    }

    @Test("a brand at the limits and a description of combining marks still fit the byte limit with the ellipsis")
    func brandAndBytes() throws {
        let brand = "A" + String(repeating: "😀", count: FoodDataCentralLookup.longestBrand - 1)
        #expect(brand.utf8.count <= FoodDataCentralLookup.longestBrandBytes)
        let description = String(repeating: "a" + String(repeating: "\u{0301}", count: 19) + " ", count: 100)
        let name = try #require(FoodDataCentralLookup.suggestedName(description, brandName: brand))
        #expect(name.hasPrefix(brand + " "))
        #expect(name.hasSuffix("…"))
        #expect(name.utf8.count <= FoodDataCentralLookup.longestNameBytes)
        #expect(name.utf8.count > FoodDataCentralLookup.longestNameBytes - 25)
    }

    @Test("a brand over the limits is left out rather than cut")
    func brandTooLong() {
        let long = String(repeating: "B", count: FoodDataCentralLookup.longestBrand + 1)
        #expect(FoodDataCentralLookup.suggestedName("COLA", brandName: long) == "Cola")
        let heavy = "Ab" + String(repeating: "\u{0301}", count: FoodDataCentralLookup.longestBrandBytes)
        #expect(FoodDataCentralLookup.suggestedName("COLA", brandName: heavy) == "Cola")
    }

    @Test("a record whose barcode differs is skipped however good its brand")
    func brandDoesNotMatch() async throws {
        let json = #"{"foods": [{"description": "PIZZA KIT", "gtinUpc": "4006381333931", "brandName": "LUNCHABLES"}]}"#
        #expect(try await lookUp(FixedTransport(json: json)) == .notFound)
    }

    @Test("a blank description gives no name even with a brand, so a later record can")
    func blankDescriptionWithBrand() async throws {
        #expect(FoodDataCentralLookup.suggestedName("  \u{0} ", brandName: "LUNCHABLES") == nil)
        let json = #"""
        {"foods": [
          {"description": "  ", "gtinUpc": "036000291452", "brandName": "LUNCHABLES"},
          {"gtinUpc": "036000291452", "brandName": "LUNCHABLES"},
          {"description": "PIZZA KIT", "gtinUpc": "036000291452", "brandName": "LUNCHABLES"}
        ]}
        """#
        #expect(try await lookUp(FixedTransport(json: json)) == found("Lunchables pizza kit"))
        let only = #"{"foods": [{"description": "", "gtinUpc": "036000291452", "brandName": "LUNCHABLES"}]}"#
        #expect(try await lookUp(FixedTransport(json: only)) == .notFound)
    }
}
