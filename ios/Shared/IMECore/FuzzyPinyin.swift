//
//  FuzzyPinyin.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：模糊音（fuzzy pinyin）——把「南方口音拼音」折叠成等价类，让 zh/z、ch/c、sh/s、
//            in/ing、en/eng、l/n、an/ang、ian/iang、uan/uang 不分的用户也能打出正确候选。
//            本文件只做字符串变换 + 词库命中收集，不改变候选打分公式（降权由引擎侧统一处理）。
//  依赖：Foundation、PinyinSyllables（421 音节表与最少音节切分）、PinyinDictionary（只读查询）
//  使用方：PinyinEngine（候选生成时展开模糊变体）、IMEKit（门面暴露与诊断）、
//          keyboard-ui 的 ExtensionSettingsSheet（设置页开关）
//

import Foundation

// MARK: - 规则

/// 模糊音等价规则（一条规则 = 一对可互换的音节片段）。
///
/// 规则只作用于**音节内部**：`zhong` → `zong` 合法，但不会把跨音节的 `z` 与 `h`
/// 硬拼成 `zh`（那种做法会产生 `xingi` 这类垃圾串）。
public enum FuzzyPinyinRule: String, CaseIterable, Codable, Sendable {
    /// `zh` 与 `z` 不分，如 `zhong` / `zong`。
    case zhZ = "zh-z"
    /// `ch` 与 `c` 不分，如 `chi` / `ci`。
    case chC = "ch-c"
    /// `sh` 与 `s` 不分，如 `shi` / `si`。
    case shS = "sh-s"
    /// `in` 与 `ing` 不分，如 `xin` / `xing`。
    case inIng = "in-ing"
    /// `en` 与 `eng` 不分，如 `fen` / `feng`。
    case enEng = "en-eng"
    /// `l` 与 `n` 不分，如 `li` / `ni`。
    case lN = "l-n"
    /// `an` 与 `ang` 不分，如 `ban` / `bang`。
    case anAng = "an-ang"
    /// `ian` 与 `iang` 不分，如 `xian` / `xiang`。
    case ianIang = "ian-iang"
    /// `uan` 与 `uang` 不分，如 `guan` / `guang`。
    case uanUang = "uan-uang"

    /// 人读的规则名（如 `zh/z`），可直接用于设置页与诊断文案。
    public var displayName: String {
        rawValue.replacingOccurrences(of: "-", with: "/")
    }
}

// MARK: - 选项

/// 模糊音开关与启用的规则集合（可 `Codable`，经 `SharedStore` 持久化）。
///
/// 默认开启前 5 条（`zh/z`、`ch/c`、`sh/s`、`in/ing`、`l/n`），理由：
/// 1. 这 5 条是普通话区（尤其南方口音）最普遍的混淆，覆盖绝大多数据"打不出字"的抱怨；
/// 2. `zh/ch/sh` 与 `z/c/s` 是平翘舌，`in/ing` 是前后鼻音里最高频的一对，`l/n` 是湘赣方言标志；
/// 3. `en/eng`、`an/ang`、`ian/iang`、`uan/uang` 混淆率低得多，且展开变体多、误伤正常输入的概率大，
///    默认关闭、留给用户按需打开；
/// 4. 默认集合只产生很少的变体（一个音节最多 2 个），对按键延迟几乎无影响。
public struct FuzzyPinyinOptions: Codable, Equatable, Sendable {
    /// 是否启用模糊音匹配。
    public var enabled: Bool
    /// 启用的规则集合（`enabled == false` 时整集合不生效）。
    public var rules: Set<FuzzyPinyinRule>

    /// 默认启用的 5 条规则（zh/z、ch/c、sh/s、in/ing、l/n）。
    public static let defaultRules: Set<FuzzyPinyinRule> = [.zhZ, .chC, .shS, .inIng, .lN]
    /// 全部 9 条规则。
    public static let allEnabled: Set<FuzzyPinyinRule> = Set(FuzzyPinyinRule.allCases)

    /// 创建选项。
    /// - Parameters:
    ///   - enabled: 是否启用，默认 `true`。
    ///   - rules: 规则集合，默认 `defaultRules`（5 条）。
    public init(enabled: Bool = true, rules: Set<FuzzyPinyinRule> = FuzzyPinyinOptions.defaultRules) {
        self.enabled = enabled
        self.rules = rules
    }

