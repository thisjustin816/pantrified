import AVFoundation
import Foundation
import Observation
import UIKit
import PantrifiedApplication
import PantrifiedDomain

/// What the scan screen shows, and the camera behind it. The camera runs only while the screen is
/// visible and the app is active.
@MainActor
@Observable
final class ScannerModel {
    enum State: Equatable {
        /// No camera, such as in the simulator.
        case noCamera
        /// Waiting for the person to answer the system's camera prompt.
        case asking
        case denied
        case restricted
        case starting
        case running
        /// The camera would not start, for example while another app holds it.
        case failed
    }

    private(set) var state: State
    /// A barcode was read that is not a food product's. Shown until the next one.
    private(set) var refusal: GTINRejection?
    /// The product read, which ends the scan.
    private(set) var product: GTIN?
    private(set) var hasTorch = false
    /// For the preview, once the camera exists.
    private(set) var cameraSession: AVCaptureSession?
    private(set) var torchOn = false

    @ObservationIgnored private var scan = BarcodeScan()
    @ObservationIgnored private var camera: BarcodeCamera?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var active = true

    init() {
        state = BarcodeCamera.isAvailable ? Self.state(for: BarcodeCamera.access) : .noCamera
    }

    func appeared() async {
        visible = true
        if state == .asking {
            state = await BarcodeCamera.requestAccess() ? .starting : .denied
        }
        startIfWanted()
    }

    func disappeared() {
        visible = false
        stopCamera()
    }

    /// The camera stops whenever the app is not in the foreground, and starts again on return.
    func sceneActive(_ isActive: Bool) {
        active = isActive
        if isActive {
            // Access can change in Settings while the app is in the background.
            if BarcodeCamera.isAvailable, [.denied, .restricted, .failed].contains(state) {
                state = Self.state(for: BarcodeCamera.access)
            }
            startIfWanted()
        } else {
            stopCamera()
        }
    }

    func retry() {
        state = .starting
        startIfWanted()
    }

    func toggleTorch() {
        torchOn.toggle()
        camera?.setTorch(torchOn)
    }

    // MARK: Camera

    private func startIfWanted() {
        guard visible, active, product == nil, state == .starting || state == .running else { return }
        let camera = camera ?? BarcodeCamera { [weak self] reads in self?.receive(reads) }
        self.camera = camera
        cameraSession = camera.session
        camera.start { [weak self] running, hasTorch in
            guard let self, self.visible, self.active else { return }
            self.state = running ? .running : .failed
            self.hasTorch = hasTorch
        }
    }

    private func stopCamera() {
        camera?.stop()
        torchOn = false
        if state == .running { state = .starting }
    }

    private func receive(_ reads: [BarcodeRead]) {
        switch scan.receive(reads, at: Date()) {
        case .product(let gtin):
            stopCamera()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            product = gtin
        case .refused(let reason):
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            refusal = reason
        case nil:
            break
        }
    }

    private static func state(for access: BarcodeCamera.Access) -> State {
        switch access {
        case .notDetermined: .asking
        case .authorized: .starting
        case .denied: .denied
        case .restricted: .restricted
        }
    }
}
