//
//  PinyinDictionary.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：加载捆绑的中文基础词库 `base_dict.tsv`，建立"全拼 -> 词条"哈希索引与
//            "首字母串 -> 全拼"简拼索引，为 PinyinEngine 提供 O(1)/O(log n) 查询能力。
//  依赖：Foundation、PinyinSyllables（同模块）
//  使用方：PinyinEngine、IMEKit、host-app-ui（诊断页读取 version/wordCount）
//

import Foundation

/// 拼音词库（只读索引，加载完成后线程安全）。
///
/// 词库文件为 `ios/Shared/dict/base_dict.tsv`，每行：
/// `拼音<TAB>词<TAB>词频<TAB>flags`；以 `#` 开头的行为注释。
///
/// 加载策略：按候选路径列表逐个尝试（兼容 Bundle 根目录、`dict/` 子目录、
/// 历史上的 `Resources/dict/` 三种打包方式），全部失败时退回内置极小词表，
/// 保证键盘在词库缺失时仍可输入，不会崩溃。
public final class PinyinDictionary {

    // MARK: - 单例

    /// 获取随包词库单例。
    ///
    /// 使用 `static let` 实现，Swift 运行时保证首次访问的线程安全与惰性；
    /// 首次加载约 10-20ms（5000+ 条），远低于 80ms 预算。
    /// - Returns: 共享的词库实例。
    public static func bundled() -> PinyinDictionary {
        shared
    }

    /// 进程内共享实例（惰性初始化，线程安全）。
    private static let shared = PinyinDictionary()

    // MARK: - 对外元信息

    /// 词库版本号（来自 `dict_meta.json`，缺失时为 `"0.0.0"`）。
    public var version: String

    /// 词条总数。
    public var wordCount: Int

    /// 上次加载耗时（毫秒），供诊断页展示；加载失败时为 `0`。
    public var loadDurationMilliseconds: Double

    /// 实际命中的词库文件路径；使用内置兜底词表时为 `"<builtin>"`。
    public var loadedPath: String

    // MARK: - 索引

    /// 全部词条，按词频降序、同频按文本升序（稳定）。
    private let allEntries: [DictionaryEntry]

    /// 全拼 -> 词条（每个数组内已按词频降序）。
    private let entriesByPinyin: [String: [DictionaryEntry]]

    /// 全拼键的有序列表（用于前缀查询的二分定位）。
    private let sortedPinyinKeys: [String]

    /// 首字母串 -> 全拼键（按该全拼最高词频降序）。
    ///
    /// **惰性构建**：建索引要为每条词做一次音节 DP 切分，词库扩到 33,160 条后
    /// 这是冷启动最大的单项（Python 复刻 311 万次内层循环，Swift 侧估 47–187ms）。
    /// 简拼只在用户打纯字母串时才用得上，绝大多数人第一次上屏用不到，
    /// 故推迟到首次查询再建，把冷启动确定性开销压回解析 + 分组（约 30–40ms）。
    private var initialsIndexStorage: [String: [String]]?

    /// 首字母串的最短/最长长度（与 `initialsIndexStorage` 同时产出）。
    private var initialsLengthRangeStorage: ClosedRange<Int>?

    /// 索引构建锁（保护上面两个惰性字段）。
    private let initialsLock = NSLock()

    /// 首字母索引（惰性构建，首次访问时同步建好）。
    private var initialsIndex: [String: [String]] {
        ensureInitialsIndex()
        return initialsIndexStorage ?? [:]
    }

    /// 首字母串的最短/最长长度（惰性构建）。
    private var initialsLengthRange: ClosedRange<Int> {
        ensureInitialsIndex()
        return initialsLengthRangeStorage ?? 1...1
    }

    /// 词文本 -> 最高词频（供排序打分快速取词频）。
    private let textFrequency: [String: Int]

    /// 聊天高频词权重表（`chat_priority.tsv`，缺失时为空表）。
    ///
    /// 词库词频来自新闻/百科语料，简拼（`wq`）按它排序会先给「完全/武器」；
    /// 这张可选表是「聊天场景先验」，引擎只在简拼路径上用它纠偏。
    private let chatPriorityTable: ChatPriorityTable

    // MARK: - 首字母索引惰性构建

