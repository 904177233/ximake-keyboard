//
//  KeyRows.swift
//  墨语（Moyu）键盘扩展 · 键区（26 键 / 9 键 / 数字 / 符号）
//
//  模块职责：把当前页面的按键矩阵排成 4 行，宽度按容器宽度动态计算（375 / 390 / 430 自适应），
//            行高与行距严格等于设计规范（竖屏 39 + 6，横屏 34.5 + 6）。
//  设计依据：design/键盘布局规范.md §2（26 键逐行数学）、§2.7（命中区）、§3（9 键）、§4（数字 / 符号页）。
//  约束：所有尺寸从 `KMLayout`（其自身从 `Theme` 派生）取得；页面切换只换数据不换骨架。
//

import SwiftUI

// MARK: - 主键区（26 键 / 9 键）

/// 字母键区。
struct KeyRowsView: View {

    /// 键盘布局（26 键 / 9 键）。
    let layoutMode: KeyboardViewModel.LayoutMode

    /// Shift 状态。
    let shiftState: KeyboardViewModel.ShiftState

    /// 是否横屏。
    let isLandscape: Bool

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    /// 空格横向滑动时移动光标（参数为字符偏移，正数向右）。
    var onMoveCursor: (Int) -> Void = { _ in }

    /// 底行最右的小形象配置（`nil` 表示不显示，空格键自动回弹到 194 设计宽）。
    var mascot: KMMascotConfig? = nil

    /// 主题主色（回车键用；design/05 §1.1 允许的 4 处主色之一）。
    var accent: Color = Theme.accent

