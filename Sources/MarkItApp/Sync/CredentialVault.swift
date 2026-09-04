//
//  CredentialVault.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import Foundation
import Security
import CryptoKit
import IOKit

/// 基于设备硬件特征绑定与 AES-256-GCM 本地加密的凭证保险箱，辅以常驻内存缓存
enum CredentialVault {
    private static let serviceName = "com.debugly.markit.webdav"
    private static let vaultStorageKey = "MarkIt.WebDAVSecureVault"
    private static let defaultsSuite = "com.debugly.markit"
    private static let lock = NSLock()
    private static var memoryCache: [String: String] = [:]

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuite) ?? .standard
    }

    // MARK: - Key Derivation & Hardware Binding

    private static func getHardwareUUID() -> String {
        var mainPort: mach_port_t = 0
        if #available(macOS 12.0, *) {
            mainPort = kIOMainPortDefault
        }
        let platformExpert = IOServiceGetMatchingService(mainPort, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return "MarkIt-Device-Fallback" }
        defer { IOObjectRelease(platformExpert) }
        guard let property = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0) else {
            return "MarkIt-Device-Fallback"
        }
        return (property.takeRetainedValue() as? String) ?? "MarkIt-Device-Fallback"
    }

    private static var encryptionKey: SymmetricKey {
        let seed = "com.debugly.markit.webdav.secure-vault"
        let hwUUID = getHardwareUUID()
        let combined = "\(seed):\(hwUUID)"
        let hash = SHA256.hash(data: Data(combined.utf8))
        return SymmetricKey(data: hash)
    }

    private static func encrypt(password: String) -> Data? {
        guard let plainData = password.data(using: .utf8) else { return nil }
        return try? AES.GCM.seal(plainData, using: encryptionKey).combined
    }

    private static func decrypt(cipherData: Data) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: cipherData),
              let decryptedData = try? AES.GCM.open(box, using: encryptionKey) else {
            return nil
        }
        return String(data: decryptedData, encoding: .utf8)
    }

    // MARK: - Public Interface

    /// 启动时批量预加载密码到内存缓存，后续读取直接命中内存
    static func preload(accounts: [String]) {
        var count = 0
        for account in accounts {
            if loadPassword(for: account, useCache: false) != nil {
                count += 1
            }
        }
        print("[CredentialVault] 启动预加载完成：成功将 \(count)/\(accounts.count) 个账户密码载入内存缓存")
    }

    /// 保存密码并同步缓存到内存中（修改密码时自动更新缓存与持久化密文）
    @discardableResult
    static func save(password: String, for account: String) -> Bool {
        lock.lock()
        memoryCache[account] = password
        lock.unlock()

        // 1. 使用基于硬件特征绑定的 AES-256-GCM 加密，并存入应用私有配置
        guard let cipher = encrypt(password: password) else { return false }
        lock.lock()
        var vault = defaults.dictionary(forKey: vaultStorageKey) as? [String: Data] ?? [:]
        vault[account] = cipher
        defaults.set(vault, forKey: vaultStorageKey)
        lock.unlock()

        // 2. 清理历史系统钥匙串遗留条目
        purgeLegacyKeychainItem(account: account)

        print("[CredentialVault] 密码已安全加密保存并同步更新到内存缓存 (account: \(account))")
        return true
    }

    /// 获取密码：默认优先从内存缓存中读取，若缓存未命中则从本地硬件绑定的加密保险箱中解密并载入内存
    static func loadPassword(for account: String, useCache: Bool = true) -> String? {
        if useCache {
            lock.lock()
            if let cached = memoryCache[account] {
                lock.unlock()
                return cached
            }
            lock.unlock()
        }

        // 从本地加密库读取
        lock.lock()
        let vault = defaults.dictionary(forKey: vaultStorageKey) as? [String: Data] ?? [:]
        let cipherData = vault[account]
        lock.unlock()

        if let cipherData = cipherData, let password = decrypt(cipherData: cipherData) {
            lock.lock()
            memoryCache[account] = password
            lock.unlock()
            print("[CredentialVault] 成功从本地加密库解密密码并载入内存缓存 (account: \(account))")
            return password
        }

        return nil
    }

    /// 彻底删除密码（包括内存缓存、本地加密存储和历史系统条目）
    @discardableResult
    static func delete(account: String) -> Bool {
        lock.lock()
        memoryCache.removeValue(forKey: account)
        var vault = defaults.dictionary(forKey: vaultStorageKey) as? [String: Data] ?? [:]
        vault.removeValue(forKey: account)
        defaults.set(vault, forKey: vaultStorageKey)
        lock.unlock()

        print("[CredentialVault] 密码已从内存缓存及存储中删除 (account: \(account))")
        purgeLegacyKeychainItem(account: account)
        return true
    }

    @discardableResult
    private static func purgeLegacyKeychainItem(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    @discardableResult
    static func savePassword(_ password: String, for account: String) -> Bool {
        return save(password: password, for: account)
    }

    @discardableResult
    static func deletePassword(for account: String) -> Bool {
        return delete(account: account)
    }

    /// 清空内存密码缓存
    static func clearMemoryCache() {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()
    }
}
