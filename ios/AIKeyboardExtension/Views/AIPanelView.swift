//
//  AIPanelView.swift
//  墨语（Moyu）键盘扩展 · AI 面板
//
//  模块职责：AI 能力的输入与参数区（高度增量固定 +168，绝不因内容变化而变高）。
//            布局：8 上边距 / 44 输入框 / 8 / 44 语气行 / 8 / 44 生成按钮 / 12 下边距。
//            输入框支持「一键填入当前输入框内容」「从剪贴板填入」「只读预览 + 可编辑」两态。
//  设计依据：design/键盘布局规范.md §4.4、§5 状态 ③（加载中骨架 / >3s 文案）。
//  约束：键盘扩展内无法可靠弹出系统键盘，因此不使用 SwiftUI `TextField`；
//        编辑态由键盘自己的按键写入 `model.panelText`（详见 README「面板输入方案」）。
//

import SwiftUI

/// AI 面板。
struct AIPanelView: View {

    /// 键盘状态机。
    @ObservedObject var model: KeyboardViewModel

    /// 面板聚焦动画（进入时淡入）。
    @State private var appeared: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            contextPreviewRow
            inputRow
            toneRow
            actionRow
        }
        .padding(.top, KMLayout.panelTopPadding)
        .padding(.bottom, KMLayout.panelBottomPadding)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: KMLayout.aiPanelExtraHeight, alignment: .top)
        .background(Theme.keyboardBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: Theme.MaterialToken.strokeWidth)
        }
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 上下文预览

    /// 上下文预览行（可选，20pt 高；有预览时输入框压缩到 32 以保持 168 总增量）。
    @ViewBuilder
    private var contextPreviewRow: some View {
        if !model.panelContextPreview.isEmpty {
            HStack(spacing: Theme.Spacing.sm) {
                KMIconGlyph(symbol: "text.cursor", fallback: "⌶", size: 10, tint: Theme.textTertiary)
                Text(model.panelContextPreview)
                    .font(Theme.fontCaption)
                    .foregroundColor(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
                if model.showsContextTruncationHint {
                    Text("仅取最近 200 字")
                        .font(Theme.fontCaption)
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 20)  // TOKEN: design/键盘布局规范.md §4.4 上下文预览行 20
        }
    }

    // MARK: - 输入框

    /// 输入行：胶囊输入框 + 右侧发送圆钮。
    private var inputRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            inputField
            sendButton
        }
        .frame(height: inputRowHeight)
        .padding(.top, model.panelContextPreview.isEmpty ? 0 : Theme.Spacing.xs)
    }

    /// 输入框可视高度（有上下文预览时压缩到 32，保证 168 不变）。
    private var inputRowHeight: CGFloat {
        model.panelContextPreview.isEmpty ? KMLayout.panelInputHeight : 32  // TOKEN: design/键盘布局规范.md §4.4
    }

    /// 胶囊输入框（只读预览 + 可编辑两态）。
    private var inputField: some View {
        Button(action: {
            KMHaptics.chip()
            model.setPanelEditing(true)
        }) {
            HStack(spacing: Theme.Spacing.sm) {
                if model.panelText.isEmpty {
                    Text(model.isPanelEditing ? "用键盘输入…" : "点这里输入，或从下方填入")
                        .font(Theme.fontBody)
                        .foregroundColor(Theme.textPlaceholder)
                        .lineLimit(1)
                } else {
                    Text(model.panelText)
                        .font(Theme.fontBody)
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.isPanelEditing {
                    // 光标位置指示（简化渲染：末尾插入点）。
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2, height: 16)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: inputRowHeight)
            .background(
                RoundedRectangle(cornerRadius: inputRowHeight / 2, style: .continuous)
                    .fill(Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: inputRowHeight / 2, style: .continuous)
                    .strokeBorder(model.isPanelEditing ? Theme.accent : Color.clear,
                                  lineWidth: Theme.MaterialToken.strokeWidth)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 1.0, pressedOpacity: 0.95))
        .accessibilityLabel(Text(model.panelText.isEmpty ? "AI 输入框，空" : "AI 输入框，内容 \(model.panelText)"))
        .accessibilityHint(Text("点击进入编辑"))
    }

    /// 发送 / 生成圆钮（36×36 accent）。
    private var sendButton: some View {
        Button(action: {
            KMHaptics.chip()
            model.submitPanel(feature: model.lastFeature)
        }) {
            KMIconGlyph(symbol: "arrow.up", fallback: "↑", size: 16, tint: Theme.textOnAccent)
                .frame(width: 36, height: 36)  // TOKEN: design/键盘布局规范.md §4.4 发送圆钮 36×36
                .background(Circle().fill(canSubmit ? Theme.accent : Theme.accent.opacity(0.4)))
                .contentShape(Circle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.94, pressedOpacity: 0.9))
        .disabled(!canSubmit)
        .accessibilityLabel(Text("生成"))
    }

    /// 是否可提交。
    private var canSubmit: Bool {
        !model.panelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.aiState.isBusy
    }

    // MARK: - 语气行

    /// 语气选择行。
    private var toneRow: some View {
        HStack(spacing: 0) {
            KMToneSelector(selected: model.tone, onSelect: { tone in model.setTone(tone) })
        }
        .frame(height: KMLayout.panelToneRowHeight)
        .padding(.top, KMLayout.panelRowGap)
    }

    // MARK: - 动作行

    /// 生成按钮 + 快捷填入。
    private var actionRow: some View {
        HStack(spacing: KMLayout.panelRowGap) {
            KMPrimaryButton(
                title: primaryTitle,
                systemImage: "sparkles",
                isEnabled: !model.aiState.isBusy,
                isLoading: false,
                height: KMLayout.panelActionHeight,
                fullWidth: true,
                action: { model.submitPanel(feature: model.lastFeature) }
            )

            Button(action: {
                KMHaptics.chip()
                model.fillPanelFromHost()
            }) {
                Text("填入输入框")
                    .font(Theme.fontCaption)
                    .fontWeight(.medium)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.md)
                    .frame(height: KMLayout.panelActionHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.chipBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.9))
            .accessibilityLabel(Text("填入当前输入框内容"))

            Button(action: {
                KMHaptics.chip()
                model.fillPanelFromClipboard()
            }) {
                KMIconGlyph(symbol: "doc.on.clipboard", fallback: "📋", size: 16, tint: Theme.textPrimary)
                    .frame(width: KMLayout.panelActionHeight, height: KMLayout.panelActionHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .fill(Theme.chipBackground)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(KMPressableStyle(scale: 0.97, pressedOpacity: 0.9))
            .accessibilityLabel(Text("从剪贴板填入"))
        }
        .frame(height: KMLayout.panelActionHeight)
        .padding(.top, KMLayout.panelRowGap)
    }

    /// 主按钮标题（按能力切换）。
    private var primaryTitle: String {
        model.lastFeature.usesImageClient ? "开始绘制" : "生成\(model.lastFeature.title)"
    }
}
