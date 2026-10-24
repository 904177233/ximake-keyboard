//
//  PasteboardBridge.swift
//  ios/Shared/Storage
//
//  模块职责：免费签名（无 App Group）下 App ↔ 键盘扩展的**配置搬运通道**。
//            用命名剪贴板 `com.moyu.config` 传一段带 magic / 版本 / 校验和的 JSON，
//            两边各自解析后落到自己的 `ConfigStore`，从而实现「一键搬家」。
//  依赖：Foundation、UIKit（仅 `UIPasteboard`；**不使用** `UIApplication.shared`）、
//        `Models`（ConfigSnapshot）、KeychainStore（可选导出 API Key）。
//  使用方：宿主 App 设置页「导出配置 / 导入配置」、键盘内设置 Sheet。
//
//  安全说明：默认导出**不含** API Key（只含服务商配置与偏好）。
//            `includeAPIKeys: true` 时会把 API Key 明文放进剪贴板，
//            **不做加密**——因为剪贴板内容任何 App 都能读，加密只是把明文换成一个
//            同样能被读走的密钥。UI 必须对此弹二次确认（见 README「风险提示」）。
//

import Foundation
import UIKit

/// 命名剪贴板配置搬运。
///
/// 用法（宿主 App 导出）：
/// ```swift
/// try PasteboardBridge.export(snapshot, includeAPIKeys: false)
/// // 提示用户：打开键盘 → 设置 → 导入配置
/// ```
/// 用法（键盘扩展导入）：
/// ```swift
/// if let imported = PasteboardBridge.importSnapshot() {
///     configStore.save(imported)
/// }
/// ```
public enum PasteboardBridge {

    /// 命名剪贴板名称。App 与扩展必须使用同一个名字。
    public static let pasteboardName = UIPasteboard.Name("com.moyu.config")

    /// 协议魔数（出现在载荷首行，用于识别「这段文本是不是墨语配置」）。
    public static let magic = "MOYU_CONFIG_V1"

    /// 当前导出格式版本（与 `ConfigSnapshot.currentVersion` 独立：前者是搬运信封格式，
    /// 后者是配置结构版本；信封里会同时写入两者）。
    public static let envelopeVersion = 1

    // MARK: - 导出

    /// 把配置快照写入命名剪贴板。
    ///
    /// 载荷格式（全部为 UTF-8 文本，四行 + JSON 体）：
    /// ```
    /// MOYU_CONFIG_V1
    /// envelope:1 snapshot:2
    /// fnv1a64:<16 位十六进制>
    /// {"version":2,"providers":[...],...}
    /// ```
    /// 第 3 行的校验和只覆盖第 4 行的 JSON 字节（FNV-1a 64 位），用于检测复制过程中的截断。
    ///
    /// - Parameters:
    ///   - snapshot: 要导出的快照。
    ///   - includeAPIKeys: 是否把 API Key 一并导出（明文，默认 false）。
    /// - Throws: `PasteboardBridgeError.encodingFailed` / `.emptyPayload`。
    public static func export(_ snapshot: ConfigSnapshot, includeAPIKeys: Bool = false) throws {
        let envelope = try makeEnvelope(snapshot, includeAPIKeys: includeAPIKeys)
        let pasteboard = UIPasteboard(name: pasteboardName, create: true)
        pasteboard?.string = envelope
        // 同时写系统剪贴板：用户在键盘里可能直接长按粘贴（nibble 场景更稳）。
        // 说明：这里只是写 string，不读取系统剪贴板，不涉及隐私权限弹窗。
        UIPasteboard.general.string = envelope
    }

