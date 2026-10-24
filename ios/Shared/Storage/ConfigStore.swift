//
//  ConfigStore.swift
//  ios/Shared/Storage
//
//  模块职责：`ConfigSnapshot` 的持久化实现（`ConfigStoring`）。负责
//            ① JSON 编解码；② 版本迁移（v1 → v2）；③ 首次启动的默认快照工厂；
//            ④ 保存后回写归一化后的 version。
//  依赖：Foundation、`Models`（ConfigSnapshot）、SharedStore。
//  使用方：宿主 App（AppState 持有一个 `ConfigStore`）、键盘扩展（读取默认 Provider）、
//          `PasteboardBridge`（导入后落盘）、设置页「恢复默认」。
//
//  存储位置：`SharedStore.shared` 的 `moyu.config.snapshot` 键（JSON Data）。
//  迁移规则：见 `migrate(_:)` 与 `ios/Shared/Storage/README.md`。
//

import Foundation

/// 配置存储协议（docs/02 §4.3）。
///
/// 只依赖协议即可替换实现（测试里用内存实现）。
public protocol ConfigStoring: AnyObject {
    /// 读取当前配置快照（永不失败：解析失败时返回默认快照）。
    func load() -> ConfigSnapshot
    /// 保存配置快照。
    func save(_ snapshot: ConfigSnapshot)
}

/// `ConfigSnapshot` 的 JSON 持久化实现（基于 `SharedStore`）。
///
/// 用法：
/// ```swift
/// let store = ConfigStore()                 // 默认读 SharedStore.shared
/// var snapshot = store.load()
/// snapshot.defaultTone = "正式"
/// store.save(snapshot)
/// ```
///
/// 线程安全：所有操作都落在 `UserDefaults`（自身线程安全）上，本类型无可变状态。
public final class ConfigStore: ConfigStoring, @unchecked Sendable {

    /// 默认存储键。
    public static let defaultKey = "moyu.config.snapshot"

    /// 共享存储。
    private let store: SharedStore
    /// 存储键。
    private let key: String

    /// 创建实例。
    ///
    /// - Parameters:
    ///   - store: 共享存储，默认 `.shared`。
    ///   - key: 存储键，默认 `ConfigStore.defaultKey`（`moyu.config.snapshot`）。
    ///     键盘扩展**不要**另起一个新键（否则 App 与扩展读到的不是同一份配置）。
    public init(store: SharedStore = .shared, key: String = ConfigStore.defaultKey) {
        self.store = store
        self.key = key
    }

    // MARK: - 读写

    /// 读取配置快照。
    ///
    /// 行为：
    /// - 无数据（首次启动）→ 返回 `ConfigSnapshot.defaultValue()`（不写盘，由调用方决定何时保存）；
    /// - 有数据 → 解码，并执行 `migrate(_:)`，保证返回的 `version` 一定是当前版本；
    /// - 数据损坏 → 返回默认快照（不抛错，避免键盘整体不可用）。
    public func load() -> ConfigSnapshot {
        guard let data = store.data(forKey: key) else {
            return ConfigSnapshot.defaultValue()
        }
        guard let decoded = try? JSONDecoder().decode(ConfigSnapshot.self, from: data) else {
            return ConfigSnapshot.defaultValue()
        }
        return migrate(decoded)
    }

    /// 保存配置快照（自动把 `version` 归一为 `ConfigSnapshot.currentVersion`）。
    public func save(_ snapshot: ConfigSnapshot) {
        var normalized = snapshot
        normalized.version = ConfigSnapshot.currentVersion
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        store.setData(data, forKey: key)
    }

    /// 恢复为出厂默认（会覆盖磁盘上的快照）。
    @discardableResult
    public func resetToDefault() -> ConfigSnapshot {
        let snapshot = ConfigSnapshot.defaultValue()
        save(snapshot)
        return snapshot
    }

