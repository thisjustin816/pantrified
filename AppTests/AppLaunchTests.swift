import Foundation
import Testing
import PantrifiedApplication
import PantrifiedDomain
import PantrifiedPersistence
@testable import Pantrified

/// The launch path inside the app's sandbox, on the real SwiftData store.
@MainActor
@Suite("App launch")
struct AppLaunchTests {
    private func makeFiles() throws -> (files: StoreFiles, cleanup: () -> Void) {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("AppLaunchTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (StoreFiles(directory: directory), { try? FileManager.default.removeItem(at: directory) })
    }

    private func launch(_ files: StoreFiles, undoWindow: Duration = .seconds(8)) async -> AppLaunch {
        let launch = AppLaunch(files: { files }, undoWindow: undoWindow)
        await launch.start()
        return launch
    }

    private func ready(_ launch: AppLaunch) throws -> PantryModel {
        guard case .ready(let model) = launch.state else {
            Issue.record("expected the app to be ready, but it is \(launch.state)")
            throw CancellationError()
        }
        return model
    }

    private func refusal(_ launch: AppLaunch) throws -> StoreProblem {
        guard case .unavailable(let problem) = launch.state else {
            Issue.record("expected the data to be unavailable, but the app is \(launch.state)")
            throw CancellationError()
        }
        return problem
    }

    // MARK: Opening

    @Test("a first launch is ready with Fridge, Freezer and Pantry and nothing in them")
    func firstLaunch() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }

        let snapshot = try #require(try ready(await launch(files)).snapshot)

        #expect(snapshot.locations.map(\.name) == ["Fridge", "Freezer", "Pantry"])
        #expect(snapshot.entries.isEmpty)
    }

    @Test("food added in one launch is there in the next, in the same place")
    func foodSurvivesRelaunch() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        do {
            let first = try ready(await launch(files))
            let fridge = try #require(first.snapshot?.locations.first)
            #expect(await first.add(NewFood(name: "Milk", location: fridge.id, quantity: .aboutHalf)))
        }

        let second = try ready(await launch(files))

        let snapshot = try #require(second.snapshot)
        #expect(snapshot.locations.map(\.name) == ["Fridge", "Freezer", "Pantry"])
        #expect(snapshot.entries.map(\.package.name) == ["Milk"])
        #expect(snapshot.entries.first?.locationName == "Fridge")
        #expect(snapshot.entries.first?.package.quantity == .aboutHalf)
    }

    @Test("starting twice opens the store once")
    func startIsIdempotent() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let launch = AppLaunch(files: { files })

        await launch.start()
        let first = try ready(launch)
        await launch.start()

        #expect(first === (try ready(launch)))
    }

    // MARK: Data the app must not touch

    @Test("a store written by a newer version is refused, explained, and left exactly as it was")
    func newerStoreIsRefused() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let marker = files.directory.appendingPathComponent("schema-version")
        try Data("99".utf8).write(to: marker)

        let problem = try refusal(await launch(files))

        #expect(problem.kind == .newerVersion)
        #expect(problem.title == "Update Pantrified")
        #expect(try Data(contentsOf: marker) == Data("99".utf8))
        #expect(!FileManager.default.fileExists(atPath: files.store.path))
    }

    @Test("a store that cannot be opened is reported and left exactly as it was")
    func unreadableStoreIsReported() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let garbage = Data("this is not a database".utf8)
        try garbage.write(to: files.store)

        let problem = try refusal(await launch(files))

        #expect(problem.kind == .cannotOpen)
        #expect(problem.message.contains("has not been changed or deleted"))
        #expect(try Data(contentsOf: files.store) == garbage)
    }

    @Test("a Space marker that cannot be read is reported and never replaced")
    func unreadableSpaceMarkerIsReported() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        do { _ = try ready(await launch(files)) }
        let marker = files.directory.appendingPathComponent("local-space")
        try Data("not a uuid".utf8).write(to: marker)

        let problem = try refusal(await launch(files))

        #expect(problem.kind == .cannotOpen)
        #expect(try Data(contentsOf: marker) == Data("not a uuid".utf8))
    }

    // MARK: Using the model

    @Test("a blank name is refused with a message and nothing is stored")
    func blankNameIsRefused() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let model = try ready(await launch(files))
        let fridge = try #require(model.snapshot?.locations.first)

        #expect(await model.add(NewFood(name: "   ", location: fridge.id)) == false)

        #expect(model.problem == "Enter a name for the food.")
        #expect(model.snapshot?.entries.isEmpty == true)
        model.dismissProblem()
        #expect(model.problem == nil)
    }

    @Test("using food up takes it off the list, offers an undo, and the undo puts it back")
    func usedUpAndUndo() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let model = try ready(await launch(files))
        let fridge = try #require(model.snapshot?.locations.first)
        #expect(await model.add(NewFood(name: "Milk", location: fridge.id)))
        let entry = try #require(model.snapshot?.entries.first)

        await model.perform(.usedUp, on: entry)

        #expect(model.snapshot?.entries.isEmpty == true)
        #expect(model.undoPrompt?.message == "Milk used up")

        await model.undo()

        #expect(model.snapshot?.entries.map(\.package.name) == ["Milk"])
        #expect(model.undoPrompt == nil)
    }

    @Test("a move says where the food went, and undoing it moves it back")
    func moveAndUndo() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let model = try ready(await launch(files))
        let locations = try #require(model.snapshot?.locations)
        #expect(await model.add(NewFood(name: "Peas", location: locations[0].id)))
        let entry = try #require(model.snapshot?.entries.first)

        await model.perform(.move(to: locations[1].id), on: entry)

        #expect(model.undoPrompt?.message == "Moved Peas to Freezer")
        #expect(model.snapshot?.entries.first?.locationName == "Freezer")
        await model.undo()
        #expect(model.snapshot?.entries.first?.locationName == "Fridge")
    }

    @Test("an action that changes nothing offers no undo")
    func unchangedOffersNoUndo() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let model = try ready(await launch(files))
        let fridge = try #require(model.snapshot?.locations.first)
        #expect(await model.add(NewFood(name: "Milk", location: fridge.id)))
        let entry = try #require(model.snapshot?.entries.first)
        await model.perform(.opened, on: entry)
        model.dismissUndo()
        let opened = try #require(model.snapshot?.entries.first)

        await model.perform(.opened, on: opened)

        #expect(model.undoPrompt == nil)
        #expect(model.problem == nil)
    }

    @Test("an undo offer expires, and a newer one is not cleared by the older one's timer")
    func undoExpiry() async throws {
        let (files, cleanup) = try makeFiles()
        defer { cleanup() }
        let model = try ready(await launch(files, undoWindow: .seconds(1)))
        let fridge = try #require(model.snapshot?.locations.first)
        #expect(await model.add(NewFood(name: "Milk", location: fridge.id)))
        #expect(await model.add(NewFood(name: "Eggs", location: fridge.id)))
        let milk = try #require(model.snapshot?.entries.first { $0.package.name == "Milk" })
        let eggs = try #require(model.snapshot?.entries.first { $0.package.name == "Eggs" })

        await model.perform(.usedUp, on: milk)
        try await Task.sleep(for: .milliseconds(600))
        await model.perform(.usedUp, on: eggs)
        try await Task.sleep(for: .milliseconds(600))
        // The first offer's second has passed; the newer one's has not.
        #expect(model.undoPrompt?.message == "Eggs used up")

        try await Task.sleep(for: .seconds(1))
        #expect(model.undoPrompt == nil)
    }
}
