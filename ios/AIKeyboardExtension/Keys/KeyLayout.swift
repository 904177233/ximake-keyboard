//
//  KeyLayout.swift
//  墨语键盘 · 键位
//
//  算出每个键的位置和含义。这里只有数据和几何，不碰绘制和触摸。
//

import UIKit

/// 按键动作。
enum KeyAction: Equatable {
    /// 26 键字母。
    case letter(Character)
    /// 九宫格数字键（2-9）。
    case t9(Character)
    /// 直接上屏的字符（数字、符号）。
    case text(String)
    /// 标点：组字中会先上屏首选。
    case punctuation(String)
    /// 分词。
    case separator
    case backspace
    case shift
    case space
    case enter
    /// 中英切换。
    case language
    case showNumbers
    case showLetters
    case showSymbols
    /// 清空组字。
    case clearComposition
    /// 26 键 / 九宫格切换。
    case toggleLayout
    /// 切到下一个键盘（有 Home 键的机型必须提供）。
    case nextKeyboard
}

/// 按键外观。
enum KeyStyle {
    case letter, function, accent, space
}

/// 一个键。
struct KeyDef {
    let action: KeyAction
    var title: String = ""
    /// 九宫格数字这种写在主标题上方的小字。
    var caption: String?
    /// 右上角的小提示，上滑打出的字符。
    var hint: String?
    /// 上滑或长按的动作。
    var alternate: KeyAction?
    /// SF Symbol。
    var symbol: String?
    var style: KeyStyle = .letter
    /// 主标题字号。
    var fontSize: CGFloat = 22
    /// 中文/英文切换键的两段文字：(高亮的, 暗的, 高亮在前)。
    var languageLabel: (active: String, inactive: String, activeFirst: Bool)?
    /// 是否显示按下时的气泡。
    var showsPopup: Bool = false
    /// 是否不可用（比如输入框是空的时候的发送键）。
    var isDisabled: Bool = false
    var frame: CGRect = .zero
}

/// 决定键盘长什么样的全部状态。
struct KeyboardVisualState: Equatable {

    enum Kind: Equatable {
        case qwerty, nineKey, numbers
    }

    enum Shift: Equatable {
        case off, once, locked
    }

    var kind: Kind = .qwerty
    var isChinese = true
    var shift: Shift = .off
    var isComposing = false
    var returnTitle = "换行"
    var returnIsAccent = false
    var returnIsDisabled = false
    var showsNextKeyboard = false
}

/// 尺寸。
struct KeyboardMetrics {
    let capHeight: CGFloat
    let rowGap: CGFloat
    let topBarHeight: CGFloat
    let isLandscape: Bool

    let columnGap: CGFloat = 5
    let sidePadding: CGFloat = 3
    let topPadding: CGFloat = 6
    let bottomPadding: CGFloat = 4

    init(height: KeyboardPrefs.Height, isLandscape: Bool) {
        self.isLandscape = isLandscape
        if isLandscape {
            capHeight = 33
            rowGap = 6
            topBarHeight = 40
        } else {
            switch height {
            case .low:
                capHeight = 40
                rowGap = 8
            case .standard:
                capHeight = 44
                rowGap = 9
            case .tall:
                capHeight = 50
                rowGap = 10
            }
            topBarHeight = 48
        }
    }

    /// 键区总高。
    var surfaceHeight: CGFloat {
        topPadding + capHeight * 4 + rowGap * 3 + bottomPadding
    }
}

/// 布局结果。
struct KeyboardLayoutResult {
    var keys: [KeyDef]
    /// 九宫格左边那一栏的位置。
    var sideStrip: CGRect?
}

/// 键位计算。
enum KeyLayoutBuilder {

    private static let row1: [(Character, String)] = [
        ("q", "1"), ("w", "2"), ("e", "3"), ("r", "4"), ("t", "5"),
        ("y", "6"), ("u", "7"), ("i", "8"), ("o", "9"), ("p", "0")
    ]
    private static let row2Chinese: [(Character, String)] = [
        ("a", "@"), ("s", "#"), ("d", "¥"), ("f", "%"), ("g", "&"),
        ("h", "*"), ("j", "（"), ("k", "）"), ("l", "“")
    ]
    private static let row3Chinese: [(Character, String)] = [
        ("z", "…"), ("x", "—"), ("c", "："), ("v", "；"), ("b", "？"), ("n", "！"), ("m", "、")
    ]
    private static let row2English: [(Character, String)] = [
        ("a", "@"), ("s", "#"), ("d", "$"), ("f", "%"), ("g", "&"),
        ("h", "*"), ("j", "("), ("k", ")"), ("l", "\"")
    ]
    private static let row3English: [(Character, String)] = [
        ("z", "-"), ("x", "_"), ("c", ":"), ("v", ";"), ("b", "?"), ("n", "!"), ("m", "'")
    ]

