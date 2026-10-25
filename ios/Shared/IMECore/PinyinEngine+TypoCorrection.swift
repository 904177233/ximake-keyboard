//
//  PinyinEngine+TypoCorrection.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：输入纠错的候选插入逻辑（从 `PinyinEngine.candidates(for:limit:)` 抽出来，
//            避免主文件超 600 行上限）。
//  依赖：Foundation、TypoCorrector、IMECandidate、PinyinDictionary、PinyinSyllables。
//  使用方：PinyinEngine（候选生成收尾阶段调用）。
//

import Foundation

extension PinyinEngine {

    /// 输入纠错：用户很可能打错拼音时，把 `TypoCorrector` 的结果插进候选（打 `纠错` 标记）。
    ///
    /// ## v1.7 修的两个叠加 bug（用户反馈「纠错基本上用不了」）
    /// 1. **触发条件错**。v1.6 只在 `results.count < 3` 时触发，但用户把 `zhongguo` 打成
    ///    `zongguo` 时，前缀路径会给出「总/宗/纵…」一大堆候选，`results.count` 早就 ≥ 3，
    ///    于是纠错**永远不触发**。现在改成看「整串在词库里有没有精确词条」。
    /// 2. **不显示**。候选栏从未渲染 `isTypoCorrection`（只有设置页文案提过），
    ///    用户看到一条陌生词排在最前面却不知道它是纠错结果。现在 `CandidateBar` 会打 `纠错` 角标。
    ///
    /// ## 插入策略（三种情况）
    /// | 情况 | 判定 | 插入位置 |
    /// |---|---|---|
    /// | 用户打错了一个字母 | 有词以前缀匹配、但整串没有精确词条 | **最前面**，置顶 1 条「你是不是想打 X」 |
    /// | 用户正在打前缀 | 整串本身就是某些词的前缀（`zhongg`） | 追加到**尾部**，不打扰正常候选 |
    /// | 输入正确 | 整串有精确词条 | 追加到**尾部** |
    ///
    /// - Parameters:
    ///   - normalized: 归一化后的输入串（小写纯字母）。
    ///   - limit: 候选上限（决定最终截断长度）。
    ///   - results: 已排好序的候选（原地修改）。
    func appendTypoCorrections(normalized: String, limit: Int, into results: inout [IMECandidate]) {
        guard isTypoCorrectionEnabled else { return }
        guard limit > 0, !normalized.isEmpty else { return }
        // 已经在候选里的、以及整串本身，都不该被纠错「纠正」成别的东西。
        guard PinyinSyllables.isSyllable(normalized) || PinyinSyllables.segment(normalized) != nil else { return }

        let hasExactMatch = !dictionary.exactEntries(pinyin: normalized, limit: 1).isEmpty
        let isKnownPrefix = !dictionary.pinyinKeys(prefix: normalized, limit: 1).isEmpty

        // 触发闸门：输入正确且候选够多 → 不打扰；正在打合法前缀且已有一屏候选 → 不打扰。
        if hasExactMatch, results.count >= 3 { return }
        if isKnownPrefix, !hasExactMatch, results.count >= 8 { return }

        let corrections = TypoCorrector.correct(normalized, knownInitials: { candidate in
            guard PinyinSyllables.isSyllable(candidate) || PinyinSyllables.segment(candidate) != nil else {
                return false
            }
            return !dictionary.pinyinKeys(prefix: candidate, limit: 1).isEmpty
        }, limit: 3)
        guard !corrections.isEmpty else { return }

        var newCandidates: [IMECandidate] = []
        for correction in corrections {
            let text = dictionary.exactEntries(pinyin: correction.corrected, limit: 1).first?.text
                ?? correction.corrected
            if results.contains(where: { $0.text == text && $0.pinyin == correction.corrected }) { continue }
            if newCandidates.contains(where: { $0.text == text && $0.pinyin == correction.corrected }) { continue }
            newCandidates.append(IMECandidate(
                text: text,
                pinyin: correction.corrected,
                score: -1.0,
                kind: .word,
                isTypoCorrection: true
            ))
        }
        guard !newCandidates.isEmpty else { return }

        // 「打错了」才置顶，而且只置顶 1 条——置顶太多会把用户真正想要的候选挤下去。
        if !hasExactMatch, !isKnownPrefix, let best = newCandidates.first {
            results.insert(best, at: 0)
            newCandidates.removeFirst()
        }
        results.append(contentsOf: newCandidates)
        if results.count > limit {
            results = Array(results.prefix(limit))
        }
    }
}
