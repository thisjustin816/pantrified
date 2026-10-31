import AVFoundation
import UIKit

/// The back camera for batch intake: a preview and a shutter that can be pressed again before the
/// last photo is done. Each photo's bytes go to the caller, which writes them to the staging folder.
/// Nothing is saved to the photo library, no location is added, and no frame is read while the
/// preview runs.
///
/// Session work runs on a private serial queue, because starting a session blocks. Photos are
/// delivered on the main actor.
final class BatchCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    enum Access {
        case notDetermined, authorized, denied, restricted
    }

    struct Shot: Sendable {
        let data: Data
        let fileExtension: String
        let takenAt: Date
    }

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "com.thisjustin816.Pantrified.batch-camera")
    private let onShot: @MainActor @Sendable (Shot?) -> Void
    /// Used only on `queue`.
    private var configured = false
    private var device: AVCaptureDevice?

    /// `onShot` gets each photo, or nil when one could not be taken.
    init(onShot: @escaping @MainActor @Sendable (Shot?) -> Void) {
        self.onShot = onShot
    }

    static var isAvailable: Bool { backCamera() != nil }

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start(_ done: @escaping @MainActor @Sendable (_ running: Bool, _ hasTorch: Bool) -> Void) {
        queue.async { [self] in
            if !configured { configured = configure() }
            if configured, !session.isRunning { session.startRunning() }
            let running = session.isRunning
            let hasTorch = device?.hasTorch ?? false
            Task { @MainActor in done(running, hasTorch) }
        }
    }

    func stop() {
        queue.async { [self] in
            setTorch(false)
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(on: Bool) {
        queue.async { [self] in setTorch(on) }
    }

    /// Takes a photo. Can be called again at once; photos arrive in the order they finish.
    func shoot() {
        queue.async { [self] in
            guard session.isRunning else { return }
            let format: [String: Any] = output.availablePhotoCodecTypes.contains(.hevc)
                ? [AVVideoCodecKey: AVVideoCodecType.hevc]
                : [AVVideoCodecKey: AVVideoCodecType.jpeg]
            let settings = AVCapturePhotoSettings(format: format)
            // A flash glares on shiny packaging; the light button lights a label instead.
            settings.flashMode = .off
            settings.photoQualityPrioritization = .balanced
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Delegate

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let shot: Shot? = error == nil ? photo.fileDataRepresentation().map { data in
            Shot(data: data, fileExtension: PhotoFormat.fileExtension(of: data), takenAt: Date())
        } : nil
        Task { @MainActor [onShot] in onShot(shot) }
    }

    // MARK: Setup

    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        ).devices.first
    }

    private func configure() -> Bool {
        guard let camera = Self.backCamera(), let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        // Rapid shots: the next photo can start while the last one is still being processed.
        if output.isResponsiveCaptureSupported {
            output.isResponsiveCaptureEnabled = true
            if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = true }
        }
        device = camera
        if (try? camera.lockForConfiguration()) != nil {
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            // A virtual device with the ultra wide camera can switch to it for close focus.
            let hasUltraWide = camera.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            if hasUltraWide, let wide = camera.virtualDeviceSwitchOverVideoZoomFactors.first {
                camera.videoZoomFactor = min(CGFloat(truncating: wide), camera.activeFormat.videoMaxZoomFactor)
            }
            camera.unlockForConfiguration()
        }
        return true
    }

    private func setTorch(_ on: Bool) {
        guard let camera = device, camera.hasTorch, camera.isTorchAvailable, (try? camera.lockForConfiguration()) != nil else { return }
        camera.torchMode = on ? .on : .off
        camera.unlockForConfiguration()
    }
}
