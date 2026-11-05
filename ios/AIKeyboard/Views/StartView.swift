//
//  StartView.swift
//  墨语 App · 开始
//
//  告诉人还差哪一步，能查到的状态都查一下。旁边放个输入框，装好马上能试。
//

import SwiftUI
import UIKit

@MainActor
struct StartView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var trial = ""
    @FocusState private var trialFocused: Bool

    var body: some View {
        AppPage(title: "墨语", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                step(number: 1,
                     isDone: model.isKeyboardAdded == true,
                     title: "添加键盘",
                     detail: "设置 › 通用 › 键盘 › 键盘 › 添加新键盘 › 墨语")
                step(number: 2,
                     isDone: false,
                     title: "打开完全访问",
                     detail: "同一页点进墨语，打开「允许完全访问」。不开也能打字，但 AI 连不上网。")
                step(number: 3,
                     isDone: model.isChatReady,
                     title: "填一个 AI 服务",
                     detail: model.isChatReady ? "\(model.snapshot.defaultProvider?.name ?? "") 已填好" : "到「AI」页填。DeepSeek 最便宜，充 10 块能用很久。")

                SecondaryButton(title: "打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .padding(.top, 14)

                #if MOYU_SIM_CHECK
                SimCheckField()
                    .frame(height: 40)
                Text(SimCheckField.modesText)
                    .font(.system(size: 11))
                #endif
                SectionLabel(text: "在这里试试")
                TextField("点这里，切到墨语键盘，打一句话", text: $trial, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(3...6)
                    .focused($trialFocused)
                    .padding(12)
                    .background(palette.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                SectionLabel(text: "这台手机")
                LineRow(title: "App 和键盘的配置",
                        detail: model.isSharedWithKeyboard
                            ? "在这里填一次，键盘里就能用。\(SharedBlob.statusText)"
                            : "\(SharedBlob.statusText)。可以直接在键盘里填，也可以把这边的配置发过去") {
                    if model.isSharedWithKeyboard {
                        StateText(text: "已打通", isGood: true)
                    } else {
                        Button("发给键盘") { model.sendConfigToKeyboard() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                if let days = model.signatureDaysLeft {
                    LineRow(title: "签名还剩", detail: "到期前重新安装一次就行") {
                        StateText(text: "\(days) 天")
                    }
                }
                LineRow(title: "版本") {
                    StateText(text: model.versionText)
                }
            }
        }
    }

    private var subtitle: String {
        model.isChatReady && model.isKeyboardAdded == true
            ? "都装好了。到任何聊天框里，切到墨语就能用。"
            : "三步装好，就能在任何聊天框里用 AI。"
    }

    private func step(number: Int, isDone: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? palette.accent.color : palette.surface.color)
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(palette.onAccent.color)
                } else {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(palette.text.color)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(palette.text.color)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondary.color)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
    }
}

#if MOYU_SIM_CHECK
/// 模拟器实测用：模拟器里点不了地球键，这个输入框直接指定用墨语键盘。只有实测版才有。
struct SimCheckField: UIViewRepresentable {
    final class Field: UITextField {
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { SimCheckField.identifier(of: $0).contains("moyu") } ?? super.textInputMode
        }
    }

    static func identifier(of mode: UITextInputMode) -> String {
        guard mode.responds(to: NSSelectorFromString("identifier")) else { return mode.primaryLanguage ?? "?" }
        return "\(mode.value(forKey: "identifier") ?? "?")"
    }

    static var modesText: String {
        UITextInputMode.activeInputModes.map { identifier(of: $0) }.joined(separator: " | ")
    }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.placeholder = "模拟器实测"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Self.selectMoyuKeyboard()
            field.becomeFirstResponder()
        }
        // 第一次切的时候键盘可能还没准备好，再切一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            Self.selectMoyuKeyboard()
            field.reloadInputViews()
        }
        return field
    }

    func updateUIView(_ uiView: Field, context: Context) {}

    /// 只在实测版里调系统的私有方法，把当前输入法切成墨语。
    private static func selectMoyuKeyboard() {
        guard let type = NSClassFromString("UIKeyboardInputModeController") as? NSObject.Type,
              let shared = type.perform(NSSelectorFromString("sharedInputModeController"))?.takeUnretainedValue() as? NSObject,
              let mode = UITextInputMode.activeInputModes.first(where: { identifier(of: $0).contains("moyu") }) else {
            return
        }
        _ = shared.perform(NSSelectorFromString("setCurrentInputMode:"), with: mode)
    }
}
#endif
