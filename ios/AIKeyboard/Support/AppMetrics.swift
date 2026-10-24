//
//  AppMetrics.swift
//  墨语 · 宿主 App
//
//  宿主 App 侧的派生度量、字体与颜色。
//
//  设计约束（docs/02 §5、验收闸门 2）：**所有颜色 / 字号 / 间距都必须来自 `Theme`**。
//  `Theme` 已经提供 tokens.json 的全部刻度（Spacing / Radius / Sizing / Motion / Shadow / 字体），
//  所以本文件只做两步：
//    1) 用 `Theme` 的原生符号直接别名化，让页面读起来语义清晰；
//    2) 少数 tokens 里有、`Theme` 没暴露的合成量（按钮高度、列表行高、头像尺寸…）用
//       **令牌组合**表达，绝不在视图里写裸数值。
//
//  对齐来源：`design/tokens.json` v1.0 + `design/组件库.md` v1.0。
//
import SwiftUI

/// 页面级派生度量：优先直接引用 `Theme` 令牌，其次用令牌组合。
enum AppMetrics {

    // MARK: - 间距（tokens.spacing）

    /// 页面左右外边距（tokens: spacing.screenMargin = 16）
    static let pageInset: CGFloat = Theme.Spacing.screenMargin

    /// 卡片内边距（tokens: spacing.xl = 16）
    static let cardPadding: CGFloat = Theme.Spacing.xl

    /// 大分组之间的间距（tokens: spacing.sectionGap = 28）
    static let sectionGap: CGFloat = Theme.Spacing.sectionGap

    /// 极大间隔（tokens: spacing.xxxl = 32）
    static let heroGap: CGFloat = Theme.Spacing.xxxl

    /// 普通视图块之间的间距（tokens: spacing.md = 8）
    static let blockGap: CGFloat = Theme.Spacing.md

    /// 列表行上下内边距（tokens: spacing.lg = 12）
    static let rowVPadding: CGFloat = Theme.Spacing.lg

    /// 行内元素（图标 / 文本 / 附件）间距（tokens: spacing.lg = 12）
    static let rowGap: CGFloat = Theme.Spacing.lg

    /// 紧凑间距（tokens: spacing.sm = 4）
    static let tightGap: CGFloat = Theme.Spacing.sm

    /// 极紧凑间距（tokens: spacing.xs = 2）
    static let hairGap: CGFloat = Theme.Spacing.xs

    // MARK: - 尺寸

    /// 列表左侧图标列宽（12 * 2 = 24）
    static let iconColumn: CGFloat = Theme.Spacing.lg * 2

    /// 首屏 / 空态大图标尺寸（= tokens.adornment 48，用 spacing 组合）
    static let heroIcon: CGFloat = Theme.Spacing.xl * 3

    /// 中号图标尺寸（16 * 1.5 = 24）
    static let mediumIcon: CGFloat = Theme.Spacing.xl * 1.5

    /// 圆形徽标的直径（16 * 2 = 32）
    static let badgeSize: CGFloat = Theme.Spacing.xl * 2

    /// 列表行最小高度（tokens: spacing.rowMinHeight = 44）
    static let minTapHeight: CGFloat = Theme.Spacing.rowMinHeight

    /// 分隔线粗细（tokens: material.strokeWidth = 0.5）
    static let hairline: CGFloat = Theme.MaterialToken.strokeWidth

    /// 头像 / 预览缩略图的方形边长 40
    static let thumbnailSize: CGFloat = Theme.Spacing.xl * 2 + Theme.Spacing.md

    // MARK: - 圆角（tokens.radius）

    /// 卡片圆角（tokens: radius.card = 16）
    static let cardRadius: CGFloat = Theme.Radius.card

    /// 胶囊按钮（tokens: radius.capsule）
    static let capsuleRadius: CGFloat = Theme.Radius.capsule

    /// Sheet 圆角（tokens: radius.sheet = 24）
    static let sheetRadius: CGFloat = Theme.Radius.sheet

    /// 控件圆角（tokens: radius.control = 10）
    static let controlRadius: CGFloat = Theme.Radius.control

    /// 缩略图圆角（tokens: radius.thumbnail = 12）
    static let thumbnailRadius: CGFloat = Theme.Radius.thumbnail

    /// 极小圆角（tokens: radius.small = 6）
    static let smallRadius: CGFloat = Theme.Radius.small

    /// 胶囊形标签圆角（tokens: radius.chip = 14）
    static let chipRadius: CGFloat = Theme.Radius.chip

    // MARK: - 控件尺寸（对齐 design/组件库.md 的固定高度）

    /// 胶囊 chip 高 30（tool / tone）
    static let chipHeight: CGFloat = Theme.Sizing.aiChipHeight

    /// Provider 预设 chip 高 32
    static let chipHeightProvider: CGFloat = Theme.Spacing.xl * 2

    /// 只读标签 chip 高 22
    static let chipHeightTag: CGFloat = Theme.Spacing.xl + Theme.Spacing.md - Theme.Spacing.xs