    /// 确保首字母索引已建好（幂等、线程安全，双检锁）。
    private func ensureInitialsIndex() {
        if initialsIndexStorage != nil { return }
        initialsLock.lock()
        defer { initialsLock.unlock() }
        if initialsIndexStorage != nil { return }
        let built = Self.buildInitialsIndex(allEntries)
        initialsIndexStorage = built.index
        initialsLengthRangeStorage = built.range
    }

    // MARK: - 初始化

    /// 使用随包词库创建实例（测试与调试可注入自定义文件）。
    ///
    /// - Parameter dictionaryURL: 指定词库文件；传 `nil` 时按候选路径列表自动查找。
    public init(dictionaryURL: URL? = nil) {
        let startTime = Date().timeIntervalSinceReferenceDate

        var resolvedURL = dictionaryURL
        var resolvedEntries: [DictionaryEntry] = []
        if let url = resolvedURL, let parsed = Self.parseFile(at: url) {
            resolvedEntries = parsed
        } else {
            // 自动查找候选路径
            for candidate in Self.candidateURLs() {
                if let parsed = Self.parseFile(at: candidate) {
                    resolvedURL = candidate
                    resolvedEntries = parsed
                    break
                }
            }
        }

        // 兜底：词库缺失时用内置极小词表，保证键盘可用
        var usedBuiltin = false
        if resolvedEntries.isEmpty {
            resolvedEntries = Self.builtinSeedEntries()
            usedBuiltin = true
        }

        let sorted = Self.sortedEntries(resolvedEntries)
        let grouped = Self.groupByPinyin(sorted)
        self.allEntries = sorted
        self.entriesByPinyin = grouped
        self.textFrequency = Self.buildTextFrequency(sorted)
        self.chatPriorityTable = ChatPriorityTable.load()
        self.sortedPinyinKeys = grouped.keys.sorted()
        self.initialsIndexStorage = nil
        self.initialsLengthRangeStorage = nil
        self.wordCount = sorted.count
        self.version = Self.readVersion(fallback: usedBuiltin ? "0.0.0-builtin" : "0.0.0")
        self.loadedPath = usedBuiltin ? "<builtin>" : (resolvedURL?.path ?? "<unknown>")
        self.loadDurationMilliseconds = (Date().timeIntervalSinceReferenceDate - startTime) * 1000
    }

    /// 使用内存中的词条数组创建实例（单元测试用）。
    ///
    /// - Parameters:
    ///   - entries: 词条数组。
    ///   - version: 版本号。
    public init(entries: [DictionaryEntry], version: String = "test") {
        let sorted = Self.sortedEntries(entries)
        let grouped = Self.groupByPinyin(sorted)
        self.allEntries = sorted
        self.entriesByPinyin = grouped
        self.textFrequency = Self.buildTextFrequency(sorted)
        self.chatPriorityTable = ChatPriorityTable.load()
        self.sortedPinyinKeys = grouped.keys.sorted()
        self.initialsIndexStorage = nil
        self.initialsLengthRangeStorage = nil
        self.wordCount = sorted.count
        self.version = version
        self.loadedPath = "<memory>"
        self.loadDurationMilliseconds = 0
    }

    // MARK: - 查询 API

    /// 按全拼查询词条。
    ///
    /// 语义：先做精确匹配；若该全拼不存在，则退化为前缀匹配（把 `zhongg` 当作
    /// `zhong*` 查），因此调用方既可以查完整拼音，也可以查未打完的前缀。
    ///
    /// - Parameters:
    ///   - pinyin: 无声调全拼，大小写不敏感。
    ///   - limit: 最多返回条数；`<= 0` 时返回空数组。
    /// - Returns: 按词频降序的词条数组。
    public func lookup(pinyin: String, limit: Int) -> [DictionaryEntry] {
        guard limit > 0 else { return [] }
        let key = Self.normalize(pinyin)
        guard !key.isEmpty else { return [] }

        if let exact = entriesByPinyin[key] {
            return Array(exact.prefix(limit))
        }

        // 前缀退化：合并所有以 key 开头的全拼结果，按词频重排
        var collected: [DictionaryEntry] = []
        for prefixKey in pinyinKeys(prefix: key, limit: 32) {
            if let list = entriesByPinyin[prefixKey] {
                collected.append(contentsOf: list)
            }
            if collected.count >= limit * 4 { break }
        }
        if collected.isEmpty { return [] }
        return Array(Self.sortedEntries(collected).prefix(limit))
    }