    /// 计算全部键位。
    static func build(state: KeyboardVisualState, size: CGSize, metrics: KeyboardMetrics) -> KeyboardLayoutResult {
        switch state.kind {
        case .qwerty:
            return KeyboardLayoutResult(keys: qwerty(state: state, width: size.width, metrics: metrics), sideStrip: nil)
        case .nineKey:
            return nineKey(state: state, width: size.width, metrics: metrics)
        case .numbers:
            return KeyboardLayoutResult(keys: numbers(state: state, width: size.width, metrics: metrics), sideStrip: nil)
        }
    }

    private static func rowY(_ row: Int, _ metrics: KeyboardMetrics) -> CGFloat {
        metrics.topPadding + CGFloat(row) * (metrics.capHeight + metrics.rowGap)
    }

    private static func letterKey(_ pair: (Character, String), uppercase: Bool, frame: CGRect) -> KeyDef {
        let title = uppercase ? String(pair.0).uppercased() : String(pair.0)
        return KeyDef(action: .letter(pair.0),
                      title: title,
                      hint: pair.1,
                      alternate: .text(pair.1),
                      style: .letter,
                      showsPopup: true,
                      frame: frame)
    }

    private static func qwerty(state: KeyboardVisualState, width: CGFloat, metrics: KeyboardMetrics) -> [KeyDef] {
        var keys: [KeyDef] = []
        let gap = metrics.columnGap
        let content = width - metrics.sidePadding * 2
        let keyWidth = (content - gap * 9) / 10
        let height = metrics.capHeight
        let uppercase = state.shift != .off

        // 第一行
        var x = metrics.sidePadding
        var y = rowY(0, metrics)
        for pair in row1 {
            keys.append(letterKey(pair, uppercase: uppercase, frame: CGRect(x: x, y: y, width: keyWidth, height: height)))
            x += keyWidth + gap
        }

        // 第二行：9 个键居中
        let row2 = state.isChinese ? row2Chinese : row2English
        y = rowY(1, metrics)
        x = (width - (keyWidth * 9 + gap * 8)) / 2
        for pair in row2 {
            keys.append(letterKey(pair, uppercase: uppercase, frame: CGRect(x: x, y: y, width: keyWidth, height: height)))
            x += keyWidth + gap
        }

        // 第三行：Shift + 7 个字母 + 退格
        let row3 = state.isChinese ? row3Chinese : row3English
        y = rowY(2, metrics)
        let sideKey = max(keyWidth * 1.28, 40)
        keys.append(KeyDef(action: .shift,
                           symbol: state.shift == .off ? "shift" : (state.shift == .locked ? "capslock.fill" : "shift.fill"),
                           style: .function,
                           frame: CGRect(x: metrics.sidePadding, y: y, width: sideKey, height: height)))
        x = (width - (keyWidth * 7 + gap * 6)) / 2
        for pair in row3 {
            keys.append(letterKey(pair, uppercase: uppercase, frame: CGRect(x: x, y: y, width: keyWidth, height: height)))
            x += keyWidth + gap
        }
        keys.append(KeyDef(action: .backspace,
                           symbol: "delete.left",
                           style: .function,
                           frame: CGRect(x: width - metrics.sidePadding - sideKey, y: y, width: sideKey, height: height)))

        keys.append(contentsOf: bottomRow(state: state, width: width, metrics: metrics, includesPunctuation: true))
        return keys
    }

