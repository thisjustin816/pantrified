import AVFoundation
import PantrifiedApplication
import PantrifiedDomain

/// The back camera, reading product barcodes. Only decoded barcode text reaches the app: the
/// metadata output decodes inside AVFoundation, no video data output is attached, and the preview
/// layer draws frames without handing them to app code. No frame is kept or saved.
///
/// Session work runs on a private serial queue, because starting a session blocks. Barcodes are
/// delivered on the main queue.
final class BarcodeCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    enum Access {
        case notDetermined, authorized, denied, restricted
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.thisjustin816.Pantrified.camera")
    private let onReads: @MainActor @Sendable ([BarcodeRead]) -> Void
    /// Used only on `queue`.
    private var device: AVCaptureDevice?

    init(onReads: @escaping @MainActor @Sendable ([BarcodeRead]) -> Void) {
        self.onReads = onReads
    }

    /// False on a device with no back camera, such as the simulator.
    static var isAvailable: Bool { backCamera() != nil }

    static var access: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    /// Shows the system's camera prompt the first time, and returns the answer.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Configures the session the first time, then starts it. Reports whether it is running, along
    /// with whether the camera has a torch.
    func start(_ done: @escaping @MainActor @Sendable (_ running: Bool, _ hasTorch: Bool) -> Void) {
        queue.async { [self] in
            if device == nil { device = configure() }
            if device != nil, !session.isRunning { session.startRunning() }
            let running = session.isRunning
            let hasTorch = device?.hasTorch ?? false
            Task { @MainActor in done(running, hasTorch) }
        }
    }

    func stop() {
        queue.async { [self] in
            setTorch(false, on: device)
            if session.isRunning { session.stopRunning() }
        }
    }

    func setTorch(_ on: Bool) {
        queue.async { [self] in setTorch(on, on: device) }
    }

    // MARK: Delegate

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let reads = metadataObjects.compactMap { object -> BarcodeRead? in
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let payload = code.stringValue,
                  let symbology = Self.symbology(code.type)
            else { return nil }
            return BarcodeRead(payload: payload, symbology: symbology)
        }
        guard !reads.isEmpty else { return }
        // The delegate queue is the main queue, set in `configure`.
        MainActor.assumeIsolated { onReads(reads) }
    }

    // MARK: Setup

    /// UPC-A arrives as EAN-13 with a leading zero; AVFoundation has no type of its own for it.
    private static func symbology(_ type: AVMetadataObject.ObjectType) -> BarcodeSymbology? {
        switch type {
        case .ean13: .ean13
        case .ean8: .ean8
        case .upce: .upcE
        default: nil
        }
    }

    /// A virtual device that includes the ultra wide camera can switch to it for close focus, which
    /// a barcode held near the phone needs on models whose wide camera cannot focus that close.
    private static func backCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        ).devices.first
    }

    private func configure() -> AVCaptureDevice? {
        guard let camera = Self.backCamera(), let input = try? AVCaptureDeviceInput(device: camera) else { return nil }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        session.addOutput(output)
        // The types an output offers are known only once it is in a session with an input.
        let wanted: [AVMetadataObject.ObjectType] = [.ean13, .ean8, .upce]
        output.metadataObjectTypes = wanted.filter(output.availableMetadataObjectTypes.contains)
        output.setMetadataObjectsDelegate(self, queue: .main)
        tune(camera)
        return camera
    }

    private func tune(_ camera: AVCaptureDevice) {
        guard (try? camera.lockForConfiguration()) != nil else { return }
        defer { camera.unlockForConfiguration() }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        if camera.isAutoFocusRangeRestrictionSupported { camera.autoFocusRangeRestriction = .near }
        // A virtual device with the ultra wide camera starts at the ultra wide field of view. The
        // first switch-over factor is the wide camera's, which frames a barcode as people expect.
        let hasUltraWide = camera.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide, let wide = camera.virtualDeviceSwitchOverVideoZoomFactors.first {
            camera.videoZoomFactor = min(CGFloat(truncating: wide), camera.activeFormat.videoMaxZoomFactor)
        }
    }

    private func setTorch(_ on: Bool, on camera: AVCaptureDevice?) {
        guard let camera, camera.hasTorch, camera.isTorchAvailable, (try? camera.lockForConfiguration()) != nil else { return }
        camera.torchMode = on ? .on : .off
        camera.unlockForConfiguration()
    }
}
