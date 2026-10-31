import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PantrifiedApplication
import PantrifiedDomain

/// A product lookup against USDA FoodData Central's branded food search. A request carries the
/// barcode and the app's api.data.gov key and nothing about the person; the result is a name
/// suggestion only when the record's own barcode is the one scanned.
public struct FoodDataCentralLookup: ProductLookupService {
    public static let source = "USDA FoodData Central"
    static let endpoint = "https://api.nal.usda.gov/fdc/v1/foods/search"
    /// Branded foods are the records with barcodes; a small page keeps the answer small.
    static let fixedQuery = [URLQueryItem(name: "dataType", value: "Branded"), URLQueryItem(name: "pageSize", value: "10")]
    /// A larger answer than a ten-result page can be is not read.
    static let largestBody = 1_000_000
    static let longestName = 100

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
        guard !Task.isCancelled else { return .failed(.cancelled) }
        switch await transport.get(request(for: barcode)) {
        case .failure(let failure):
            return .failed(failure.lookupFailure)
        case .success(let reply):
            return Self.result(of: reply, for: barcode)
        }
    }

    func request(for barcode: GTIN) -> URLRequest {
        var components = URLComponents(string: Self.endpoint)
        components?.queryItems = [URLQueryItem(name: "query", value: barcode.issuedForm)] + Self.fixedQuery
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
        case 429: return .failed(.rateLimited)
        default: return .failed(.providerError)
        }
        guard reply.body.count <= largestBody,
              let response = try? JSONDecoder().decode(SearchResponse.self, from: reply.body)
        else { return .failed(.providerError) }
        for food in response.foods where food.gtinUpc.flatMap(GTIN.init) == barcode {
            if let name = food.description.flatMap(suggestedName) {
                return .found(ProductSuggestion(name: name, source: source))
            }
        }
        return .notFound
    }

    /// The record's description as a name a person would type: control characters removed, spaces
    /// collapsed, all-capitals text in sentence case, and no longer than `longestName`.
    static func suggestedName(_ description: String) -> String? {
        let visible = String(String.UnicodeScalarView(description.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : $0
        }))
        var name = visible.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !name.contains(where: \.isLowercase) {
            name = name.lowercased()
            if let first = name.first { name = first.uppercased() + name.dropFirst() }
        }
        if name.count > longestName {
            name = String(name.prefix(longestName)).trimmingCharacters(in: .whitespaces)
        }
        return name.isEmpty ? nil : name
    }

    private struct SearchResponse: Decodable {
        let foods: [Food]

        struct Food: Decodable {
            let description: String?
            let gtinUpc: String?
        }
    }
}

public struct HTTPReply: Sendable, Hashable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
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
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
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
        session = URLSession(configuration: configuration)
    }

    public func get(_ request: URLRequest) async -> Result<HTTPReply, HTTPFailure> {
        guard request.url?.scheme == "https" else { return .failure(.other) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.other) }
            return .success(HTTPReply(status: http.statusCode, body: data))
        } catch let error as URLError {
            return .failure(HTTPFailure(error))
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.other)
        }
    }
}
