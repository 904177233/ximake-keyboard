//
//  KMInputEngine.swift
//  墨语（Moyu）键盘扩展 · 输入法内核薄封装
//
//  模块职责：键盘扩展对 `IMECore.IMEKit` 的唯一入口。所有词库、学习、短语、剪贴板能力都转发给
//            `IMEKit`，本类型只负责：①懒加载单例（避免键盘唤起时同步阻塞主线程）；
//            ②把「没有完全访问」时的剪贴板读取降级为安全空值；③给 UI 层提供稳定的只读诊断信息。
//  设计依据：docs/02 §4.6（IMECore API 契约）、Lead 指令（不得自建第二套拼音引擎）。
//  线程模型：`shared` 单例在 `prepare()` 中初始化 `IMEKit`；`IMEKit` 内部为同步只读查询，
//            由 `KeyboardViewModel`（@MainActor）顺序调用，不存在并发写。
//

import Foundation

/// 键盘扩展内的输入法内核门面。
///
/// 说明：本类型是 `IMEKit` 的薄封装，不重复实现任何拼音算法，也不自行解析词库文件。
/// 词库加载、学习权重、短语库与剪贴板历史全部由 `ios/Shared/IMECore` 提供，
/// 保证键盘扩展与宿主 App 共享同一份数据与同一套排序逻辑。
final class KMInputEngine: @unchecked Sendable {

    /// 全局单例：词库只加载一次，避免每次唤起键盘重复 IO。
    static let shared = KMInputEngine()

    /// 懒加载的内核门面（首次访问时初始化）。
    private var kitStorage: IMEKit?

    /// 键盘扩展内剪贴板历史开关的缓存值（用于诊断展示）。
    private var clipboardEnabled = false

    /// 单例初始化：不在初始化阶段读盘。
    private init() {}

    // MARK: - 生命周期

    /// 预热内核（幂等）。
    ///
    /// 在 `KeyboardViewController.viewDidLoad` 与首次候选请求前调用；
    /// 词库加载耗时约数毫秒，放在主线程可接受，且早于用户首次按键。
    /// - Parameter clipboardEnabled: 剪贴板历史开关的初始值（来自 `ConfigSnapshot`）。
    func prepare(clipboardEnabled: Bool = false) {
        if let kit = kitStorage {
            if clipboardEnabled != self.clipboardEnabled {
                self.clipboardEnabled = clipboardEnabled
                kit.clipboard.setEnabled(clipboardEnabled)
            }
            return
        }
        self.clipboardEnabled = clipboardEnabled
        let kit = IMEKit(store: SharedStore.shared, clipboardEnabled: clipboardEnabled)
        kitStorage = kit
    }

    /// 当前内核是否已完成初始化。
    var isReady: Bool {
        kitStorage != nil
    }

    /// 内部内核（未初始化时先按默认参数预热）。
    private var kit: IMEKit {
        if let existing = kitStorage {
            return existing
        }
        let created = IMEKit(store: SharedStore.shared, clipboardEnabled: clipboardEnabled)
        kitStorage = created
        return created
    }

    // MARK: - 候选

    /// 生成候选。
    /// - Parameters:
    ///   - input: 当前拼音组字串（小写、无空格）。
    ///   - limit: 最多返回条数，默认 30（候选栏一页展示量）。
    /// - Returns: 已按引擎分数排序的候选。
    func candidates(for input: String, limit: Int = 30) -> [IMECandidate] {
        kit.candidates(for: input, limit: limit)
    }

    /// 上屏并记录学习。
    /// - Parameters:
    ///   - candidate: 被用户选中的候选。
    ///   - input: 选中所对应的输入串。
    func commit(_ candidate: IMECandidate, input: String) {
        kit.commit(candidate, input: input)
    }

    /// 上屏后的联想候选。
    /// - Parameters:
    ///   - text: 已上屏文本。
    ///   - limit: 最多返回条数。
    /// - Returns: 联想候选。
    func predictNext(after text: String, limit: Int = 6) -> [IMECandidate] {
        kit.predictNext(after: text, limit: limit)
    }

    // MARK: - 短语库

    /// 快捷短语（置顶优先）。
    var phrases: [PhraseItem] {
        kit.phrases.items
    }

    /// 按键触发的短语展开（支持 `{date}` `{time}` `{clipboard}` 占位符）。
    /// - Parameters:
    ///   - item: 被点击的短语。
    ///   - clipboard: 剪贴板内容；无完全访问权限时传 `nil`。
    /// - Returns: 展开后的最终文本。
    func expand(_ item: PhraseItem, clipboard: String?) -> String {
        kit.phrases.expand(item, clipboard: clipboard)
    }

    /// 新增或更新一条短语。
    func upsertPhrase(_ item: PhraseItem) {
        kit.phrases.upsert(item)
    }

    /// 删除一条短语。
    func removePhrase(id: String) {
        kit.phrases.remove(id: id)
    }

    // MARK: - 剪贴板历史

    /// 剪贴板历史（最近在前，最多 20 条）。
    var clipboardItems: [String] {
        kit.clipboard.items
    }

    /// 记录一条剪贴板文本。
    func addClipboard(_ text: String) {
        kit.clipboard.add(text)
    }

    /// 置顶一条剪贴板文本。
    func pinClipboard(_ text: String) {
        kit.clipboard.pin(text)
    }

    /// 清空剪贴板历史。
    func clearClipboard() {
        kit.clipboard.clear()
    }

    /// 更新剪贴板历史开关。
    func setClipboardEnabled(_ enabled: Bool) {
        clipboardEnabled = enabled
        kit.clipboard.setEnabled(enabled)
    }

    // MARK: - 诊断

    /// 词库版本号。
    var dictionaryVersion: String {
        kit.dictionaryVersion
    }

    /// 词条总数。
    var wordCount: Int {
        kit.wordCount
    }

    /// 词库加载耗时（毫秒）。
    var loadDurationMilliseconds: Double {
        kit.loadDurationMilliseconds
    }

    /// 一条中文诊断摘要，用于设置页「关于」行。
    var diagnosticsSummary: String {
        kit.diagnosticsSummary
    }
}
