//
//  SharedVault.swift
//  墨语 · 存储
//
//  App 和键盘是两个沙盒，免费签名配不了 App Group，所以旧版的 API Key 要填两遍。
//
//  这里试另一条路：钥匙串访问组。同一个开发者团队的 App 可以共用一个访问组，
//  免费账号的描述文件通常也带 `团队ID.*`。能不能用要看签名工具有没有把这条权限写进包里，
//  所以运行时试一次：写得进就当打通了，写不进（-34018）就退回各存各的，什么也不会坏。
//
//  只用来放配置和 API Key 这类小数据，单条不超过几十 KB。
//

import Foundation
import Security

/// 跨 App 与键盘共享的小数据保险箱。
public final class SharedVault: @unchecked Sendable {

    public static let shared = SharedVault()

    private static let service = "com.moyu.vault"
    private static let groupSuffix = "moyu.shared"

    /// 打通时的访问组；nil 表示没打通。
    public let accessGroup: String?

    /// App 和键盘的配置是否已经打通。
    public var isAvailable: Bool { accessGroup != nil }

    private init() {
        accessGroup = Self.resolveAccessGroup()
    }

    /// 读。
    public func data(forKey key: String) -> Data? {
        guard let accessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    /// 写（nil 表示删除）。
    public func set(_ data: Data?, forKey key: String) {
        guard let accessGroup else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        guard let data else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// 探测：先取团队 ID，再试着往共享组里写一条。
    private static func resolveAccessGroup() -> String? {
        guard let team = teamIdentifier() else { return nil }
        let group = "\(team).\(groupSuffix)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "__probe__",
            kSecAttrAccessGroup as String: group
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data("1".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        SecItemDelete(query as CFDictionary)
        return group
    }

    /// 钥匙串里默认访问组的第一段就是团队 ID。
    private static func teamIdentifier() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moyu.vault.team",
            kSecAttrAccount as String: "__team__",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &item)
        if status == errSecItemNotFound {
            status = SecItemAdd(probe as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let team = group.split(separator: ".").first else {
            return nil
        }
        return String(team)
    }
}