    /// 判断是否存在以该串为前缀的拼音键（用于"还有候选"提示与提前剪枝）。
    ///
    /// - Parameter pinyin: 全拼前缀。
    /// - Returns: 存在任意键以它开头则为 `true`。
    public func hasPrefix(_ pinyin: String) -> Bool {
        let key = Self.normalize(pinyin)
        guard !key.isEmpty else { return false }
        if entriesByPinyin[key] != nil { return true }
        return !pinyinKeys(prefix: key, limit: 1).isEmpty
    }

    /// 返回以 `prefix` 开头的全部全拼键（按最高词频降序）。
    ///
    /// 实现：在有序键数组上二分定位首个 `>= prefix` 的位置，再顺序扫描。
    /// 注意扫描上限放宽到 `limit * 8`：若只扫 `limit` 个键再排序，高频键可能因字典序靠后
    /// 而被提前截断丢弃（例如 `zhong*` 下 `zhongguo` 未必字典序最靠前）。
    ///
    /// - Parameters:
    ///   - prefix: 全拼前缀。
    ///   - limit: 最多返回键数。
    /// - Returns: 全拼键数组。
    public func pinyinKeys(prefix: String, limit: Int) -> [String] {
        let key = Self.normalize(prefix)
        guard !key.isEmpty, limit > 0 else { return [] }

        var low = 0
        var high = sortedPinyinKeys.count
        while low < high {
            let mid = (low + high) / 2
            if sortedPinyinKeys[mid] < key {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let scanLimit = limit * 8
        var result: [String] = []
        var index = low
        while index < sortedPinyinKeys.count, result.count < scanLimit {
            let candidate = sortedPinyinKeys[index]
            guard candidate.hasPrefix(key) else { break }
            result.append(candidate)
            index += 1
        }
        result.sort { lhs, rhs in
            let left = entriesByPinyin[lhs]?.first?.frequency ?? 0
            let right = entriesByPinyin[rhs]?.first?.frequency ?? 0
            if left != right { return left > right }
            return lhs < rhs
        }
        return Array(result.prefix(limit))
    }

    /// 按首字母串查询候选全拼键（简拼输入，如 `zg` -> `zhongguo`/`zhège`…）。
    ///
    /// - Parameters:
    ///   - initials: 首字母串（小写字母或数字）。
    ///   - limit: 最多返回键数。
    /// - Returns: 全拼键数组，按最高词频降序。
    public func pinyinKeys(initials: String, limit: Int) -> [String] {
        let key = Self.normalize(initials)
        guard !key.isEmpty, limit > 0 else { return [] }
        guard let list = initialsIndex[key] else { return [] }
        return Array(list.prefix(limit))
    }

    /// 判断某首字母串是否在索引中（用于判断简拼是否有解）。
    /// - Parameter initials: 首字母串。
    /// - Returns: 命中为 `true`。
    public func hasInitials(_ initials: String) -> Bool {
        let key = Self.normalize(initials)
        guard !key.isEmpty else { return false }
        return initialsIndex[key] != nil
    }

    /// 首字母索引覆盖的最短长度（用于剪枝，通常为 1）。
    public var minimumInitialsLength: Int { initialsLengthRange.lowerBound }

    /// 首字母索引覆盖的最长长度（用于剪枝，最长词 9 字 -> 9）。
    public var maximumInitialsLength: Int { initialsLengthRange.upperBound }

    /// 取某全拼下的全部词条（不做前缀退化），供引擎精确判定。
    /// - Parameters:
    ///   - pinyin: 全拼。
    ///   - limit: 最多条数。
    /// - Returns: 词条数组。
    public func exactEntries(pinyin: String, limit: Int) -> [DictionaryEntry] {
        guard limit > 0 else { return [] }
        let key = Self.normalize(pinyin)
        guard let list = entriesByPinyin[key] else { return [] }
        return Array(list.prefix(limit))
    }

    /// 全部词条（只读快照，按词频降序）。
    public var entries: [DictionaryEntry] { allEntries }

    /// 某个词条在词库中的最高词频；不存在时为 0。
    /// - Parameter text: 词文本。
    /// - Returns: 词频。
    public func frequency(of text: String) -> Int {
        textFrequency[text] ?? 0
    }

    /// 某个词的「聊天高频」权重（`chat_priority.tsv`，1.0–3.0）。
    ///
    /// 语义与 `frequency(of:)` 互补：词频回答「这个词语料里多常见」，聊天权重回答
    /// 「聊天里会不会先打它」。只有**仅首字母命中**的简拼路径会用它（见
    /// `PinyinEngine+Initials.swift`），全拼/精确命中一律不参与，避免先验表改写用户
    /// 已经明确打出来的音节对应的排序。
    ///
    /// - Parameter word: 候选词文本。
    /// - Returns: 表内权重；不在表里或表文件缺失时返回 0（表示不加成）。
    public func chatPriority(for word: String) -> Double {
        chatPriorityTable.weight(for: word)
    }

    /// 聊天权重表条目数（诊断/单元测试用）。
    public var chatPriorityCount: Int { chatPriorityTable.count }

    // MARK: - 加载：候选路径

    /// 词库文件在 Bundle 中的候选路径列表。
    ///
    /// 覆盖三种打包方式：①`dict/` folder reference -> `dict/base_dict.tsv`（**当前布局**）
    /// ②旧布局 `Resources/dict/`（仅兼容保留）③TSV 直接进 Copy Bundle Resources -> 根目录。
    ///
    /// - Returns: 候选 URL 数组（按优先级）。
    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let subdirectories: [String?] = ["dict", "Resources/dict", nil]

        for bundle in searchBundles() {
            for subdirectory in subdirectories {
                if let url = bundle.url(forResource: "base_dict",
                                        withExtension: "tsv",
                                        subdirectory: subdirectory) {
                    urls.append(url)
                }
            }
        }
        // 直接拼 resourceURL，兜住 folder reference 未被索引的极端情况
        for bundle in searchBundles() {
            guard let resourceURL = bundle.resourceURL else { continue }
            urls.append(resourceURL.appendingPathComponent("dict/base_dict.tsv"))
            urls.append(resourceURL.appendingPathComponent("Resources/dict/base_dict.tsv"))
            urls.append(resourceURL.appendingPathComponent("base_dict.tsv"))
        }

        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// 参与查找的 Bundle 列表：主 Bundle 优先，其次本类所在 Bundle（framework 场景）。
    private static func searchBundles() -> [Bundle] {
        var bundles: [Bundle] = [Bundle.main]
        let classBundle = Bundle(for: PinyinDictionary.self)
        if classBundle.bundleURL.path != Bundle.main.bundleURL.path {
            bundles.append(classBundle)
        }
        return bundles
    }

    /// 读取 `dict_meta.json` 中的版本号。
    /// - Parameter fallback: 读取失败时的返回值。
    /// - Returns: 版本号字符串。
    private static func readVersion(fallback: String) -> String {
        for bundle in searchBundles() {
            for subdirectory in ["dict", "Resources/dict", nil] as [String?] {
                guard let url = bundle.url(forResource: "dict_meta",
                                           withExtension: "json",
                                           subdirectory: subdirectory),
                      let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dict = object as? [String: Any],
                      let version = dict["version"] as? String else { continue }
                return version
            }
        }
        return fallback
    }

    // MARK: - 解析与索引构建

    /// 解析 TSV 词库文件。
    /// - Parameter url: 文件 URL。
    /// - Returns: 词条数组；文件不存在或没有有效行时返回 `nil`。
    private static func parseFile(at url: URL) -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let entries = parse(text: text)
        return entries.isEmpty ? nil : entries
    }

    /// 解析 TSV 文本（自动去掉 BOM、跳过注释与空行、容忍列数不足）。
    /// - Parameter text: 文件内容。
    /// - Returns: 词条数组。
    static func parse(text: String) -> [DictionaryEntry] {
        var result: [DictionaryEntry] = []
        result.reserveCapacity(6000)
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            if line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            let pinyin = Self.normalize(String(fields[0]))
            let word = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let frequency = Int(fields[2]) ?? 0
            guard !pinyin.isEmpty, !word.isEmpty else { continue }
            let flags = fields.count >= 4 ? String(fields[3]).trimmingCharacters(in: .whitespaces) : ""
            result.append(DictionaryEntry(pinyin: pinyin,
                                          text: word,
                                          frequency: frequency,
                                          flags: flags))
        }
        return result
    }

