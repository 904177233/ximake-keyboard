//
//  TypoCorrector.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：输入纠错——当原始输入「无候选」或「候选过少」时，猜测用户可能想打的
//            拼音串，产出带 `[纠错]` 标记的候选，追加到候选列表尾部。
//  依赖：Foundation、PinyinSyllables（合法音节判定）、FuzzyPinyin（声韵母规则表，
//        必须复用，不允许在这里写第二套规则）。
//  使用方：PinyinEngine（候选生成收尾阶段，见 `PinyinEngine+TypoCorrection.swift`）。
//
//  规则来源（全部复用 `FuzzyPinyinRule`，共 9 条）：
//  声母 zh/z、ch/c、sh/s、l/n；韵母 in/ing、en/eng、an/ang、ian/iang、uan/uang。
//  额外补「单音节内编辑距离 1」（漏打 / 多打一个字母）——这一层 `FuzzyPinyin` 不覆盖。
//
//  性能：典型单音节输入实测 ≤ 0.1ms（见 `tools/dict/_probe_typo.py` 的实测输出），
//        总工作量上限约 9 次规则变体 + (n + 26(n+1)) 次编辑距离候选（n ≤ 8）。
//

import Foundation

// MARK: - 纠错

/// 输入纠错（纯函数，无状态、无 I/O）。
///
/// 设计原则：
/// 1. **声韵母类规则不自己实现**，一律走 `FuzzyPinyin.variants(of:rules:)`——保证
///    与模糊音功能用的是同一张规则表，改规则只改一处；
/// 2. 在此基础上补**编辑距离 1**（漏打 / 多打一个字母），这是 `FuzzyPinyin` 不做的；
/// 3. 候选必须能切成合法音节，且 `knownInitials` 回调判定为「词库里有词」，
///    否则不产出——宁可少纠，不可把用户正确的输入改坏；
/// 4. 输入长度 ≤ `maximumInputLength`，超长直接放弃（防组合爆炸）。
public enum TypoCorrector {

    /// 最大处理输入长度（字符数）。超过直接放弃纠错。
    public static let maximumInputLength = 8

    /// 编辑距离 1 的候选音节上限（防爆）。
    public static let maximumEditOneVariants = 64

    /// 声韵母变体最多取几条（`FuzzyPinyin` 单音节上限为 4，这里留一点余量）。
    public static let maximumFuzzyVariants = 8

    // MARK: 公开 API

    /// 一条纠错结果。
    public struct Correction: Equatable, Sendable {
        /// 纠错后的拼音串。
        public let corrected: String
        /// 置信度（0...1）。
        public let confidence: Double
        /// 命中的规则描述（如 `zh/z` / `in/ing` / `漏打字母` / `多打字母`）。
        public let rule: String
    }