    /// 回车键语义（聊天框=发送、搜索框=搜索、普通框=换行）。
    var returnKeyKind: KMReturnKeyKind = .newline

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let rowHeight = isLandscape ? KMLayout.landscapeRowHeight : KMLayout.letterRowHeight
            Group {
                if layoutMode == .nineKey {
                    nineKeyRows(width: width, rowHeight: rowHeight)
                } else {
                    qwertyRows(width: width, rowHeight: rowHeight)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .top)
        }
        .frame(height: KMLayout.keyRowsHeight)
        .padding(.horizontal, KMLayout.screenPadding)
    }

    // MARK: - 26 键

    /// 26 键四行。
    /// - Parameters:
    ///   - width: 键区可用宽度（已去掉左右 3pt）。
    ///   - rowHeight: 行高。
    private func qwertyRows(width: CGFloat, rowHeight: CGFloat) -> some View {
        let keyWidth = isLandscape ? KMLayout.landscapeKeyWidth(forWidth: width) : KMLayout.letterKeyWidth(forWidth: width)
        let secondWidth = keyWidth * 9 + KMLayout.keyGap * 8
        let secondInset = max((width - secondWidth) / 2, 0)
        let thirdWidth = keyWidth * 7 + KMLayout.functionKeyWidth * 2 + KMLayout.keyGap * 8
        let thirdInset = max((width - thirdWidth) / 2, 0)

        return VStack(spacing: KMLayout.keyGap) {
            // 行 1：10 键
            HStack(spacing: KMLayout.keyGap) {
                ForEach(Self.topRow, id: \.self) { character in
                    letterKey(character, width: keyWidth, height: rowHeight)
                }
            }
            .frame(height: rowHeight)

            // 行 2：9 键（不拉宽，居中）
            HStack(spacing: KMLayout.keyGap) {
                ForEach(Self.homeRow, id: \.self) { character in
                    letterKey(character, width: keyWidth, height: rowHeight)
                }
            }
            .padding(.horizontal, secondInset)
            .frame(height: rowHeight)

            // 行 3：Shift 42 + 7 键 + 退格 42
            HStack(spacing: KMLayout.keyGap) {
                functionKey(icon: shiftState.isUppercase ? "shift.fill" : "shift", fallback: "⇧",
                            width: KMLayout.functionKeyWidth, height: rowHeight,
                            isHighlighted: shiftState.isUppercase,
                            accessibility: "切换大小写") {
                    onTap(.shift)
                }
                ForEach(Self.thirdRow, id: \.self) { character in
                    letterKey(character, width: keyWidth, height: rowHeight)
                }
                KMBackspaceKey(height: rowHeight) { onTap(.backspace) }
            }
            .padding(.horizontal, thirdInset)
            .frame(height: rowHeight)

            KeyRowsBottomRow(
                isLandscape: isLandscape,
                height: rowHeight,
                accent: accent,
                returnKeyKind: returnKeyKind,
                mascot: mascot,
                onTap: onTap,
                onMoveCursor: onMoveCursor
            )
        }
        .frame(height: KMLayout.keyRowsHeight, alignment: .top)
    }

    // MARK: - 9 键

    /// 九宫格四行（3 行主键 + 1 行功能键）。
    /// - Parameters:
    ///   - width: 键区可用宽度。
    ///   - rowHeight: 行高。
    private func nineKeyRows(width: CGFloat, rowHeight: CGFloat) -> some View {
        let keyWidth = KMLayout.nineKeyWidth(forWidth: width)
        return VStack(spacing: KMLayout.keyGap) {
            ForEach(Array(Self.nineKeyRows.enumerated()), id: \.offset) { pair in
                HStack(spacing: KMLayout.keyGap) {
                    ForEach(pair.element, id: \.letters) { group in
                        nineKey(group: group, width: keyWidth, height: rowHeight)
                    }
                }
                .frame(height: rowHeight)
            }

            HStack(spacing: KMLayout.keyGap) {
                functionKey(icon: "textformat.123", fallback: "123",
                            width: KMLayout.functionKeyWidth, height: rowHeight,
                            accessibility: "数字键盘") {
                    onTap(.pageNumbers)
                }
                spaceKey(height: rowHeight, flexible: true)
                KMBackspaceKey(height: rowHeight) { onTap(.backspace) }
            }
            .padding(.horizontal, KMLayout.functionKeyWidth)
            .frame(height: rowHeight)
        }
        .frame(height: KMLayout.keyRowsHeight, alignment: .top)
    }

    /// 单个九宫格主键（主字符 + 下方拼音提示）。
    /// - Parameters:
    ///   - group: 键组（字母 + 提示）。
    ///   - width: 键宽。
    ///   - height: 行高。
    @ViewBuilder
    private func nineKey(group: KMNineKeyGroup, width: CGFloat, height: CGFloat) -> some View {
        if group.isLayoutToggle {
            Button(action: {
                KMHaptics.function()
                onTap(.toggleLayout)
            }) {
                VStack(spacing: 0) {
                    Text("26键")
                        .font(.system(size: 15, weight: .medium))  // TOKEN: typography.body.size = 15
                        .foregroundColor(Theme.textSecondary)
                    Text("QWERTY")
                        .font(.system(size: 10, weight: .regular))  // TOKEN: typography.caption.size ≈ 10
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyFunctionBackground)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("切换到 26 键键盘"))
        } else {
            Button(action: {
                KMHaptics.key()
                onTap(.character(group.firstLetter))
            }) {
                VStack(spacing: 0) {
                    Text(shiftState.isUppercase ? group.letters.uppercased() : group.letters.lowercased())
                        .font(.system(size: 20, weight: .regular))  // TOKEN: typography.title.size = 20
                        .foregroundColor(Theme.textPrimary)
                    Text(group.hint)
                        .font(.system(size: 10, weight: .regular))  // TOKEN: typography.caption.size ≈ 10
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyBackground)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .letter))
            .accessibilityLabel(Text("九宫格 \(group.letters)"))
            .accessibilityAddTraits(.isKeyboardKey)
        }
    }

    // MARK: - 通用键

    /// 字母键。
    /// - Parameters:
    ///   - character: 键字符（小写）。
    ///   - width: 键宽。
    ///   - height: 行高。
    private func letterKey(_ character: String, width: CGFloat, height: CGFloat) -> some View {
        let text = shiftState.isUppercase ? character.uppercased() : character.lowercased()
        return KMKeyCap(
            label: .character(text),
            style: .letter,
            width: width,
            height: height,
            action: { onTap(.character(text)) }
        )
    }

    /// 功能键（图标 + 文字兜底）。
    /// - Parameters:
    ///   - icon: SF Symbol 名。
    ///   - fallback: 图标不可用时的文字。
    ///   - width: 键宽。
    ///   - height: 行高。
    ///   - isHighlighted: 是否高亮。
    ///   - accessibility: 无障碍文案。
    ///   - action: 点击回调。
    private func functionKey(
        icon: String,
        fallback: String,
        width: CGFloat,
        height: CGFloat,
        isHighlighted: Bool = false,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            KMHaptics.function()
            action()
        }) {
            KMIconGlyph(symbol: icon, fallback: fallback, size: 18, tint: isHighlighted ? Theme.accent : Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(isHighlighted ? Theme.keyFunctionBackgroundPressed : Theme.keyFunctionBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .function))
        .accessibilityLabel(Text(accessibility))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    /// 空格键（宽度自适应）。
    /// - Parameters:
    ///   - height: 行高。
    ///   - flexible: 是否占满剩余宽度。
    private func spaceKey(height: CGFloat, flexible: Bool) -> some View {
        Button(action: {
            KMHaptics.key()
            onTap(.space)
        }) {
            Text("空格")
                .font(Theme.fontBody)
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: flexible ? .infinity : nil)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                        .fill(Theme.keyBackground)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .space))
        .accessibilityLabel(Text("空格"))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    // MARK: - 数据

    /// 26 键第一行。
    private static let topRow: [String] = ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]

    /// 26 键第二行。
    private static let homeRow: [String] = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]

    /// 26 键第三行。
    private static let thirdRow: [String] = ["z", "x", "c", "v", "b", "n", "m"]

    /// 九宫格键组。
    private static let nineKeyRows: [[KMNineKeyGroup]] = [
        [
            KMNineKeyGroup(letters: "ABC", hint: "ABC", firstLetter: "a"),
            KMNineKeyGroup(letters: "DEF", hint: "DEF", firstLetter: "d"),
            KMNineKeyGroup(letters: "GHI", hint: "GHI", firstLetter: "g")
        ],
        [
            KMNineKeyGroup(letters: "JKL", hint: "JKL", firstLetter: "j"),
            KMNineKeyGroup(letters: "MNO", hint: "MNO", firstLetter: "m"),
            KMNineKeyGroup(letters: "PQRS", hint: "PQRS", firstLetter: "p")
        ],
        [
            KMNineKeyGroup(letters: "TUV", hint: "TUV", firstLetter: "t"),
            KMNineKeyGroup(letters: "WXYZ", hint: "WXYZ", firstLetter: "w"),
            KMNineKeyGroup(letters: "26键", hint: "QWERTY", firstLetter: "", isLayoutToggle: true)
        ]
    ]
}

