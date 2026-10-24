//
//  KeychainStore.swift
//  ios/Shared/Storage
//
//  模块职责：API Key 的安全存储（Keychain，`kSecClassGenericPassword`）。
//            只存「服务商 id → API Key」这一对映射，不存任何别的配置；
//            配置快照里永远只有 `id`，Key 永远不会进入 JSON / 剪贴板导出（除非用户显式选择）。
//  依赖：Foundation、Security。
//  使用方：宿主 App（设置页填写 Key）、键盘扩展（发请求前取 Key）、`PasteboardBridge`（可选导出）。
//
//  可访问性：`kSecAttrAccessibleAfterFirstUnlock` —— 设备首次解锁后可读，
//  键盘扩展（独立进程、可能后台唤起）可用；不选 `WhenUnlocked` 是因为键盘可能在锁屏后
//  被系统预热的场景下读取，选 `AfterFirstUnlock` 更稳。
//  注意：无 App Group 时，App 与扩展的 Keychain 各自独立（与 SharedStore 一样），
//  README 里说明了用剪贴板搬运或购买付费账号的路径。
//

import Foundation
import Security

/// Keychain 读写封装（只负责 API Key）。
///
/// 用法：
/// ```swift
/// try KeychainStore.shared.setAPIKey("sk-xxx", for: "preset-deepseek")
/// let key = KeychainStore.shared.apiKey(for: "preset-deepseek")   // "sk-xxx"
/// try KeychainStore.shared.deleteAPIKey(for: "preset-deepseek")
/// ```
///
/// 线程安全：`SecItem*` 系列本身就是线程安全的；本类型无可变状态，标记 `@unchecked Sendable`。
public final class KeychainStore: @unchecked Sendable {

    /// 全局单例（默认 service `com.moyu.apikey`）。
    public static let shared = KeychainStore()

    /// Keychain service 名（同一 service + account 唯一确定一条记录）。
    public let service: String

    /// 创建实例。
    ///
    /// - Parameter service: Keychain service 名，默认 `com.moyu.apikey`。
    ///   扩展与 App 必须用同一个 service 才能读到同一份 Key（在 App Group 可用时）。
    public init(service: String = "com.moyu.apikey") {
        self.service = service
    }

    /// Keychain 当前是否可用（用于设置页提示：模拟器/受限设备上可能不可用）。
    ///
    /// 判定方式：尝试写入并删除一条探测记录；失败即视为不可用。
    public var isAvailable: Bool {
        let probeAccount = "__moyu_probe__"
        let probeValue = "1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: probeAccount
        ]
        // 先清掉可能残留的探测项
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = Data(probeValue.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    // MARK: - 读

    /// 读取某个服务商的 API Key。
    ///
    /// - Parameter providerID: 服务商 id（即 `AIProviderConfig.id`，也等于 `apiKeyRef`）。
    /// - Returns: 明文 Key；不存在或读取失败返回 nil。
    public func apiKey(for providerID: String) -> String? {
        guard !providerID.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 某个服务商是否已保存 API Key（不需要读出明文时用）。
    ///
    /// - Parameter providerID: 服务商 id。
    /// - Returns: 是否已保存。
    public func hasAPIKey(for providerID: String) -> Bool {
        apiKey(for: providerID) != nil
    }

    // MARK: - 写 / 删

    /// 保存（或覆盖）某个服务商的 API Key。
    ///
    /// - Parameters:
    ///   - apiKey: 明文 Key（会先 trim 首尾空白；传空串等价于删除）。
    ///   - providerID: 服务商 id。
    /// - Throws: `KeychainError`（`unexpectedStatus` / `emptyProviderID` / `encodingFailed`）。
    public func setAPIKey(_ apiKey: String, for providerID: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty else {
            throw KeychainError.emptyProviderID
        }
        guard !trimmed.isEmpty else {
            try deleteAPIKey(for: providerID)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // 先尝试更新；不存在则新增（避免 errSecDuplicateItem）。
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// 删除某个服务商的 API Key（不存在时不报错）。
    ///
    /// - Parameter providerID: 服务商 id。
    /// - Throws: `KeychainError.unexpectedStatus`（除「未找到」之外的非成功状态）。
    public func deleteAPIKey(for providerID: String) throws {
        guard !providerID.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 清空本 service 下的全部 API Key（「重置所有服务商」用）。
    public func deleteAllAPIKeys() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 列出本 service 下已保存 Key 的服务商 id（不读明文）。
    ///
    /// - Returns: 服务商 id 数组（顺序不保证）。
    public func providerIDsWithKeys() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

// MARK: - 错误

/// Keychain 操作错误。
public enum KeychainError: LocalizedError, Equatable, Sendable {
    /// 服务商 id 为空。
    case emptyProviderID
    /// Key 转 UTF-8 失败（理论上不会发生）。
    case encodingFailed
    /// 其它 OSStatus（`errSecSuccess` 之外）。
    case unexpectedStatus(OSStatus)

    /// 中文错误描述。
    public var errorDescription: String? {
        switch self {
        case .emptyProviderID:
            return "服务商标识为空，无法保存 API Key。"
        case .encodingFailed:
            return "API Key 编码失败，请检查是否包含不可见字符。"
        case .unexpectedStatus(let status):
            if status == errSecInteractionNotAllowed {
                return "设备当前已锁定，无法访问钥匙串。请解锁后重试。"
            }
            if status == errSecMissingEntitlement {
                return "缺少钥匙串访问权限，请检查工程的 Keychain Sharing 配置。"
            }
            return "钥匙串操作失败（OSStatus \(status)）。"
        }
    }

    /// 中文修复建议。
    public var recoverySuggestion: String? {
        switch self {
        case .emptyProviderID:
            return "请先在「设置 › AI 服务」里选择一个服务商。"
        case .encodingFailed:
            return "重新粘贴一遍 API Key，确认没有换行或空格。"
        case .unexpectedStatus(let status):
            if status == errSecInteractionNotAllowed {
                return "解锁设备后重新进入设置页即可。"
            }
            if status == errSecMissingEntitlement {
                return "在 Xcode 的 Signing & Capabilities 里为 App 与键盘扩展添加 Keychain Sharing（同一 group）。"
            }
            return "重启 App 后重试；若仍失败，请检查代码签名与设备钥匙串状态。"
        }
    }
}