    /// 大按钮高 50
    static let buttonLargeHeight: CGFloat = Theme.Spacing.xl * 3 + Theme.Spacing.xs

    /// 中按钮高 44（= 最小可点高度）
    static let buttonMediumHeight: CGFloat = Theme.Spacing.rowMinHeight

    /// 小按钮高 36
    static let buttonSmallHeight: CGFloat = Theme.Spacing.xl * 2 + Theme.Spacing.sm

    /// 单行设置行高 44
    static let rowHeightSingle: CGFloat = Theme.Spacing.rowMinHeight

    /// 带副标题的设置行高 60
    static let rowHeightSubtitle: CGFloat = Theme.Spacing.xl * 3 + Theme.Spacing.lg

    /// Provider 列表项高 68
    static let providerRowHeight: CGFloat = Theme.Spacing.xl * 4 + Theme.Spacing.sm

    /// Provider 字母标 40×40
    static let providerAvatar: CGFloat = Theme.Spacing.xl * 2 + Theme.Spacing.md

    /// 步骤卡序号圆直径 28
    static let stepIndexSize: CGFloat = Theme.Spacing.xl + Theme.Spacing.lg

    /// 分组标题行高 34
    static let sectionHeaderHeight: CGFloat = Theme.Spacing.xl * 2 + Theme.Spacing.xs

    /// 胶囊内图标与文字的间距 5（契约 §2.1：图标 13pt + 间距 5）
    static let chipIconGap: CGFloat = Theme.Spacing.sm + Theme.Spacing.xs / 2

    /// 空态图标底盒 72×72
    static let emptyIconBox: CGFloat = Theme.Spacing.xl * 4 + Theme.Spacing.md

    /// 设置行左侧色块图标 28×28
    static let iconTileSize: CGFloat = Theme.Spacing.xl + Theme.Spacing.lg

    /// 设置行色块圆角 7
    static let iconTileRadius: CGFloat = Theme.Radius.small + Theme.Spacing.xs / 2

    /// 组件库 IconGlyph 默认字号 17（= tokens typography.headline）
    static let glyphSize: CGFloat = Theme.Spacing.xl + Theme.Spacing.xs / 2

    /// 默认图标字号 15（= tokens typography.body）
    static let glyphSizeSmall: CGFloat = Theme.Spacing.xl - Theme.Spacing.xs / 2

    /// 大图标字号 44（空态图标）
    static let glyphSizeLarge: CGFloat = Theme.Spacing.xl * 3 - Theme.Spacing.sm

    /// 设置行图标列宽 56（图标 28 + 间距 12 + 16）
    static let settingsIconColumn: CGFloat = Theme.Spacing.xl * 3 + Theme.Spacing.md

    /// AI 结果卡头高 28
    static let resultHeaderHeight: CGFloat = Theme.Spacing.xl + Theme.Spacing.lg

    /// AI 结果卡动作条高 44
    static let resultActionHeight: CGFloat = Theme.Sizing.resultActionHeight + Theme.Spacing.md

    /// 流式文本最大高度 132
    static let streamingMaxHeight: CGFloat = Theme.Spacing.xl * 8 + Theme.Spacing.sm

    /// 生图进度环直径 48
    static let progressRingSize: CGFloat = Theme.Spacing.xl * 3

    /// 图片结果缩略图最大宽 160
    static let imageMaxWidth: CGFloat = Theme.Spacing.xl * 10

    /// 图片结果缩略图最大高 120
    static let imageMaxHeight: CGFloat = Theme.Spacing.xl * 7 + Theme.Spacing.md

    /// Sheet 标题栏高 52（tokens: sizing.navBarHeight 44 + 抓手区）
    static let sheetHeaderHeight: CGFloat = Theme.Spacing.xxxl + Theme.Spacing.xxl - Theme.Spacing.sm

    /// 引导页标题字号 28（tokens: typography 无 28，用 spacing 组合表达）
    static let onboardingTitleSize: CGFloat = Theme.Spacing.xxl + Theme.Spacing.sm

    /// 引导页大图标字号 48
    static let onboardingIconSize: CGFloat = Theme.Spacing.xl * 3

    /// 引导页图标底框 120
    static let onboardingIconBox: CGFloat = Theme.Spacing.xl * 7 + Theme.Spacing.md

    /// 引导页图标底框圆角 28
    static let onboardingIconRadius: CGFloat = Theme.Radius.card + Theme.Spacing.lg

    /// 分段控件高 36
    static let segmentedHeight: CGFloat = Theme.Spacing.xl * 2 + Theme.Spacing.sm

    /// 表单控件高 44
    static let fieldHeight: CGFloat = Theme.Spacing.rowMinHeight

    /// 步骤卡片之间连接线的高度 12
    static let stepConnectorHeight: CGFloat = Theme.Spacing.lg

    /// 步骤卡代码块圆角 8
    static let codeBlockRadius: CGFloat = Theme.Radius.key

    /// 编辑器文本域最小高度 120
    static let textEditorMinHeight: CGFloat = Theme.Spacing.xl * 7 + Theme.Spacing.md