/// 九宫格键组。
struct KMNineKeyGroup: Equatable, Hashable {

    /// 字母串（ABC / DEF …）。
    let letters: String

    /// 键内提示（拼音首字母提示）。
    let hint: String

    /// 首个字母（点击上屏的字符）。
    let firstLetter: String

    /// 是否布局切换键（九宫格右下角切回 26 键）。
    var isLayoutToggle: Bool = false
}

// MARK: - 数字页

/// 数字与符号输入页（4 行，右侧功能列）。
struct NumberPadView: View {

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let rowHeight = KMLayout.letterRowHeight
            VStack(spacing: KMLayout.keyGap) {
                numberRow(["1", "2", "3"], trailing: .backspace, width: width, height: rowHeight)
                numberRow(["4", "5", "6"], trailing: nil, width: width, height: rowHeight)
                numberRow(["7", "8", "9"], trailing: .newline, width: width, height: rowHeight)
                lastRow(width: width, height: rowHeight)
            }
            .frame(width: width, height: proxy.size.height, alignment: .top)
        }
        .frame(height: KMLayout.keyRowsHeight)
        .padding(.horizontal, KMLayout.screenPadding)
    }

    /// 一行数字 + 右侧功能键。
    /// - Parameters:
    ///   - digits: 数字数组。
    ///   - trailing: 右侧功能键（nil 表示留空）。
    ///   - width: 键区宽度。
    ///   - height: 行高。
    private func numberRow(_ digits: [String], trailing: KeyboardKey?, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: KMLayout.keyGap) {
            ForEach(digits, id: \.self) { digit in
                numberKey(digit, height: height)
            }
            if let trailing {
                trailingKey(trailing, height: height)
            } else {
                Color.clear.frame(width: KMLayout.functionKeyWidth, height: height)
            }
        }
        .frame(height: height)
    }

    /// 数字键。
    /// - Parameters:
    ///   - digit: 数字字符。
    ///   - height: 行高。
    private func numberKey(_ digit: String, height: CGFloat) -> some View {
        KMKeyCap(
            label: .character(digit),
            style: .letter,
            width: nil,
            height: height,
            action: { onTap(.character(digit)) }
        )
    }

    /// 右侧功能键（退格 / 回车）。
    /// - Parameters:
    ///   - key: 按键。
    ///   - height: 行高。
    private func trailingKey(_ key: KeyboardKey, height: CGFloat) -> some View {
        // 退格走可长按连续删除的专用按键；回车仍是普通 Button。
        if key != .newline {
            return AnyView(KMBackspaceKey(height: height) { onTap(key) })
        }
        return AnyView(Button(action: {
            KMHaptics.rigid()
            onTap(key)
        }) {
            KMIconGlyph(
                symbol: "return",
                fallback: "⏎",
                size: 18,
                tint: Theme.textOnAccent
            )
            .frame(width: KMLayout.functionKeyWidth, height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                    .fill(Theme.accent)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMKeyCapStyle(style: .accent))
        .accessibilityLabel(Text("回车"))
        .accessibilityAddTraits(.isKeyboardKey))
    }

    /// 末行：[ABC] [0] [.] [⏎]。
    /// - Parameters:
    ///   - width: 键区宽度。
    ///   - height: 行高。
    private func lastRow(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: KMLayout.keyGap) {
            Button(action: {
                KMHaptics.function()
                onTap(.pageLetters)
            }) {
                Text("ABC")
                    .font(Theme.fontButton)
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("字母键盘"))

            // 地球键放在数字页：字母页左下角换成了 123 键（切键盘收进长按），
            // 这里保留一颗显式的切换键，保证任何时候都能切走（Apple 要求必须提供）。
            Button(action: {
                KMHaptics.function()
                onTap(.globe)
            }) {
                KMIconGlyph(symbol: "globe", fallback: "🌐", size: 17, tint: Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(width: KMLayout.functionKeyWidth, height: height)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("切换键盘"))

            KMKeyCap(label: .character("0"), style: .letter, width: nil, height: height,
                     action: { onTap(.character("0")) })

            KMKeyCap(label: .character("."), style: .letter, width: nil, height: height,
                     action: { onTap(.character(".")) })

            trailingKey(.newline, height: height)
        }
        .frame(height: height)
    }
}

