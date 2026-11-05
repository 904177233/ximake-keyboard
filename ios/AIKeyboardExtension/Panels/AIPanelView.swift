//
//  AIPanelView.swift
//  墨语键盘 · AI 面板
//
//  和键盘一样高，打开时界面不会跳。上面选功能和语气，中间是结果，下面是操作。
//

import SwiftUI

@MainActor
struct AIPanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var ai: AIPanelModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            tabs
            params
            resultBody
                .padding(.horizontal, 8)
            actions
                .frame(height: 50)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - 页签

    private var tabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(AIPanelFeature.allCases) { feature in
                        Button {
                            ai.switchTo(feature)
                        } label: {
                            VStack(spacing: 3) {
                                Text(feature.title)
                                    .font(.system(size: 15, weight: ai.feature == feature ? .semibold : .regular))
                                    .foregroundColor(ai.feature == feature ? palette.text.color : palette.secondary.color)
                                RoundedRectangle(cornerRadius: 1.25)
                                    .fill(ai.feature == feature ? palette.accent.color : Color.clear)
                                    .frame(width: 26, height: 2.5)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }
            PanelCloseButton { session.closePanel() }
                .padding(.trailing, 4)
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private var params: some View {
        switch ai.feature {
        case .polish, .expand:
            chipRow(AIPanelModel.tones, selected: ai.tone) { ai.setTone($0) }
        case .reply:
            chipRow(AIPanelModel.replyTones, selected: ai.tone) { ai.setTone($0) }
        case .translate:
            chipRow(AIPanelModel.languages, selected: ai.targetLanguage, prefix: "翻成") { ai.setTargetLanguage($0) }
        case .image:
            EmptyView()
        }
    }

    private func chipRow(_ items: [String], selected: String, prefix: String = "",
                         action: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    PanelChip(title: prefix + item, isSelected: item == selected) { action(item) }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 32)
    }

    // MARK: - 中间

    private var resultBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.key.color)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch ai.phase {
        case .needsFullAccess:
            note("键盘还连不上网。")
            note("打开 设置 › 通用 › 键盘 › 键盘 › 墨语，把「允许完全访问」打开，再回来。")
        case .needsProvider:
            note("还没配 AI 服务。选一家，把 Key 填上就能用。")
        case .needsSource:
            sourceHint
        case .stopped:
            sourceLine
            note("已停止。")
        case let .waiting(message):
            sourceLine
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(palette.secondary.color)
        case .streaming, .done:
            sourceLine
            finishedContent
        case let .failed(title, detail, _):
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                note(detail)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(palette.secondary.color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sourceHint: some View {
        switch ai.feature {
        case .reply:
            note("先在聊天里长按对方的话，点拷贝，再点下面的按钮。")
        case .image:
            note("先在输入框里写下想画什么，比如「雨夜的小酒馆」，再回来点这里。")
        default:
            note("输入框是空的。先打一句话，或者选中一段字，再回来点这里。")
        }
    }

    private var sourceLine: some View {
        Text((ai.feature == .reply ? "对方说：" : "原文：") + ai.source)
            .font(.system(size: 12))
            .foregroundColor(palette.secondary.color)
            .lineLimit(1)
    }

    @ViewBuilder
    private var finishedContent: some View {
        if ai.feature == .image, let image = ai.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity)
        } else if ai.feature == .reply, !ai.replies.isEmpty {
            ForEach(Array(ai.replies.enumerated()), id: \.offset) { pair in
                Button {
                    ai.chooseReply(pair.element)
                } label: {
                    Text(pair.element)
                        .font(.system(size: 15))
                        .foregroundColor(palette.text.color)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if pair.offset < ai.replies.count - 1 {
                    palette.line.color.frame(height: 0.5)
                }
            }
        } else {
            Text(ai.output)
                .font(.system(size: 15))
                .foregroundColor(palette.text.color)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 下面

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch ai.phase {
            case .needsFullAccess:
                Spacer(minLength: 0)
            case .needsProvider:
                Spacer(minLength: 0)
                PanelButton(title: "去配置", isPrimary: true) { session.openProviderSettings() }
            case .needsSource:
                if ai.feature == .reply {
                    Spacer(minLength: 0)
                    PanelButton(title: "读我复制的那句", isPrimary: true) { ai.useClipboard() }
                } else {
                    Spacer(minLength: 0)
                }
            case .waiting, .streaming:
                PanelButton(title: "停止") { ai.cancel() }
                Spacer(minLength: 0)
            case .stopped:
                PanelButton(title: "重试") { ai.run() }
                Spacer(minLength: 0)
            case .done:
                doneActions
            case let .failed(_, _, suggestsSettings):
                PanelButton(title: "重试") { ai.run() }
                Spacer(minLength: 0)
                if suggestsSettings {
                    PanelButton(title: "去设置", isPrimary: true) { session.openProviderSettings() }
                }
            }
        }
    }

    @ViewBuilder
    private var doneActions: some View {
        switch ai.feature {
        case .image:
            PanelButton(title: "重画") { ai.regenerate() }
            Spacer(minLength: 0)
            PanelButton(title: "复制图片", isPrimary: true) { ai.copyImage() }
        case .reply:
            PanelButton(title: "换一批") { ai.regenerate() }
            if !ai.sourceIsClipboard {
                PanelButton(title: "读我复制的那句") { ai.useClipboard() }
            }
            Spacer(minLength: 0)
        default:
            PanelButton(title: "重写") { ai.regenerate() }
            PanelButton(title: "复制") { ai.copyResult() }
            Spacer(minLength: 0)
            PanelButton(title: ai.sourceIsClipboard ? "放进输入框" : "替换", isPrimary: true) { ai.replace() }
        }
    }
}
