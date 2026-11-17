import Foundation
import Security
import OSLog

/// Stores balance-query API keys as a 0600 JSON file inside the app's sandbox
/// container (`Application Support/OpenYoink/balance-keys.json`).
///
/// The Keychain was the first choice, but macOS ties a Keychain item's access
/// control to the creating app's code signature. During development every
/// rebuild changes the signature, so the system treated each build as a
/// stranger and asked for the login password again. A sandboxed file is read
/// only by this app (the container is per-app) and never prompts.
struct APIKeyStore {
    private let fileURL: URL
    private let legacyService: String
    private let logger = Logger(subsystem: "com.weijue.OpenYoink", category: "BalanceKeys")

    init(directoryURL: URL = AppDirectories.applicationSupport(),
         legacyService: String = "com.weijue.OpenYoink.balance") {
        self.fileURL = directoryURL.appendingPathComponent("balance-keys.json")
        self.legacyService = legacyService
    }

    func setKey(_ key: String, for id: UUID) {
        var keys = load()
        keys[id.uuidString] = key
        save(keys)
    }

    func key(for id: UUID) -> String? {
        let keys = load()
        if let key = keys[id.uuidString], !key.isEmpty { return key }
        // One-time migration from the Keychain used by earlier builds.
        if let key = legacyKey(for: id), !key.isEmpty {
            var migrated = keys
            migrated[id.uuidString] = key
            save(migrated)
            legacyDelete(for: id)
            return key
        }
        return nil
    }

    func deleteKey(for id: UUID) {
        var keys = load()
        if keys.removeValue(forKey: id.uuidString) != nil {
            save(keys)
        }
        legacyDelete(for: id)
    }

    // MARK: File storage

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func save(_ keys: [String: String]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            logger.error("Balance key file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Legacy Keychain (read once, then removed)

    private func legacyKey(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func legacyDelete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
