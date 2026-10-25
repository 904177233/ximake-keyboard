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
import Foundation

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

    /// 候选栏高度（单行效用行，v1.3 起与 AI 工具条共用）。
    static let candidateBarHeight: CGFloat = Theme.Sizing.candidateBarHeight

    /// 效用行高度 44 —— 候选条与 AI 工具条共用**同一行**，二选一显示。
    ///
    /// v1.3 交互改造（用户反馈「候选词状态栏一直都在，非常影响正常打字」）：
    /// 组字中显示候选，未组字显示 AI 工具，交叉淡入淡出，不再上下叠两行。
    static let utilityRowHeight: CGFloat = Theme.Sizing.utilityRowHeight

    /// AI 工具条高度（= 效用行高度，保留名字兼容旧调用点）。
    static let aiBarHeight: CGFloat = utilityRowHeight

    /// 效用行高度（旧名 `chromeHeight` 保留，语义已从「候选栏 + 工具条 84」变为「一行 44」）。
    static let chromeHeight: CGFloat = utilityRowHeight

    /// 键盘基础高度（竖屏 **218** = 44 效用行 + 174 键区）。
    ///
    /// v1.3 起由「效用行 44 + 键区 174」两段算出，而不是直接取
    /// `Theme.Sizing.keyboardHeightPortrait` —— 后者是 v1 的 258（44 候选栏 + 40 工具条 + 174），
    /// 仍被 `consistency_check` 的 REQUIRED_SIZING 与 docs/02 §5 钉死为契约值，不能改；
    /// 实际布局按合并后的一行算，比 v1 省 40pt（还给宿主 App）。
    static let portraitHeight: CGFloat = utilityRowHeight + keyRowsHeight

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

    // MARK: - AI 对话面板（design/04-AI对话与智能联想规范.md §6.1）
    //
    // 说明：以下 15 个 sizing 与 3 个 motion 常量已写入 `design/tokens.json`（313 叶子），
    // 但 `ios/Shared/Theme/Theme.swift` 的对应令牌由 ai-service 维护，本文件暂以派生/字面量
    // 形式落地（每行标 `// TOKEN:`），待 Theme.Sizing / Theme.Motion 补齐同名令牌后
    // 可无痛改为直连，视图侧无需改动。

    /// 34 —— 旋钮视觉圆直径（竖屏）。
    static let aiChatKnobSize: CGFloat = 34  // TOKEN: sizing.aiChatKnobSize

    /// 32 —— 旋钮视觉圆直径（横屏，规范 §2.1「横屏 32」）。
    ///
    /// 由 `aiChatKnobSize − 2` 派生而非独立令牌：`tokens.json` 的 `sizing` 组里没有这一项，
    /// 硬写 `// TOKEN:` 会让一致性检查指向一个不存在的键（v1.1 收尾时按规范 §6 的备选方案改派生）。
    static let aiChatKnobLandscapeSize: CGFloat = aiChatKnobSize - 2

    /// 44 —— 旋钮命中区边长（横竖屏恒 44）。
    static let aiChatKnobHitSize: CGFloat = Theme.Sizing.minTapTarget

    /// 8 —— 旋钮右边距。
    static let aiChatKnobInset: CGFloat = Theme.Spacing.md

    /// 16 —— 旋钮图标的绘制框边长（16×16 坐标系）。
    static let aiChatKnobGlyphSize: CGFloat = Theme.Spacing.xl

    /// 40 —— 对话面板标题条高度。
    static let aiChatTopBarHeight: CGFloat = 40  // TOKEN: sizing.aiChatTopBarHeight

    /// 32 —— 横屏标题条高度（规范 §3.11）。
    static let aiChatLandscapeTopBarHeight: CGFloat = 32  // TOKEN: sizing.aiChatTopBarHeight - 8

    /// 180 —— 对话消息区高度（竖屏）。
    static let aiChatMessageHeight: CGFloat = 180  // TOKEN: sizing.aiChatMessageHeight

    /// 108 —— 对话消息区高度（横屏，规范 §3.11「消息区 108 只能显示 1–2 条，属可接受降级」）。
    static let aiChatLandscapeMessageHeight: CGFloat = 108  // TOKEN: design §3.11

    /// 156 —— 横屏键区总高 = 4 × 34.5 + 3 × 6（规范 §3.11）。
    ///
    /// 竖屏 `keyRowsHeight` 是 174 = 4 × 39 + 3 × 6；横屏行高降到 34.5，
    /// 若不换这个值，横屏对话页的 340 会被四段分区撑爆（40+180+44+174 = 438）。
    static let landscapeKeyRowsHeight: CGFloat =
        landscapeRowHeight * CGFloat(Theme.Sizing.keyboardRowCount)
        + keyGap * CGFloat(Theme.Sizing.keyboardRowCount - 1)

    /// 44 —— 对话输入行高度（= 候选栏高度，组合态原地换候选行不跳高）。
    static let aiChatInputHeight: CGFloat = Theme.Sizing.candidateBarHeight

    /// 36 —— 发送按钮直径。
    static let aiChatSendSize: CGFloat = 36  // TOKEN: sizing.aiChatSendSize

    /// 16 —— 气泡圆角。
    static let aiChatBubbleCorner: CGFloat = Theme.Radius.card

    /// 32 —— 最新 AI 消息操作行高度。
    static let aiChatActionHeight: CGFloat = 32  // TOKEN: sizing.aiChatActionHeight

    /// 220 —— 对话面板展开增量。
    ///
    /// 对话页隐藏 44pt 效用行，四段分区固定 `40 + 180 + 44 + 174 = 438`；
    /// 竖屏基础高 v1.3 起为 218（不再含 84pt 双行 chrome），故增量 = 438 − 218 = 220。
    static let aiChatExtraHeight: CGFloat = 220  // TOKEN: 派生值 438 − portraitHeight

    /// 30 —— 联想胶囊高度。
    static let sugChipHeight: CGFloat = Theme.Sizing.aiChipHeight

    /// 8 —— 联想胶囊间距。
    static let sugChipGap: CGFloat = Theme.Sizing.aiChipGap

    /// 3 —— 联想胶囊最多条数。
    static let sugChipMaxCount: Int = 3  // TOKEN: sizing.sugChipMaxCount

    /// 12 —— 联想胶囊每条最大字数。
    static let sugChipMaxChars: Int = 12  // TOKEN: sizing.sugChipMaxChars

    /// 0.35 —— 联想防抖（秒）。
    static let suggestDebounce: TimeInterval = 0.35  // TOKEN: motion.suggestDebounce

    /// 3.0 —— 联想节流（秒）：两次请求之间的最小间隔。
    static let suggestThrottle: TimeInterval = 3.0  // TOKEN: design §4.4 ④

    /// 1.5 —— 联想超时（秒）：超过即放弃，静默不显示。
    ///
    /// 规范 §6 采纳「方案 A」：不新增 `suggestTimeout` 令牌，此处以具名常量落地。
    static let suggestTimeout: TimeInterval = 1.5

    /// 0.08 —— 旋钮按下动效时长。
    static let knobPress: TimeInterval = Theme.Motion.keyPress

    /// 0.15 —— 旋钮反色渐变时长。
    static let knobActiveFade: TimeInterval = Theme.Motion.fast

    /// 对话面板总高（竖屏 438 = 40 + 180 + 44 + 174）。
    static let aiChatHeight: CGFloat = portraitHeight + aiChatExtraHeight

    /// 对话面板总高（横屏 340 = 32 + 108 + 44 + 156）。
    static let aiChatLandscapeHeight: CGFloat = landscapeHeight + landscapeExtraHeight

    // MARK: - 主题与小形象（design/05 §3.2）

    /// 22 —— 小形象符号视觉尺寸（竖屏）。
    static let mascotVisualSize: CGFloat = 22  // TOKEN: theme.mascot.visualSizePortrait

    /// 18 —— 小形象符号视觉尺寸（横屏）。
    static let mascotVisualSizeLandscape: CGFloat = 18  // TOKEN: theme.mascot.visualSizeLandscape

    /// 30 —— 底行小形象角落格宽度（竖屏）。
    static let mascotCornerWidth: CGFloat = 30  // TOKEN: theme.mascot.cornerCellWidthPortrait

    /// 26 —— 底行小形象角落格宽度（横屏）。
    static let mascotCornerWidthLandscape: CGFloat = 26  // TOKEN: theme.mascot.cornerCellWidthLandscape

    /// 156 —— 有小形象时空格键宽度（design/05 §3.2 给的基准值）。
    ///
    /// 说明：底行 `42 + 42 + 156 + 88 + 30 + 6 × 4 = 382`，比内容宽 384 少 2pt，
    /// 因此实现里空格键仍走弹性宽度（390pt 屏上实际 158pt），由它吸收这 2pt，
    /// 避免行尾出现 2pt 空隙（否则形象格与右边距会错位）。
    static let spaceBarWidthWithMascot: CGFloat = 156  // TOKEN: theme.mascot.spaceBarWidth

    /// 2 —— 形象格在屏幕右边距之上再加的内边距（3 + 2 = 5pt，符合 §3.2）。
    static let mascotTrailingInset: CGFloat = Theme.Spacing.xs

    /// 1 —— 形象格与回车键之间在 `keyGap` 之上再加的间距（6 + 1 = 7pt，符合 §3.2）。
    static let mascotReturnSpacing: CGFloat = 1

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
            case .aiPanel, .settings, .result, .aiChat, .voice:
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
        case .aiChat, .voice:
            // 语音页与对话页同高 438（复用 aiChatExtraHeight，不新增高度令牌）。
            height += aiChatExtraHeight
        default:
            break
        }
        return height + safeAreaBottom
    }
}
