//
//  IMEKit.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：把词库、学习、引擎、短语库、剪贴板历史、上下文联想组装成单一门面，供 UI 层一次性初始化，
//            避免上层关心各子组件的加载顺序与依赖关系（契约 §4.6 的可选 facade）。
//  依赖：Foundation、PinyinDictionary、PinyinEngine、UserLearningStore、PhraseLibrary、
//        ClipboardHistory、LocalSuggestionIndex
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

    /// 上下文联想（L1 本地索引；L2 的提示词与解析见 `AISuggestionPrompt`）。
    public let contextual: LocalSuggestionIndex

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
        self.contextual = LocalSuggestionIndex(store: store)
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

    // MARK: - 上下文联想

    /// 本地上下文联想（转发 `LocalSuggestionIndex.suggestions(context:composing:limit:)`）。
    /// - Parameters:
    ///   - context: 输入框里光标前的文本。
    ///   - composing: 当前组字串（可为空）。
    ///   - limit: 最多返回条数（内部还会再夹到 `AISuggestionPolicy.maximumLocalResults`）。
    /// - Returns: 上下文联想候选（0~2 条）。
    public func contextualSuggestions(context: String,
                                      composing: String,
                                      limit: Int = AISuggestionPolicy.maximumLocalResults) -> [ContextualSuggestion] {
        contextual.suggestions(context: context, composing: composing, limit: limit)
    }

    /// 记录一次上下文联想的上屏，用于 L1 学习（转发 `LocalSuggestionIndex.record`）。
    /// - Parameters:
    ///   - context: 生成候选时使用的上下文。
    ///   - committed: 实际上屏的文本。
    public func recordContextualCommit(context: String, committed: String) {
        contextual.record(context: context, committed: committed)
    }

    // MARK: - 诊断信息

    /// 词库版本号。
    public var dictionaryVersion: String { dictionary.version }

    /// 词条总数。
    public var wordCount: Int { dictionary.wordCount }

    /// 词库加载耗时（毫秒），用于诊断页展示与性能回归。
    public var loadDurationMilliseconds: Double { dictionary.loadDurationMilliseconds }

    /// 词库来源（供诊断页直接渲染，不需要解析字符串）。
    public enum DictionarySource: String, Sendable {
        /// 成功读取随包词库文件。
        case bundled
        /// 未找到词库文件，正在使用内置极小词表（只有 50 条，中文候选会非常少）。
        case builtin
        /// 由内存词条构造（单元测试 / 调试）。
        case memory
    }

    /// 当前词库来源。
    ///
    /// 这是排查"键盘打不出中文"的第一判断依据：只要不是 `.bundled`，
    /// 说明 `dict/base_dict.tsv` 没有被打进当前 Bundle（扩展必须自带一份词库，
    /// 因为扩展里的 `Bundle.main` 是 `.appex` 而不是宿主 App）。
    public var dictionarySource: DictionarySource {
        switch dictionary.loadedPath {
        case "<builtin>": return .builtin
        case "<memory>": return .memory
        default: return .bundled
        }
    }

    /// 是否退回到内置 50 条极小词表（`true` 表示词库没加载上）。
    public var isUsingBuiltinDictionary: Bool {
        dictionarySource == .builtin
    }

    /// 词库在 Bundle 内的相对路径（如 `dict/base_dict.tsv`）；兜底时为 `<builtin>`。
    ///
    /// 只保留最后两级路径，避免在设置页展示超长的沙盒绝对路径。
    public var dictionaryRelativePath: String {
        let path = dictionary.loadedPath
        guard path.hasPrefix("/") else { return path }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }

    /// 一条中文诊断摘要（设置页/诊断页可直接展示）。
    ///
    /// 明确包含「词库来源」与「实际命中路径」两段，便于用户在真机上判断
    /// 词库到底有没有打进 Bundle（这是"候选很少/没有中文"的唯一现场证据）。
    public var diagnosticsSummary: String {
        let sourceText: String
        switch dictionarySource {
        case .bundled: sourceText = "打包词库"
        case .builtin: sourceText = "⚠️ 内置兜底词库"
        case .memory: sourceText = "内存词库"
        }
        let duration = String(format: "%.1f", dictionary.loadDurationMilliseconds)
        return "词库 v\(dictionary.version)｜\(dictionary.wordCount) 条｜来源：\(sourceText)"
            + "｜路径：\(dictionaryRelativePath)｜加载 \(duration)ms"
    }

    /// 一条上下文联想诊断摘要（诊断页可直接展示）。
    public var contextualDiagnosticsSummary: String {
        "上下文联想｜内置模板 \(contextual.seedRuleCount) 条｜已学习 \(contextual.learnedKeyCount) 个上下文"
    }
}
