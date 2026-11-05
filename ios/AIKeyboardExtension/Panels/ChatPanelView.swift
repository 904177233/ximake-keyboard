//
//  ChatPanelView.swift
//  墨语键盘 · AI 对话（键区上方的部分）
//
//  键区和候选由控制器摆在下面，所以这里只有消息列表和输入行。
//

import SwiftUI

@MainActor
struct ChatPanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var chat: ChatModel
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geometry in
            // 打字时键区占了大部分地方，放不下消息就只留输入行
            let showsMessages = !session.chatTyping || geometry.size.height >= 110
            VStack(spacing: 0) {
                if showsMessages {
                    ZStack(alignment: .topTrailing) {
                        messages
                        HStack(spacing: 0) {
                            if !chat.messages.isEmpty {
                                Button {
                                    chat.clear()
                                } label: {
                                    Image(systemName: "square.and.pencil")
                                        .font(.system(size: 14))
                                        .foregroundColor(palette.secondary.color)
                                        .frame(width: 34, height: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("新对话")
                            }
                            PanelCloseButton { session.setPage(.keys) }
                        }
                    }
                }
                inputRow(showsClose: !showsMessages)
            }
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if case let .thinking(text) = chat.phase {
                        Text(text)
                            .font(.system(size: 12))
                            .foregroundColor(palette.secondary.color)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .padding(.trailing, chat.messages.isEmpty ? 60 : 0)
            }
            .onChange(of: chat.messages) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("想问什么直接打字。回答可以一键放进聊天框。")
                .font(.system(size: 13))
                .foregroundColor(palette.secondary.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(["帮我想个回复", "这句话怎么说更好", "翻译成英文"], id: \.self) { sample in
                    PanelChip(title: sample, isSelected: false) {
                        session.insert(sample)
                        chat.send()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatBubble) -> some View {
        let isUser = message.role == .user
        VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
            Text(message.text.isEmpty ? " " : message.text)
                .font(.system(size: 14))
                .foregroundColor(isUser ? palette.onAccent.color : palette.text.color)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isUser ? palette.accent.color : palette.key.color)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            if !isUser, !message.isStreaming, !message.text.isEmpty {
                HStack(spacing: 14) {
                    if message.isError {
                        actionText("重试") { chat.retry() }
                    } else {
                        actionText("放进输入框") { chat.useInField(message) }
                        actionText("复制") { chat.copy(message) }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func actionText(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(palette.accentText.color)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

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
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(palette.key.color)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                // 看回答时没有键区，点这里回去打字
                Button {
                    session.setChatTyping(true)
                } label: {
                    Text("接着问…")
                        .font(.system(size: 14.5))
                        .foregroundColor(palette.secondary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(palette.key.color)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if session.chatTyping || chat.phase != .idle {
                Button {
                    chat.send()
                } label: {
                    Image(systemName: chat.phase == .idle ? "arrow.up" : "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.onAccent.color)
                        .frame(width: 32, height: 32)
                        .background(palette.accent.color)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chat.phase == .idle ? "发送" : "停止")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .overlay(alignment: .top) {
            palette.line.color.frame(height: 0.5)
        }
    }
}
