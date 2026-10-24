//
//  SharedStore.swift
//  ios/Shared/Storage
//
//  模块职责：App 与键盘扩展之间的共享存储门面。按三级策略选择底层容器：
//            ① App Group `UserDefaults(suiteName:)`（配置了 entitlements 且系统可用）
//            ② `UserDefaults.standard`（同一进程内可用，App 与扩展各自独立）
//            ③ 内存字典（最后兜底，写不落盘但不会崩溃）
//  依赖：Foundation。
//  使用方：ConfigStore（配置快照）、PromptLibrary（自定义模板）、PhraseLibrary（短语，IMECore）、
//          宿主 App（首次启动标记 / 外观模式）、键盘扩展。
//
//  现实约束（免费 Apple ID，见 docs/01 §6）：
//  免费个人团队签名无法为键盘扩展配置 App Group，因此 `isAppGroupAvailable` 通常为 false，
//  App 与键盘扩展**各自持有独立的 UserDefaults**。用户可走的路径有两条：
//    1) 在宿主 App 里「导出配置」→ 复制到命名剪贴板 `com.moyu.config` → 键盘内「导入配置」；
//    2) 购买付费开发者账号后补 App Group（`group.com.moyu.keyboard`），代码无需改动即自动升级到 ①。
//  API Key 始终只存在 Keychain（且 Keychain 需要 App Group 才能跨进程共享，
//  无 App Group 时同样需要靠剪贴板搬移配置，README 里有完整操作路径）。
//

import Foundation

/// App 与键盘扩展共享的存储门面（三级降级策略）。
///
/// 用法：
/// ```swift
/// SharedStore.shared.set("自然", forKey: "moyu.settings.tone")
/// let tone = SharedStore.shared.string(forKey: "moyu.settings.tone") ?? "自然"
/// let defaults = SharedStore.shared.defaults   // 直接给 UserDefaults 用法（bool(forKey:) 等）
/// ```
///
/// 说明：
/// - `defaults` 永远非 nil 且可直接使用：无 App Group 时返回 `.standard`，
///   再不可用时返回一个进程内的 `UserDefaults` 实例（不会崩溃，但重启后丢失）。
/// - 本类型**不缓存**值，保证 App 与扩展在各自进程里读到的都是底层最新数据。
public final class SharedStore: @unchecked Sendable {

    /// 全局单例。
    public static let shared = SharedStore()

    /// App Group 标识。宿主 App 与键盘扩展的 entitlements 必须一致。
    public static let appGroupIdentifier = "group.com.moyu.keyboard"

    /// 未配置 App Group 时使用的回退键前缀（避免与 App 自身键冲突）。
    static let fallbackPrefix = "moyu.shared."

    /// 底层容器类型。
    public enum Backing: String, Sendable {
        /// App Group 共享容器（理想状态）。
        case appGroup
        /// 进程内标准 UserDefaults（App 与扩展各存各的）。
        case standard
        /// 纯内存兜底（不落盘）。
        case memory
    }

    /// 当前生效的底层容器类型。
    public let backing: Backing

    /// 底层 `UserDefaults`（`backing == .memory` 时是一个内存实例，仍可安全读写）。
    public let defaults: UserDefaults

    /// 是否真的能跨进程共享（只有 ① 为 true）。
    public var isAppGroupAvailable: Bool {
        backing == .appGroup
    }

    /// 给用户看的中文状态说明（设置页「存储状态」一行）。
    public var storageStatusDescription: String {
        switch backing {
        case .appGroup:
            return "App Group 可用，App 与键盘扩展共享配置"
        case .standard:
            return "App Group 不可用，App 与键盘扩展各自独立存储（可用剪贴板搬运配置）"
        case .memory:
            return "存储不可用，本次运行内的配置不会保存"
        }
    }

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: App Group 标识，默认 `group.com.moyu.keyboard`。
    ///   - forceMemory: 强制使用内存兜底（仅测试 / 自检用，写入不落盘）。
    init(
        appGroupIdentifier: String = SharedStore.appGroupIdentifier,
        forceMemory: Bool = false
    ) {
        if forceMemory {
            // ③ 内存兜底：仅测试或极端情况下显式启用（不落盘）。
            self.backing = .memory
            self.defaults = SharedStore.makeMemoryDefaults()
            return
        }

        var resolvedBacking: Backing = .standard
        var resolvedDefaults: UserDefaults = .standard

        if let groupDefaults = UserDefaults(suiteName: appGroupIdentifier),
           SharedStore.probe(groupDefaults) {
            // `UserDefaults(suiteName:)` 在未配置 App Group 时也可能返回对象，
            // 但写入后立刻读取会失败。`probe` 做一次写-读-删，确认真的可用。
            resolvedBacking = .appGroup
            resolvedDefaults = groupDefaults
        } else {
            // `.standard` 在 App 与扩展里各自独立，是免费账号下的现实方案。
            resolvedBacking = .standard
            resolvedDefaults = .standard
        }

        self.backing = resolvedBacking
        self.defaults = resolvedDefaults
    }

