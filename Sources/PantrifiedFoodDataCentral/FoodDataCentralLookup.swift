import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PantrifiedApplication
import PantrifiedDomain

/// A product lookup against USDA FoodData Central's branded food search. A request carries the
/// barcode, written in each length the service may store it in, and the app's api.data.gov key,
/// and nothing about the person; the result is a name suggestion only when the record's own
/// barcode is the one scanned.
public struct FoodDataCentralLookup: ProductLookupService, RateLimitReportingLookup {
    public static let source = "USDA FoodData Central"
    static let endpoint = "https://api.nal.usda.gov/fdc/v1/foods/search"
    /// Branded foods are the records with barcodes; a small page keeps the answer small.
    static let fixedQuery = [URLQueryItem(name: "dataType", value: "Branded"), URLQueryItem(name: "pageSize", value: "10")]
    /// Far more than a ten-result page. The transport stops reading an answer that grows past it.
    static let largestBody = 1_000_000
    /// The hard ceiling on a name, applied last whatever the steps before it produce.
    static let longestName = 100
    /// Also a byte limit, because one character can hold any number of combining marks.
    static let longestNameBytes = 400
    /// A longer name is cut back to a word boundary at or before this many characters, the
    /// ellipsis included, so the suggestion reads as a name rather than an ingredient list.
    static let shortName = 60
    static let ellipsis: Character = "…"
    /// A brand past these is left out rather than cut, since half a brand names nothing.
    static let longestBrand = 30
    static let longestBrandBytes = 120
    /// `brandOwner` is a company's legal name more often than a brand, so it stands in for a
    /// missing `brandName` only when it is short and carries no company word.
    static let longestOwner = 24
    static let mostOwnerWords = 3
    static let companyWords: Set<String> = [
        "inc", "incorporated", "llc", "ltd", "limited", "co", "corp", "corporation", "company", "companies",
        "lp", "llp", "plc", "gmbh", "holdings", "group", "brands", "enterprises", "industries", "international",
    ]

    private let apiKey: String
    private let transport: any HTTPTransport

