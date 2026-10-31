import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain

@Suite("When photos are read")
struct ReadingPolicyTests {
    let policy = ReadingPolicy.standard

    @Test("one at a time while the camera is open, two at a time after Done")
    func slots() {
        #expect(policy.slots(cameraOpen: true, conditions: DeviceConditions()) == 1)
        #expect(policy.slots(cameraOpen: false, conditions: DeviceConditions()) == 2)
        #expect(policy.slots(cameraOpen: true, conditions: DeviceConditions(thermal: .fair)) == 1)
    }

    @Test("with the camera open, a warm device or Low Power Mode pauses reading", arguments: [
        (DeviceConditions(thermal: .serious), ReadingPause.warm),
        (DeviceConditions(thermal: .critical), .warm),
        (DeviceConditions(thermal: .critical, lowPowerMode: true), .warm),
        (DeviceConditions(lowPowerMode: true), .lowPower),
    ])
    func pausesWhileCapturing(conditions: DeviceConditions, pause: ReadingPause) {
        #expect(policy.pause(cameraOpen: true, conditions: conditions) == pause)
        #expect(policy.slots(cameraOpen: true, conditions: conditions) == 0)
    }

    @Test("after Done nothing pauses reading but the background; warm reads one at a time and Low Power Mode does not slow it")
    func afterDone() {
        #expect(policy.pause(cameraOpen: false, conditions: DeviceConditions(thermal: .critical, lowPowerMode: true)) == nil)
        #expect(policy.slots(cameraOpen: false, conditions: DeviceConditions(thermal: .serious)) == 1)
        #expect(policy.slots(cameraOpen: false, conditions: DeviceConditions(thermal: .critical)) == 1)
        #expect(policy.slots(cameraOpen: false, conditions: DeviceConditions(lowPowerMode: true)) == 2)
        #expect(policy.slots(cameraOpen: false, conditions: DeviceConditions(thermal: .fair)) == 2)
    }

    @Test("nothing is read while the app is in the background")
    func background() {
        for cameraOpen in [true, false] {
            #expect(policy.pause(cameraOpen: cameraOpen, conditions: DeviceConditions(appActive: false)) == .inBackground)
            #expect(policy.slots(cameraOpen: cameraOpen, conditions: DeviceConditions(appActive: false)) == 0)
        }
    }

    @Test("the next photos to start fill the free slots in order, skipping those being read")
    func next() {
        let photos = (0..<5).map { _ in IntakePhotoID() }
        #expect(policy.next(waiting: photos, reading: [], slots: 1) == [photos[0]])
        #expect(policy.next(waiting: photos, reading: [photos[0]], slots: 1).isEmpty)
        #expect(policy.next(waiting: photos, reading: [photos[0]], slots: 2) == [photos[1]])
        #expect(policy.next(waiting: photos, reading: [], slots: 2) == [photos[0], photos[1]])
        // A cancelled read still holds its photo in memory until it ends, so it still takes a slot.
        #expect(policy.next(waiting: Array(photos.dropFirst()), reading: [photos[0]], slots: 2) == [photos[1]])
        #expect(policy.next(waiting: photos, reading: [], slots: 0).isEmpty)
    }
}
