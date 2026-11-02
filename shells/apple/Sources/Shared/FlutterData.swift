import Foundation

/// The Flutter app's data, which the page imports once (docs/contracts/bridge.md, shell.flutterData): its drift
/// database `ompanion.sqlite` in path_provider's application support folder, and its flutter_secure_storage entries
/// (Keychain.flutter).
enum FlutterData {
    private static let database = "ompanion.sqlite"

    /// path_provider's application support folder: macOS adds the bundle id, iOS does not.
    private static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return support.appendingPathComponent(Shell.appID, isDirectory: true)
        #else
        return support
        #endif
    }

    /// `{database: path | null, secrets: {key: value}}`.
    static func read() throws -> [String: Any] {
        let path = folder.appendingPathComponent(database).path
        var secrets: [String: String] = [:]
        for key in try Keychain.flutter.keys() {
            secrets[key] = try Keychain.flutter.get(key)
        }
        return [
            "database": FileManager.default.fileExists(atPath: path) ? path : NSNull(),
            "secrets": secrets,
        ]
    }

    /// Deletes the entries and renames the database and its side files to `<name>.imported`, the user's backup.
    static func clear() throws {
        for key in try Keychain.flutter.keys() {
            try Keychain.flutter.delete(key)
        }
        for name in [database, "\(database)-journal", "\(database)-wal", "\(database)-shm"] {
            let file = folder.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: file) else { continue }
            guard rename(file, file + ".imported") == 0 else {
                throw ShellError("renaming \(file) failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}
