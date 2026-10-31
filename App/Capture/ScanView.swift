import AVFoundation
import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// Scanning, then Add food in the same sheet: a product barcode opens the form with the barcode
/// attached, and adding by hand opens it without one.
struct ScanSheet: View {
    let model: PantryModel

    private enum Stage: Equatable {
        case scanning
        case adding(GTIN?)
    }

    @State private var stage = Stage.scanning

    var body: some View {
        switch stage {
        case .scanning:
            ScanView { stage = .adding($0) }
        case .adding(let barcode):
            AddFoodView(model: model, barcode: barcode)
        }
    }
}

/// The live camera with what to do next, or why the camera cannot be used and the way to add food
/// by hand instead.
private struct ScanView: View {
    let finish: (GTIN?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var scanner = ScannerModel()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan a barcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if scanner.state == .running && scanner.hasTorch {
                        ToolbarItem(placement: .primaryAction) {
                            Button(scanner.torchOn ? "Turn off light" : "Turn on light",
                                   systemImage: scanner.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                                scanner.toggleTorch()
                            }
                        }
                    }
                }
        }
        .task { await scanner.appeared() }
        .onDisappear { scanner.disappeared() }
        .onChange(of: scenePhase) { _, phase in scanner.sceneActive(phase == .active) }
        .onChange(of: scanner.product) { _, product in
            if let product { finish(product) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.state {
        case .starting, .running:
            camera
        case .asking:
            unavailable(
                "Camera access",
                systemImage: "barcode.viewfinder",
                "Pantrified uses the camera only to read barcodes. Nothing is recorded or saved."
            )
        case .noCamera:
            unavailable(
                "Camera not available",
                systemImage: "camera",
                "This device has no camera Pantrified can use. You can still add food by hand."
            )
        case .denied:
            unavailable(
                "Camera access is off",
                systemImage: "camera",
                "To scan barcodes, allow camera access for Pantrified in Settings. You can still add food by hand.",
                opensSettings: true
            )
        case .restricted:
            unavailable(
                "Camera access is restricted",
                systemImage: "camera",
                "This device doesn't allow camera access, for example because of Screen Time. You can still add food by hand."
            )
        case .failed:
            unavailable(
                "Couldn't start the camera",
                systemImage: "camera",
                "Another app may be using it. Try again, or add food by hand.",
                retries: true
            )
        }
    }

    private var camera: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: scanner.cameraSession)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(maxWidth: 320, maxHeight: 180)
                .padding(.horizontal, 32)
                .accessibilityHidden(true)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Text(scanner.refusal.map(Self.message) ?? "Point the camera at the barcode on a package.")
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityAddTraits(.updatesFrequently)
                Button("Add by hand") { finish(nil) }
                    .buttonStyle(.borderedProminent)
                Text("Only the barcode number is read. No photos are taken.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(radius: 2)
            }
            .padding()
        }
    }

    private func unavailable(
        _ title: String,
        systemImage: String,
        _ detail: String,
        opensSettings: Bool = false,
        retries: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            if opensSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
                    .buttonStyle(.borderedProminent)
            }
            if retries {
                Button("Try again") { scanner.retry() }
                    .buttonStyle(.borderedProminent)
            }
            if scanner.state != .asking {
                Button("Add by hand") { finish(nil) }
                    .buttonStyle(opensSettings || retries ? .bordered : .borderedProminent)
            }
        }
    }

    static func message(_ refusal: GTINRejection) -> String {
        switch refusal {
        case .storeInternal: "That's the store's own barcode, so it can't name the product. Add this food by hand."
        case .coupon: "That's a coupon barcode. Look for the product barcode."
        case .publication: "That's a book or magazine barcode."
        case .refundReceipt: "That's a receipt barcode."
        case .notAConsumerUnit: "That barcode is for a case, not one package."
        case .malformed, .checkDigit: "That barcode didn't read cleanly. Hold the phone steady."
        }
    }
}

/// Draws the camera's frames. The layer shows them on screen without passing them to app code.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = session
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // The layer class above makes this cast always succeed.
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
