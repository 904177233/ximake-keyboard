//
//  KMLayout.swift
//  墨语（Moyu）键盘扩展 · 派生布局度量
//
//  模块职责：把 Theme.Sizing / Theme.Spacing / Theme.Radius 换算成键盘布局所需的全部尺寸。
//  设计依据：design/键盘布局规范.md §1–§4、§10（LayoutMetrics 常量块）。
//  约束：本文件不新增设计数值，尽量全部由 Theme 派生；只有设计规范里给出的
//        几何常量（如基准屏宽 390、空格键基准宽 194）以派生表达式写出。
//

import CoreGraphics

/// 键盘布局度量（纯计算，无状态）。
enum KMLayout {

    // MARK: - 横向

    /// 设计基准屏宽（iPhone 14 / 390pt）。
    static let baselineWidth: CGFloat = 390

    /// 屏幕左右留白：规范 §2「左右严格 3pt」。
    static let screenPadding: CGFloat = Theme.Sizing.keyHorizontalPadding

    /// 键横向间距。
    static let keyGap: CGFloat = Theme.Sizing.keyGap

    /// 基准内容宽度 384 = 390 − 3 × 2。
    static let contentWidthBaseline: CGFloat = baselineWidth - screenPadding * 2

    /// 基准字母键宽 33 = (384 − 9 × 6) / 10。
    static let letterKeyWidthBaseline: CGFloat = Theme.Sizing.letterKeyWidth

    /// 功能键基准宽度（Shift / 退格 / 地球 / 表情）。
    static let functionKeyWidth: CGFloat = Theme.Sizing.functionKeyWidth

    /// 回车键基准宽度。
    static let returnKeyWidth: CGFloat = Theme.Sizing.returnKeyWidth

    /// 空格键基准宽度 194 = 384 − 42 × 2 − 88 − 6 × 3。
    static let spaceBarWidthBaseline: CGFloat =
        contentWidthBaseline - functionKeyWidth * 2 - returnKeyWidth - keyGap * 3

    /// 9 键主键宽度 124 = (384 − 6 × 2) / 3。
    static let nineKeyWidthBaseline: CGFloat = (contentWidthBaseline - keyGap * 2) / 3

    // MARK: - 纵向

    /// 键帽视觉高度 39。
    static let letterRowHeight: CGFloat = Theme.Sizing.letterRowHeight

    /// 最小命中高度 44（视觉 39 + 上下各 2.5 的透明命中区）。
    static let keyHitHeight: CGFloat = Theme.Sizing.minTapTarget

    /// 单行上下各外扩的命中区高度（44 − 39) / 2 = 2.5。
    static let rowHitOverflow: CGFloat = (keyHitHeight - letterRowHeight) / 2

    /// 字母行行距（43.5 ≈ 39 + 6），仅横屏使用 34.5。
    static let rowPitch: CGFloat = letterRowHeight + keyGap

    /// 横屏行高 34.5（Theme 提供）。
    static let landscapeRowHeight: CGFloat = Theme.Sizing.letterRowPitchLandscape

    /// 键区总高 174 = 4 × 39 + 3 × 6。
    static let keyRowsHeight: CGFloat =
        letterRowHeight * CGFloat(Theme.Sizing.keyboardRowCount)
        + keyGap * CGFloat(Theme.Sizing.keyboardRowCount - 1)

    /// 候选栏高度。
    static let candidateBarHeight: CGFloat = Theme.Sizing.candidateBarHeight

    /// AI 工具条高度。
    static let aiBarHeight: CGFloat = Theme.Sizing.aiBarHeight

    /// 候选栏 + AI 工具条共用的连续玻璃背景高度（规范 §8 ④：先铺 84 再放两行）。
    static let chromeHeight: CGFloat = candidateBarHeight + aiBarHeight

    /// 键盘基础高度（竖屏 258 = 44 + 40 + 174）。
    static let portraitHeight: CGFloat = Theme.Sizing.keyboardHeightPortrait

    /// 键盘基础高度（横屏 200 = 44 + 4 × 34.5 + 3 × 6）。
    static let landscapeHeight: CGFloat = Theme.Sizing.keyboardHeightLandscape

    /// AI 面板展开增量 168。
    static let aiPanelExtraHeight: CGFloat = Theme.Sizing.aiPanelExtraHeight

    /// 结果卡片展开增量 180。
    static let resultExtraHeight: CGFloat = Theme.Sizing.resultExtraHeight

    /// 横屏展开增量 140（规范 §1.3：横屏 200 → 340）。
    static let landscapeExtraHeight: CGFloat =
        CGFloat(340) - landscapeHeight

    // MARK: - AI 面板（规范 §4.4）

    /// 面板上边距 8。
    static let panelTopPadding: CGFloat = Theme.Spacing.md

    /// 面板下边距 12。
    static let panelBottomPadding: CGFloat = Theme.Spacing.lg

