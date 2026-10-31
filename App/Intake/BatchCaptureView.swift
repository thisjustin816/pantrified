import AVFoundation
import Observation
import PhotosUI
import SwiftUI
import PantrifiedApplication
import PantrifiedDomain

/// The camera behind the batch screen. It runs only while the screen is visible and the app is
/// active. It reads nothing itself: each kept photo is read by the intake pipeline, one at a time
/// at low priority, so the shutter and preview keep the processor.
@MainActor
@Observable
final class BatchCameraModel {
    enum State: Equatable {
        case noCamera, asking, denied, restricted, starting, running, failed
    }

    private(set) var state: State
    private(set) var hasTorch = false
    private(set) var torchOn = false
    private(set) var session: AVCaptureSession?
    /// Photos taken and not yet kept, so the shutter can show it is busy without blocking.
    private(set) var pending = 0

    @ObservationIgnored private var camera: BatchCamera?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var active = true
    @ObservationIgnored var onShot: (BatchCamera.Shot) -> Void = { _ in }
    @ObservationIgnored var onFailedShot: () -> Void = {}

    init() {
        state = BatchCamera.isAvailable ? Self.state(for: BatchCamera.access) : .noCamera
    }

    func appeared() async {
        visible = true
        if state == .asking {
            state = await BatchCamera.requestAccess() ? .starting : .denied
        }
        startIfWanted()
    }

    func disappeared() {
        visible = false
        stop()
    }

    func sceneActive(_ isActive: Bool) {
        active = isActive
        if isActive {
            if BatchCamera.isAvailable, [.denied, .restricted, .failed].contains(state) {
                state = Self.state(for: BatchCamera.access)
            }
            startIfWanted()
        } else {
            stop()
        }
    }

    func retry() {
        state = .starting
        startIfWanted()
    }

    func shoot() {
        guard state == .running else { return }
        pending += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera?.shoot()
    }

    func toggleTorch() {
        torchOn.toggle()
        camera?.setTorch(on: torchOn)
    }

    private func received(_ shot: BatchCamera.Shot?) {
        pending = max(0, pending - 1)
        if let shot { onShot(shot) } else { onFailedShot() }
    }

    private func startIfWanted() {
        guard visible, active, state == .starting || state == .running else { return }
        let camera = camera ?? BatchCamera { [weak self] shot in self?.received(shot) }
        self.camera = camera
        session = camera.session
        camera.start { [weak self] running, hasTorch in
            guard let self, self.visible, self.active else { return }
            self.state = running ? .running : .failed
            self.hasTorch = hasTorch
        }
    }

    private func stop() {
        camera?.stop()
        torchOn = false
        if state == .running { state = .starting }
    }

    private static func state(for access: BatchCamera.Access) -> State {
        switch access {
        case .notDetermined: .asking
        case .authorized: .starting
        case .denied: .denied
        case .restricted: .restricted
        }
    }
}

/// Taking photos for a batch: a shutter that can be tapped as fast as the person likes, a strip of
/// what has been taken with whether each is read yet, a tentative count of packages, Done to see the
/// list, and the Photos picker for photos already taken. Reading never holds up the shutter.
struct BatchCaptureView: View {
    let intake: IntakeModel
    let addByHand: () -> Void
    let close: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var camera = BatchCameraModel()
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var confirmingDiscard = false
    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 56

