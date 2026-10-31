import Foundation
import Observation
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedFoodDataCentral
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

    /// The app's own data, or in a Debug screenshot run a throwaway store.
    static let defaultFiles: @Sendable () throws -> StoreFiles = {
        #if DEBUG
        if let scenario = ScreenshotScenario.current { return try scenario.freshFiles() }
        #endif
        return try StoreFiles.applicationSupport()
    }

    init(
        files: @escaping @Sendable () throws -> StoreFiles = AppLaunch.defaultFiles,
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
                evidence: store.productEvidence, guidance: Self.guidance(), time: time
            )
            try await pantry.prepare()
            #if DEBUG
            if let scenario = ScreenshotScenario.current { try await scenario.seed(pantry) }
            #endif
            let model = PantryModel(pantry: pantry, undoWindow: undoWindow, lookup: Self.lookup())
            await model.load()
            state = .ready(model)
        } catch {
            state = .unavailable(StoreProblem(error))
        }
    }

    /// FoodData Central when the build carries a key, paced to its rate limit with any pause kept
    /// across launches, otherwise no lookup. A screenshot run never looks anything up, so its
    /// images do not depend on the network.
    private static func lookup() -> (any ProductLookupService)? {
        #if DEBUG
        if ScreenshotScenario.current != nil { return nil }
        #endif
        let key = Bundle.main.object(forInfoDictionaryKey: "FoodDataCentralAPIKey") as? String ?? ""
        guard let foodDataCentral = FoodDataCentralLookup(apiKey: key) else { return nil }
        return PacedProductLookup(inner: foodDataCentral, store: LookupPauseFile.inCaches())
    }

    private static func guidance() -> any StorageGuidanceRepository {
        guard let dataset = try? BundledGuidance.dataset() else { return NoGuidance() }
        return BundledStorageGuidance(dataset: dataset)
    }
}