    /// 生成导出文本（不落地，便于单测 / 校验和验证）。
    ///
    /// - Parameters:
    ///   - snapshot: 快照。
    ///   - includeAPIKeys: 是否含 API Key。
    /// - Returns: 可直接放进剪贴板的字符串。
    /// - Throws: `PasteboardBridgeError.encodingFailed`。
    public static func makeEnvelope(_ snapshot: ConfigSnapshot, includeAPIKeys: Bool) throws -> String {
        // 导出前把 version 归一，保证对方读到的一定是当前结构。
        var normalized = snapshot
        normalized.version = ConfigSnapshot.currentVersion

        var apiKeys: [String: String] = [:]
        if includeAPIKeys {
            for provider in normalized.providers {
                if let key = KeychainStore.shared.apiKey(for: provider.id), !key.isEmpty {
                    apiKeys[provider.id] = key
                }
            }
        }

        let payload = ExportPayload(
            snapshot: normalized,
            apiKeys: apiKeys.isEmpty ? nil : apiKeys
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            throw PasteboardBridgeError.encodingFailed
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw PasteboardBridgeError.encodingFailed
        }
        let checksum = String(format: "%016llx", fnv1a64(data))
        return """
        \(magic)
        envelope:\(envelopeVersion) snapshot:\(normalized.version)
        fnv1a64:\(checksum)
        \(json)
        """
    }

    // MARK: - 导入

    /// 从命名剪贴板导入配置快照。
    ///
    /// 依次校验：magic 行 → 信封版本 → 校验和 → JSON 结构。
    /// **不读取也不写入 Keychain**（API Key 需要用户另行导出/填写）。
    ///
    /// - Returns: 解析成功的快照；剪贴板为空 / 不是墨语配置 / 校验失败时返回 nil。
    public static func importSnapshot() -> ConfigSnapshot? {
        guard let raw = pasteboardString() else { return nil }
        guard let decoded = try? decodeEnvelope(raw) else { return nil }
        return decoded.snapshot
    }

    /// 从命名剪贴板导入「配置 + API Key」。
    ///
    /// - Returns: 解析成功的信封；失败返回 nil。
    public static func importEnvelope() -> ExportPayload? {
        guard let raw = pasteboardString() else { return nil }
        return try? decodeEnvelope(raw)
    }

    /// 解析导入文本（不读剪贴板，便于单测）。
    ///
    /// - Parameter raw: 导出时生成的字符串。
    /// - Returns: 解析出的信封。
    /// - Throws: `PasteboardBridgeError`。
    public static func decodeEnvelope(_ raw: String) throws -> ExportPayload {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PasteboardBridgeError.emptyPayload }

        // 允许用户在消息里转发时被加上首尾空白/换行，按行切分后取前四段。
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 4 else { throw PasteboardBridgeError.malformed("内容不完整，请重新导出后复制") }
        guard lines[0].trimmingCharacters(in: .whitespaces) == magic else {
            throw PasteboardBridgeError.wrongMagic
        }

        // 第 2 行：envelope:1 snapshot:2
        let metaLine = lines[1]
        let envelopeVersionValue = metaLine
            .split(separator: " ")
            .first { $0.hasPrefix("envelope:") }
            .flatMap { Int($0.dropFirst("envelope:".count)) }
        guard let envelopeVersionValue else {
            throw PasteboardBridgeError.malformed("缺少信封版本号")
        }
        guard envelopeVersionValue <= envelopeVersion else {
            throw PasteboardBridgeError.unsupportedVersion("该配置来自更新版本的墨语（信封 v\(envelopeVersionValue)），请先升级 App。")
        }

        // 第 3 行：fnv1a64:xxxx
        let checksumLine = lines[2].trimmingCharacters(in: .whitespaces)
        guard checksumLine.hasPrefix("fnv1a64:") else {
            throw PasteboardBridgeError.malformed("缺少校验和")
        }
        let expectedChecksum = String(checksumLine.dropFirst("fnv1a64:".count))

        // 第 4 行起是 JSON（JSON 内部可能包含换行，因此把剩余行重新拼回）。
        let json = lines[3...].joined(separator: "\n")
        guard let data = json.data(using: .utf8) else {
            throw PasteboardBridgeError.malformed("配置内容不是有效文本")
        }
        let actualChecksum = String(format: "%016llx", fnv1a64(data))
        guard actualChecksum == expectedChecksum else {
            throw PasteboardBridgeError.checksumMismatch
        }