    /// Nil when the key is empty, which turns lookup off.
    public init?(apiKey: String, transport: any HTTPTransport = URLSessionTransport()) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        self.apiKey = key
        self.transport = transport
    }

    public func lookUp(_ barcode: GTIN) async -> ProductLookupResult {
        await lookUpReportingRateLimit(barcode).result
    }

    /// The result with the rate limit headers that came with it, for `PacedProductLookup`.
    public func lookUpReportingRateLimit(_ barcode: GTIN) async -> ReportedLookup {
        guard !Task.isCancelled else { return ReportedLookup(.failed(.cancelled)) }
        switch await transport.get(request(for: barcode)) {
        case .failure(let failure):
            return ReportedLookup(.failed(failure.lookupFailure))
        case .success(let reply):
            return ReportedLookup(
                Self.result(of: reply, for: barcode),
                rateLimit: RateLimitReport(remaining: reply.rateLimitRemaining, retryAfter: reply.retryAfter)
            )
        }
    }

    func request(for barcode: GTIN) -> URLRequest {
        var components = URLComponents(string: Self.endpoint)
        // Separate words in one query match any of them, so one request covers every length.
        let query = barcode.foodDataCentralForms.joined(separator: " ")
        components?.queryItems = [URLQueryItem(name: "query", value: query)] + Self.fixedQuery
        // The endpoint is a constant, so building its URL cannot fail.
        var request = URLRequest(url: components!.url!)
        request.httpMethod = "GET"
        // In a header rather than the query, so the key stays out of URLs that get logged.
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Fixed values, so the request does not carry the device's OS version or language.
        request.setValue("Pantrified", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    static func result(of reply: HTTPReply, for barcode: GTIN) -> ProductLookupResult {
        switch reply.status {
        case 200..<300: break
        case 401, 403: return .failed(.keyRejected)
        // When lookups may resume is the pacing's decision, from the Retry-After it is passed.
        case 429: return .failed(.rateLimited(resumesAt: nil))
        default: return .failed(.providerError)
        }
        guard reply.body.count <= largestBody,
              let response = try? JSONDecoder().decode(SearchResponse.self, from: reply.body)
        else { return .failed(.providerError) }
        for food in response.foods where food.gtinUpc.flatMap(GTIN.init) == barcode {
            if let description = food.description,
               let name = suggestedName(description, brandName: food.brandName, brandOwner: food.brandOwner) {
                return .found(ProductSuggestion(name: name, source: source))
            }
        }
        return .notFound
    }

    /// The record as a name a person would type: the brand, when the description does not already
    /// name it, then the description. Each part has control characters removed and spaces
    /// collapsed; an all-capitals description is put in sentence case and an all-capitals brand
    /// has each word capitalized. A name longer than `shortName` characters, or `longestNameBytes`
    /// bytes of UTF-8, has its description cut back to a word boundary and ends in an ellipsis,
    /// so the brand is kept. A description with no usable text gives no name, brand or not.
    static func suggestedName(_ description: String, brandName: String? = nil, brandOwner: String? = nil) -> String? {
        guard let (lowered, wasCapitals) = cleaned(description) else { return nil }
        let sentence = wasCapitals ? lowered.prefix(1).uppercased() + lowered.dropFirst() : lowered
        guard let alone = shortened(sentence, characters: shortName, bytes: longestNameBytes) else { return nil }
        guard let brand = brand(name: brandName, owner: brandOwner), !mentions(alone, brand) else {
            return capped(alone)
        }
        // After the brand, an all-capitals description reads as a continuation, so it stays lowercase.
        guard let rest = shortened(
            lowered,
            characters: shortName - brand.count - 1,
            bytes: longestNameBytes - brand.utf8.count - 1
        ) else { return nil }
        return capped(brand + " " + rest)
    }

    /// Control characters become spaces, runs of spaces become one, and text with no lowercase
    /// letter is lowercased, which the second value reports. Nil when nothing is left.
    static func cleaned(_ text: String) -> (String, Bool)? {
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        let joined = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        let capitals = !joined.contains(where: \.isLowercase)
        return (capitals ? joined.lowercased() : joined, capitals)
    }

    /// `brandName` when it is usable, otherwise `brandOwner` when it is short and reads like a brand.
    static func brand(name: String?, owner: String?) -> String? {
        if let name, let brand = presentableBrand(name) { return brand }
        guard let owner, let brand = presentableBrand(owner),
              brand.count <= longestOwner,
              brand.split(separator: " ").count <= mostOwnerWords,
              !words(brand).contains(where: companyWords.contains)
        else { return nil }
        return brand
    }

    /// The brand cleaned like a description, with an all-capitals brand capitalized word by word
    /// and a mixed-case brand left as written. Nil when it has no letter, is a single character,
    /// or is past the brand limits.
    static func presentableBrand(_ text: String) -> String? {
        guard let (lowered, wasCapitals) = cleaned(text) else { return nil }
        let brand = wasCapitals ? wordCapitalized(lowered) : lowered
        guard brand.count >= 2, brand.count <= longestBrand, brand.utf8.count <= longestBrandBytes,
              brand.contains(where: \.isLetter)
        else { return nil }
        return brand
    }

    /// Capitalizes each letter that starts the text or follows a space, hyphen, ampersand, slash
    /// or full stop, so "coca-cola" reads "Coca-Cola" and "m&m's" reads "M&M's".
    static func wordCapitalized(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            let starts = previous.map { " -&/.".contains($0) } ?? true
            result += starts && character.isLetter ? character.uppercased() : String(character)
            previous = character
        }
        return result
    }

    /// Whether the brand's words appear together in the text, ignoring case and punctuation, so
    /// "Lay" is not found in "Layered".
    static func mentions(_ text: String, _ brand: String) -> Bool {
        let needle = words(brand)
        let haystack = words(text)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains {
            haystack[$0..<($0 + needle.count)].elementsEqual(needle)
        }
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The text unchanged when it fits, otherwise cut so that it and an ellipsis fit both limits.
    /// The cut is between characters, so never inside a grapheme cluster or a scalar, and goes back
    /// to the last space when it would land inside a word; text with no space in reach is cut
    /// at the last character that fits. Separators left dangling at the end are dropped. Nil when
    /// not even one character fits.
    static func shortened(_ text: String, characters: Int, bytes: Int) -> String? {
        if text.count <= characters, text.utf8.count <= bytes { return text }
        let ellipsisBytes = String(ellipsis).utf8.count
        var end = text.startIndex
        var count = 0
        var used = 0
        while end < text.endIndex {
            let size = text[end].utf8.count
            guard count + 2 <= characters, used + size + ellipsisBytes <= bytes else { break }
            count += 1
            used += size
            end = text.index(after: end)
        }
        let fitting = text[..<end]
        guard !fitting.isEmpty else { return nil }
        var kept = fitting
        if end < text.endIndex, !text[end].isWhitespace, let space = fitting.lastIndex(where: \.isWhitespace) {
            kept = fitting[..<space]
        }
        let dangling: (Character) -> Bool = { $0.isWhitespace || ",;:&-/+(".contains($0) }
        while let last = kept.last, dangling(last) { kept = kept.dropLast() }
        if kept.isEmpty { kept = fitting }
        return String(kept) + String(ellipsis)
    }

    /// The last guard: at most `longestName` characters and `longestNameBytes` bytes of UTF-8, cut
    /// between characters. Nil when nothing is left.
    static func capped(_ name: String) -> String? {
        var kept = ""
        var bytes = 0
        for character in name.prefix(longestName) {
            bytes += character.utf8.count
            guard bytes <= longestNameBytes else { break }
            kept.append(character)
        }
        let trimmed = kept.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct SearchResponse: Decodable {
        let foods: [Food]

        struct Food: Decodable {
            let description: String?
            let gtinUpc: String?
            let brandName: String?
            let brandOwner: String?

            private enum CodingKeys: String, CodingKey {
                case description, gtinUpc, brandName, brandOwner
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                description = try container.decodeIfPresent(String.self, forKey: .description)
                gtinUpc = try container.decodeIfPresent(String.self, forKey: .gtinUpc)
                // The brand only adds to a name, so a brand of the wrong type is read as absent
                // rather than failing the whole answer.
                brandName = try? container.decodeIfPresent(String.self, forKey: .brandName)
                brandOwner = try? container.decodeIfPresent(String.self, forKey: .brandOwner)
            }
        }
    }
}

extension GTIN {
    /// The digit strings FoodData Central may hold this GTIN as in a record's `gtinUpc`, shortest
    /// first: the 14 digits cut to each of 8, 12, 13 and 14 digits that drops only leading zeros.
    /// Its search matches a barcode only as the exact string stored, and records store one in
    /// different lengths, so a search for one length misses the others.
    ///
    /// By what was scanned: a UPC-A, a UPC-E (as the UPC-A it expands to), an EAN-13 starting 0
    /// and a GTIN-14 starting 00 get 12, 13 and 14 digits; an EAN-13 with another first digit and
    /// a GTIN-14 starting with one 0 get 13 and 14; any code whose 14 digits start with six zeros,
    /// an EAN-8 or a UPC-A starting 0000, also gets 8. A UPC-E's own eight digits are not a form,
    /// since they read as a different GTIN-8, and no other length is one, since `GTIN` reads no
    /// other length as a GTIN and a record stored that way could never be accepted.
    var foodDataCentralForms: [String] {
        [8, 12, 13, 14]
            .filter { length in digits.prefix(14 - length).allSatisfy { $0 == "0" } }
            .map { String(digits.suffix($0)) }
    }
}

public struct HTTPReply: Sendable, Hashable {
    public var status: Int
    public var body: Data
    /// The answer's Retry-After as seconds from when it arrived, read by `RateLimitHeaders`.
    public var retryAfter: TimeInterval?
    /// The answer's X-RateLimit-Remaining, read by `RateLimitHeaders`.
    public var rateLimitRemaining: Int?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil, rateLimitRemaining: Int? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
        self.rateLimitRemaining = rateLimitRemaining
    }
}

/// Reads the rate limit headers of an answer. They come from a remote service, so each is read
/// strictly and any value outside its bounds is dropped rather than repaired. Neither is ever logged.
enum RateLimitHeaders {
    /// Past this a Retry-After is nonsense rather than a long block, and is dropped.
    static let largestRetryAfter: TimeInterval = 7 * 86_400
    static let largestRemaining = 10_000_000

    /// The value of the one header with this name, matched without regard to case. Nil when no
    /// header or more than one has the name.
    static func value(_ name: String, in fields: [AnyHashable: Any]) -> String? {
        let matching = fields.filter { ($0.key as? String)?.lowercased() == name.lowercased() }
        guard matching.count == 1 else { return nil }
        return matching.first?.value as? String
    }

    /// Retry-After as a non-negative whole number of seconds, or as an IMF-fixdate HTTP date such
    /// as `Sun, 06 Nov 1994 08:49:37 GMT`. A date is measured from the answer's own Date header
    /// when that is readable, so a wrong device clock does not stretch it, and from `now`
    /// otherwise; a date already past counts as no wait. The result is held between
    /// `LookupPacing.shortestPause` and `LookupPacing.longestPause`. Nil for anything else,
    /// including a sign, a fraction, an exponent, non-ASCII digits, a list, or more than
    /// `largestRetryAfter`.
    static func retryAfter(_ text: String?, date: String? = nil, now: Date) -> TimeInterval? {
        guard let text = trimmed(text) else { return nil }
        let seconds: TimeInterval
        if let whole = digits(text, longest: 9) {
            seconds = TimeInterval(whole)
        } else if let retry = httpDate(text) {
            let base = trimmed(date).flatMap(httpDate) ?? now
            seconds = max(0, retry.timeIntervalSince(base))
        } else {
            return nil
        }
        guard seconds <= largestRetryAfter else { return nil }
        return LookupPacing.pause(retryAfter: seconds)
    }

    /// X-RateLimit-Remaining as a whole number from 0 to `largestRemaining`, or nil.
    static func remaining(_ text: String?) -> Int? {
        guard let text = trimmed(text), let value = digits(text, longest: 8), value <= largestRemaining else { return nil }
        return value
    }

    /// The text without the spaces and tabs HTTP allows around a value, or nil when nothing is left.
    private static func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        let inner = text.drop(while: blank).reversed().drop(while: blank).reversed()
        return inner.isEmpty ? nil : String(inner)
    }

    /// The text as a number when it is one to `longest` ASCII digits and nothing else.
    private static func digits(_ text: String, longest: Int) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...longest).contains(bytes.count), bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    private static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// An IMF-fixdate, exactly 29 ASCII characters, with a real day of the month. The weekday is
    /// checked for form only. Obsolete HTTP date forms are not read.
    static func httpDate(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 29, bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        func part(_ from: Int, _ length: Int) -> String {
            String(decoding: bytes[from..<(from + length)], as: UTF8.self)
        }
        func number(_ from: Int, _ length: Int) -> Int? { digits(part(from, length), longest: length) }
        guard weekdays.contains(part(0, 3)), part(3, 2) == ", ", bytes[7] == 0x20, bytes[11] == 0x20,
              bytes[16] == 0x20, bytes[19] == 0x3A, bytes[22] == 0x3A, text.hasSuffix(" GMT"),
              let day = number(5, 2), let monthIndex = months.firstIndex(of: part(8, 3)),
              let year = number(12, 4), let hour = number(17, 2), let minute = number(20, 2),
              let second = number(23, 2),
              hour < 24, minute < 60, second < 61
        else { return nil }
        let month = monthIndex + 1
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][monthIndex]
        guard (1...monthDays).contains(day) else { return nil }
        let days = daysSince1970(year: year, month: month, day: day)
        return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
    }

    /// Days from 1 January 1970 to a date in the proleptic Gregorian calendar.
    private static func daysSince1970(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

public enum HTTPFailure: Error, Sendable, Hashable {
    case offline
    case timedOut
    case cancelled
    case other

    var lookupFailure: ProductLookupFailure {
        switch self {
        case .offline: .offline
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .other: .providerError
        }
    }

    /// How a URL loading error reads to a person: no network, too slow, stopped, or anything else.
    public init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .callIsActive:
            self = .offline
        case .timedOut: self = .timedOut
        case .cancelled: self = .cancelled
        default: self = .other
        }
    }
}

