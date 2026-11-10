//
//  SmartPunctuation.swift
//  墨语 · 输入法内核
//
//  打标点时按光标前面的内容做几处小调整，都是中文输入法的常见习惯：
//  - 数字后面的「。」多半是小数点，「：」多半是时间（12:30）
//  - 引号成对：前面有没配上的「“」，再打就给「”」
//

import Foundation

public enum SmartPunctuation {

    /// 只看光标前这么多个字，够判断引号配没配上了。
    private static let window = 200

    /// 按光标前的内容调整要打的标点。
    /// - Parameters:
    ///   - text: 键上的标点。
    ///   - context: 光标前的文字。
    public static func adjusted(_ text: String, before context: String) -> String {
        let last = context.last
        let afterDigit = last.map { $0.isASCII && $0.isNumber } ?? false
        switch text {
        case "。":
            return afterDigit ? "." : text
        case "：":
            return afterDigit ? ":" : text
        case "“":
            return hasUnclosed(open: "“", close: "”", in: context) ? "”" : text
        case "‘":
            return hasUnclosed(open: "‘", close: "’", in: context) ? "’" : text
        default:
            return text
        }
    }

    private static func hasUnclosed(open: Character, close: Character, in context: String) -> Bool {
        var depth = 0
        for character in context.suffix(window) {
            if character == open {
                depth += 1
            } else if character == close {
                depth = max(depth - 1, 0)
            } else if character == "\n" {
                // 换了段，前面没配上的不管了
                depth = 0
            }
        }
        return depth > 0
    }

    /// 英文里这些标点前面不留空格（点了补全会自动加一个空格，接着打标点时要去掉）。
    public static func closesUpSpace(_ text: String) -> Bool {
        [".", ",", "!", "?", ":", ";", "'", ")"].contains(text)
    }
}
