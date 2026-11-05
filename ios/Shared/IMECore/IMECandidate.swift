//
//  IMECandidate.swift
//  墨语 · 输入法内核
//
//  内核对外的数据结构：一次转换的输入（IMEQuery）和输出（IMEConversion）。
//

import Foundation

/// 一条候选。
public struct IMECandidate: Identifiable, Sendable, Equatable {

    /// 候选类型。界面只用它决定要不要打小标记。
    public enum Kind: String, Sendable {
        /// 词库或学习到的词。
        case word
        /// 多个词拼成的整句。
        case sentence
        /// 表情。
        case emoji
        /// 用户打的原文（hello）。
        case raw
        /// 模糊音命中。
        case fuzzy
        /// 打错字纠正后命中。
        case corrected
    }

    public var id: String { "\(text)|\(consumed)" }

    /// 上屏文本。
    public var text: String

    /// 这个候选对应的拼音（用于学习），表情和原文可能为空。
    public var key: String

    /// 选中它会吃掉多少个输入单位（字母或九宫格数字）。
    ///
    /// 小于输入长度时，剩下的拼音继续转换。这就是「一个词一个词选」。
    public var consumed: Int

    /// 类型。
    public var kind: Kind

    public init(text: String, key: String, consumed: Int, kind: Kind = .word) {
        self.text = text
        self.key = key
        self.consumed = consumed
        self.kind = kind
    }
}

/// 一次转换请求。
public struct IMEQuery: Sendable, Equatable {

    /// 输入方式。
    public enum Mode: Sendable {
        /// 26 键：input 是小写字母。
        case qwerty
        /// 九宫格：input 是数字 2-9。
        case t9
    }

    public var mode: Mode

    /// 输入串（只含小写字母或数字 2-9）。
    public var input: [UInt8]

    /// 用户手动分词的位置（分词键）：下标 i 表示在第 i 个输入单位之前断开。
    public var breaks: Set<Int>

    /// 九宫格里用户选定的字母：下标 -> 字母。26 键不用。
    public var locks: [Int: UInt8]

    public init(mode: Mode, input: [UInt8], breaks: Set<Int> = [], locks: [Int: UInt8] = [:]) {
        self.mode = mode
        self.input = input
        self.breaks = breaks
        self.locks = locks
    }
}

/// 一次转换结果。
public struct IMEConversion: Sendable, Equatable {

    /// 候选（已排好序）。
    public var candidates: [IMECandidate]

    /// 给人看的拼音，例如 wo'xi'huan'ni。
    public var spelling: String

    /// 九宫格左栏的拼音选项（26 键为空）。
    public var pinyinChoices: [String]

    public init(candidates: [IMECandidate] = [], spelling: String = "", pinyinChoices: [String] = []) {
        self.candidates = candidates
        self.spelling = spelling
        self.pinyinChoices = pinyinChoices
    }

    public static let empty = IMEConversion()
}