/// One HTTPS GET. Behind a protocol so the lookup's handling of each answer is tested without a
/// network.
public protocol HTTPTransport: Sendable {
    func get(_ request: URLRequest) async -> Result<HTTPReply, HTTPFailure>
}

/// URLSession with an ephemeral configuration: no cookies, no cache and no credential storage, so
/// nothing about a lookup is kept on the device, and a short timeout so a slow network gives up
/// quickly instead of leaving the person waiting.
///
/// It sends a request only to FoodData Central's host, follows no redirect, so the key header
/// never goes anywhere else, and stops reading an answer once its body, after any decompression,
/// grows past the limit.
public struct URLSessionTransport: HTTPTransport {
    /// Where requests may go: scheme, host and port must all match.
    struct Origin: Sendable, Hashable {
        var scheme: String
        var host: String
        var port: Int?

        static let foodDataCentral = Origin(scheme: "https", host: "api.nal.usda.gov", port: nil)

        func allows(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme?.lowercased() == scheme && url.host?.lowercased() == host && url.port == port
        }
    }

    private let timeout: TimeInterval
    private let origin: Origin
    private let limit: Int

    public init(timeout: TimeInterval = 8) {
        self.init(timeout: timeout, origin: .foodDataCentral, limit: FoodDataCentralLookup.largestBody)
    }

