import Foundation
import Security

/// Minimal wrapper around the macOS login keychain. Keys are never written to disk or logs.
enum KeychainStore {
    static let service = "local.deepcast"

    enum Account: String, CaseIterable, Sendable {
        case fishAudio = "fish-audio"
        case openRouter = "openrouter"
        case googleAI = "google-ai"

        var displayName: String {
            switch self {
            case .fishAudio: "Fish Audio"
            case .openRouter: "OpenRouter"
            case .googleAI: "Google AI Studio"
            }
        }

        /// Where to create a key.
        var createURL: URL {
            switch self {
            case .fishAudio: URL(string: "https://fish.audio/app/api-keys")!
            case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
            case .googleAI: URL(string: "https://aistudio.google.com/apikey")!
            }
        }
    }

    /// Storage location: login keychain (encrypted, recommended) or a file owned by the app
    /// (`keys.json`, permissions 0600, unencrypted – no keychain prompts).
    enum Storage: String, CaseIterable, Sendable, Identifiable {
        case keychain, appFile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keychain: String(localized: "macOS-Schlüsselbund (verschlüsselt, empfohlen)")
            case .appFile: String(localized: "In der App (Datei, unverschlüsselt, keine Abfragen)")
            }
        }
    }

    private static let storageKey = "keyStorage"
    static var fileURL: URL { AppPaths.applicationSupport().appending(path: "keys.json") }

    static var storage: Storage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(Storage.init(rawValue:)) ?? .keychain
    }

    /// Moves all keys to the new location and removes them from the old one.
    static func setStorage(_ new: Storage) throws {
        guard !isDisabled, new != storage else { return }
        var values: [Account: String] = [:]
        for account in Account.allCases { if let value = read(account) { values[account] = value } }
        let old = storage
        UserDefaults.standard.set(new.rawValue, forKey: storageKey)
        do {
            for (account, value) in values { try save(value, for: account) }
        } catch {
            UserDefaults.standard.set(old.rawValue, forKey: storageKey)
            throw error
        }
        switch old {
        case .keychain: for account in Account.allCases { deleteFromKeychain(account) }
        case .appFile: try? FileManager.default.removeItem(at: fileURL)
        }
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return String(localized: "Schlüsselbund-Fehler: \(message)")
            }
        }
    }

    /// Keys are read once per launch and kept in memory, so macOS asks at most once.
    private static let cache = KeyCache()

    /// True while running unit tests: never touch the real keychain (no password prompts).
    static let isDisabled = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func read(_ account: Account) -> String? {
        if isDisabled { return nil }
        if let cached = cache.value(for: account) { return cached.isEmpty ? nil : cached }
        let value = storage == .appFile ? readFile()[account.rawValue] : readFromKeychain(account)
        cache.set(value ?? "", for: account)
        return value
    }

    private static func readFromKeychain(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func save(_ value: String, for account: Account) throws {
        if isDisabled { return }
        if storage == .appFile {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            var all = readFile()
            all[account.rawValue] = trimmed
            try writeFile(all)
            cache.set(trimmed, for: account)
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        cache.set(trimmed, for: account)
        let data = Data(trimmed.utf8)
        let updateStatus = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "DeepCast \(account.displayName)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    static func delete(_ account: Account) throws {
        if isDisabled { return }
        if storage == .appFile {
            var all = readFile()
            all[account.rawValue] = nil
            try writeFile(all)
            cache.set("", for: account)
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        cache.set("", for: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

extension KeychainStore {
    static func readFile() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    static func writeFile(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func deleteFromKeychain(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Checks a key against the provider (one cheap request).
    static func test(_ value: String, for account: Account) async -> Result<String, Error> {
        var request: URLRequest
        switch account {
        case .fishAudio:
            request = URLRequest(url: URL(string: "https://api.fish.audio/model?page_size=1&self=true")!)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .openRouter:
            request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .googleAI:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
            request.setValue(value, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return .failure(URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey:
                    status == 401 || status == 403 ? String(localized: "Key ungültig (HTTP \(status))") : String(localized: "HTTP \(status)")]))
            }
            if account == .openRouter,
               let info = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any],
               let quota = info["free_model_daily_requests"] as? [String: Any], let remaining = quota["remaining"] as? Int {
                return .success(String(localized: "OK – heute noch \(remaining) Gratis-Anfragen"))
            }
            return .success(String(localized: "OK"))
        } catch {
            return .failure(error)
        }
    }
}

private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [KeychainStore.Account: String] = [:]

    func value(for account: KeychainStore.Account) -> String? { lock.withLock { values[account] } }
    func set(_ value: String, for account: KeychainStore.Account) { lock.withLock { values[account] = value } }
}