    /// 排序：词频降序，同频按文本字典序（保证重跑结果稳定）。
    private static func sortedEntries(_ entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency }
            if lhs.text != rhs.text { return lhs.text < rhs.text }
            return lhs.pinyin < rhs.pinyin
        }
    }

    /// 按全拼分组，组内保持词频降序。
    private static func groupByPinyin(_ entries: [DictionaryEntry]) -> [String: [DictionaryEntry]] {
        var result: [String: [DictionaryEntry]] = [:]
        result.reserveCapacity(5000)
        for entry in entries {
            result[entry.pinyin, default: []].append(entry)
        }
        return result
    }

    /// 建立"词文本 -> 最高词频"映射。
    /// - Parameter entries: 已排序词条（词频降序，故首次出现即最高）。
    /// - Returns: 映射表。
    private static func buildTextFrequency(_ entries: [DictionaryEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries where result[entry.text] == nil {
            result[entry.text] = entry.frequency
        }
        return result
    }

    /// 构建简拼（首字母）索引。
    ///
    /// 音节切分规则：优先"恰好等于词字数"的切分（词库全拼逐字生成，字数 == 音节数），
    /// 失败则退回最少音节切分；纯 ASCII 词（如 `yyds`）直接以自身作为首字母串。
    ///
    /// - Parameter entries: 已排序词条。
    /// - Returns: 索引字典与首字母长度范围。
    private static func buildInitialsIndex(_ entries: [DictionaryEntry])
        -> (index: [String: [String]], range: ClosedRange<Int>) {
        // 先用一次线性扫描建"全拼 -> 最高词频"表，避免在排序比较器里反复线性查找
        var bestFrequency: [String: Int] = [:]
        bestFrequency.reserveCapacity(entries.count)
        for entry in entries where (bestFrequency[entry.pinyin] ?? 0) < entry.frequency {
            bestFrequency[entry.pinyin] = entry.frequency
        }

        var index: [String: [String]] = [:]
        var seenKeys: Set<String> = []
        var minLength = Int.max
        var maxLength = 0

        for entry in entries {
            guard let initials = initialsString(for: entry) else { continue }
            minLength = min(minLength, initials.count)
            maxLength = max(maxLength, initials.count)
            let dedupKey = initials + "\u{1F}" + entry.pinyin
            guard seenKeys.insert(dedupKey).inserted else { continue }
            index[initials, default: []].append(entry.pinyin)
        }

        // 每个首字母串内部按最高词频降序
        var sortedIndex: [String: [String]] = [:]
        sortedIndex.reserveCapacity(index.count)
        for (key, keys) in index {
            sortedIndex[key] = keys.sorted { lhs, rhs in
                let left = bestFrequency[lhs] ?? 0
                let right = bestFrequency[rhs] ?? 0
                if left != right { return left > right }
                return lhs < rhs
            }
        }

        let range = maxLength >= minLength && minLength != Int.max ? minLength...maxLength : 1...1
        return (sortedIndex, range)
    }

    /// 计算某词条的首字母串。
    /// - Parameter entry: 词条。
    /// - Returns: 首字母串；无法计算时为 `nil`。
    private static func initialsString(for entry: DictionaryEntry) -> String? {
        let pinyin = entry.pinyin
        let charCount = entry.text.count
        var syllables: [String] = []

        if charCount > 0, let exact = PinyinSyllables.segment(pinyin, exactly: charCount) {
            syllables = exact
        } else if let minimal = PinyinSyllables.segment(pinyin) {
            syllables = minimal
        } else {
            // 纯 ASCII 词（yyds/emoji 别名等）：直接用原串做首字母索引
            if pinyin.allSatisfy({ $0.isASCII && $0.isLetter }) {
                return pinyin
            }
            return nil
        }

        var initials = ""
        initials.reserveCapacity(syllables.count)
        for syllable in syllables {
            guard let first = syllable.first else { continue }
            initials.append(first)
        }
        return initials.isEmpty ? nil : initials
    }

    // MARK: - 工具

    /// 归一化拼音串：小写、去空白、去声调记号（保留字母/数字）。
    /// - Parameter pinyin: 原始输入。
    /// - Returns: 归一化结果。
    static func normalize(_ pinyin: String) -> String {
        var result = ""
        result.reserveCapacity(pinyin.count)
        for character in pinyin.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
            }
        }
        return result
    }
}
