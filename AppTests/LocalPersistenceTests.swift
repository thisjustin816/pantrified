import Foundation
import Testing
@testable import Pantrified

@Suite("Local persistence")
struct LocalPersistenceTests {
    @Test("the local store keeps a package and a location across a relaunch, protected and included in backups")
    func survivesRelaunch() async throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("LocalPersistenceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let check = try await LocalPersistence.relaunchCheck(in: directory)

        #expect(check.packageName == "Milk")
        #expect(check.locationNames == ["Fridge"])
        #expect(check.protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        #expect(check.excludedFromBackup == false)
    }
}
