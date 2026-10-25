import Foundation

/// 聊天高频词权重表（随包文件 `chat_priority.tsv`，两列：`词 <TAB> 权重`）。
///
/// 为什么需要一张额外的表：词库词频来自新闻/百科语料，和「聊天里先打哪个词」不是
/// 一回事。两个字母的简拼（`wq`）在语料里先命中 `完全`/`武器`，而用户要的是 `我去`
/// ——这是**语料词频与聊天场景用词**的错配，只能靠一张显式先验表纠正。
///
/// 约定与词库一致：文件缺失、解析失败都**静默降级**为空表（`empty`），引擎退回原逻辑，
/// 绝不因为一张可选表而让键盘起不来。
public struct ChatPriorityTable {

    /// 词 → 权重（1.0–3.0）。
    private let weights: [String: Double]

    /// 空表（文件缺失或解析失败时使用）。
    public static let empty = ChatPriorityTable(weights: [:])

    /// 表内词条数（诊断用；`IMEKit` 不展示）。
    public var count: Int { weights.count }

    /// 直接用量表创建（单元测试用）。
    /// - Parameter weights: 词 → 权重。
    public init(weights: [String: Double]) {
        self.weights = weights
    }

    /// 某个词的聊天权重。
    /// - Parameter word: 候选词文本。
    /// - Returns: 1.0–3.0；不在表里返回 0（表示「不加成」）。
    public func weight(for word: String) -> Double {
        weights[word] ?? 0
    }

    // MARK: - 解析

    /// 解析 `词 <TAB> 权重` 文本。
    ///
    /// 容忍度与 `PinyinDictionary.parse` 保持一致：去 BOM、去行尾 `\r`、跳过空行与
    /// `#` 注释行。权重不在 `1.0...3.0`（含 NaN）或列数不足的行**直接丢弃**——宁可
    /// 少加一点权重，也不让脏数据把排序搅乱。
    ///
    /// - Parameter text: 文件全文。
    /// - Returns: 词 → 权重。
    static func parse(text: String) -> [String: Double] {
        var table: [String: Double] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            let word = String(fields[0]).trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty,
                  let weight = Double(fields[1]),
                  weight >= 1.0,
                  weight <= 3.0
            else { continue }
            // 同一个词重复出现时取较大权重（表是手写的，重复行按「更强的先验」理解）
            table[word] = max(table[word] ?? 0, weight)
        }
        return table
    }

    // MARK: - 加载

    /// 从 App Bundle 加载权重表；找不到文件时返回 `.empty`。
    ///
    /// 搜索路径与 `PinyinDictionary` 完全一致（`dict/` folder reference 优先，
    /// 其次旧的 `Resources/dict/`，最后直接进 Copy Bundle Resources 的根目录），
    /// 这样词库和权重表永远同生共死。
    ///
    /// - Returns: 权重表（失败为空表，不抛错）。
    public static func load() -> ChatPriorityTable {
        for url in candidateURLs() {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            return ChatPriorityTable(weights: parse(text: text))
        }
        return .empty
    }

    /// 参与查找的 Bundle 列表：主 Bundle 优先，其次本类型所在 Bundle。
    private static func searchBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.main]
        let classBundle = Bundle(for: PinyinEngine.self)
        if classBundle.bundleURL.path != Bundle.main.bundleURL.path {
            bundles.append(classBundle)
        }
        return bundles
    }

    /// `chat_priority.tsv` 的候选路径（去重后按优先级返回）。
    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let subdirectories: [String?] = ["dict", "Resources/dict", nil]
        for bundle in searchBundles() {
            for subdirectory in subdirectories {
                if let url = bundle.url(forResource: "chat_priority",
                                        withExtension: "tsv",
                                        subdirectory: subdirectory) {
                    urls.append(url)
                }
            }
        }
        // 兜住 folder reference 未被索引的极端情况（与词库同款兜底）
        for bundle in searchBundles() {
            guard let resourceURL = bundle.resourceURL else { continue }
            urls.append(resourceURL.appendingPathComponent("dict/chat_priority.tsv"))
            urls.append(resourceURL.appendingPathComponent("Resources/dict/chat_priority.tsv"))
            urls.append(resourceURL.appendingPathComponent("chat_priority.tsv"))
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
