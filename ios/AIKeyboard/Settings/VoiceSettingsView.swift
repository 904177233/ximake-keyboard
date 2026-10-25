//
//  VoiceSettingsView.swift
//  墨语 · 宿主 App
//
//  模块职责：语音输入的**权限申请页**。
//
//  为什么权限必须在这里申请（v1.4 架构修正）：
//  键盘扩展里调 `SFSpeechRecognizer.requestAuthorization` /
//  `AVAudioApplication.requestRecordPermission` 会弹系统权限框，而**弹系统框会让键盘
//  失去第一响应者、被系统收起，从而切回上一个输入法** —— 用户看到的现象就是
//  「一点语音就切到别的输入法」。所以授权只能由宿主 App 发起，键盘扩展只读状态。
//
//  依赖：SwiftUI、Speech、AVFoundation、SurfaceCard / SectionHeader / ListGroup /
//        SettingsRow / PrimaryButton / EmptyState。
//  使用方：AppearanceView 的「语音输入」分组。
//

import AVFoundation
import Speech
import SwiftUI

/// 语音输入权限页。
struct VoiceSettingsView: View {

    /// 麦克风是否已授权。
    @State private var micGranted: Bool = VoiceSettingsView.readMicGranted()

    /// 语音识别授权状态。
    @State private var speechStatus: SFSpeechRecognizerAuthorizationStatus =
        SFSpeechRecognizer.authorizationStatus()

    /// 是否正在申请。
    @State private var isRequesting: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppMetrics.sectionGap) {
                statusSection
                actionSection
                footnoteSection
            }
            .padding(.horizontal, AppMetrics.pageInset)
            .padding(.bottom, Theme.Spacing.xxl + AppMetrics.pageInset)
        }
        .background(AppColor.pageBackground.ignoresSafeArea())
        .navigationTitle("语音输入")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    // MARK: - 状态

    /// 两项权限的当前状态。
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            SectionHeader(
                title: "权限状态",
                footnote: "语音识别在你的手机上完成，录音不会上传到墨语的服务器（也没有这个服务器）"
            )

            ListGroup {
                SettingsRow(
                    icon: IconSpec(
                        symbol: micGranted ? "mic.fill" : "mic.slash.fill",
                        tint: micGranted ? Theme.success : Theme.warning
                    ),
                    title: "麦克风",
                    subtitle: micGranted ? "已允许" : "未允许",
                    accessory: .none
                )

                RowDivider()

                SettingsRow(
                    icon: IconSpec(
                        symbol: "waveform",
                        tint: speechStatus == .authorized ? Theme.success : Theme.warning
                    ),
                    title: "语音识别",
                    subtitle: Self.speechStatusText(speechStatus),
                    accessory: .none
                )
            }
        }
    }

    // MARK: - 动作

    /// 申请按钮 / 去系统设置。
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: AppMetrics.blockGap) {
            if micGranted && speechStatus == .authorized {
                SurfaceCard {
                    HStack(spacing: Theme.Spacing.md) {
                        IconGlyph(symbol: "checkmark.circle.fill", fallback: "✅", size: 20, tint: Theme.success)
                        Text("键盘里的麦克风按钮现在可以直接用了。")
                            .font(Theme.fontBody)
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                SectionHeader(
                    title: "申请权限",
                    footnote: "两项都要允许；在键盘里点麦克风不会再弹窗（弹窗会把键盘顶掉）"
                )

                PrimaryButton(
                    title: isRequesting ? "正在申请…" : "允许麦克风与语音识别",
                    systemImage: "mic.badge.plus",
                    size: .large,
                    isEnabled: !isRequesting,
                    isLoading: isRequesting,
                    action: request
                )

                if micGranted == false || speechStatus == .denied || speechStatus == .restricted {
                    SecondaryButton(
                        title: "去系统设置里打开",
                        systemImage: "gearshape",
                        tone: .neutral,
                        size: .medium,
                        fullWidth: true,
                        action: openSystemSettings
                    )
                }
            }
        }
    }

    // MARK: - 说明

    /// 底部说明。
    private var footnoteSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("为什么不能在键盘里申请")
                .font(Theme.fontHeadline)
                .foregroundColor(Theme.textPrimary)
            Text("iOS 规定：键盘扩展一旦弹系统权限框，键盘会自动收起并切回上一个输入法。所以授权统一放在这里做，键盘只读取已有的授权状态。")
                .font(Theme.fontFootnote)
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Spacing.md)
    }

    // MARK: - 动作实现

    /// 依次申请麦克风与语音识别。
    private func request() {
        guard !isRequesting else { return }
        isRequesting = true
        Haptics.selection()

        requestMicrophone { micOK in
            guard micOK else {
                isRequesting = false
                refresh()
                return
            }
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async {
                    isRequesting = false
                    refresh()
                }
            }
        }
    }

    /// 申请麦克风（iOS 17+ 走 `AVAudioApplication`，iOS 16 走 `AVAudioSession`）。
    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    /// 刷新两项状态。
    private func refresh() {
        micGranted = Self.readMicGranted()
        speechStatus = SFSpeechRecognizer.authorizationStatus()
    }

    /// 打开系统设置里的本 App 页。
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - 状态读取

    /// 当前麦克风授权状态（只读）。
    static func readMicGranted() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// 语音识别状态的中文描述。
    static func speechStatusText(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "已允许"
        case .denied:
            return "已拒绝，需要到系统设置里改"
        case .restricted:
            return "系统限制（家长控制或企业策略）"
        case .notDetermined:
            return "还没有申请"
        @unknown default:
            return "未知状态"
        }
    }
}
