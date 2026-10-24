//
//  ThemePreviewCard.swift
//  墨语 · 宿主 App
//
//  模块职责：主题与形象页顶部的「等比缩小键盘示意图」。用纯 SwiftUI 画出极简键盘，
//  只让主色（theme.accent）出现在规范允许的 4 处：候选栏首选字背景、AI 工具条选中胶囊、
//  回车键、右下角形象。其余键帽/功能键/底色/文字全部取 theme 的 tint / tint2 / canvas / sub / deep。
//  依赖：SwiftUI、UIKit（仅用于把自定义形象 PNG 解成 UIImage）；Shared 层 `AppTheme`。
//  使用方：ThemeSettingsView。
//  规范依据：design/05-主题与小形象规范.md §1.1（主色只允许 4 处）、§3.2（形象 22pt）。
//

import SwiftUI
import UIKit

/// 等比缩小的键盘示意图，用来实时预览当前主题的配色效果。
///
/// 尺寸由外部 `.frame` 决定（推荐 320×212）；内部所有比例都按容器尺寸换算，
/// 所以换主题、换深色模式都不需要额外布局代码。
struct ThemePreviewCard: View {

    /// 当前预览的主题。
    let theme: AppTheme
    /// 自定义形象 PNG 数据（nil 时右下角画几何占位）。
    let mascotData: Data?
    /// 键盘右下角是否显示形象。
    let showsMascot: Bool

    /// 圆角：与真键盘键帽一致。
    private var keyRadius: CGFloat { Theme.Radius.key }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // 三段高度占比：候选栏 22%、AI 工具条 14%、键区占剩余。
            let candidateHeight = height * 0.22
            let aiBarHeight = height * 0.14

