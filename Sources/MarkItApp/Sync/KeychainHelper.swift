//
//  KeychainHelper.swift
//  Markit
//
//  Created by AppKit Migration on 2026/9/3.
//

import Foundation
import Security

enum KeychainHelper {
    private static let serviceName = "com.debugly.markit.webdav"

    static func save(password: String, for account: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // Delete existing item first to avoid duplicate errors
        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadPassword(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
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
}
