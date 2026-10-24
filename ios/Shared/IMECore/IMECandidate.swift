//
//  IMECandidate.swift
//  墨语 · 输入法内核（IMECore）
//
//  模块职责：定义输入法内核对外暴露的数据结构（契约 §4.6 的 IMECandidate / DictionaryEntry），
//            它们是候选栏渲染与词库读取的公共载体。
//  依赖：Foundation
//  使用方：PinyinEngine、PinyinDictionary、IMEKit（以及 keyboard-ui 的候选栏）
//

import Foundation

/// 输入法候选词。
///
/// 候选由引擎产出，UI 只负责展示与上屏，不参与排序。
public struct IMECandidate: Identifiable, Sendable, Equatable {

    /// 稳定标识：候选文本与拼音拼接，供 SwiftUI 列表使用。
    public var id: String { text + "|" + pinyin }

    /// 候选文本（上屏内容，可能是汉字、英文、emoji 或标点）。
    public var text: String

    /// 候选对应的输入全拼（便于调试与学习统计，不含声调）。
    public var pinyin: String

    /// 排序得分：越大越靠前，仅用于排序与诊断，不保证归一化。
    public var score: Double

    /// 候选类型，UI 可据此切换字体或角标。
    public enum Kind: String, Sendable {
        /// 普通中文词。
        case word
        /// emoji 联想。
        case emoji
        /// 英文/数字直通。
        case english
        /// 标点联想。
        case punctuation
        /// 用户学习或自造词。
        case learned
    }

    /// 候选类型。
    public var kind: Kind

    /// 创建候选。
    /// - Parameters:
    ///   - text: 上屏文本。
    ///   - pinyin: 输入全拼。
    ///   - score: 排序得分，默认 0。
    ///   - kind: 候选类型，默认 `.word`。
    public init(text: String, pinyin: String, score: Double = 0, kind: Kind = .word) {
        self.text = text
        self.pinyin = pinyin
        self.score = score
        self.kind = kind
    }
}

/// 词库条目（与 `base_dict.tsv` 的列一一对应）。
public struct DictionaryEntry: Codable, Sendable {

    /// 无声调全拼（小写、连写，`ü` 写作 `v`）。
    public var pinyin: String

    /// 词条文本。
    public var text: String

    /// 词频（越大越常用）。
    public var frequency: Int

    /// 标记串，逗号分隔（如 `chat,net`）。
    public var flags: String

    /// 创建词库条目。
    public init(pinyin: String, text: String, frequency: Int, flags: String) {
        self.pinyin = pinyin
        self.text = text
        self.frequency = frequency
        self.flags = flags
    }

    /// 判断是否带某个标记（如 `emoji`）。
    /// - Parameter flag: 标记名。
    /// - Returns: 命中返回 `true`。
    public func hasFlag(_ flag: String) -> Bool {
        flags.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == flag }
    }

    /// 是否为 emoji 条目。
    public var isEmoji: Bool { hasFlag("emoji") }

    /// 是否为标点条目。
    public var isPunctuation: Bool { hasFlag("punct") }
}
