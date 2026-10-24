//
//  KMThemePicker.swift
//  AIKeyboardExtension
//
//  键盘内主题选择器（design/05-主题与小形象规范.md §1.1 / §4）。
//
//  只做「选主题」这一件事：横向排列 6 个 32pt 圆形色块，点一下立即写
//  `ThemeStore.shared.currentThemeID` 并触感反馈。导入 / 自定义形象等完整能力
//  在宿主 App 的主题设置页里做，键盘内不重复实现（键盘扩展内存预算 40–60MB）。
//
//  数据源：`ThemeStore.shared.availableThemes`（= `AppTheme.allPresets`，6 套预设）。
//  全部颜色来自 `AppTheme` 与 `Theme`，本文件不写任何 hex。
//

import SwiftUI

// MARK: - 选择器

/// 键盘内主题选择器（横向 6 个色块，高 44，可横向滚动）。
struct KMThemePicker: View {

    /// 当前主题 id（用于高亮）。
    let selectedThemeID: String

    /// 点选回调（参数为 `AppTheme`，调用方负责写入 `ThemeStore` 并触发重绘）。
    let onSelect: (AppTheme) -> Void

    /// 可选主题列表（默认取 `ThemeStore` 暴露的 6 套预设）。
    var themes: [AppTheme] = ThemeStore.shared.availableThemes

    /// 色块直径（32pt，design/05 §4）。
    private let swatchSize: CGFloat = 32  // TOKEN: sizing.themeSwatchSize = 32

    /// 选中态白环宽度（2pt）。
    private let ringWidth: CGFloat = 2  // TOKEN: sizing.themeRingWidth = 2

    /// 色块之间的间距。
    private let spacing: CGFloat = Theme.Spacing.lg

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(themes) { theme in
                        swatch(theme)
                            .id(theme.id)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .frame(maxHeight: .infinity)
            }
            .onChange(of: selectedThemeID) { newValue in
                // 外部改主题时（例如宿主 App 同步），把选中项滚到可见处。
                withAnimation(KMAnimation.animation(duration: Theme.Motion.fast)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .frame(height: KMLayout.settingsRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("主题颜色，共 \(themes.count) 套"))
    }

    // MARK: - 单个色块

    /// 单个主题色块。
    /// - Parameter theme: 主题数据（`AppTheme`，含 accent / tint 等动态色）。
    private func swatch(_ theme: AppTheme) -> some View {
        let isSelected = theme.id == selectedThemeID
        return Button {
            KMHaptics.chip()
            onSelect(theme)
        } label: {
            ZStack {
                // 选中态：主色外环（2pt）+ 白色内环（2pt），参考 design/05 §4。
                if isSelected {
                    Circle()
                        .strokeBorder(theme.accent, lineWidth: ringWidth)
                        .frame(width: swatchSize + ringWidth * 2, height: swatchSize + ringWidth * 2)
                    Circle()
                        .strokeBorder(Theme.keyboardBackground, lineWidth: ringWidth)
                        .frame(width: swatchSize, height: swatchSize)
                }
                // 色块本体：用两个半圆拼出「主色 + 辅色」的双色预览。
                Circle()
                    .fill(theme.accent)
                    .frame(width: swatchSize - (isSelected ? ringWidth * 2 : 0),
                           height: swatchSize - (isSelected ? ringWidth * 2 : 0))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(theme.tint)
                            .frame(width: (swatchSize - (isSelected ? ringWidth * 2 : 0)) / 2,
                                   height: (swatchSize - (isSelected ? ringWidth * 2 : 0)) / 2)
                            .offset(x: -(isSelected ? ringWidth : 0), y: -(isSelected ? ringWidth : 0))
                            .blendMode(.normal)
                            .opacity(0.9)
                    }
                    .clipShape(Circle())
            }
            .frame(width: swatchSize + ringWidth * 2, height: swatchSize + ringWidth * 2)
            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.92, duration: Theme.Motion.fast))
        .accessibilityLabel(Text(theme.name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(Text(theme.brandNote ?? "切换为该主题"))
    }
}

// MARK: - 设置页里的「主题」行

/// 设置页的「主题」分组内容：当前主题名 + 解释文案 + 横向色块选择器。
///
/// 与 `SettingsRowButton` 风格保持一致：上方一行标题 + 右侧当前值，
/// 下方直接展开选择器（不弹 Sheet，避免键盘内又多一层模态）。
struct KMThemeSettingsRow: View {

    /// 当前主题。
    let currentTheme: AppTheme

    /// 点选回调。
    let onSelect: (AppTheme) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Text("🎨")
                    .font(Theme.fontBody)
                    .frame(width: Theme.Spacing.xxl, alignment: .leading)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("主题")
                        .font(Theme.fontBody)
                        .foregroundColor(Theme.textPrimary)
                    Text(currentTheme.brandNote ?? "跟随你的喜好换一套主色")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text(currentTheme.name)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(height: KMLayout.settingsRowHeight)

            KMThemePicker(selectedThemeID: currentTheme.id, onSelect: onSelect)
                .padding(.bottom, Theme.Spacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("主题，当前 \(currentTheme.name)"))
    }
}

#if DEBUG
/// 主题选择器预览宿主（仅 DEBUG）。
struct KMThemePickerPreviewHost: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            KMThemePicker(selectedThemeID: AppTheme.default.id) { _ in }
            KMThemeSettingsRow(currentTheme: AppTheme.default) { _ in }
        }
        .padding(.vertical)
        .background(Theme.keyboardBackground)
    }
}
#endif
