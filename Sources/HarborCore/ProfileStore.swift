import Foundation
import Security

public struct ProfileStore {
    public let file: URL
    public init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Harbor", isDirectory: true).appendingPathComponent("connections.json")
    }
    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: file))
    }
    public func save(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

public enum PasswordStore {
    private static let service = "io.github.miaodidi.harbor.mysql"
    public static func read(for id: UUID) throws -> String? {
        var query = base(id); query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = output as? Data else { throw error(status) }
        return String(data: data, encoding: .utf8)
    }
    public static func save(_ password: String, for id: UUID) throws {
        let attributes = [kSecValueData: Data(password.utf8)] as CFDictionary
        let status = SecItemUpdate(base(id) as CFDictionary, attributes)
        if status == errSecItemNotFound {
            var query = base(id); query[kSecValueData] = Data(password.utf8); query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    public static func delete(for id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }
    private static func base(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }
    private static func error(_ status: OSStatus) -> HarborError {
        .message("钥匙串：" + ((SecCopyErrorMessageString(status, nil) as String?) ?? "错误 \(status)"))
    }
}