    /// 底行：123、表情、逗号、空格、句号、中/英、回车。
    private static func bottomRow(state: KeyboardVisualState, width: CGFloat, metrics: KeyboardMetrics,
                                  includesPunctuation: Bool) -> [KeyDef] {
        var keys: [KeyDef] = []
        let y = rowY(3, metrics)
        let height = metrics.capHeight
        let gap = metrics.columnGap
        var x = metrics.sidePadding

        let scale: CGFloat = metrics.isLandscape ? 1.25 : 1.0
        let numberWidth = 42 * scale
        let symbolWidth = 38 * scale
        let punctuationWidth = 32 * scale
        let languageWidth = 40 * scale
        let returnWidth = 68 * scale

        keys.append(KeyDef(action: .showNumbers, title: "123", style: .function, fontSize: 15,
                           frame: CGRect(x: x, y: y, width: numberWidth, height: height)))
        x += numberWidth + gap

        // 有 Home 键的机型必须能切键盘，把表情键的位置让出来。表情从工具栏进。
        if state.showsNextKeyboard {
            keys.append(KeyDef(action: .nextKeyboard, symbol: "globe", style: .function,
                               frame: CGRect(x: x, y: y, width: symbolWidth, height: height)))
        } else {
            keys.append(KeyDef(action: .showSymbols, symbol: "face.smiling", style: .function,
                               frame: CGRect(x: x, y: y, width: symbolWidth, height: height)))
        }
        x += symbolWidth + gap

        var rightEdge = width - metrics.sidePadding - returnWidth
        let returnFrame = CGRect(x: rightEdge, y: y, width: returnWidth, height: height)
        rightEdge -= gap + languageWidth
        let languageFrame = CGRect(x: rightEdge, y: y, width: languageWidth, height: height)

        if includesPunctuation {
            let comma = state.isChinese ? "，" : ","
            let period = state.isChinese ? "。" : "."
            let question = state.isChinese ? "？" : "?"
            let exclamation = state.isChinese ? "！" : "!"
            keys.append(KeyDef(action: .punctuation(comma), title: comma, hint: question,
                               alternate: .punctuation(question), style: .letter, fontSize: 18, showsPopup: true,
                               frame: CGRect(x: x, y: y, width: punctuationWidth, height: height)))
            x += punctuationWidth + gap
            rightEdge -= gap + punctuationWidth
            keys.append(KeyDef(action: .punctuation(period), title: period, hint: exclamation,
                               alternate: .punctuation(exclamation), style: .letter, fontSize: 18, showsPopup: true,
                               frame: CGRect(x: rightEdge, y: y, width: punctuationWidth, height: height)))
        }

        keys.append(KeyDef(action: .space, title: "墨语", style: .space, fontSize: 13,
                           frame: CGRect(x: x, y: y, width: rightEdge - gap - x, height: height)))

        keys.append(KeyDef(action: .language,
                           style: .function,
                           languageLabel: state.isChinese
                               ? (active: "中", inactive: "/英", activeFirst: true)
                               : (active: "英", inactive: "中/", activeFirst: false),
                           frame: languageFrame))
        keys.append(KeyDef(action: .enter, title: state.returnTitle,
                           style: state.returnIsAccent ? .accent : .function,
                           fontSize: 15,
                           isDisabled: state.returnIsDisabled,
                           frame: returnFrame))
        return keys
    }

    private static func nineKey(state: KeyboardVisualState, width: CGFloat, metrics: KeyboardMetrics) -> KeyboardLayoutResult {
        var keys: [KeyDef] = []
        let gap = metrics.columnGap
        let stripWidth: CGFloat = metrics.isLandscape ? 70 : 50
        let rightWidth: CGFloat = metrics.isLandscape ? 80 : 58
        let height = metrics.capHeight
        let gridLeft = metrics.sidePadding + stripWidth + gap
        let gridRight = width - metrics.sidePadding - rightWidth - gap
        let keyWidth = (gridRight - gridLeft - gap * 2) / 3

        let grid: [[(KeyAction, String, String)]] = [
            [(.separator, "1", "分词"), (.t9("2"), "2", "ABC"), (.t9("3"), "3", "DEF")],
            [(.t9("4"), "4", "GHI"), (.t9("5"), "5", "JKL"), (.t9("6"), "6", "MNO")],
            [(.t9("7"), "7", "PQRS"), (.t9("8"), "8", "TUV"), (.t9("9"), "9", "WXYZ")]
        ]
        for (rowIndex, row) in grid.enumerated() {
            for (columnIndex, cell) in row.enumerated() {
                let frame = CGRect(x: gridLeft + CGFloat(columnIndex) * (keyWidth + gap),
                                   y: rowY(rowIndex, metrics),
                                   width: keyWidth,
                                   height: height)
                keys.append(KeyDef(action: cell.0,
                                   title: cell.2,
                                   caption: cell.1,
                                   style: cell.0 == .separator ? .function : .letter,
                                   fontSize: 15,
                                   frame: frame))
            }
        }

        let rightX = width - metrics.sidePadding - rightWidth
        keys.append(KeyDef(action: .backspace, symbol: "delete.left", style: .function,
                           frame: CGRect(x: rightX, y: rowY(0, metrics), width: rightWidth, height: height)))
        keys.append(KeyDef(action: state.isComposing ? .clearComposition : .text("@"),
                           title: state.isComposing ? "清空" : "@",
                           style: .function, fontSize: 15,
                           frame: CGRect(x: rightX, y: rowY(1, metrics), width: rightWidth, height: height)))
        keys.append(KeyDef(action: .toggleLayout, title: "26键", style: .function, fontSize: 14,
                           frame: CGRect(x: rightX, y: rowY(2, metrics), width: rightWidth, height: height)))

        keys.append(contentsOf: bottomRow(state: state, width: width, metrics: metrics, includesPunctuation: false))

        let strip = CGRect(x: metrics.sidePadding, y: rowY(0, metrics), width: stripWidth,
                           height: height * 3 + metrics.rowGap * 2)
        return KeyboardLayoutResult(keys: keys, sideStrip: strip)
    }

