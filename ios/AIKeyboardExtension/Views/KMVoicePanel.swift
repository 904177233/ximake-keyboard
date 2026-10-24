//
//  KMVoicePanel.swift
//  AIKeyboardExtension
//
//  键盘内语音输入面板：整页，与 `.aiChat` / `.result` 同高 438（40 + 180 + 44 + 174，不新增高度令牌）。
//  录音与转写逻辑全部在 `KMVoiceInput`；本视图只做呈现，「完成并上屏」通过 `onCommit` 交回调用方。
//

import SwiftUI

/// 键盘内语音输入面板。
struct KMVoicePanel: View {
    /// 语音输入控制器（默认全局单例）。
    @ObservedObject var voice: KMVoiceInput
    /// 关闭面板（不提交）。
    let onClose: () -> Void
    /// 提交最终文本（上屏）。
    let onCommit: (String) -> Void

    /// 麦克风按钮直径 64pt；音量环基础 96pt / 每环 +18pt。
    private let micSize: CGFloat = 64  // TOKEN: sizing.voiceMicrophoneSize = 64
    private let ringBase: CGFloat = 96  // TOKEN: sizing.voiceRingBaseSize = 96
    private let ringStep: CGFloat = 18  // TOKEN: sizing.voiceRingStep = 18

    var body: some View {
        VStack(spacing: 0) {
            topBar
            mainArea
            statusBar
            actionArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.keyboardBackground)
        .accessibilityElement(children: .contain)
    }

    // MARK: - 标题条 40pt

    private var topBar: some View {
        ZStack {
            Text("语音输入")
                .font(Theme.fontHeadline)
                .foregroundColor(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button {
                    voice.cancel()
                    onClose()
                } label: {
                    KMIconGlyph(symbol: "xmark", fallback: "✕", size: 15,
                                weight: .semibold, tint: Theme.textSecondary)
                        .frame(width: Theme.Sizing.minTapTarget, height: KMLayout.aiChatTopBarHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KMPressableStyle(scale: 0.92, duration: Theme.Motion.fast))
                .accessibilityLabel(Text("关闭语音输入"))
                Spacer(minLength: 0)
                // 右侧同宽占位，保证标题真正居中。
                Color.clear.frame(width: Theme.Sizing.minTapTarget,
                                  height: KMLayout.aiChatTopBarHeight)
            }
        }
        .frame(height: KMLayout.aiChatTopBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: Theme.MaterialToken.strokeWidth)
        }
    }

    // MARK: - 主区 180pt

    private var mainArea: some View {
        VStack(spacing: Theme.Spacing.md) {
            ZStack {
                if isRecording { levelRings }
                micButton
            }
            .frame(width: ringBase + ringStep * 2, height: ringBase + ringStep * 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(isRecording ? "正在录音" : "语音输入"))
            Text(elapsedText)
                .font(Theme.fontMonoDigit)
                .foregroundColor(Theme.textSecondary)
                .opacity(voice.state.isActive ? 1 : 0)
                .accessibilityHidden(true)
            partialText
        }
        .frame(height: KMLayout.aiChatMessageHeight)
        .frame(maxWidth: .infinity)
    }