    /// 面板分组间距 8。
    static let panelRowGap: CGFloat = Theme.Spacing.md

    /// 输入框高度 44。
    static let panelInputHeight: CGFloat = Theme.Sizing.aiPanelInputHeight

    /// 语气行高度 44。
    static let panelToneRowHeight: CGFloat = Theme.Sizing.aiPanelToneRowHeight

    /// 生成按钮高度 44。
    static let panelActionHeight: CGFloat = Theme.Sizing.minTapTarget

    // MARK: - 结果卡片（规范 §4.5）

    /// 结果区域内边距 8。
    static let resultPadding: CGFloat = Theme.Spacing.md

    /// 卡片高度 164 = 28 + 92 + 44。
    static let resultCardHeight: CGFloat =
        Theme.Sizing.resultCardHeight - resultPadding * 2

    /// 卡片左右边距 8。
    static let resultCardSideInset: CGFloat = Theme.Spacing.md

    /// header 高 28。
    static let resultHeaderHeight: CGFloat = Theme.Spacing.sectionGap

    /// 正文区高 92。
    static let resultBodyHeight: CGFloat = resultCardHeight - resultHeaderHeight - Theme.Sizing.minTapTarget

    /// 动作条高 44。
    static let resultActionHeight: CGFloat = Theme.Sizing.minTapTarget

    // MARK: - 设置面板（规范 §4.6）

    /// 设置列表行高 44。
    static let settingsRowHeight: CGFloat = Theme.Spacing.rowMinHeight

    /// 设置头部高 52。
    static let settingsHeaderHeight: CGFloat = Theme.Sizing.largeTitleHeight

    // MARK: - 方法

    /// 指定宽度下的字母键宽；390pt 时正好 33。
    /// - Parameter width: 键盘可用宽度。
    /// - Returns: 单键宽度（不小于 1）。
    static func letterKeyWidth(forWidth width: CGFloat) -> CGFloat {
        let content = max(width - screenPadding * 2, 0)
        return max((content - keyGap * 9) / 10, 1)
    }

    /// 指定宽度下空格键宽度（随容器伸缩）。
    /// - Parameter width: 键盘可用宽度。
    /// - Returns: 空格键宽度。
    static func spaceBarWidth(forWidth width: CGFloat) -> CGFloat {
        let content = max(width - screenPadding * 2, 0)
        return max(content - functionKeyWidth * 2 - returnKeyWidth - keyGap * 3, 1)
    }

    /// 指定宽度下数字页数字键宽度 108 = (384 − 42 − 3 × 6) / 3。
    /// - Parameter width: 键盘可用宽度。
    /// - Returns: 数字键宽度。
    static func numberKeyWidth(forWidth width: CGFloat) -> CGFloat {
        let content = max(width - screenPadding * 2, 0)
        return max((content - functionKeyWidth - keyGap * 3) / 3, 1)
    }

    /// 横屏字母键宽（规范 §1.3：W × 0.76 − 54 后除以 10）。
    /// - Parameter width: 横屏键盘宽度。
    /// - Returns: 横屏单键宽度。
    static func landscapeKeyWidth(forWidth width: CGFloat) -> CGFloat {
        max((width * 0.76 - keyGap * 9) / 10, 1)
    }

    /// 横屏左右留白 = (W − 10 × keyW − 9 × gap) / 2。
    /// - Parameter width: 横屏键盘宽度。
    /// - Returns: 左右各留白。
    static func landscapeSideInset(forWidth width: CGFloat) -> CGFloat {
        max((width - landscapeKeyWidth(forWidth: width) * 10 - keyGap * 9) / 2, 0)
    }

    /// 9 键主键宽度。
    /// - Parameter width: 键盘可用宽度。
    /// - Returns: 九宫格主键宽度。
    static func nineKeyWidth(forWidth width: CGFloat) -> CGFloat {
        let content = max(width - screenPadding * 2, 0)
        return max((content - keyGap * 2) / 3, 1)
    }

    /// 键盘目标高度。
    /// - Parameters:
    ///   - isLandscape: 是否横屏。
    ///   - page: 当前页面。
    ///   - safeAreaBottom: 底部安全区（仅竖屏叠加）。
    /// - Returns: `inputView` 高度约束的目标值。
    static func keyboardHeight(isLandscape: Bool, page: KeyboardViewModel.Page, safeAreaBottom: CGFloat) -> CGFloat {
        if isLandscape {
            switch page {
            case .aiPanel, .settings, .result:
                return landscapeHeight + landscapeExtraHeight
            default:
                return landscapeHeight
            }
        }
        var height = portraitHeight
        switch page {
        case .aiPanel:
            height += aiPanelExtraHeight
        case .result:
            height += resultExtraHeight
        case .settings:
            height += aiPanelExtraHeight
        default:
            break
        }
        return height + safeAreaBottom
    }
}
