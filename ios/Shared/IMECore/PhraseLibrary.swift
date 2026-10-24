//
//  PhraseLibrary.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：用户自定义短语库的增删改查与占位符展开（`{date}`/`{time}`/`{clipboard}`），
//            数据经 SharedStore 持久化，App 与键盘扩展共用同一份。
//  依赖：Foundation、SharedStore（同 target，仅使用公开方法）
//  使用方：host-app-ui 的 SharedBridge.PhraseStore、keyboard-ui 的短语面板
//

import Foundation

/// 一条用户短语。
public struct PhraseItem: Identifiable, Codable, Sendable, Equatable {
    /// 唯一标识（UUID 字符串）。
    public var id: String

    /// 快捷触发词（空串表示不设触发词，只能在短语面板手动选择）。
    public var key: String

    /// 短语正文，可含 `{date}`/`{time}`/`{clipboard}` 占位符。
    public var text: String

    /// 是否置顶（置顶项排在列表前面）。
    public var isPinned: Bool

    /// 创建一条短语。
    /// - Parameters:
    ///   - id: 唯一标识。
    ///   - key: 快捷触发词。
    ///   - text: 短语正文。
    ///   - isPinned: 是否置顶。
    public init(id: String, key: String, text: String, isPinned: Bool) {
        self.id = id
        self.key = key
        self.text = text
        self.isPinned = isPinned
    }

    /// 便捷创建（自动生成 id、不置顶）。
    /// - Parameters:
    ///   - key: 快捷触发词。
    ///   - text: 短语正文。
    public init(key: String, text: String) {
        self.init(id: UUID().uuidString, key: key, text: text, isPinned: false)
    }
}

/// 短语库（线程安全）。
///
/// 排序规则：置顶项在前，其余按添加顺序（先加的在前）。
/// 占位符展开只在 `expand(_:clipboard:)` 时进行，不改动存储的原文。
public final class PhraseLibrary {

    // MARK: - 常量

    /// 持久化键。
    private enum Keys {
        static let phrases = "moyu.phrases.v1"
    }

    /// 内置示例短语（首次启动且存储为空时写入，便于用户理解占位符用法）。
    private static let seededPhrases: [PhraseItem] = [
        PhraseItem(id: "seed-date", key: "rq", text: "今天是{date}", isPinned: false),
        PhraseItem(id: "seed-time", key: "sj", text: "现在是{time}，我稍后回你", isPinned: false),
        PhraseItem(id: "seed-addr", key: "dz", text: "我的地址是：", isPinned: false)
    ]

    // MARK: - 状态

    private let store: SharedStore
    private let lock = NSLock()
    private var stored: [PhraseItem]

    // MARK: - 初始化

    /// 创建短语库。
    /// - Parameter store: 共享存储容器。
    public init(store: SharedStore) {
        self.store = store
        if let data = store.data(forKey: Keys.phrases),
           let decoded = try? JSONDecoder().decode([PhraseItem].self, from: data) {
            self.stored = decoded
        } else if let legacy = store.string(forKey: Keys.phrases),
                  let data = legacy.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([PhraseItem].self, from: data) {
            // 兼容旧版本以字符串形式存储的数据
            self.stored = decoded
        } else {
            self.stored = Self.seededPhrases
            if let data = try? JSONEncoder().encode(Self.seededPhrases) {
                store.setData(data, forKey: Keys.phrases)
            }
        }
    }

    // MARK: - 查询