    private var micButton: some View {
        Button {
            toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(isRecording ? Theme.accent : Theme.surfaceElevated)
                    .frame(width: micSize, height: micSize)
                    .overlay {
                        Circle().strokeBorder(isRecording ? Color.clear : Theme.separator,
                                              lineWidth: Theme.MaterialToken.strokeWidth)
                    }
                KMIconGlyph(symbol: isRecording ? "stop.fill" : "mic.fill",
                            fallback: isRecording ? "■" : "🎤",
                            size: 24, weight: .semibold,
                            tint: isRecording ? Theme.textOnAccent : Theme.accent)
            }
            .frame(minWidth: Theme.Sizing.minTapTarget, minHeight: Theme.Sizing.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(KMPressableStyle(scale: 0.94, duration: Theme.Motion.fast))
        .disabled(isBusy || isFinished)
        .opacity(isBusy ? 0.6 : 1)
        .accessibilityLabel(Text(isRecording ? "结束录音" : "开始录音"))
        .accessibilityHint(Text("点击后开始说话，再点一次结束"))
    }

    /// 三圈随音量脉动；Reduce Motion 时 `KMAnimation.animation` 返回 nil，自动静态。
    private var levelRings: some View {
        let level = currentLevel
        return ZStack {
            ForEach(0..<3, id: \.self) { index in
                let scale = 1.0 + level * (0.18 + Float(index) * 0.12)
                Circle()
                    .strokeBorder(Theme.accent.opacity(max(0.28 - Double(index) * 0.07, 0.08)),
                                  lineWidth: 1.5)
                    .frame(width: ringBase + ringStep * CGFloat(index),
                           height: ringBase + ringStep * CGFloat(index))
                    .scaleEffect(CGFloat(scale))
                    .animation(KMAnimation.animation(duration: Theme.Motion.fast), value: level)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var partialText: some View {
        Group {
            if voice.partialText.isEmpty {
                Text("说点什么试试…").font(Theme.fontBody).foregroundColor(Theme.textTertiary)
            } else {
                Text(voice.partialText)
                    .font(Theme.fontBody)
                    .foregroundColor(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.horizontal, Theme.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Theme.Sizing.letterRowHeight * 2)
        .accessibilityLabel(Text(voice.partialText.isEmpty ? "还没有识别到文字"
                                                           : "识别中：\(voice.partialText)"))
    }

    // MARK: - 状态行 44pt

    private var statusBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if isFailed {
                KMIconGlyph(symbol: "exclamationmark.triangle.fill", fallback: "!",
                            size: 13, tint: Theme.warning)
            }
            Text(statusText)
                .font(Theme.fontCaption)
                .foregroundColor(isFailed ? Theme.warning : Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: KMLayout.aiChatInputHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 动作区 174pt

    private var actionArea: some View {
        VStack(spacing: Theme.Spacing.md) {
            if showsUnsupportedFallback { fallbackCard }
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.md) {
                KMSecondaryButton(title: "取消", height: Theme.Sizing.minTapTarget) {
                    voice.cancel()
                    onClose()
                }
                .accessibilityLabel(Text("取消语音输入"))
                KMPrimaryButton(title: primaryTitle,
                                isEnabled: !isBusy,
                                isLoading: voice.state == .transcribing,
                                height: Theme.Sizing.minTapTarget,
                                fullWidth: true) {
                    handlePrimaryAction()
                }
                .accessibilityLabel(Text(primaryTitle))
            }
            .padding(.horizontal, Theme.Spacing.xl)
            Text("语音在设备上转写，不会上传到服务器")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textTertiary)
                .padding(.bottom, Theme.Spacing.md)
        }
        .frame(height: KMLayout.keyRowsHeight)
        .frame(maxWidth: .infinity)
    }

    /// 环境不支持时的备选路径卡片。
    private var fallbackCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("先在 App 里用语音").font(Theme.fontChip).foregroundColor(Theme.textPrimary)
            Text("键盘扩展内无法录音时，可以到「墨语」App 的语音页说一句话，复制结果，回到这里长按输入框粘贴。")
                .font(Theme.fontCaption)
                .foregroundColor(Theme.textSecondary)
                .lineLimit(3)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Theme.warningSoft))
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 派生状态

    private var isRecording: Bool { if case .recording = voice.state { return true }; return false }
    private var isFinished: Bool { if case .finished = voice.state { return true }; return false }
    private var isFailed: Bool { if case .failed = voice.state { return true }; return false }
    private var isBusy: Bool {
        switch voice.state {
        case .requestingPermission, .transcribing: return true
        default: return false
        }
    }
    private var showsUnsupportedFallback: Bool {
        if case let .failed(_, unsupported) = voice.state { return unsupported }
        return false
    }
    private var currentLevel: Float {
        if case let .recording(level, _) = voice.state { return level }
        return 0
    }
    private var primaryTitle: String {
        switch voice.state {
        case .idle: return "开始说话"
        case .requestingPermission: return "正在请求权限…"
        case .recording: return "结束录音"
        case .transcribing: return "正在转写…"
        case .finished: return "完成并上屏"
        case .failed: return "重试"
        }
    }
    private var statusText: String {
        switch voice.state {
        case .idle: return "点下面的按钮开始，说完会自动转成文字"
        case .requestingPermission: return "请允许麦克风与语音识别权限"
        case let .recording(_, elapsed):
            return String(format: "正在录音 %.1f 秒 · 最长 %.0f 秒", elapsed, KMVoiceInput.maximumDuration)
        case .transcribing: return "正在把你的话转成文字…"
        case .finished: return "识别完成，点「完成并上屏」插入到输入框"
        case let .failed(reason, _): return reason
        }
    }
    private var elapsedText: String {
        if case let .recording(_, elapsed) = voice.state { return String(format: "%.1f s", elapsed) }
        if case .transcribing = voice.state { return "转写中…" }
        return "0.0 s"
    }

    // MARK: - 交互

    private func handlePrimaryAction() {
        switch voice.state {
        case .idle, .failed:
            voice.start()
        case .recording:
            voice.stop()
        case .finished(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            voice.reset()
            if !trimmed.isEmpty { onCommit(trimmed) }
            onClose()
        case .requestingPermission, .transcribing:
            break
        }
    }

    private func toggleRecording() {
        switch voice.state {
        case .idle, .failed: voice.start()
        case .recording: voice.stop()
        default: break
        }
    }
}
