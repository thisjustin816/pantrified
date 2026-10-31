import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A small HTTP server on 127.0.0.1 for testing the URLSession transport against a real socket.
/// Every connection gets the same reply: `head`, then `body` written `repeats` times, until the
/// client stops reading. It records each request's head and how many body bytes the client took.
///
/// `pause` waits between body writes. Loopback is far faster than any network a phone uses, and
/// URLSession delivers data to its delegate on a queue of its own, so a busy test machine can read
/// megabytes ahead of the delegate before a cancel takes effect. How many bytes the server managed
/// to write therefore depends on machine load, and a test must not assert on it.
///
/// `holdOpen` makes the server stop after the last body write and keep the connection open, sending
/// nothing, until the client closes it or `holdSeconds` pass. A client that stops reading on its own
/// closes the connection at once. A client that waits for the end of an answer that never comes
/// does not, which a test can see without any timing assumption: see `clientClosedBeforeEnd`.
final class LoopbackServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let head: String
    private let body: Data
    private let repeats: Int
    private let pause: useconds_t
    private let holdOpen: Bool
    private let holdSeconds: Int32
    private let lock = NSLock()
    /// Guarded by `lock`.
    private var heads: [String] = []
    /// Guarded by `lock`.
    private var sent = 0
    /// Guarded by `lock`.
    private var stopped = false
    /// Guarded by `lock`.
    private var closedWhileHeld = false
    private let finishedConnection = DispatchSemaphore(value: 0)

    init(
        head: String, body: Data = Data(), repeats: Int = 1, pauseMicroseconds: UInt32 = 0,
        holdOpen: Bool = false, holdSeconds: Int32 = 15
    ) throws {
        self.head = head
        self.body = body
        self.repeats = repeats
        pause = useconds_t(pauseMicroseconds)
        self.holdOpen = holdOpen
        self.holdSeconds = holdSeconds
        #if canImport(Glibc)
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard listener >= 0 else { throw ServerError() }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(listener, generic, length) == 0 && listen(listener, 8) == 0
                    && getsockname(listener, generic, &length) == 0
            }
        }
        guard bound else {
            close(listener)
            throw ServerError()
        }
        self.listener = listener
        port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global().async { self.serve() }
    }

    struct ServerError: Error {}

    /// The head of every request received, in order.
    var requests: [String] { lock.withLock { heads } }
    /// Body bytes the server wrote, across all connections. Depends on machine load: do not assert on it.
    var bodyBytesSent: Int { lock.withLock { sent } }
    /// With `holdOpen`: whether the client closed the connection while the server was still holding
    /// it open, that is, before the answer ended.
    var clientClosedBeforeEnd: Bool { lock.withLock { closedWhileHeld } }

    /// Waits until a connection has been answered and closed.
    func waitForConnection(seconds: Double = 30) -> Bool {
        finishedConnection.wait(timeout: .now() + seconds) == .success
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func serve() {
        while !lock.withLock({ stopped }) {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 50) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            answer(connection)
            close(connection)
            finishedConnection.signal()
        }
        close(listener)
    }

    private func answer(_ connection: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.range(of: Data("\r\n\r\n".utf8)) == nil, received.count < 65_536 {
            let count = recv(connection, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            received.append(contentsOf: buffer[0..<count])
        }
        lock.withLock { heads.append(String(decoding: received, as: UTF8.self)) }
        guard write(Data(head.utf8), to: connection) else { return }
        for _ in 0..<repeats {
            guard write(body, to: connection) else {
                // The client went away while the answer was still being written.
                if holdOpen { lock.withLock { closedWhileHeld = true } }
                return
            }
            lock.withLock { sent += body.count }
            if pause > 0 { usleep(pause) }
        }
        if holdOpen { waitForClientToClose(connection) }
    }

    /// Sends nothing and waits for the client to close, which shows as a read of zero bytes or an
    /// error, for at most `holdSeconds`.
    private func waitForClientToClose(_ connection: Int32) {
        var waiting = pollfd(fd: connection, events: Int16(POLLIN), revents: 0)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var remaining = holdSeconds * 1000
        while remaining > 0, !lock.withLock({ stopped }) {
            guard poll(&waiting, 1, 50) > 0 else {
                remaining -= 50
                continue
            }
            if recv(connection, &buffer, buffer.count, 0) <= 0 {
                lock.withLock { closedWhileHeld = true }
                return
            }
        }
    }

    private func write(_ data: Data, to connection: Int32) -> Bool {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let written = send(connection, raw.baseAddress! + offset, raw.count - offset, flags)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
