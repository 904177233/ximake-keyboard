//
//  PanelRootView.swift
//  墨语键盘 · 面板入口
//
//  除了打字以外的界面都是 SwiftUI 面板，这里按页面切换。公共小部件也放在这里。
//

import SwiftUI
import UIKit

/// 面板根视图。
@MainActor
struct PanelRootView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var ai: AIPanelModel
    @ObservedObject var chat: ChatModel

    var body: some View {
        ZStack {
            (session.prefs.systemBackground ? Color.clear : session.palette.canvas.color)
            switch session.page {
            case .symbols:
                SymbolPanelView(session: session)
            case .candidates:
                CandidateGridView(session: session)
            case .ai:
                AIPanelView(session: session, ai: ai)
            case .chat:
                ChatPanelView(session: session, chat: chat)
            case .settings:
                SettingsPanelView(session: session, settings: session.settings)
            case .field:
                FieldEditView(session: session)
            case .voice:
                VoicePanelView(session: session)
            case .keys, .numbers:
                EmptyView()
            }
        }
        .environment(\.palette, session.palette)
    }
}

/// 面板顶部的关闭按钮。
struct PanelCloseButton: View {
    @Environment(\.palette) private var palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.secondary.color)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }
}

/// 面板里的普通按钮。
struct PanelButton: View {
    @Environment(\.palette) private var palette
    let title: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isPrimary ? .semibold : .regular))
                .foregroundColor(isPrimary ? palette.onAccent.color : palette.text.color)
                .padding(.horizontal, isPrimary ? 20 : 13)
                .frame(height: 36)
                .background(isPrimary ? palette.accent.color : palette.function.color)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 语气、语言这种小标签。
struct PanelChip: View {
    @Environment(\.palette) private var palette
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(isSelected ? palette.onAccent.color : palette.secondary.color)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(isSelected ? palette.accent.color : palette.function.color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
