import Foundation
import Security

public struct ApplicationPreferences: Codable {
    public var llm: LLMConfiguration
    public var asr: ASRConfiguration
    public var storage: ModelStorageConfig
    public init(llm: LLMConfiguration, asr: ASRConfiguration, storage: ModelStorageConfig) {
        self.llm = llm
        self.asr = asr
        self.storage = storage
    }
    public func encodedWithoutSecrets() throws -> Data {
        var safe = self
        safe.llm.onlineAPIKey = ""
        return try JSONEncoder().encode(safe)
    }
}

public enum ServiceCredentials {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.videoautotranslate.api", kSecAttrAccount as String: account]
    }
    public static func read(account: String) -> String {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func remove(account: String) { SecItemDelete(query(account) as CFDictionary) }
    public static func write(_ key: String, account: String) throws {
        guard !account.isEmpty else { return }
        let request = query(account)
        if key.isEmpty { return }
        let data = Data(key.utf8)
        var status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = request
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
