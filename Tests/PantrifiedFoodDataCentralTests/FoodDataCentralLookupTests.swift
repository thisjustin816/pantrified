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

    @Test("a long description is cut to the longest name, without a trailing space")
    func longNames() throws {
        let words = String(repeating: "Abc ", count: 40)
        let name = try #require(FoodDataCentralLookup.suggestedName(words))
        #expect(name.count <= FoodDataCentralLookup.longestName)
        #expect(name.count >= FoodDataCentralLookup.longestName - 1)
        #expect(!name.hasSuffix(" "))
        let exact = String(repeating: "a", count: FoodDataCentralLookup.longestName)
        #expect(FoodDataCentralLookup.suggestedName(exact)?.count == FoodDataCentralLookup.longestName)
        #expect(FoodDataCentralLookup.suggestedName(exact + "b")?.count == FoodDataCentralLookup.longestName)
    }
}
