import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import PantrifiedApplication
import PantrifiedDomain
@testable import PantrifiedFoodDataCentral

private let limit = 1_000_000
private let chunk = Data(repeating: UInt8(ascii: "a"), count: 65_536)

private func transport(to server: LoopbackServer) -> URLSessionTransport {
    URLSessionTransport(
        timeout: 20,
        origin: URLSessionTransport.Origin(scheme: "http", host: "127.0.0.1", port: server.port),
        limit: limit
    )
}

private func request(_ server: LoopbackServer, path: String = "/fdc/v1/foods/search") -> URLRequest {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
    request.setValue("secret-key", forHTTPHeaderField: "X-Api-Key")
    return request
}

/// Holds what a completion handler was given.
private final class Answer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    private var calls = 0

    var value: Value? { lock.withLock { stored } }
    var count: Int { lock.withLock { calls } }

    func set(_ value: Value?) {
        lock.withLock {
            stored = value
            calls += 1
        }
    }
}

/// A task that is never resumed, for driving the delegate by hand.
private func idleTask() -> URLSessionDataTask {
    URLSession(configuration: .ephemeral).dataTask(with: URL(string: "http://127.0.0.1:9/")!)
}

@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {
    // MARK: Against a local server

    @Test("a body that keeps growing past the limit is cut off, not read to the end")
    func streamingBodyStopsEarly() async throws {
        // 32 MB with no length announced, so only the running count can stop it, at about 30 MB a
        // second, faster than a phone's network.
        let server = try LoopbackServer(
            head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
            body: chunk, repeats: 512, pauseMicroseconds: 2_000
        )
        defer { server.stop() }

        let result = await transport(to: server).get(request(server))

        #expect(result == .failure(.other))
        #expect(server.waitForConnection())
        // The limit plus what the sockets and URLSession buffer, far short of the 32 MB on offer.
        #expect(server.bodyBytesSent < 16_000_000, "\(server.bodyBytesSent) bytes were read")
    }

    @Test("a body announced as larger than the limit is refused without reading it")
    func announcedLengthRefused() async throws {
        let size = 64 * chunk.count * 16
        let server = try LoopbackServer(
            head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n",
            body: chunk, repeats: size / chunk.count, pauseMicroseconds: 2_000
        )
        defer { server.stop() }

        let result = await transport(to: server).get(request(server))

        #expect(result == .failure(.other))
        #expect(server.waitForConnection())
        #expect(server.bodyBytesSent < size / 4, "\(server.bodyBytesSent) bytes were read")
    }

    @Test("a body within the limit is returned whole with its status")
    func smallBody() async throws {
        let json = Data(#"{"foods": []}"#.utf8)
        let server = try LoopbackServer(
            head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n",
            body: json
        )
        defer { server.stop() }

        let result = await transport(to: server).get(request(server))

        #expect(result == .success(HTTPReply(status: 200, body: json)))
        #expect(server.requests.first?.contains("X-Api-Key: secret-key") == true)
    }

    @Test("a body exactly at the limit is returned")
    func bodyAtLimit() async throws {
        let body = Data(repeating: UInt8(ascii: " "), count: limit)
        let server = try LoopbackServer(
            head: "HTTP/1.1 200 OK\r\nContent-Length: \(limit)\r\nConnection: close\r\n\r\n", body: body
        )
        defer { server.stop() }

        let result = await transport(to: server).get(request(server))

        #expect(result == .success(HTTPReply(status: 200, body: body)))
    }

    @Test("a redirect is not followed, so the key reaches no other server, and the 3xx is returned as it is")
    func redirectNotFollowed() async throws {
        let elsewhere = try LoopbackServer(head: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n", body: Data("{}".utf8))
        defer { elsewhere.stop() }
        let server = try LoopbackServer(
            head: "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(elsewhere.port)/steal\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        defer { server.stop() }

        let result = await transport(to: server).get(request(server))

        #expect(result == .success(HTTPReply(status: 302, body: Data())))
        #expect(server.requests.count == 1)
        // Long enough for a followed redirect to have arrived.
        #expect(!elsewhere.waitForConnection(seconds: 1))
        #expect(elsewhere.requests.isEmpty)
    }

    @Test("a redirect reads to the person as a provider error")
    func redirectIsProviderError() async throws {
        let server = try LoopbackServer(
            head: "HTTP/1.1 301 Moved Permanently\r\nLocation: https://example.com/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        defer { server.stop() }
        let reply = await transport(to: server).get(request(server))
        let body = try #require(try? reply.get())

        #expect(FoodDataCentralLookup.result(of: body, for: GTIN("036000291452")!) == .failed(.providerError))
    }

    @Test("a request for any other scheme, host or port is not sent")
    func otherOriginsRefused() async throws {
        let server = try LoopbackServer(head: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }
        let elsewhere = URLSessionTransport(
            timeout: 5, origin: URLSessionTransport.Origin(scheme: "http", host: "127.0.0.1", port: server.port + 1), limit: limit
        )

        #expect(await elsewhere.get(request(server)) == .failure(.other))
        #expect(!server.waitForConnection(seconds: 0.5))
        #expect(server.requests.isEmpty)
    }

    // MARK: The production origin

    @Test("only HTTPS to api.nal.usda.gov on the default port is allowed", arguments: [
        ("https://api.nal.usda.gov/fdc/v1/foods/search", true),
        ("HTTPS://API.NAL.USDA.GOV/fdc/v1/foods/search", true),
        ("http://api.nal.usda.gov/fdc/v1/foods/search", false),
        ("https://api.nal.usda.gov:8443/fdc/v1/foods/search", false),
        ("https://api.nal.usda.gov.example.com/fdc/v1/foods/search", false),
        ("https://example.com/fdc/v1/foods/search", false),
        ("https://evil.example/?host=api.nal.usda.gov", false),
    ])
    func productionOrigin(url: String, allowed: Bool) {
        #expect(URLSessionTransport.Origin.foodDataCentral.allows(URL(string: url)) == allowed)
    }

    @Test("the default transport refuses a non-FoodData Central URL without sending it")
    func defaultTransportRefuses() async throws {
        let refused = URLRequest(url: try #require(URL(string: "https://example.com/fdc/v1/foods/search")))
        #expect(await URLSessionTransport().get(refused) == .failure(.other))
    }

    // MARK: The delegate by hand

    @Test("an announced length over the limit cancels before the body; one at the limit or unknown is allowed")
    func announcedLength() {
        func disposition(_ length: Int) -> URLSession.ResponseDisposition? {
            let download = CappedDownload(limit: 100)
            let response = URLResponse(url: URL(string: "http://127.0.0.1/")!, mimeType: nil, expectedContentLength: length, textEncodingName: nil)
            let answer = Answer<URLSession.ResponseDisposition>()
            download.urlSession(URLSession.shared, dataTask: idleTask(), didReceive: response) { answer.set($0) }
            return answer.value
        }
        #expect(disposition(101) == .cancel)
        #expect(disposition(100) == .allow)
        #expect(disposition(-1) == .allow)
    }

    @Test("data past the limit is dropped and the task cancelled; data within it is kept")
    func runningLimit() {
        let download = CappedDownload(limit: 100)
        let task = idleTask()

        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 60))
        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 40))
        #expect(download.heldBytes == 100)
        #expect(task.state == .suspended)

        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 1))
        #expect(download.heldBytes == 0)
        #expect(task.state != .suspended)

        download.urlSession(URLSession.shared, dataTask: task, didReceive: Data(count: 1))
        #expect(download.heldBytes == 0)
    }

    @Test("every redirect is refused")
    func redirectRefused() {
        let download = CappedDownload(limit: 100)
        let url = URL(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
        let followed = Answer<URLRequest>()

        download.urlSession(URLSession.shared, task: idleTask(), willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)) {
            followed.set($0)
        }

        #expect(followed.count == 1)
        #expect(followed.value == nil)
    }
}