    // MARK: - 读写 API（String / Data / Bool / Int / Double）

    /// 读字符串。
    ///
    /// - Parameter key: 键（会自动加 `moyu.shared.` 前缀，仅在非 App Group 时用于隔离）。
    /// - Returns: 值；不存在或类型不符时返回 nil。
    public func string(forKey key: String) -> String? {
        defaults.string(forKey: scopedKey(key))
    }

    /// 写字符串（nil 等价于删除）。
    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: scopedKey(key))
        } else {
            defaults.removeObject(forKey: scopedKey(key))
        }
    }

    /// 读 Data。
    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: scopedKey(key))
    }

    /// 写 Data。
    public func setData(_ value: Data?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: scopedKey(key))
        } else {
            defaults.removeObject(forKey: scopedKey(key))
        }
    }

    /// 读 Bool（不存在时返回 `defaultValue`）。
    public func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        guard defaults.object(forKey: scopedKey(key)) != nil else { return defaultValue }
        return defaults.bool(forKey: scopedKey(key))
    }

    /// 写 Bool。
    public func setBool(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: scopedKey(key))
    }

    /// 读 Int（不存在时返回 `defaultValue`）。
    public func integer(forKey key: String, default defaultValue: Int = 0) -> Int {
        guard defaults.object(forKey: scopedKey(key)) != nil else { return defaultValue }
        return defaults.integer(forKey: scopedKey(key))
    }

    /// 写 Int。
    public func setInteger(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: scopedKey(key))
    }

    /// 读 Double（不存在时返回 `defaultValue`）。
    public func double(forKey key: String, default defaultValue: Double = 0) -> Double {
        guard defaults.object(forKey: scopedKey(key)) != nil else { return defaultValue }
        return defaults.double(forKey: scopedKey(key))
    }

    /// 写 Double。
    public func setDouble(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: scopedKey(key))
    }

    /// 是否存在某个键。
    public func hasValue(forKey key: String) -> Bool {
        defaults.object(forKey: scopedKey(key)) != nil
    }

    /// 删除某个键。
    public func remove(forKey key: String) {
        defaults.removeObject(forKey: scopedKey(key))
    }

    /// 把所有 `moyu.shared.` 前缀的键清空（「恢复默认设置」用；不影响 App 其它偏好）。
    public func removeAllSharedValues() {
        let prefix = SharedStore.fallbackPrefix
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - 内部实现

    /// 非 App Group 时给键加前缀，避免与宿主 App 自身偏好同名互踩。
    ///
    /// App Group 可用时**不加前缀**（保持与旧版 / 文档一致的原始键名）。
    private func scopedKey(_ key: String) -> String {
        guard !isAppGroupAvailable else { return key }
        guard !key.hasPrefix(SharedStore.fallbackPrefix) else { return key }
        return SharedStore.fallbackPrefix + key
    }

    /// 写-读-删探测 App Group 是否真的可用。
    private static func probe(_ defaults: UserDefaults) -> Bool {
        let probeKey = "moyu.probe.\(UUID().uuidString)"
        let probeValue = "ok"
        defaults.set(probeValue, forKey: probeKey)
        let readable = defaults.string(forKey: probeKey) == probeValue
        defaults.removeObject(forKey: probeKey)
        return readable
    }

    /// 构造一个纯内存 `UserDefaults`（`UserDefaults(suiteName:)` 指向不存在的 suite 也不保证内存语义，
    /// 因此这里用临时 suite 名并立即清空，作为最后兜底：至少 API 一致、不会崩溃）。
    private static func makeMemoryDefaults() -> UserDefaults {
        let suiteName = "moyu.memory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

// MARK: - 便捷键名常量

/// 共享存储中使用的键名（集中管理，避免拼写错误）。
public enum SharedStoreKey {
    /// 配置快照 JSON（`ConfigStore`）。
    public static let configSnapshot = "moyu.config.snapshot"
    /// 自定义提示词模板（`PromptLibrary`）。
    public static let customPrompts = "moyu.prompts.custom.v1"
    /// 自定义短语（`PhraseLibrary`）。
    public static let phrases = "moyu.phrases.v1"
    /// 剪贴板历史开关（`ConfigSnapshot.enableClipboardHistory` 的冗余镜像，供键盘热路径快速读）。
    public static let clipboardHistoryEnabled = "moyu.settings.clipboardHistory"
    /// 当前语气（最近一次选择）。
    public static let currentTone = "moyu.settings.tone"
    /// 当前目标语言（翻译）。
    public static let targetLanguage = "moyu.settings.targetLanguage"
    /// 上次使用的对话服务商 id（优先于 snapshot.defaultProviderID，用于「临时切换」场景）。
    public static let lastChatProviderID = "moyu.settings.lastChatProviderID"
    /// 首次启动标记。
    public static let hasCompletedOnboarding = "moyu.host.hasCompletedOnboarding"
}
