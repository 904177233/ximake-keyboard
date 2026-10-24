//
//  PinyinEngine+TypoCorrection.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：输入纠错的候选追加逻辑（从 `PinyinEngine.candidates(for:limit:)` 抽出来，
//            避免主文件超 600 行上限）。
//  依赖：Foundation、TypoCorrector、IMECandidate、PinyinDictionary。
//  使用方：PinyinEngine（候选生成收尾阶段调用）。
//

import Foundation

extension PinyinEngine {

    /// 输入纠错兜底：候选过少时把 `TypoCorrector` 的结果追加到尾部（打 `[纠错]` 标记）。
    ///
    /// 只在「原始输入无候选或候选 < 3 条」时触发；纠错候选分数固定 -1（排在最后），
    /// `isTypoCorrection = true` 供 UI 打 `[纠错]` 角标。
    /// 可通过 `PinyinEngine.isTypoCorrectionEnabled` 关闭（默认开启）。
    func appendTypoCorrections(normalized: String, limit: Int, into results: inout [IMECandidate]) {
        guard isTypoCorrectionEnabled else { return }
        guard results.count < min(3, limit), !normalized.isEmpty else { return }
        let corrections = TypoCorrector.correct(normalized, knownInitials: { candidate in
            // 合法音节判定：能整串切成音节，才可能是用户想打的拼音串。
            guard PinyinSyllables.isSyllable(candidate) || PinyinSyllables.segment(candidate) != nil else {
                return false
            }
            // 词库里要有以它开头的词，否则纠出来的拼音串没有对应汉字可上屏。
            return !dictionary.pinyinKeys(prefix: candidate, limit: 1).isEmpty
        }, limit: 3)
        for correction in corrections {
            let text = dictionary.exactEntries(pinyin: correction.corrected, limit: 1).first?.text
                ?? correction.corrected
            if results.contains(where: { $0.text == text && $0.pinyin == correction.corrected }) { continue }
            results.append(IMECandidate(
                text: text,
                pinyin: correction.corrected,
                score: -1.0,
                kind: .word,
                isTypoCorrection: true
            ))
        }
    }
}
