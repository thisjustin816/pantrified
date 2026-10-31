import Foundation
import PantrifiedDomain

/// The identity of the Space this device keeps its own food in. It is chosen once and kept in a
/// small file beside the store, because every stored row is filed under it: a different identity on
/// the next launch would leave the stored data unreachable.
public enum LocalSpace {
    static func marker(_ files: StoreFiles) -> URL { files.directory.appendingPathComponent("local-space") }

    /// The Space ID this device uses, created on first use. A marker that exists but cannot be read
    /// is an error and is never replaced, for the same reason the store is never replaced.
    ///
    /// Call it once per launch, from the one process that owns the store.
    public static func id(in files: StoreFiles) throws(PersistenceError) -> SpaceID {
        let marker = marker(files)
        if FileManager.default.fileExists(atPath: marker.path) {
            guard let data = try? Data(contentsOf: marker),
                  let id = UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw .corrupt("unreadable local space marker") }
            return SpaceID(id)
        }
        let id = UUID()
        do {
            try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            try Data(id.uuidString.utf8).write(to: marker, options: .atomic)
        } catch {
            throw .cannotOpen("local space marker not written: \(error)")
        }
        return SpaceID(id)
    }
}