    init(timeout: TimeInterval, origin: Origin, limit: Int) {
        self.timeout = timeout
        self.origin = origin
        self.limit = limit
    }

    public func get(_ request: URLRequest) async -> Result<HTTPReply, HTTPFailure> {
        guard origin.allows(request.url) else { return .failure(.other) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        let download = CappedDownload(limit: limit)
        // A session per request, because its delegate holds that request's body.
        let session = URLSession(configuration: configuration(), delegate: download, delegateQueue: nil)
        let task = session.dataTask(with: request)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                download.start(task, reporting: continuation)
            }
        } onCancel: {
            task.cancel()
        }
        session.finishTasksAndInvalidate()
        return result
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        #if canImport(Darwin)
        // Offline answers at once, so the person is never left waiting for a network to appear.
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        #endif
        return configuration
    }
}

/// Collects one task's answer. URLSession hands the delegate the body as it arrives, already
/// decompressed, so the limit applies to the bytes the app would hold, and the task is cancelled
/// as soon as they pass it. A body announced as larger than the limit is refused before any of it
/// is read. Every redirect is refused, so a 3xx answer completes the task as it is.
final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    /// Guarded by `lock`.
    private var body = Data()
    /// Guarded by `lock`.
    private var tooLarge = false
    /// Guarded by `lock`.
    private var continuation: CheckedContinuation<Result<HTTPReply, HTTPFailure>, Never>?

    init(limit: Int) {
        self.limit = limit
    }

    /// The bytes held so far, for tests.
    var heldBytes: Int { lock.withLock { body.count } }

    func start(_ task: URLSessionDataTask, reporting continuation: CheckedContinuation<Result<HTTPReply, HTTPFailure>, Never>) {
        lock.withLock { self.continuation = continuation }
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= Int64(limit) else {
            lock.withLock { tooLarge = true }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = lock.withLock { () -> Bool in
            if tooLarge { return true }
            guard body.count + data.count <= limit else {
                tooLarge = true
                body = Data()
                return true
            }
            body.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let response = task.response
        let (result, waiting) = lock.withLock { () -> (Result<HTTPReply, HTTPFailure>, CheckedContinuation<Result<HTTPReply, HTTPFailure>, Never>?) in
            let waiting = continuation
            continuation = nil
            if tooLarge { return (.failure(.other), waiting) }
            if let error { return (.failure((error as? URLError).map(HTTPFailure.init) ?? .other), waiting) }
            guard let http = response as? HTTPURLResponse else { return (.failure(.other), waiting) }
            let headers = http.allHeaderFields
            return (.success(HTTPReply(
                status: http.statusCode,
                body: body,
                retryAfter: RateLimitHeaders.retryAfter(
                    RateLimitHeaders.value("Retry-After", in: headers),
                    date: RateLimitHeaders.value("Date", in: headers),
                    now: Date()
                ),
                rateLimitRemaining: RateLimitHeaders.remaining(RateLimitHeaders.value("X-RateLimit-Remaining", in: headers))
            )), waiting)
        }
        waiting?.resume(returning: result)
    }
}