    /// 输入框最小高度 120（试验场）
    static let playgroundInputHeight: CGFloat = Theme.Spacing.xl * 7 + Theme.Spacing.md

    /// App 图标展示尺寸 96
    static let appIconShowcase: CGFloat = Theme.Spacing.xl * 6

    /// App 图标圆角 22
    static let appIconShowcaseRadius: CGFloat = Theme.Radius.card + Theme.Radius.small

    /// 自检状态点直径 10
    static let statusDotSize: CGFloat = Theme.Spacing.md + Theme.Spacing.xs

    /// 自检状态点内圈直径 6
    static let statusDotCore: CGFloat = Theme.Spacing.sm + Theme.Spacing.xs

    // MARK: - 动效

    /// 快速动效时长（tokens: motion.fast = 0.15）
    static let fast = Theme.Motion.fast

    /// 标准动效时长（tokens: motion.normal = 0.25）
    static let normal = Theme.Motion.normal

    /// 弹簧动画（tokens: motion.springDuration 0.35 / springDamping 0.82）
    static let spring: Animation = Theme.Motion.spring

    // MARK: - 阴影

    /// 卡片阴影（tokens: shadow.card）
    static let cardShadow = Theme.Shadow.card

    /// 胶囊阴影（tokens: shadow.chip）
    static let chipShadow = Theme.Shadow.chip
}

/// 宿主 App 侧字体：绝大多数直接引用 `Theme` 的字体令牌。
enum AppFont {

    /// 首屏大标题（token: largeTitle 34 bold）
    static let largeTitle: Font = Theme.fontLargeTitle

    /// 页面标题（token: title 20 semibold）
    static let pageTitle: Font = Theme.fontTitle

    /// 卡片标题 / 列表主文本（token: headline 17 semibold）
    static let headline: Font = Theme.fontHeadline

    /// 正文（token: body 15）
    static let body: Font = Theme.fontBody

    /// 说明文字（token: caption 12）
    static let caption: Font = Theme.fontCaption

    /// 辅助说明（token: footnote 13）
    static let footnote: Font = Theme.fontFootnote

    /// 强调说明文字（footnote 加权重）
    static let footnoteStrong: Font = Theme.fontFootnote.weight(.medium)

    /// 胶囊文字（token: chip 13 medium）
    static let chip: Font = Theme.fontChip

    /// 按钮文字（token: button 17 semibold）
    static let button: Font = Theme.fontButton

    /// 统计数字
    static let number: Font = Theme.fontTitle.weight(.bold)

    /// AI 结果正文（token: result 16）
    static let result: Font = Theme.fontResult

    /// 候选字号（键盘域，宿主预览用）
    static let candidate: Font = Theme.fontCandidate

    /// 等宽字体（JSON 预览、路径、命令行；token: monoDigit）
    static let monospaced: Font = Theme.fontMonoDigit

    /// 等宽脚注（诊断报告）
    static let monospacedFootnote: Font = .system(.footnote, design: .monospaced)

    /// 等宽正文
    static let monospacedBody: Font = .system(.body, design: .monospaced)
}

/// 宿主 App 侧派生颜色：全部由 `Theme` 颜色得到，禁止硬编码 hex。
enum AppColor {

    /// 页面背景（tokens: bg.surfaceGrouped）
    static let pageBackground: Color = Theme.surfaceGrouped

    /// 卡片背景（tokens: bg.surface）
    static let cardBackground: Color = Theme.surface

    /// 卡片描边（tokens: separator.opaque）
    static let cardStroke: Color = Theme.separatorOpaque

    /// 强调色浅底（tokens: accent.soft）
    static let accentWash: Color = Theme.accentSoft

    /// 成功浅底
    static let successWash: Color = Theme.successSoft

    /// 警告浅底
    static let warningWash: Color = Theme.warningSoft

    /// 危险浅底
    static let dangerWash: Color = Theme.dangerSoft

    /// 玻璃材质上的描边（比普通分隔线更淡）
    static let glassStroke: Color = Theme.separator.opacity(0.7)

    /// 遮罩层（tokens: overlay.scrim）
    static let scrim: Color = Theme.overlayScrim

    /// 强调色底上的文字（tokens: text.onAccent）
    static let onAccent: Color = Theme.textOnAccent

    /// 强调色块上的次级文字
    static let onAccentSecondary: Color = Theme.textOnAccent.opacity(0.78)

    /// 胶囊 / 工具条底（tokens: chip.bg）
    static let chipFill: Color = Theme.chipBackground

    /// 胶囊按下态（tokens: chip.bg.pressed）
    static let chipFillPressed: Color = Theme.chipBackgroundPressed

    /// 胶囊描边（tokens: chip.border）
    static let chipBorder: Color = Theme.chipBorder

    /// 胶囊内文字（tokens: chip.text）
    static let chipText: Color = Theme.chipText

    /// 玻璃高光顶部（tokens: material.highlight，浅深两套都是固定白 25%）
    static let highlightTop: Color = Theme.textOnAccent.opacity(0.25)

    /// 玻璃高光底部（同色系全透明）
    static let highlightBottom: Color = Theme.textOnAccent.opacity(0)
}