        guard let payload = try? JSONDecoder().decode(ExportPayload.self, from: data) else {
            throw PasteboardBridgeError.malformed("配置 JSON 解析失败")
        }
        // 信封里的快照版本可能低于当前版本，交给 ConfigStore.migrate 处理。
        return payload
    }

    /// 命名剪贴板里是否有看起来像墨语配置的内容（不解析，用于 UI 显示「可导入」）。
    public static var hasImportableContent: Bool {
        guard let raw = pasteboardString() else { return false }
        return raw.hasPrefix(magic)
    }

    /// 清空命名剪贴板（导出成功后可按需调用，避免残留）。
    public static func clear() {
        UIPasteboard(name: pasteboardName, create: false)?.string = nil
    }

    // MARK: - 内部实现

    /// 读取命名剪贴板；不可用时回退到系统剪贴板（用户在键盘里长按粘贴的场景）。
    private static func pasteboardString() -> String? {
        if let value = UIPasteboard(name: pasteboardName, create: false)?.string, !value.isEmpty {
            return value
        }
        if let fallback = UIPasteboard.general.string, fallback.hasPrefix(magic) {
            return fallback
        }
        return nil
    }

    /// FNV-1a 64 位哈希（用于检测复制截断，非加密用途）。
    ///
    /// - Parameter data: 待校验字节。
    /// - Returns: 64 位哈希值。
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - 导出载荷

/// 剪贴板搬运的信封结构（JSON 体）。
public struct ExportPayload: Codable, Equatable, Sendable {

    /// 配置快照。
    public var snapshot: ConfigSnapshot
    /// API Key 映射（`providerID -> key`）；默认导出为 nil。
    ///
    /// 注意：这是**明文**。存在值说明用户显式选择了「连同 API Key 一起导出」。
    public var apiKeys: [String: String]?

    /// 成员初始化。
    public init(snapshot: ConfigSnapshot, apiKeys: [String: String]? = nil) {
        self.snapshot = snapshot
        self.apiKeys = apiKeys
    }

    /// 把信封里的 API Key 写入 Keychain（逐条覆盖）。
    ///
    /// - Returns: 成功写入的条数。
    @discardableResult
    public func applyAPIKeys() -> Int {
        guard let apiKeys else { return 0 }
        var applied = 0
        for (providerID, key) in apiKeys {
            if (try? KeychainStore.shared.setAPIKey(key, for: providerID)) != nil {
                applied += 1
            }
        }
        return applied
    }
}

// MARK: - 错误

/// 剪贴板搬运错误（中文文案可直接展示给用户）。
public enum PasteboardBridgeError: LocalizedError, Equatable, Sendable {
    /// 剪贴板里没有内容。
    case emptyPayload
    /// 不是墨语的配置文本（magic 不匹配）。
    case wrongMagic
    /// 校验和不匹配（内容被截断或篡改）。
    case checksumMismatch
    /// 版本过高。
    case unsupportedVersion(String)
    /// 结构不完整。
    case malformed(String)
    /// 编码失败。
    case encodingFailed

    /// 中文错误描述。
    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "剪贴板里没有内容。"
        case .wrongMagic:
            return "这段内容不是墨语配置。"
        case .checksumMismatch:
            return "配置校验失败，内容可能在复制时被截断。"
        case .unsupportedVersion(let detail):
            return detail
        case .malformed(let detail):
            return "配置格式不正确：\(detail)"
        case .encodingFailed:
            return "配置编码失败，请重试。"
        }
    }

    /// 中文修复建议。
    public var recoverySuggestion: String? {
        switch self {
        case .emptyPayload, .wrongMagic:
            return "回到「墨语」App → 设置 → 导出配置，再回到键盘内「导入配置」。"
        case .checksumMismatch, .malformed:
            return "请重新导出一次再复制；不要手动编辑这段文本。"
        case .unsupportedVersion:
            return "把 App 与键盘扩展升级到同一版本后重试。"
        case .encodingFailed:
            return "重启 App 后重试。"
        }
    }
}
