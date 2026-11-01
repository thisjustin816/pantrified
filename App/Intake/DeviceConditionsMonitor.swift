import Foundation
import UIKit
import PantrifiedApplication

/// Tells batch intake how warm the device is, whether Low Power Mode is on and whether the app is in
/// the background, so `ReadingPolicy` can pause or slow reading. It reads only these three states,
/// and lives as long as the app.
@MainActor
final class DeviceConditionsMonitor {
    private let pipeline: IntakePipeline
    private var inBackground = false
    private var observers: [NSObjectProtocol] = []

    init(pipeline: IntakePipeline) {
        self.pipeline = pipeline
        let center = NotificationCenter.default
        let changes: [(Notification.Name, Bool?)] = [
            (ProcessInfo.thermalStateDidChangeNotification, nil),
            (.NSProcessInfoPowerStateDidChange, nil),
            (UIApplication.didEnterBackgroundNotification, true),
            (UIApplication.didBecomeActiveNotification, false),
        ]
        for (name, background) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let background { self?.inBackground = background }
                    self?.report()
                }
            })
        }
        inBackground = UIApplication.shared.applicationState == .background
        report()
    }

    private func report() {
        let info = ProcessInfo.processInfo
        let thermal: ThermalLevel = switch info.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        let conditions = DeviceConditions(thermal: thermal, lowPowerMode: info.isLowPowerModeEnabled, appActive: !inBackground)
        Task { [pipeline] in await pipeline.setConditions(conditions) }
    }
}