// MARK: - 符号页

/// 符号页（3 行符号 + 1 行功能键）。
struct SymbolPadView: View {

    /// 按键回调。
    let onTap: (KeyboardKey) -> Void

    var body: some View {
        GeometryReader { proxy in
            let rowHeight = KMLayout.letterRowHeight
            VStack(spacing: KMLayout.keyGap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { pair in
                    HStack(spacing: KMLayout.keyGap) {
                        ForEach(pair.element, id: \.self) { symbol in
                            KMKeyCap(
                                label: .symbol(symbol),
                                style: .letter,
                                width: nil,
                                height: rowHeight,
                                action: { onTap(.character(symbol)) }
                            )
                        }
                    }
                    .frame(height: rowHeight)
                }
                functionRow(height: rowHeight)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(height: KMLayout.keyRowsHeight)
        .padding(.horizontal, KMLayout.screenPadding)
    }

    /// 功能行：[123] [空格] [.] [⌫]。
    /// - Parameter height: 行高。
    private func functionRow(height: CGFloat) -> some View {
        HStack(spacing: KMLayout.keyGap) {
            Button(action: {
                KMHaptics.function()
                onTap(.pageNumbers)
            }) {
                Text("123")
                    .font(Theme.fontButton)
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: KMLayout.functionKeyWidth * 2, height: height)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("数字键盘"))

            Button(action: {
                KMHaptics.key()
                onTap(.space)
            }) {
                Text("空格")
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .space))
            .accessibilityLabel(Text("空格"))

            KMKeyCap(label: .symbol("."), style: .letter, width: KMLayout.functionKeyWidth, height: height,
                     action: { onTap(.character(".")) })

            KMBackspaceKey(height: height) { onTap(.backspace) }
        }
        .frame(height: height)
    }

    /// 符号行数据（常用中文标点优先，符合规范 §4）。
    private static let rows: [[String]] = [
        ["，", "。", "？", "！", "、", "：", "；", "…", "~"],
        ["（", "）", "“", "”", "《", "》", "—", "·", "¥"],
        ["@", "#", "$", "%", "&", "*", "+", "=", "/"]
    ]
}
