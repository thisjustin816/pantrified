import Foundation
import Observation
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedGuidanceData
import PantrifiedPersistence

/// Opens the local store and builds what the screens use. It never deletes or replaces data it
/// cannot open: the person sees why, and the data stays where it is.
@MainActor
@Observable
final class AppLaunch {
    enum State {
        case opening
        case ready(PantryModel)
        case unavailable(StoreProblem)
    }

    private(set) var state: State = .opening
    private var started = false
    private let files: @Sendable () throws -> StoreFiles
    private let undoWindow: Duration

    init(
        files: @escaping @Sendable () throws -> StoreFiles = { try StoreFiles.applicationSupport() },
        undoWindow: Duration = .seconds(8)
    ) {
        self.files = files
        self.undoWindow = undoWindow
    }

    /// Opens the store once. Calling it again does nothing.
    func start() async {
        guard !started else { return }
        started = true
        do {
            let files = try files()
            let store = try LocalPersistence.open(files)
            let space = try LocalSpace.id(in: files)
            let time = SystemTime()
            let replica = try store.replica(for: space, transport: OfflineTransport(), time: time)
            let pantry = Pantry(
                space: space, inventory: replica, locations: store.locations,
                guidance: Self.guidance(), time: time
            )
            try await pantry.prepare()
            let model = PantryModel(pantry: pantry, undoWindow: undoWindow)
            await model.load()
            state = .ready(model)
        } catch {
            state = .unavailable(StoreProblem(error))
        }
    }

    private static func guidance() -> any StorageGuidanceRepository {
        guard let dataset = try? BundledGuidance.dataset() else { return NoGuidance() }
        return BundledStorageGuidance(dataset: dataset)
    }
}
