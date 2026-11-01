import Foundation
import PantrifiedDomain

/// How warm the device is, as the platform reports it.
public enum ThermalLevel: Int, Sendable, Hashable, Comparable {
    case nominal, fair, serious, critical

    public static func < (a: ThermalLevel, b: ThermalLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What the device is doing that changes how hard reading may work.
public struct DeviceConditions: Sendable, Hashable {
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool
    /// The app is on screen. In the background the system may stop the work at any time.
    public var appActive: Bool

    public init(thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false, appActive: Bool = true) {
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.appActive = appActive
    }
}

/// Why reading is waiting, for the screen to say.
public enum ReadingPause: Sendable, Hashable {
    case warm
    case lowPower
    case inBackground
}

/// When photos are read, and how many at once. Pure, so every rule is tested without a device.
///
/// - While the camera is open, one photo at a time at low priority, so the shutter and preview keep
///   the processor. Reading waits while the device is warm (serious or critical) or in Low Power
///   Mode, and carries on when that ends or at Done.
/// - After Done the person is waiting, so two at a time, or one while the device is warm. Low Power
///   Mode does not slow this: the work is the same either way, and finishing sooner lets the
///   device rest sooner.
/// - Nothing is read while the app is not active.
///
/// Each read holds one decoded photo (at most `VisionPhotoRecognizer.maximumPixels` on its longest
/// side), so the most reads at once is also the most decoded photos in memory for reading.
public struct ReadingPolicy: Sendable, Hashable {
    public var whileCapturing = 1
    public var afterDone = 2
    public var afterDoneWhenWarm = 1
    /// Unread photos left at Done that are read with the list shown but not yet changeable. More
    /// than this shows progress instead.
    public var fewLeft = 3

    public init() {}

    public static let standard = ReadingPolicy()

    /// Why reading waits now, or nil when it may go on.
    public func pause(cameraOpen: Bool, conditions: DeviceConditions) -> ReadingPause? {
        if !conditions.appActive { return .inBackground }
        guard cameraOpen else { return nil }
        if conditions.thermal >= .serious { return .warm }
        if conditions.lowPowerMode { return .lowPower }
        return nil
    }

    /// How many photos may be read at once now.
    public func slots(cameraOpen: Bool, conditions: DeviceConditions) -> Int {
        guard pause(cameraOpen: cameraOpen, conditions: conditions) == nil else { return 0 }
        if cameraOpen { return max(1, whileCapturing) }
        return conditions.thermal >= .serious ? max(1, afterDoneWhenWarm) : max(1, afterDone)
    }

    /// The photos to start reading now, in the order given: as many of `waiting` as the free slots
    /// allow, skipping any already being read.
    public func next(waiting: [IntakePhotoID], reading: Set<IntakePhotoID>, slots: Int) -> [IntakePhotoID] {
        let free = max(0, slots - reading.count)
        return Array(waiting.lazy.filter { !reading.contains($0) }.prefix(free))
    }
}

/// How barcode lookups are spread out. A lookup needs only a barcode, so each distinct barcode is
/// asked as soon as a photo showing it has been read, while photos are still being taken.
public struct LookupPolicy: Sendable, Hashable {
    /// Lookups at once. Below the lookup service's own limit, so its pacing still decides.
    public var inFlight = 2
    /// Lookups started per pass, to stay well inside the shared key's hourly limit. A pass starts
    /// when the batch opens and again at Done.
    public var perPass = 40

    public init() {}

    public static let standard = LookupPolicy()
}
