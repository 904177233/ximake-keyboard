//
//  IMEKit.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：把词库、学习、引擎、短语库、剪贴板历史组装成单一门面，供 UI 层一次性初始化，
//            避免上层关心各子组件的加载顺序与依赖关系（契约 §4.6 的可选 facade）。
//  依赖：Foundation、PinyinDictionary、PinyinEngine、UserLearningStore、PhraseLibrary、ClipboardHistory
//  使用方：keyboard-ui 的 KeyboardViewModel、host-app-ui 的启动流程与诊断页
//

import Foundation

/// 输入法内核门面。
///
/// 典型用法：
/// ```swift
/// let kit = IMEKit(store: SharedStore.shared)
/// let candidates = kit.candidates(for: "zg")
/// kit.commit(candidates[0], input: "zg")
/// ```
public final class IMEKit {

    // MARK: - 子组件

    /// 拼音词库（全局单例，多实例共享）。
    public let dictionary: PinyinDictionary

    /// 用户学习数据。
    public let learning: UserLearningStore

    /// 候选引擎。
    public let engine: PinyinEngine

    /// 用户短语库。
    public let phrases: PhraseLibrary

    /// 剪贴板历史。
    public let clipboard: ClipboardHistory

    // MARK: - 初始化

    /// 创建门面。
    /// - Parameters:
    ///   - store: 共享存储容器（App 与键盘扩展共用）。
    ///   - dictionary: 词库；默认使用打包在 App 内的 `base_dict.tsv`。
    ///   - clipboardEnabled: 剪贴板历史开关的初始值。
    public init(
        store: SharedStore,
        dictionary: PinyinDictionary = PinyinDictionary.bundled(),
        clipboardEnabled: Bool = false
    ) {
        let learning = UserLearningStore(store: store)
        self.dictionary = dictionary
        self.learning = learning
        self.engine = PinyinEngine(dictionary: dictionary, learning: learning)
        self.phrases = PhraseLibrary(store: store)
        self.clipboard = ClipboardHistory(store: store, enabled: clipboardEnabled)
    }

    // MARK: - 候选

    /// 生成候选（转发 `PinyinEngine.candidates(for:limit:)`）。
    /// - Parameters:
    ///   - input: 输入串。
    ///   - limit: 最多返回条数。
    /// - Returns: 候选数组。
    public func candidates(for input: String, limit: Int = 30) -> [IMECandidate] {
        engine.candidates(for: input, limit: limit)
    }

    /// 上屏并学习（转发 `PinyinEngine.commit(_:input:)`）。
    /// - Parameters:
    ///   - candidate: 被选中的候选。
    ///   - input: 输入串。
    public func commit(_ candidate: IMECandidate, input: String) {
        engine.commit(candidate, input: input)
    }

    /// 上屏后联想（转发 `PinyinEngine.predictNext(after:limit:)`）。
    /// - Parameters:
    ///   - text: 已上屏文本。
    ///   - limit: 最多返回条数。
    /// - Returns: 联想候选。
    public func predictNext(after text: String, limit: Int) -> [IMECandidate] {
        engine.predictNext(after: text, limit: limit)
    }

    // MARK: - 诊断信息

    /// 词库版本号。
    public var dictionaryVersion: String { dictionary.version }

    /// 词条总数。
    public var wordCount: Int { dictionary.wordCount }

    /// 词库加载耗时（毫秒），用于诊断页展示与性能回归。
    public var loadDurationMilliseconds: Double { dictionary.loadDurationMilliseconds }

    /// 一条中文诊断摘要（设置页/诊断页可直接展示）。
    public var diagnosticsSummary: String {
        let path = dictionary.loadedPath
        let source = path == "<builtin>" ? "内置兜底词库" : "打包词库"
        let duration = String(format: "%.1f", dictionary.loadDurationMilliseconds)
        return "词库 v\(dictionary.version)｜\(dictionary.wordCount) 条｜\(source)｜加载 \(duration)ms"
    }
}