    /// 默认配置（开启 + 5 条规则）。
    public static let onDefault = FuzzyPinyinOptions()
    /// 关闭配置（保留规则集合，便于用户再打开）。
    public static let off = FuzzyPinyinOptions(enabled: false)
    /// 全开配置（9 条规则）。
    public static let full = FuzzyPinyinOptions(enabled: true, rules: FuzzyPinyinOptions.allEnabled)

    /// 当前是否真的会做模糊展开（开关关掉或规则为空时为 `false`）。
    public var isActive: Bool { enabled && !rules.isEmpty }

    /// 真正生效的规则集合（关闭时为空）。
    public var activeRules: Set<FuzzyPinyinRule> { enabled ? rules : [] }

    /// 生效规则条数。
    public var activeRuleCount: Int { enabled ? rules.count : 0 }

    /// 稳定的持久化字符串（规则按 rawValue 排序，保证同配置字节相同）。
    public var storageValue: String {
        let list = rules.map(\.rawValue).sorted().joined(separator: ",")
        return "v1|enabled=\(enabled ? 1 : 0)|rules=\(list)"
    }

    /// 从持久化字符串还原；无法识别时返回 `nil`（调用方回退默认值）。
    ///
    /// 容错策略：未知规则直接忽略（便于未来版本降级运行），`enabled` 缺失则视为不合法。
    public init?(storageValue raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var flag: Bool?
        var parsedRules: Set<FuzzyPinyinRule> = []
        var hasRulesField = false
        for field in trimmed.split(separator: "|") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1])
            switch key {
            case "enabled":
                flag = (value == "1" || value == "true")
            case "rules":
                hasRulesField = true
                parsedRules = []
                for piece in value.split(separator: ",") {
                    if let rule = FuzzyPinyinRule(rawValue: String(piece)) {
                        parsedRules.insert(rule)
                    }
                }
            default:
                break
            }
        }
        guard let enabled = flag else { return nil }
        self.enabled = enabled
        self.rules = hasRulesField ? parsedRules : FuzzyPinyinOptions.defaultRules
    }
}

// MARK: - 词库命中

/// 一条模糊音命中（已被过滤为纯 CJK 词条）。
public struct FuzzyMatch: Sendable, Equatable {
    /// 命中的词（纯汉字）。
    public let text: String
    /// 被命中的拼音串（模糊变体，不是用户原文）。
    public let pinyin: String
    /// 词频（用于和正常候选一起参与打分）。
    public let frequency: Int
    /// `true` = 变体全拼精确命中；`false` = 变体前缀预测命中。
    public let isExact: Bool
    /// 前缀预测的覆盖率（`变体长度 / 命中键长度`，精确命中为 1.0）。
    public let coverage: Double

    /// 创建一条命中记录。
    public init(text: String, pinyin: String, frequency: Int, isExact: Bool, coverage: Double) {
        self.text = text
        self.pinyin = pinyin
        self.frequency = frequency
        self.isExact = isExact
        self.coverage = coverage
    }
}

// MARK: - 展开

/// 模糊音变体展开（纯函数，无状态、无 I/O）。
///
/// 两段式设计：`variants(of:rules:limit:)` 做单音节等价类，
/// `expand(_:rules:limit:)` 先把整串切成音节再对每个音节取变体并按「改动越少越靠前」组合，
/// 因此不会出现跨音节错拼，也不会因为音节多而组合爆炸。
public enum FuzzyPinyin {

    /// 单音节变体上限（含自身），硬上限，防组合爆炸。
    public static let maximumVariantsPerSyllable = 4
    /// 整串展开时「同时改动的音节个数」上限。
    public static let maximumChangedSyllables = 4
    /// 整串展开的变体数硬上限（调用方传更大的 `limit` 也会被夹住）。
    public static let maximumExpandedVariants = 24
    /// 收集命中时每个变体最多取多少条词。
    public static let maximumMatchesPerVariant = 8
    /// 收集命中时每个变体最多看多少个前缀键。
    public static let maximumPrefixKeysPerVariant = 8

    // MARK: 公开 API

