//
//  ChatPanelView.swift
//  墨语键盘 · AI 对话
//
//  两种状态：打字时上面只留输入行（下面是候选栏和键区，候选栏位置放推理、长短等开关）；
//  看回答时整个键盘都是对话。
//

import SwiftUI

@MainActor
struct ChatPanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var chat: ChatModel
    @Environment(\.palette) private var palette
    @State private var expandedReasoning: Set<UUID> = []
    @State private var expandedSources: Set<UUID> = []

    var body: some View {
        GeometryReader { geometry in
            // 打字时键区占了大部分地方，放不下消息就只留输入行
            let showsMessages = !session.chatTyping || geometry.size.height >= 110
            VStack(spacing: 0) {
                if showsMessages {
                    header
                    messageList
                }
                inputRow(showsClose: !showsMessages)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(palette.accent.color)
                Image(systemName: "drop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.onAccent.color)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("AI 对话")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.text.color)
                Text(providerLine)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.secondary.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !chat.messages.isEmpty {
                iconButton("square.and.pencil", label: "新对话") { chat.clear() }
            }
            PanelCloseButton { session.setPage(.keys) }
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 40)
    }

    private var providerLine: String {
        guard let provider = session.snapshot.defaultProvider else { return "还没配 AI 服务" }
        let name = PresetProviders.preset(id: provider.id) != nil ? PresetProviders.shortName(id: provider.id) : provider.name
        return "\(name) · \(provider.model) · 联网\(chat.prefs.webSearch.title) · 推理\(chat.prefs.reasoning.title)"
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundColor(palette.secondary.color)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - 消息

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: chat.messages) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("想聊点什么？回答可以一键放进聊天框。")
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                starter("text.bubble", "帮我回这句话", template: "帮我回复这句话：")
                starter("wand.and.stars", "润色我写的", template: "帮我润色：")
                starter("globe", "翻成英文", template: "翻成英文：")
                starter("paintbrush", "画一张图", template: "画一张")
            }
        }
    }

    private func starter(_ symbol: String, _ title: String, template: String) -> some View {
        Button {
            session.insert(template)
            session.setChatTyping(true)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundColor(palette.accentText.color)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(palette.text.color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(palette.key.color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func bubble(_ message: ChatBubble) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 14.5))
                    .foregroundColor(palette.onAccent.color)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.accent.color)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if !message.sources.isEmpty {
                    sourcesView(message)
                }
                if !message.reasoning.isEmpty {
                    reasoningView(message)
                }
                if let image = message.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Text(message.text)
                        .font(.system(size: 11.5))
                        .foregroundColor(palette.secondary.color)
                        .lineLimit(2)
                } else if message.isStreaming && message.text.isEmpty {
                    HStack(spacing: 8) {
                        ThinkingDots(color: palette.secondary.color)
                        if case let .thinking(text) = chat.phase {
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundColor(palette.secondary.color)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(palette.key.color)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text(message.text)
                        .font(.system(size: 14.5))
                        .foregroundColor(message.isError ? palette.secondary.color : palette.text.color)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(palette.key.color)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !message.isStreaming {
                    actions(for: message)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 联网搜到的网页，点开看。
    private func sourcesView(_ message: ChatBubble) -> some View {
        let expanded = expandedSources.contains(message.id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if expandedSources.contains(message.id) {
                    expandedSources.remove(message.id)
                } else {
                    expandedSources.insert(message.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 10.5))
                    Text("联网搜了 \(message.sources.count) 个网页")
                        .font(.system(size: 11.5))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(palette.secondary.color)
            }
            .buttonStyle(.plain)
            if expandedSources.contains(message.id) {
                ForEach(Array(message.sources.enumerated()), id: \.offset) { pair in
                    Button {
                        chat.open(pair.element)
                    } label: {
                        Text("[\(pair.offset + 1)] \(pair.element.title)")
                            .font(.system(size: 12))
                            .foregroundColor(palette.accentText.color)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func reasoningView(_ message: ChatBubble) -> some View {
        let expanded = expandedReasoning.contains(message.id)
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                if expanded {
                    expandedReasoning.remove(message.id)
                } else {
                    expandedReasoning.insert(message.id)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                        .font(.system(size: 10.5))
                    Text(message.isStreaming && message.text.isEmpty ? "正在思考" : "思考过程")
                        .font(.system(size: 11.5))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(palette.secondary.color)
            }
            .buttonStyle(.plain)
            if expanded {
                Text(message.reasoning)
                    .font(.system(size: 12))
                    .foregroundColor(palette.secondary.color)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        palette.line.color.frame(width: 2)
                    }
            }
        }
    }

    @ViewBuilder
    private func actions(for message: ChatBubble) -> some View {
        HStack(spacing: 14) {
            if message.isError {
                actionButton("arrow.clockwise", "重试") { chat.retry() }
            } else if message.image != nil {
                actionButton("doc.on.doc", "复制图片") { chat.copyImage(message) }
                actionButton("square.and.arrow.down", "存相册") { chat.saveImage(message) }
            } else if !message.text.isEmpty {
                actionButton("arrow.down.to.line", "放进输入框") { chat.useInField(message) }
                actionButton("doc.on.doc", "复制") { chat.copy(message) }
                actionButton("paintbrush", "画成图") { chat.drawAnswer(message) }
            }
        }
        .padding(.leading, 4)
    }

    private func actionButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundColor(palette.accentText.color)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 输入行

    @ViewBuilder
    private func inputRow(showsClose: Bool) -> some View {
        HStack(spacing: 6) {
            if showsClose {
                PanelCloseButton { session.setPage(.keys) }
            }
            if session.chatTyping {
                HStack(spacing: 0) {
                    Text(session.draft.isEmpty ? " " : session.draft)
                        .font(.system(size: 14.5))
                        .foregroundColor(palette.text.color)
                        .lineLimit(1)
                        .truncationMode(.head)
                    palette.accent.color.frame(width: 1.5, height: 17)
                    if session.draft.isEmpty {
                        Text(chat.drawNext ? "说说想画什么" : "问点什么，或者说「画一只猫」")
                            .font(.system(size: 14))
                            .foregroundColor(palette.secondary.color)
                            .lineLimit(1)
                            .padding(.leading, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(palette.key.color)
                .clipShape(Capsule())
            } else {
                // 看回答时没有键区，点这里回去打字
                Button {
                    session.setChatTyping(true)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 13))
                        Text("接着问…")
                            .font(.system(size: 14.5))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(palette.secondary.color)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(palette.key.color)
                    .clipShape(Capsule())
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if session.chatTyping || chat.phase != .idle {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: chat.phase == .idle ? (chat.drawNext ? "paintbrush.fill" : "arrow.up") : "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.onAccent.color)
                        .frame(width: 34, height: 34)
                        .background(palette.accent.color)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chat.phase == .idle ? "发送" : "停止")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
    }
}

/// 三个跳动的点：模型在想。
struct ThinkingDots: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * (sin(time * 6 - Double(index) * 0.9) + 1) / 2)
                }
            }
        }
    }
}
