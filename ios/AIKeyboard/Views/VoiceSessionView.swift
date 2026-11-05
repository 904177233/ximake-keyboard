//
//  VoiceSessionView.swift
//  墨语 App · 说话转文字
//
//  键盘点麦克风或长按空格（会话没开时）会跳到这里。会话开着时麦克风一直在，
//  回到聊天框长按空格就能说，说完文字自动放进输入框。
//

import SwiftUI
import UIKit

@MainActor
struct VoiceSessionView: View {
    /// 一进来就开始听。键盘跳过来时用。
    var autoStart = false
    var onClose: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @ObservedObject private var voice = VoiceSession.shared
    @State private var didAutoStart = false

    var body: some View {
        VStack(spacing: 16) {
            header
            ScrollView {
                Text(displayText)
                    .font(.system(size: 18))
                    .foregroundColor(isPlaceholder ? palette.secondary.color : palette.text.color)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(hint)
                .font(.system(size: 13))
                .foregroundColor(palette.secondary.color)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            buttons
        }
        .padding(20)
        .background(palette.page.color.ignoresSafeArea())
        .navigationTitle("说话转文字")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起", action: onClose)
                }
            }
        }
        .onAppear {
            guard autoStart, !didAutoStart else { return }
            didAutoStart = true
            voice.open(listenNow: true)
        }
    }

    // MARK: - 上面的状态

    private var header: some View {
        HStack(spacing: 14) {
            Waveform(level: CGFloat(voice.level), isActive: voice.state == .listening, color: palette.accent.color)
                .frame(width: 64, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(palette.text.color)
                if voice.isOpen {
                    Text("会话开着，\(voice.minutesLeft) 分钟没用会自动关")
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.secondary.color)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch voice.state {
        case .off: return "语音会话没开"
        case .starting: return "正在准备…"
        case .ready: return "随时可以说"
        case .listening: return "正在听"
        case .transcribing: return "正在转文字"
        case .failed: return "出了点问题"
        }
    }

    private var isPlaceholder: Bool {
        voice.text.isEmpty && voice.lastResult.isEmpty
    }

    private var displayText: String {
        switch voice.state {
        case let .failed(reason):
            return reason
        case .listening, .transcribing:
            return voice.text.isEmpty ? "请说话…" : voice.text
        default:
            if !voice.lastResult.isEmpty { return voice.lastResult }
            return "点下面的按钮开始说话"
        }
    }

    private var hint: String {
        if voice.isOpen {
            return "现在可以回到聊天框：长按空格说话，松开文字就放进输入框，上滑取消。状态栏的橙色麦克风标记说明麦克风开着。"
        }
        return "打开以后麦克风会开着一会儿，回到聊天框长按空格就能直接说。说完的文字会自动放进输入框，也会复制一份。"
    }

    @ViewBuilder
    private var buttons: some View {
        switch voice.state {
        case .listening:
            PrimaryButton(title: "说完了") { voice.endUtterance() }
        case .transcribing, .starting:
            PrimaryButton(title: "请稍等…") {}
                .disabled(true)
        case .ready:
            PrimaryButton(title: "再说一段") { voice.beginUtterance() }
            SecondaryButton(title: "关闭语音会话") { voice.close() }
        case .off, .failed:
            PrimaryButton(title: "打开语音") { voice.open(listenNow: true) }
        }
    }
}

/// 跟着音量跳的几根竖条。
struct Waveform: View {
    let level: CGFloat
    let isActive: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isActive)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<5, id: \.self) { index in
                    let wiggle = isActive ? (sin(time * 7 + Double(index) * 1.3) + 1) / 2 : 0
                    let height = 6 + (CGFloat(wiggle) * 0.5 + level * 0.8) * 28
                    Capsule()
                        .fill(color.opacity(isActive ? 1 : 0.35))
                        .frame(width: 6, height: min(height, 36))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
