//
//  VoiceSessionView.swift
//  墨语 App · 说话转文字
//
//  苹果不给键盘用麦克风，键盘点麦克风会跳到这里。开了后台音频，录音时可以回到原来的 App 接着说。
//  说完后结果交给 VoiceBridge，键盘回来时放进输入框。
//

import AVFoundation
import Speech
import SwiftUI
import UIKit

@MainActor
struct VoiceSessionView: View {
    /// 一进来就开始录。键盘跳过来时用。
    var autoStart = false
    var onClose: (() -> Void)?

    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @ObservedObject private var voice = KMVoiceInput.shared
    @State private var didAutoStart = false

    var body: some View {
        VStack(spacing: 14) {
            Text(hint)
                .font(.system(size: 13.5))
                .foregroundColor(palette.secondary.color)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                Text(displayText)
                    .font(.system(size: 18))
                    .foregroundColor(isPlaceholder ? palette.secondary.color : palette.text.color)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            PrimaryButton(title: buttonTitle) { toggle() }
        }
        .padding(20)
        .background(palette.page.color.ignoresSafeArea())
        .navigationTitle("说话转文字")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                }
            }
        }
        .onAppear {
            guard autoStart, !didAutoStart else { return }
            didAutoStart = true
            start()
        }
        .onChange(of: voice.state) { state in
            switch state {
            case let .finished(text):
                VoiceBridge.publishFinished(text)
            case let .failed(reason, _):
                VoiceBridge.publish(VoiceBridgeState(status: .failed, text: reason))
            default:
                break
            }
        }
        .task {
            // 把听到的字传给键盘，顺便接收键盘的「说完了」。回到别的 App 时这里还在跑。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                relay()
            }
        }
        .onDisappear {
            if voice.state.isActive {
                VoiceBridge.clear()
            }
            voice.cancel()
        }
    }

    private func relay() {
        switch voice.state {
        case .recording:
            VoiceBridge.publish(VoiceBridgeState(status: .listening, text: voice.partialText))
        case .transcribing:
            VoiceBridge.publish(VoiceBridgeState(status: .transcribing, text: voice.partialText))
        default:
            return
        }
        switch VoiceBridge.takeCommand() {
        case .stop:
            voice.stop()
        case .discard:
            voice.cancel()
            VoiceBridge.clear()
        case nil:
            break
        }
    }

    private var hint: String {
        switch voice.state {
        case .recording:
            return VoiceBridge.canShareLive
                ? "正在听。可以点左上角回到刚才的 App 接着说，也可以在这里说完。"
                : "正在听。说完点下面的按钮。"
        case .finished:
            return "好了。点左上角回到刚才的 App，文字会自动放进输入框。"
        default:
            return "说完后回到聊天框，文字会自动放进输入框。"
        }
    }

    private var isPlaceholder: Bool {
        if case .finished = voice.state { return false }
        return voice.partialText.isEmpty
    }

    private var displayText: String {
        switch voice.state {
        case let .finished(text):
            return text
        case let .failed(reason, _):
            return reason
        case .recording:
            return voice.partialText.isEmpty ? "请说话…" : voice.partialText
        case .requestingPermission:
            return "正在准备…"
        default:
            return voice.partialText.isEmpty ? "点下面的按钮开始说话" : voice.partialText
        }
    }

    private var buttonTitle: String {
        if case .recording = voice.state { return "说完了" }
        if case .transcribing = voice.state { return "正在转文字…" }
        if case .finished = voice.state { return "再说一段" }
        return "开始说话"
    }

    private func toggle() {
        if case .recording = voice.state {
            voice.stop()
            return
        }
        guard !voice.state.isActive else { return }
        start()
    }

    private func start() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    guard granted, status == .authorized else {
                        let reason = "还没允许麦克风或语音识别。到 设置 › 墨语 里打开。"
                        VoiceBridge.publish(VoiceBridgeState(status: .failed, text: reason))
                        model.showToast(reason)
                        return
                    }
                    VoiceBridge.clear()
                    voice.reset()
                    voice.start()
                }
            }
        }
    }
}
