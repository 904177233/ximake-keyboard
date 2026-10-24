//
//  EmojiPanelView.swift
//  墨语（Moyu）键盘扩展 · Emoji 面板
//
//  模块职责：纯 Unicode Emoji 输入面板。分类 Tab（36）+ 8 列 × 5 行网格 + 底部功能行 39。
//            最近使用最多 32 个，存 `SharedStore`（键 `moyu.emoji.recent`），不占图片资源。
//  设计依据：design/键盘布局规范.md §4（.emoji 页）。
//  约束：无图片资源、无第三方；emoji 22pt 固定字号；单格命中区 ≥44×44 由外层行高补足。
//

import SwiftUI

/// Emoji 面板。
struct EmojiPanelView: View {

    /// 按键回调（退格 / 返回字母页等）。
    let onTap: (KeyboardKey) -> Void

    /// 插入文本回调（emoji 直接上屏）。
    let onInsert: (String) -> Void

    /// 当前选中的分类索引。
    @State private var selectedCategory: Int = 0

    /// 最近使用的 emoji。
    @State private var recent: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            categoryBar
            grid
            bottomBar
        }
        .frame(height: KMLayout.keyRowsHeight)
        .background(Theme.keyboardBackground)
    }

    // MARK: - 分类 Tab

    /// 分类横滚 Tab（36 高）。
    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(Self.categories.enumerated()), id: \.offset) { pair in
                    Button(action: {
                        KMHaptics.chip()
                        selectedCategory = pair.offset
                    }) {
                        Text(pair.element.title)
                            .font(Theme.fontCaption)
                            .fontWeight(selectedCategory == pair.offset ? .semibold : .regular)
                            .foregroundColor(selectedCategory == pair.offset ? Theme.accent : Theme.textSecondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .frame(height: 28)  // TOKEN: design/键盘布局规范.md §4 Emoji Tab 内高
                            .background(
                                Capsule(style: .continuous)
                                    .fill(selectedCategory == pair.offset ? Theme.accentSoft : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(KMPressableStyle(scale: 0.96))
                    .accessibilityLabel(Text("表情分类 \(pair.element.title)"))
                    .accessibilityAddTraits(selectedCategory == pair.offset ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
        }
        .frame(height: 36)  // TOKEN: design/键盘布局规范.md §4 Emoji Tab 高 36
    }

    // MARK: - 网格

    /// 8 列 × 5 行网格。
    private var grid: some View {
        GeometryReader { proxy in
            let columns = 8
            let rows = 5
            let spacing = Theme.Spacing.sm
            let cellWidth = max((proxy.size.width - Theme.Spacing.md * 2 - CGFloat(columns - 1) * spacing) / CGFloat(columns), 0)
            let cellHeight = max((proxy.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows), 0)
            let items = currentEmoji

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns),
                    spacing: spacing
                ) {
                    ForEach(Array(items.enumerated()), id: \.offset) { pair in
                        Button(action: {
                            KMHaptics.key()
                            insert(pair.element)
                        }) {
                            Text(pair.element)
                                .font(.system(size: 22))  // TOKEN: typography.key.size = 22
                                .frame(width: cellWidth, height: max(cellHeight, Theme.Sizing.minTapTarget))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(KMPressableStyle(scale: 0.9))
                        .accessibilityLabel(Text("表情 \(pair.element)"))
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 底部功能行

    /// 底部功能行 39：[ABC] [最近] [⌫]。
    private var bottomBar: some View {
        HStack(spacing: KMLayout.keyGap) {
            Button(action: {
                KMHaptics.function()
                onTap(.pageLetters)
            }) {
                Text("ABC")
                    .font(Theme.fontButton)
                    .foregroundColor(Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: KMLayout.letterRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("字母键盘"))

            Button(action: {
                KMHaptics.chip()
                selectedCategory = 0
            }) {
                Text("最近")
                    .font(Theme.fontBody)
                    .foregroundColor(selectedCategory == 0 ? Theme.accent : Theme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: KMLayout.letterRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("最近使用的表情"))

            Button(action: {
                KMHaptics.function()
                onTap(.backspace)
            }) {
                KMIconGlyph(symbol: "delete.left", fallback: "⌫", size: 18, tint: Theme.textPrimary)
                    .frame(width: KMLayout.functionKeyWidth, height: KMLayout.letterRowHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.key, style: .continuous)
                            .fill(Theme.keyFunctionBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMKeyCapStyle(style: .function))
            .accessibilityLabel(Text("退格"))
        }
        .padding(.horizontal, KMLayout.screenPadding)
        .frame(height: KMLayout.letterRowHeight)
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - 数据

    /// 当前分类的 emoji 列表。
    private var currentEmoji: [String] {
        if selectedCategory == 0 {
            return recent.isEmpty ? Array(Self.categories[1].items.prefix(40)) : recent
        }
        let index = min(selectedCategory, Self.categories.count - 1)
        return Self.categories[index].items
    }

    /// 插入并记录最近使用（最多 32）。
    /// - Parameter emoji: 表情字符。
    private func insert(_ emoji: String) {
        onInsert(emoji)
        var updated = recent.filter { $0 != emoji }
        updated.insert(emoji, at: 0)
        if updated.count > 32 {  // TOKEN: design/键盘布局规范.md §4 最近最多 32 个
            updated = Array(updated.prefix(32))
        }
        recent = updated
        SharedStore.shared.set(updated.joined(), forKey: Self.recentKey)
    }

    /// 最近使用存储键。
    private static let recentKey = "moyu.emoji.recent"

    /// 分类数据（纯 Unicode，无图片资源）。
    static let categories: [KMCategory] = [
        KMCategory(title: "最近", items: []),
        KMCategory(title: "表情", items: ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "😇", "🙂", "🙃", "😉", "😌", "😍", "🥰", "😘", "😗", "😙", "😚", "😋", "😛", "😝", "😜", "🤪", "🤨", "🧐", "🤓", "😎", "🥳", "😏", "😒", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖"]),
        KMCategory(title: "手势", items: ["👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🤟", "🤘", "🤙", "👈", "👉", "👆", "👇", "☝️", "👋", "🤚", "🖐", "✋", "🖖", "👏", "🙌", "🤝", "🙏", "💪", "🦾"]),
        KMCategory(title: "心情", items: ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💟", "☮️", "✨", "⭐", "🌟", "💫", "🔥", "💥"]),
        KMCategory(title: "日常", items: ["🍎", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🍒", "🍑", "🥭", "🍍", "🥥", "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌶", "🌽", "🥕", "🧄", "🧅", "🥔", "🍠"]),
        KMCategory(title: "活动", items: ["⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🥏", "🎱", "🪀", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏", "🪃", "🥅", "⛳️", "🪁", "🏹", "🎣", "🤿", "🥊", "🥋"]),
        KMCategory(title: "符号", items: ["✅", "❌", "⭕️", "❗️", "❓", "‼️", "⁉️", "💯", "🔅", "🔆", "〽️", "⚠️", "🚸", "🔱", "⚜️", "🔰", "♻️", "✳️", "❇️", "©️", "®️", "™️", "🔟", "🔠", "🔡", "🔤"])
    ]
}

/// Emoji 分类。
struct KMCategory: Equatable {

    /// 分类标题。
    let title: String

    /// 该分类下的 emoji。
    let items: [String]
}