    private var remaining: Int { max(0, intake.photoLimit - intake.photos.count) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add a batch")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { controls }
                .intakeProblemAlert(intake)
        }
        .task {
            camera.onShot = { shot in Task { await intake.keep(shot.data, source: .camera, takenAt: shot.takenAt) } }
            camera.onFailedShot = { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            await camera.appeared()
        }
        .onDisappear { camera.disappeared() }
        .onChange(of: scenePhase) { _, phase in camera.sceneActive(phase == .active) }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await importPhotos(items) }
        }
        .confirmationDialog("Discard this batch?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Photos", role: .destructive) {
                Task {
                    await intake.discard()
                    close()
                }
            }
        } message: {
            Text("The photos are deleted now. Nothing is added.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Menu("Close", systemImage: "xmark") {
                Button("Keep for Later", systemImage: "tray.and.arrow.down") { close() }
                Button("Add by Hand", systemImage: "square.and.pencil") { addByHand() }
                Button("Discard Photos", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
            }
        }
        if camera.state == .running && camera.hasTorch {
            ToolbarItem(placement: .primaryAction) {
                Button(camera.torchOn ? "Turn off light" : "Turn on light",
                       systemImage: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill") {
                    camera.toggleTorch()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { Task { await intake.finishCapture() } }
                .disabled(intake.photos.isEmpty || camera.pending > 0 || importing)
                .accessibilityHint("Reads any photos left and shows what was found")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch camera.state {
        case .starting, .running:
            ZStack {
                Color.black.ignoresSafeArea()
                BatchCameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        case .asking:
            unavailable("Camera access", "Pantrified takes photos of your food so it can read their labels. \(IntakeText.photosStayHere)")
        case .noCamera:
            unavailable("Camera not available", "This device has no camera Pantrified can use. You can add photos you already took, or add food by hand.")
        case .denied:
            unavailable("Camera access is off", "To take photos here, allow camera access for Pantrified in Settings. You can still add photos you already took, or add food by hand.", opensSettings: true)
        case .restricted:
            unavailable("Camera access is restricted", "This device doesn't allow camera access, for example because of Screen Time. You can still add photos you already took, or add food by hand.")
        case .failed:
            unavailable("Couldn't start the camera", "Another app may be using it. Try again, or add photos you already took.", retries: true)
        }
    }

    private func unavailable(_ title: String, _ detail: String, opensSettings: Bool = false, retries: Bool = false) -> some View {
        let view = ContentUnavailableView {
            Label(title, systemImage: "camera")
        } description: {
            Text(detail)
        } actions: {
            if opensSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { openURL(settings) }
                    .buttonStyle(.borderedProminent)
            }
            if retries {
                Button("Try Again") { camera.retry() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Add by Hand") { addByHand() }
                .buttonStyle(.bordered)
        }
        return ViewThatFits(in: .vertical) {
            view
            ScrollView { view }
        }
    }

    /// The strip of photos taken, then the picker, shutter and count.
    private var controls: some View {
        VStack(spacing: 12) {
            if !intake.photos.isEmpty { strip }
            HStack(alignment: .center) {
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: max(1, remaining),
                    selectionBehavior: .ordered,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Label("Add photos", systemImage: "photo.on.rectangle")
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(remaining == 0 || importing)
                .accessibilityLabel("Add photos you already took")
                Spacer()
                shutter
                Spacer()
                counts
            }
            if let pause = intake.live?.pause, !intake.photos.isEmpty {
                Text(IntakeText.pause(pause))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            #if DEBUG
            if let timing = intake.readTiming {
                Text(timing)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            #endif
            if let notice = intake.notice, intake.photos.isEmpty {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            Text(IntakeText.photosStayHere)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(.regularMaterial)
    }

    /// Photos taken, and the packages they make so far, which can change as more are read.
    private var counts: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(IntakeText.photoCount(intake.photos.count))
                .font(.subheadline.monospacedDigit())
            if let live = intake.live, live.progress.read > 0 {
                Text(IntakeText.soFar(live.packagesSoFar))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(countsLabel)
    }

    private var countsLabel: String {
        var label = IntakeText.photoCount(intake.photos.count) + " taken"
        if let live = intake.live, live.progress.read > 0 { label += ", " + IntakeText.soFar(live.packagesSoFar) }
        return label
    }

    private var shutter: some View {
        Button {
            camera.shoot()
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: 64, height: 64)
                Circle().strokeBorder(.black.opacity(0.25), lineWidth: 3).frame(width: 56, height: 56)
                if camera.pending > 0 { ProgressView() }
            }
        }
        .disabled(camera.state != .running || remaining == 0)
        .accessibilityLabel("Take photo")
        .accessibilityHint("Take a photo of each package: the front, the barcode and the date. Tap Done when finished.")
    }

    private var strip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(intake.photos.enumerated()), id: \.element.id) { index, photo in
                        let state = intake.live?.states[photo.id] ?? .waiting
                        Thumbnail(image: intake.thumbnails[photo.id], size: thumbnailSize)
                            .overlay(alignment: .bottomTrailing) {
                                ReadBadge(state: state, settled: intake.live?.settled.contains(photo.id) == true)
                            }
                            .id(photo.id)
                            .contextMenu {
                                Button("Remove Photo", systemImage: "trash", role: .destructive) {
                                    Task { await intake.remove(photo.id) }
                                }
                            }
                            .accessibilityElement()
                            .accessibilityLabel("Photo \(index + 1), \(IntakeText.state(state))")
                            .accessibilityAction(named: "Remove photo") { Task { await intake.remove(photo.id) } }
                    }
                }
                .frame(height: thumbnailSize)
            }
            .scrollIndicators(.hidden)
            .onChange(of: intake.photos.count) {
                guard let last = intake.photos.last?.id else { return }
                reader.scrollTo(last, anchor: .trailing)
            }
        }
    }

    /// Copies each picked photo into the staging folder. The originals stay in Photos, untouched.
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        importing = true
        defer { importing = false }
        for item in items.prefix(remaining) {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            await intake.keep(data, source: .imported, takenAt: PhotoFormat.takenAt(data))
        }
    }
}

/// A photo's reading state, small in the corner of its thumbnail: nothing while it waits, an
/// ellipsis while it is read, a check once read (filled once its package looks complete), and a
/// warning when it could not be read. Static symbols, so Reduce Motion needs nothing more.
private struct ReadBadge: View {
    let state: PhotoReadState
    let settled: Bool

    var body: some View {
        if let symbol {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .padding(2)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String? {
        switch state {
        case .waiting: nil
        case .reading: "ellipsis.circle.fill"
        case .read: settled ? "checkmark.circle.fill" : "checkmark.circle"
        case .couldNotRead: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        state == .couldNotRead ? .orange : .black.opacity(0.6)
    }
}

/// A photo's thumbnail, or a placeholder while it loads or once its file is deleted.
struct Thumbnail: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

/// Draws the camera's frames without passing them to app code.
private struct BatchCameraPreview: UIViewRepresentable {
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