            VStack(spacing: 0) {
                candidateBar(height: candidateHeight)
                aiToolBar(height: aiBarHeight)
                keyPad(width: width, height: height - candidateHeight - aiBarHeight)
            }
            .frame(width: width, height: height)
            .background(theme.canvas)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(theme.name)主题的键盘预览"))
    }

    // MARK: - 候选栏

    /// 候选栏：底色 tint，第一个候选字用 accent 实底 + textOnAccent。
    private func candidateBar(height: CGFloat) -> some View {
        HStack(spacing: spacing(height: height)) {
            ForEach(0..<6, id: \.self) { index in
                Text(candidateSample(index))
                    .font(AppFont.chip)
                    .foregroundColor(index == 0 ? Theme.textOnAccent : theme.sub)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(minWidth: candidateMinWidth(height: height))
                    .frame(height: candidatePillHeight(height: height))
                    .background(
                        index == 0 ? theme.accent : Color.clear,
                        in: RoundedRectangle(cornerRadius: keyRadius * 0.6, style: .continuous)
                    )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, spacing(height: height))
        .frame(height: height)
        .background(theme.tint)
    }

    private func candidateSample(_ index: Int) -> String {
        let samples = ["可", "以", "好", "的", "不", "是"]
        return samples[index % samples.count]
    }

    private func candidateMinWidth(height: CGFloat) -> CGFloat {
        height * 0.9
    }

    private func candidatePillHeight(height: CGFloat) -> CGFloat {
        height * 0.62
    }

    // MARK: - AI 工具条

    /// AI 工具条：底色 tint，选中的胶囊用 accent 实底 + 白字，其余用 tint2 描边。
    private func aiToolBar(height: CGFloat) -> some View {
        HStack(spacing: spacing(height: height)) {
            ForEach(0..<3, id: \.self) { index in
                Text(aiSample(index))
                    .font(AppFont.chip)
                    .foregroundColor(index == 0 ? Theme.textOnAccent : theme.deep)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(height: height * 0.62)
                    .background(
                        index == 0 ? theme.accent : theme.tint2,
                        in: Capsule(style: .continuous)
                    )
            }
            Spacer(minLength: 0)
            IconGlyph(symbol: "sparkles", size: AppMetrics.glyphSizeSmall, tint: theme.deep)
        }
        .padding(.horizontal, spacing(height: height))
        .frame(height: height)
        .background(theme.tint)
    }

    private func aiSample(_ index: Int) -> String {
        let samples = ["润色", "扩写", "翻译"]
        return samples[index % samples.count]
    }

    // MARK: - 键区

    /// 键区：普通键帽用 keyBackground，功能键用 keyFunctionBackground，回车键用 accent。
    ///
    /// 前三行按 10 等分；**底行按 `Theme.Sizing` 的真实键宽权重排布**
    /// （功能键 42 / 字母键 33 × 7 / 形象格 30 / 回车键 88），
    /// 这样回车键约为字母键的 2.7 倍宽，与键盘规范的比例一致，不会画成方块。
    private func keyPad(width: CGFloat, height: CGFloat) -> some View {
        let gap = spacing(height: height)
        let rows = 4
        let rowHeight = (height - gap * CGFloat(rows + 1)) / CGFloat(rows)

        return VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<10, id: \.self) { column in
                        letterKey(row: row, column: column, width: width, height: rowHeight, gap: gap)
                    }
                }
            }
            bottomRow(width: width, height: rowHeight, gap: gap)
        }
        .padding(gap)
    }

    /// 上三行的单个字母键（等宽）。
    private func letterKey(row: Int, column: Int, width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        let keyWidth = (width - gap * 11) / 10
        return ZStack {
            keyBackground(isAccent: false, isFunction: false)
            Text(letterLabel(row: row, column: column))
                .font(AppFont.chip)
                .foregroundColor(theme.deep)
                .minimumScaleFactor(0.6)
        }
        .frame(width: keyWidth, height: height)
    }

    /// 底行：功能键 + 7 个字母 + 形象格 + 回车键，宽度按 `Theme.Sizing` 的权重分配。
    private func bottomRow(width: CGFloat, height: CGFloat, gap: CGFloat) -> some View {
        // 形象格宽 30pt（design/05 §3.2），由间距令牌组合而来，不引裸数值。
        let mascotWeight = Theme.Spacing.xl * 2 - Theme.Spacing.xs
        let totalWeight = Theme.Sizing.functionKeyWidth
            + Theme.Sizing.letterKeyWidth * 7
            + mascotWeight
            + Theme.Sizing.returnKeyWidth
        let unit = (width - gap * 4) / totalWeight

        return HStack(spacing: gap) {
            ZStack {
                keyBackground(isAccent: false, isFunction: true)
                IconGlyph(symbol: "shift.fill", size: AppMetrics.glyphSizeSmall, tint: theme.sub)
            }
            .frame(width: Theme.Sizing.functionKeyWidth * unit, height: height)

            ForEach(0..<7, id: \.self) { index in
                ZStack {
                    keyBackground(isAccent: false, isFunction: false)
                    Text(bottomLetter(index))
                        .font(AppFont.chip)
                        .foregroundColor(theme.deep)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: Theme.Sizing.letterKeyWidth * unit, height: height)
            }

            ZStack {
                if showsMascot {
                    mascotView
                } else {
                    keyBackground(isAccent: false, isFunction: false)
                }
            }
            .frame(width: mascotWeight * unit, height: height)

            ZStack {
                keyBackground(isAccent: true, isFunction: false)
                Text("换行")
                    .font(AppFont.chip)
                    .foregroundColor(Theme.textOnAccent)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: Theme.Sizing.returnKeyWidth * unit, height: height)
        }
    }

    /// 键帽底板：圆角 + 细描边；accent 用于回车键，tint2 用于功能键。
    @ViewBuilder
    private func keyBackground(isAccent: Bool, isFunction: Bool) -> some View {
        RoundedRectangle(cornerRadius: keyRadius * 0.5, style: .continuous)
            .fill(isAccent ? theme.accent : (isFunction ? theme.tint2 : Theme.keyBackground))
            .overlay(
                RoundedRectangle(cornerRadius: keyRadius * 0.5, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.35), lineWidth: AppMetrics.hairline)
            )
    }

    private func letterLabel(row: Int, column: Int) -> String {
        let letters = ["QWERTYUIOP", "ASDFGHJKLZ", "ZXCVBNMASD"]
        guard row < letters.count else { return "" }
        let line = Array(letters[row])
        return String(line[column % line.count])
    }

    private func bottomLetter(_ index: Int) -> String {
        let letters = Array("ZXCVBNM")
        guard index < letters.count else { return "" }
        return String(letters[index])
    }

    // MARK: - 右下角形象

    /// 右下角形象：有自定义图就画图，否则用几何符号（规范要求默认形象不能是第三方素材）。
    @ViewBuilder
    private var mascotView: some View {
        if let data = mascotData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .padding(AppMetrics.hairGap)
        } else {
            IconGlyph(
                symbol: "theatermasks.fill",
                size: AppMetrics.glyphSize,
                tint: theme.accent
            )
        }
    }

    // MARK: - 比例工具

    /// 统一间距：按容器高度取比例，保证任意尺寸下都不拥挤。
    private func spacing(height: CGFloat) -> CGFloat {
        max(AppMetrics.hairGap, height * 0.012)
    }
}

#if DEBUG
struct ThemePreviewCard_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ThemePreviewCard(
                theme: AppTheme.default,
                mascotData: nil,
                showsMascot: true
            )
            .frame(width: 320, height: 212)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

            ThemePreviewCard(
                theme: AppTheme.preset(.coral),
                mascotData: nil,
                showsMascot: false
            )
            .frame(width: 320, height: 212)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .padding()
        .background(AppColor.pageBackground)
    }
}
#endif