    /// 恢复为「只含内置预设」的快照（清掉用户自建服务商，但保留开关与尺寸偏好）。
    @discardableResult
    public func resetToPresetOnly() -> ConfigSnapshot {
        var snapshot = ConfigSnapshot.presetOnly()
        let current = load()
        snapshot.defaultTone = current.defaultTone
        snapshot.replyCount = current.replyCount
        snapshot.enableClipboardHistory = current.enableClipboardHistory
        snapshot.enableLearning = current.enableLearning
        snapshot.imageSize = current.imageSize
        save(snapshot)
        return snapshot
    }

    /// 是否已经有落盘的配置（用于「首次启动」判定）。
    public var hasStoredSnapshot: Bool {
        store.data(forKey: key) != nil
    }

    // MARK: - 版本迁移

    /// 把旧版本快照迁移到当前版本。
    ///
    /// 迁移规则（当前 v1 → v2）：
    /// - v1 没有 `imageProviderID`：解码时已填 nil，这里补一条可用的生图服务商 id
    ///   （优先沿用 `providers` 里已存在的生图预设，其次 `preset-seedream`）。
    /// - v1 的 `replyCount` 若越界（老版本没有 clamp）→ 收敛到 1...5。
    /// - `providers` 为空（极端损坏）→ 灌入内置预设。
    /// - 迁移只改内存中的结构，**不隐式写盘**；下一次 `save(_:)` 时自然落盘为 v2。
    ///
    /// - Parameter snapshot: 从磁盘解码出的快照。
    /// - Returns: 已迁移到当前版本的新快照。
    public func migrate(_ snapshot: ConfigSnapshot) -> ConfigSnapshot {
        var migrated = snapshot
        let sourceVersion = snapshot.version

        if sourceVersion < 2 {
            // v1：没有生图服务商概念。
            if migrated.providers.isEmpty {
                migrated.providers = ConfigSnapshot.presetOnly().providers
            }
            if migrated.imageProviderID == nil {
                migrated.imageProviderID = migrated.providers.first { $0.supportsImage }?.id
                    ?? PresetProviders.defaultImagePreset?.id
            }
            if migrated.defaultProviderID == nil {
                migrated.defaultProviderID = migrated.providers.first { $0.supportsChat }?.id
            }
        }

        // 通用收敛（任何版本都做，保证越界数据不会带进 UI）。
        migrated.replyCount = min(max(migrated.replyCount, 1), 5)
        if migrated.defaultTone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            migrated.defaultTone = "自然"
        }
        if migrated.imageSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            migrated.imageSize = "1024x1024"
        }
        if migrated.providers.isEmpty {
            migrated.providers = ConfigSnapshot.presetOnly().providers
        }
        // 默认对话 Provider 不能指向「仅生图」预设，否则 UI 一打开就是错误态。
        if let chatID = migrated.defaultProviderID,
           let provider = migrated.providers.first(where: { $0.id == chatID }),
           !provider.supportsChat {
            migrated.defaultProviderID = migrated.providers.first { $0.supportsChat }?.id
        }
        migrated.version = ConfigSnapshot.currentVersion
        return migrated
    }
}

// MARK: - 内存实现（测试 / 预览用）

/// 纯内存配置存储（用于 SwiftUI Preview 与单元测试，不落盘）。
public final class InMemoryConfigStore: ConfigStoring, @unchecked Sendable {

    /// 当前快照。
    private var snapshot: ConfigSnapshot

    /// 创建实例。
    ///
    /// - Parameter snapshot: 初始快照，默认 `ConfigSnapshot.defaultValue()`。
    public init(snapshot: ConfigSnapshot = .defaultValue()) {
        self.snapshot = snapshot
    }

    /// 读取（返回内存中的副本）。
    public func load() -> ConfigSnapshot {
        snapshot
    }

    /// 写入（仅内存）。
    public func save(_ snapshot: ConfigSnapshot) {
        self.snapshot = snapshot
    }
}