    /// 全部短语（置顶优先，其余保持添加顺序）。
    public var items: [PhraseItem] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sorted(stored)
    }

    /// 按快捷触发词精确查找。
    /// - Parameter key: 触发词。
    /// - Returns: 命中的短语；无命中为 `nil`。
    public func match(key: String) -> PhraseItem? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return Self.sorted(stored).first {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    // MARK: - 写入

    /// 新增或更新（按 `id` 判定）。
    /// - Parameter item: 短语。
    public func upsert(_ item: PhraseItem) {
        lock.lock()
        if let index = stored.firstIndex(where: { $0.id == item.id }) {
            stored[index] = item
        } else {
            stored.append(item)
        }
        let snapshot = stored
        lock.unlock()
        persist(snapshot)
    }

    /// 删除指定短语。
    /// - Parameter id: 短语 id。
    public func remove(id: String) {
        lock.lock()
        stored.removeAll { $0.id == id }
        let snapshot = stored
        lock.unlock()
        persist(snapshot)
    }

    // MARK: - 展开

    /// 展开短语中的占位符。
    ///
    /// 支持 `{date}`（今天的日期，如 `2026年10月24日`）、`{time}`（当前时间，如 `16:15`）、
    /// `{clipboard}`（剪贴板内容；传入 `nil` 或为空时展开为空串）。
    /// - Parameters:
    ///   - item: 待展开的短语。
    ///   - clipboard: 剪贴板内容。
    /// - Returns: 展开后的文本。
    public func expand(_ item: PhraseItem, clipboard: String?) -> String {
        Self.expand(text: item.text, clipboard: clipboard, date: Date())
    }

    /// 展开任意文本中的占位符（内部实现，便于测试注入固定时间）。
    /// - Parameters:
    ///   - text: 原文。
    ///   - clipboard: 剪贴板内容。
    ///   - date: 用于格式化的时间点。
    /// - Returns: 展开后的文本。
    static func expand(text: String, clipboard: String?, date: Date) -> String {
        guard text.contains("{") else { return text }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")

        var result = text
        if result.contains("{date}") {
            formatter.dateFormat = "yyyy年M月d日"
            result = result.replacingOccurrences(of: "{date}", with: formatter.string(from: date))
        }
        if result.contains("{time}") {
            formatter.dateFormat = "HH:mm"
            result = result.replacingOccurrences(of: "{time}", with: formatter.string(from: date))
        }
        if result.contains("{clipboard}") {
            let content = clipboard ?? ""
            result = result.replacingOccurrences(of: "{clipboard}", with: content)
        }
        return result
    }

    // MARK: - 内部

    /// 排序：置顶在前，其余保持原有相对顺序。
    private static func sorted(_ items: [PhraseItem]) -> [PhraseItem] {
        let pinned = items.filter { $0.isPinned }
        let normal = items.filter { !$0.isPinned }
        return pinned + normal
    }

    /// 落盘。
    /// - Parameter snapshot: 待写入的短语数组。
    private func persist(_ snapshot: [PhraseItem]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        store.setData(data, forKey: Keys.phrases)
    }
}

/// 剪贴板历史（最近 20 条、去重、可置顶、可整体关闭）。
///
/// 隐私：`enabled == false` 时不记录任何内容（`add` 直接返回），
/// 并在初始化时清空既有历史，避免用户关闭开关后仍留有敏感数据。
public final class ClipboardHistory {

    // MARK: - 常量

    /// 历史条数上限。
    public static let capacity = 20

    /// 持久化键。
    private enum Keys {
        static let history = "moyu.ime.clipboard.v1"
        static let enabled = "moyu.settings.clipboardHistory"
    }

    // MARK: - 落盘结构

    private struct Persisted: Codable {
        var items: [String]
        var pinned: [String]
    }

    // MARK: - 状态

    private let store: SharedStore
    private let lock = NSLock()
    private var records: [String]
    private var pinned: [String]

    /// 剪贴板记录开关（关闭时不采集、不保留）。
    public private(set) var isEnabled: Bool

    // MARK: - 初始化

    /// 创建剪贴板历史。
    /// - Parameters:
    ///   - store: 共享存储容器。
    ///   - enabled: 是否开启采集（用户隐私开关）。
    public init(store: SharedStore, enabled: Bool) {
        self.store = store
        self.isEnabled = enabled
        if let data = store.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            self.records = decoded.items
            self.pinned = decoded.pinned
        } else {
            self.records = []
            self.pinned = []
        }
        if !enabled {
            self.records = []
            self.pinned = []
            persist()
        }
        store.setBool(enabled, forKey: Keys.enabled)
    }

    /// 全部历史（置顶项在前，其余最新优先）。
    public var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String] = []
        var seen = Set<String>()
        for text in pinned + records where seen.insert(text).inserted {
            result.append(text)
        }
        return result
    }

    // MARK: - 写入

    /// 追加一条剪贴板内容（自动去重、限长 20、置顶项不参与淘汰）。
    /// - Parameter text: 剪贴板文本。
    public func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !trimmed.isEmpty else { return }
        lock.lock()
        records.removeAll { $0 == trimmed }
        records.insert(trimmed, at: 0)
        let overflow = records.count - Self.capacity
        if overflow > 0 {
            records.removeLast(overflow)
        }
        lock.unlock()
        persist()
    }

    /// 置顶/取消置顶某条历史。
    /// - Parameter text: 历史文本。
    public func pin(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lock.lock()
        if let index = pinned.firstIndex(of: trimmed) {
            pinned.remove(at: index)
        } else {
            pinned.insert(trimmed, at: 0)
            records.removeAll { $0 == trimmed }
        }
        lock.unlock()
        persist()
    }

    /// 清空全部历史（保留置顶项）。
    public func clear() {
        lock.lock()
        records = []
        lock.unlock()
        persist()
    }

    /// 切换开关；关闭时立即清空已记录内容。
    /// - Parameter enabled: 是否开启。
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        store.setBool(enabled, forKey: Keys.enabled)
        if !enabled {
            lock.lock()
            records = []
            pinned = []
            lock.unlock()
        }
        persist()
    }

    // MARK: - 内部

    /// 落盘。
    private func persist() {
        lock.lock()
        let snapshot = Persisted(items: records, pinned: pinned)
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            store.setData(data, forKey: Keys.history)
        }
    }
}