    /// 返回一个音节的等价变体（**含自身且自身在第 0 位**，去重、限流）。
    ///
    /// 例：`variants(of: "zong", rules: [.zhZ])` → `["zong", "zhong"]`。
    /// 只有通过 `PinyinSyllables.isSyllable` 校验的变体才会返回，避免产出非法音节。
    ///
    /// - Parameters:
    ///   - syllable: 单个音节（大小写不敏感）。
    ///   - rules: 生效的规则集合。
    ///   - limit: 最多返回多少个（含自身），默认 8。
    /// - Returns: 变体数组；输入为空时返回空数组。
    public static func variants(of syllable: String, rules: Set<FuzzyPinyinRule>, limit: Int = 8) -> [String] {
        guard limit > 0 else { return [] }
        let base = syllable.lowercased()
        guard !base.isEmpty else { return [] }
        var results: [String] = [base]
        guard !rules.isEmpty else { return results }
        let cap = min(limit, maximumVariantsPerSyllable)
        var seen: Set<String> = [base]
        for candidate in alternatives(for: base, rules: rules) {
            guard results.count < cap else { break }
            if seen.insert(candidate).inserted {
                results.append(candidate)
            }
        }
        return results
    }

    /// 展开整串拼音的模糊变体（**含原文且原文在第 0 位**，按改动数从少到多排序）。
    ///
    /// 例：`expand("zongguo", rules: [.zhZ])` → `["zongguo", "zhongguo"]`。
    /// 末尾还没打完的音节会被保留为尾巴原样拼接（`zongg` → `["zongg", "zhongg"]`），
    /// 因此前缀预测也能吃到模糊音。含数字/非字母的串直接原样返回（不做模糊）。
    ///
    /// - Parameters:
    ///   - input: 输入串（大小写不敏感）。
    ///   - rules: 生效的规则集合。
    ///   - limit: 最多返回多少个变体（含原文），默认 24，内部再夹到 `maximumExpandedVariants`。
    /// - Returns: 变体数组；输入为空时返回空数组。
    public static func expand(_ input: String, rules: Set<FuzzyPinyinRule>, limit: Int = 24) -> [String] {
        guard limit > 0 else { return [] }
        let base = input.lowercased()
        guard !base.isEmpty else { return [] }
        let cap = min(limit, maximumExpandedVariants)
        guard base.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }) else {
            return [base]
        }
        guard !rules.isEmpty else { return [base] }

        let parts = split(base)
        guard !parts.syllables.isEmpty else { return [base] }

        var options: [[String]] = []
        options.reserveCapacity(parts.syllables.count)
        for syllable in parts.syllables {
            options.append(variants(of: syllable, rules: rules, limit: maximumVariantsPerSyllable))
        }

        var results: [String] = []
        var seen: Set<String> = []
        let maxBudget = min(options.count, maximumChangedSyllables)
        var budget = 0
        while budget <= maxBudget {
            enumerate(options, index: 0, remaining: budget, tail: parts.tail, buffer: "",
                      into: &results, seen: &seen, limit: cap)
            if results.count >= cap { break }
            budget += 1
        }
        return results
    }

    /// 收集模糊音在词库里的命中（精确命中 + 前缀预测，均只保留纯汉字词条）。
    ///
    /// - Parameters:
    ///   - normalized: 已归一化的输入串（只含小写字母与数字）。
    ///   - rules: 生效的规则集合。
    ///   - dictionary: 词库（只读查询）。
    /// - Returns: 命中列表，**不含**原文自身的正常候选（原文由引擎正常流程处理）。
    public static func matches(for normalized: String,
                               rules: Set<FuzzyPinyinRule>,
                               dictionary: PinyinDictionary) -> [FuzzyMatch] {
        let variants = expand(normalized, rules: rules, limit: maximumExpandedVariants)
        guard variants.count > 1 else { return [] }
        var results: [FuzzyMatch] = []
        var seen: Set<String> = []
        for variant in variants.dropFirst() {
            for entry in dictionary.exactEntries(pinyin: variant, limit: maximumMatchesPerVariant) {
                guard isCJKWord(entry.text), seen.insert(entry.text).inserted else { continue }
                results.append(FuzzyMatch(text: entry.text, pinyin: variant,
                                          frequency: entry.frequency, isExact: true, coverage: 1.0))
            }
            let keys = dictionary.pinyinKeys(prefix: variant, limit: maximumPrefixKeysPerVariant)
            for key in keys where key != variant {
                let coverage = Double(variant.count) / Double(max(key.count, 1))
                for entry in dictionary.exactEntries(pinyin: key, limit: 2) {
                    guard isCJKWord(entry.text), seen.insert(entry.text).inserted else { continue }
                    results.append(FuzzyMatch(text: entry.text, pinyin: key,
                                              frequency: entry.frequency, isExact: false, coverage: coverage))
                }
            }
        }
        return results
    }

    // MARK: 内部实现：单音节变体

    /// 枚举单音节的全部候选（未校验、未去重）。
    private static func alternatives(for base: String, rules: Set<FuzzyPinyinRule>) -> [String] {
        var raw: [String] = []
        raw.reserveCapacity(FuzzyPinyinRule.allCases.count)
        for rule in FuzzyPinyinRule.allCases where rules.contains(rule) {
            switch rule {
            case .zhZ:
                appendDigraph("zh", "z", of: base, into: &raw)
            case .chC:
                appendDigraph("ch", "c", of: base, into: &raw)
            case .shS:
                appendDigraph("sh", "s", of: base, into: &raw)
            case .lN:
                appendInitialLNorN(of: base, into: &raw)
            case .inIng:
                appendFinal("ing", "in", of: base, excluding: [], into: &raw)
            case .enEng:
                appendFinal("eng", "en", of: base, excluding: [], into: &raw)
            case .anAng:
                appendFinal("ang", "an", of: base, excluding: ["iang", "uang"], into: &raw)
            case .ianIang:
                appendFinal("iang", "ian", of: base, excluding: [], into: &raw)
            case .uanUang:
                appendFinal("uang", "uan", of: base, excluding: [], into: &raw)
            }
        }
        var results: [String] = []
        var seen: Set<String> = [base]
        for candidate in raw {
            guard candidate != base, PinyinSyllables.isSyllable(candidate), seen.insert(candidate).inserted else { continue }
            results.append(candidate)
        }
        return results
    }

    /// 声母二元组（`zh`/`ch`/`sh`）与单字母（`z`/`c`/`s`）互换。
    ///
    /// 安全性：拼音里字母 `z`/`c`/`s` 只能作声母或作 `zh`/`ch`/`sh` 的首字母，
    /// 所以这两个方向都不会跨音节误拼。
    private static func appendDigraph(_ digraph: String, _ single: String, of base: String, into raw: inout [String]) {
        if base.hasPrefix(digraph) {
            raw.append(single + String(base.dropFirst(digraph.count)))
        } else if base.hasPrefix(single) {
            raw.append(digraph + String(base.dropFirst(single.count)))
        }
    }

    /// 声母 `l` 与 `n` 互换（单字母音节 `n`（嗯）不参与，避免 `n` ↔ `l` 这种无意义展开）。
    private static func appendInitialLNorN(of base: String, into raw: inout [String]) {
        guard base.count >= 2 else { return }
        if base.hasPrefix("l") {
            raw.append("n" + String(base.dropFirst()))
        } else if base.hasPrefix("n") {
            raw.append("l" + String(base.dropFirst()))
        }
    }

    /// 韵母长短互换（`ing` ↔ `in`、`ang` ↔ `an` 等）。
    ///
    /// - Parameter excluding: 若音节以这些更长的韵母结尾则跳过（如 `an/ang` 规则要让位给 `ian/iang`）。
    private static func appendFinal(_ long: String,
                                    _ short: String,
                                    of base: String,
                                    excluding: [String],
                                    into raw: inout [String]) {
        if excluding.contains(where: { base.hasSuffix($0) }) { return }
        if base.hasSuffix(long) {
            raw.append(String(base.dropLast(long.count - short.count)))
        } else if base.hasSuffix(short) {
            raw.append(base + String(long.dropFirst(short.count)))
        }
    }

    // MARK: 内部实现：切分与组合

    /// 把整串切成音节；末尾不完整的部分作为 `tail` 原样保留。
    ///
    /// 例：`zongguo` → `(["zong", "guo"], "")`；`zongg` → `(["zong"], "g")`。
    private static func split(_ normalized: String) -> (syllables: [String], tail: String) {
        if let full = PinyinSyllables.segment(normalized) {
            return (full, "")
        }
        var cut = normalized.count - 1
        while cut >= 1 {
            if let syllables = PinyinSyllables.segment(String(normalized.prefix(cut))) {
                return (syllables, String(normalized.dropFirst(cut)))
            }
            cut -= 1
        }
        return ([], normalized)
    }

    /// 按「改动音节个数」预算递归枚举组合（预算为 0 时只产出原文）。
    private static func enumerate(_ options: [[String]],
                                  index: Int,
                                  remaining: Int,
                                  tail: String,
                                  buffer: String,
                                  into results: inout [String],
                                  seen: inout Set<String>,
                                  limit: Int) {
        if results.count >= limit { return }
        if index >= options.count {
            let text = buffer + tail
            if seen.insert(text).inserted {
                results.append(text)
            }
            return
        }
        let choices = options[index]
        guard let original = choices.first else { return }
        enumerate(options, index: index + 1, remaining: remaining, tail: tail,
                  buffer: buffer + original, into: &results, seen: &seen, limit: limit)
        guard remaining > 0 else { return }
        for alternative in choices.dropFirst() {
            enumerate(options, index: index + 1, remaining: remaining - 1, tail: tail,
                      buffer: buffer + alternative, into: &results, seen: &seen, limit: limit)
            if results.count >= limit { return }
        }
    }

    /// 是否纯汉字词（排除 emoji / 标点 / ASCII 词条，避免模糊音把表情符号塞进候选栏）。
    private static func isCJKWord(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

// MARK: - 运行期设置

/// 模糊音运行期设置（进程内单例，读写即持久化）。
///
/// 为什么用单例而不是参数透传：`PinyinEngine` 由 `IMEKit` 在扩展启动时创建，
/// 而键盘内的「模糊音」开关在 `ExtensionSettingsSheet`（经 `KeyboardViewModel`）里，
/// 两者之间没有引用链（`KMInputEngine` 只转发既有 API，且不属于本模块写作用域）。
/// 把「当前生效设置」放在进程内单例：引擎每次取候选时读、UI 切换时写，
/// 写入同时落到 `SharedStore`（Key `moyu.ime.fuzzy.v1`），下次启动直接恢复。
public final class FuzzyPinyinSettings: @unchecked Sendable {

    /// 全局单例。
    public static let shared = FuzzyPinyinSettings()

    /// `SharedStore` 里的持久化 Key。
    public static let storageKey = "moyu.ime.fuzzy.v1"

    private let lock = NSLock()
    private var storage: SharedStore?
    private var loaded = false
    private var current: FuzzyPinyinOptions = FuzzyPinyinOptions.onDefault

    private init() {}

    /// 绑定共享存储并读取一次（幂等：只有第一次真正读盘）。
    ///
    /// - Parameter store: App 与键盘扩展共用的 `SharedStore`。
    public func configure(store: SharedStore) {
        lock.lock()
        if storage == nil { storage = store }
        let alreadyLoaded = loaded
        lock.unlock()
        guard !alreadyLoaded else { return }
        load()
    }

    /// 重新从 `SharedStore` 读取设置（未绑定存储时退回 `SharedStore.shared`）。
    public func load() {
        lock.lock()
        let bound = storage
        lock.unlock()
        let target = bound ?? SharedStore.shared
        let raw = target.string(forKey: FuzzyPinyinSettings.storageKey)
        let decoded = raw.flatMap { FuzzyPinyinOptions(storageValue: $0) } ?? FuzzyPinyinOptions.onDefault
        lock.lock()
        current = decoded
        loaded = true
        if storage == nil { storage = target }
        lock.unlock()
    }

    /// 当前设置（读取带锁；写入会立即持久化）。
    public var options: FuzzyPinyinOptions {
        get {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        set {
            lock.lock()
            current = newValue
            let target = storage ?? SharedStore.shared
            storage = target
            loaded = true
            lock.unlock()
            target.set(newValue.storageValue, forKey: FuzzyPinyinSettings.storageKey)
        }
    }

    /// 只切开关，保留规则集合。
    /// - Parameter enabled: 是否启用模糊音。
    /// - Returns: 更新后的完整设置。
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> FuzzyPinyinOptions {
        var updated = options
        updated.enabled = enabled
        options = updated
        return updated
    }

    /// 只换规则集合，保留开关状态。
    /// - Parameter rules: 新的规则集合。
    /// - Returns: 更新后的完整设置。
    @discardableResult
    public func setRules(_ rules: Set<FuzzyPinyinRule>) -> FuzzyPinyinOptions {
        var updated = options
        updated.rules = rules
        options = updated
        return updated
    }

    /// 恢复默认（开启 + 前 5 条）。
    /// - Returns: 默认设置。
    @discardableResult
    public func reset() -> FuzzyPinyinOptions {
        options = FuzzyPinyinOptions.onDefault
        return FuzzyPinyinOptions.onDefault
    }
}