    /// 对输入串做纠错，返回按置信度降序的候选拼音串。
    ///
    /// - Parameters:
    ///   - input: 用户原始输入（大小写不敏感，只处理纯小写字母串）。
    ///   - knownInitials: 判定「该拼音串在词库里有词条」的回调，用于过滤噪声。
    ///   - limit: 最多返回条数，默认 3。
    /// - Returns: 纠错候选（不含原文），已去重，按置信度降序。
    public static func correct(_ input: String, knownInitials: (String) -> Bool, limit: Int = 3) -> [Correction] {
        guard limit > 0 else { return [] }
        let base = input.lowercased()
        guard !base.isEmpty, base.count <= maximumInputLength else { return [] }
        guard base.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.lowercaseLetters.contains($0) }) else {
            return []
        }

        var best: [String: Correction] = [:]

        // 1) 声韵母规则：单音节输入逐条规则取变体（能给出具体规则名），
        //    多音节输入用整串展开（只取「改一个音节」的那一层）。
        for correction in fuzzyCorrections(of: base) {
            record(correction, into: &best)
        }

        // 2) 编辑距离 1：漏打 / 多打一个字母。
        for correction in editOneCorrections(of: base) {
            record(correction, into: &best)
        }

        // 先过滤再排序再截断——顺序不能反，否则「前 limit 条里有一条不可用」会白白少给一条。
        var results = Array(best.values).filter { isUsable($0.corrected, knownInitials: knownInitials) }
        results.sort { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.corrected.count != rhs.corrected.count { return lhs.corrected.count < rhs.corrected.count }
            return lhs.corrected < rhs.corrected
        }
        return Array(results.prefix(limit))
    }

    // MARK: 内部实现：声韵母规则（复用 FuzzyPinyin）

    /// 用 `FuzzyPinyin` 的规则表产出声韵母类纠错候选。
    ///
    /// 单音节输入：逐条规则单独调用 `variants`，这样每条结果都能标出**命中的是哪一条规则**
    /// （`zh/z`、`in/ing`…），便于 UI 显示与用户反馈。
    /// 多音节输入：用 `expand` 一次拿到「改 1 个音节」的整串变体，统一标 `声韵母`。
    private static func fuzzyCorrections(of base: String) -> [Correction] {
        var out: [Correction] = []

        if PinyinSyllables.isSyllable(base) {
            for rule in FuzzyPinyinRule.allCases {
                let variants = FuzzyPinyin.variants(of: base, rules: [rule], limit: maximumFuzzyVariants)
                for variant in variants where variant != base {
                    out.append(Correction(corrected: variant, confidence: 0.62, rule: rule.displayName))
                }
            }
            return out
        }

        let allRules = Set(FuzzyPinyinRule.allCases)
        let expanded = FuzzyPinyin.expand(base, rules: allRules, limit: maximumFuzzyVariants)
        for variant in expanded where variant != base {
            // 多音节整串的声韵母错拼（`zongguo` → `zhongguo`）比编辑距离 1 更可能，
            // 置信度必须高于 `editOneCorrections` 的 0.62，否则会被「漏打/多打」挤出前 limit 条。
            out.append(Correction(corrected: variant, confidence: 0.66, rule: "声韵母"))
        }
        return out
    }

    // MARK: 内部实现：编辑距离 1

    /// 枚举编辑距离 1 的候选（漏打 / 多打一个字母），附规则名。
    ///
    /// 置信度：漏打比多打更常见（用户少按一下键 vs 误触多按），所以漏打 0.60、多打 0.50。
    private static func editOneCorrections(of base: String) -> [Correction] {
        var out: [Correction] = []
        let chars = Array(base)
        var seen: Set<String> = []
        out.reserveCapacity(maximumEditOneVariants)

        func append(_ candidate: String, _ confidence: Double, _ rule: String) -> Bool {
            guard !candidate.isEmpty, candidate != base, seen.insert(candidate).inserted else { return false }
            out.append(Correction(corrected: candidate, confidence: confidence, rule: rule))
            return out.count >= maximumEditOneVariants
        }

        // 漏打（删除）一个字母：length n → n-1。
        for index in 0..<chars.count {
            var trimmed = chars
            trimmed.remove(at: index)
            if append(String(trimmed), 0.60, "漏打字母") { return out }
        }

        // 末尾补一个字母：length n → n+1。这是最常见的「漏打」形态（`niha` → `nihao`），
        // 置信度给 0.62（高于删除），否则会被删除类候选挤出前 limit 条。
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        for letter in alphabet {
            var padded = chars
            padded.append(letter)
            if append(String(padded), 0.62, "漏打字母") { return out }
        }

        // 其它位置插入一个字母：length n → n+1，按「末尾优先」排列。
        //
        // 若从位置 0 开始枚举，26 个字母会先把 `maximumEditOneVariants` 占满，
        // 末尾位置的候选就永远排不进来。
        var positions: [Int] = []
        positions.append(contentsOf: 0..<chars.count)
        for index in positions {
            for letter in alphabet {
                var padded = chars
                padded.insert(letter, at: index)
                if append(String(padded), 0.50, "多打字母") { return out }
            }
        }
        return out
    }

    // MARK: 内部实现：去重与可用性

    /// 同一条 `corrected` 只保留置信度最高的那条（同分时保留先出现的，即声韵母优先）。
    private static func record(_ correction: Correction, into best: inout [String: Correction]) {
        if let existing = best[correction.corrected] {
            if correction.confidence > existing.confidence {
                best[correction.corrected] = correction
            }
            return
        }
        best[correction.corrected] = correction
    }

    /// 候选是否可用：能切成合法音节 + 词库里确实有词。
    private static func isUsable(_ candidate: String, knownInitials: (String) -> Bool) -> Bool {
        guard PinyinSyllables.isSyllable(candidate) || PinyinSyllables.segment(candidate) != nil else {
            return false
        }
        return knownInitials(candidate)
    }
}
