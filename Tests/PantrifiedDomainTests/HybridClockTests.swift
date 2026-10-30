import Foundation
import Testing
@testable import PantrifiedDomain

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func seconds(_ n: Double) -> Date { t0.addingTimeInterval(n) }

@Suite("Hybrid logical clock")
struct HybridClockTests {
    @Test("readings increase while physical time advances")
    func advancesWithPhysicalTime() {
        var clock = HybridClock(replica: ReplicaID())
        let first = clock.tick(now: seconds(0))
        let second = clock.tick(now: seconds(1))

        #expect(first < second)
        #expect(second.physicalMillis == 1_800_000_001_000)
    }

    @Test("readings still increase when physical time stands still or goes backwards")
    func monotonicUnderClockRegression() {
        var clock = HybridClock(replica: ReplicaID())
        let first = clock.tick(now: seconds(10))
        let same = clock.tick(now: seconds(10))
        let earlier = clock.tick(now: seconds(5))

        #expect(first < same)
        #expect(same < earlier)
    }

    @Test("after observing a reading from a clock that runs ahead, the next local reading is later")
    func observeOrdersCausally() {
        var ahead = HybridClock(replica: ReplicaID())
        var behind = HybridClock(replica: ReplicaID())
        let remote = ahead.tick(now: seconds(5 * 3600))

        behind.observe(remote)
        let local = behind.tick(now: seconds(0))

        #expect(remote < local)
    }

    @Test("observing an older reading does not move the clock back")
    func observeOlderIsHarmless() {
        var clock = HybridClock(replica: ReplicaID())
        let latest = clock.tick(now: seconds(100))
        clock.observe(HybridTimestamp(physicalMillis: 0, counter: 0, replica: ReplicaID()))

        #expect(latest < clock.tick(now: seconds(0)))
    }

    @Test("two replicas reading the same instant are ordered by replica, never equal")
    func replicaBreaksTies() {
        var a = HybridClock(replica: ReplicaID())
        var b = HybridClock(replica: ReplicaID())
        let x = a.tick(now: seconds(0))
        let y = b.tick(now: seconds(0))

        #expect(x != y)
        #expect((x < y) != (y < x))
    }

    @Test("after observing a reading at the largest counter, the next reading moves to the next millisecond")
    func counterOverflowCarries() {
        var clock = HybridClock(replica: ReplicaID())
        let remote = HybridTimestamp(physicalMillis: 1_800_000_000_000, counter: .max, replica: ReplicaID())
        clock.observe(remote)

        let next = clock.tick(now: seconds(0))

        #expect(remote < next)
        #expect(next.physicalMillis == remote.physicalMillis + 1)
        #expect(next.counter == 0)
    }

    @Test("after observing the largest possible reading, the clock keeps issuing it instead of failing")
    func largestReadingSaturates() {
        var clock = HybridClock(replica: ReplicaID())
        clock.observe(HybridTimestamp(physicalMillis: .max, counter: .max, replica: ReplicaID()))

        let first = clock.tick(now: seconds(0))
        let second = clock.tick(now: seconds(1))

        #expect(first.physicalMillis == .max && first.counter == .max)
        #expect(second == first)
    }
}