    private static func numbers(state: KeyboardVisualState, width: CGFloat, metrics: KeyboardMetrics) -> [KeyDef] {
        var keys: [KeyDef] = []
        let gap = metrics.columnGap
        let sideWidth: CGFloat = 66
        let height = metrics.capHeight
        let centerLeft = metrics.sidePadding + sideWidth + gap
        let centerRight = width - metrics.sidePadding - sideWidth - gap
        let digitWidth = (centerRight - centerLeft - gap * 2) / 3
        let rows: [(String, [String], String)] = [
            ("%", ["1", "2", "3"], "BACK"),
            ("-", ["4", "5", "6"], "."),
            ("+", ["7", "8", "9"], "@")
        ]
        for (rowIndex, row) in rows.enumerated() {
            let y = rowY(rowIndex, metrics)
            keys.append(KeyDef(action: .text(row.0), title: row.0, style: .function, fontSize: 18,
                               frame: CGRect(x: metrics.sidePadding, y: y, width: sideWidth, height: height)))
            for (columnIndex, digit) in row.1.enumerated() {
                keys.append(KeyDef(action: .text(digit), title: digit, style: .letter, fontSize: 24, showsPopup: false,
                                   frame: CGRect(x: centerLeft + CGFloat(columnIndex) * (digitWidth + gap),
                                                 y: y, width: digitWidth, height: height)))
            }
            let rightFrame = CGRect(x: width - metrics.sidePadding - sideWidth, y: y, width: sideWidth, height: height)
            if row.2 == "BACK" {
                keys.append(KeyDef(action: .backspace, symbol: "delete.left", style: .function, frame: rightFrame))
            } else {
                keys.append(KeyDef(action: .text(row.2), title: row.2, style: .function, fontSize: 18, frame: rightFrame))
            }
        }

        let y = rowY(3, metrics)
        keys.append(KeyDef(action: .showLetters, title: "返回", style: .function, fontSize: 15,
                           frame: CGRect(x: metrics.sidePadding, y: y, width: sideWidth, height: height)))
        keys.append(KeyDef(action: .showSymbols, title: "符", style: .function, fontSize: 16,
                           frame: CGRect(x: centerLeft, y: y, width: digitWidth, height: height)))
        keys.append(KeyDef(action: .text("0"), title: "0", style: .letter, fontSize: 24,
                           frame: CGRect(x: centerLeft + digitWidth + gap, y: y, width: digitWidth, height: height)))
        keys.append(KeyDef(action: .space, title: "空格", style: .space, fontSize: 13,
                           frame: CGRect(x: centerLeft + (digitWidth + gap) * 2, y: y, width: digitWidth, height: height)))
        keys.append(KeyDef(action: .enter, title: state.returnTitle,
                           style: state.returnIsAccent ? .accent : .function, fontSize: 15,
                           isDisabled: state.returnIsDisabled,
                           frame: CGRect(x: width - metrics.sidePadding - sideWidth, y: y, width: sideWidth, height: height)))
        return keys
    }
}
