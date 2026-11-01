#if DEBUG
import Foundation
import PantrifiedApplication

/// Per-photo read times, for measuring how long Vision takes on a phone. Debug builds only: Release
/// builds compile none of this. The times stay in memory and are shown only on the batch screen.
final class ReadTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    func add(_ duration: Duration) {
        lock.withLock { durations.append(duration) }
    }

    /// "Read 12 photos: last 0.84 s, mean 0.91 s, slowest 1.30 s", or nil before the first read.
    var summary: String? {
        lock.withLock {
            guard let last = durations.last, let slowest = durations.max() else { return nil }
            let mean = durations.reduce(Duration.zero, +) / durations.count
            func seconds(_ value: Duration) -> String {
                let parts = value.components
                return String(format: "%.2f s", Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
            }
            return "Read \(durations.count) photos: last \(seconds(last)), mean \(seconds(mean)), slowest \(seconds(slowest))"
        }
    }
}

/// Times each read of the recognizer it wraps.
struct TimedRecognizer: PhotoRecognizer {
    let inner: any PhotoRecognizer
    let timer: ReadTimer

    func read(_ file: URL) async throws -> PhotoReading {
        let clock = ContinuousClock()
        let start = clock.now
        let reading = try await inner.read(file)
        timer.add(clock.now - start)
        return reading
    }
}
#endif
