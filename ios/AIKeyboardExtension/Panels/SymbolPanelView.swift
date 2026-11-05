//
//  SymbolPanelView.swift
//  墨语键盘 · 表情、符号、短语、剪贴板、候选展开
//

import SwiftUI
import UIKit

/// 表情和符号面板。
@MainActor
struct SymbolPanelView: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.palette) private var palette
    @State private var recent: [String] = UserDefaults.standard.stringArray(forKey: "moyu.emoji.recent") ?? []

    private static let chinese = ["，", "。", "？", "！", "、", "：", "；", "…", "～", "“", "”", "‘", "’", "（", "）",
                                  "《", "》", "【", "】", "—", "·", "￥", "@", "#", "%", "&", "*", "「", "」", "『", "』"]
    private static let english = [",", ".", "?", "!", ":", ";", "'", "\"", "(", ")", "[", "]", "{", "}", "<", ">",
                                  "/", "\\", "|", "_", "-", "+", "=", "*", "&", "^", "~", "`", "$", "#", "%", "@"]
    private static let math = ["+", "−", "×", "÷", "=", "≠", "≈", "<", ">", "≤", "≥", "±", "%", "‰", "°", "π",
                               "∞", "√", "∑", "∈", "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩"]

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.symbolTab {
        case .emoji:
            grid(recent + EmojiData.all.filter { !recent.contains($0) }, columns: 9, fontSize: 25, isEmoji: true)
        case .chinese:
            grid(Self.chinese, columns: 8, fontSize: 20, isEmoji: false)
        case .english:
            grid(Self.english, columns: 8, fontSize: 20, isEmoji: false)
        case .math:
            grid(Self.math, columns: 8, fontSize: 20, isEmoji: false)
        case .phrases:
            phraseList
        case .clipboard:
            clipboardList
        }
    }

    private func grid(_ items: [String], columns: Int, fontSize: CGFloat, isEmoji: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns), spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    Button {
                        session.insert(pair.element)
                        if isEmoji {
                            remember(pair.element)
                        }
                    } label: {
                        Text(pair.element)
                            .font(.system(size: fontSize))
                            .foregroundColor(palette.text.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func remember(_ emoji: String) {
        var list = UserDefaults.standard.stringArray(forKey: "moyu.emoji.recent") ?? []
        list.removeAll { $0 == emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(18)), forKey: "moyu.emoji.recent")
    }

    private var phraseList: some View {
        let items = session.kit.phrases.items
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    Text("还没有短语。到墨语 App 的「键盘」页添加。")
                        .font(.system(size: 14))
                        .foregroundColor(palette.secondary.color)
                        .padding(14)
                }
                ForEach(items) { item in
                    listRow(item.text, caption: item.key.isEmpty ? nil : "打 \(item.key) 也能出来") {
                        session.insert(session.kit.phrases.expand(item, clipboard: nil))
                        session.setPage(.keys)
                    }
                }
            }
        }
    }

    private var clipboardList: some View {
        let isEnabled = session.snapshot.enableClipboardHistory
        let items = isEnabled ? session.kit.clipboard.items : []
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                listRow("粘贴现在复制的内容", caption: "系统可能会问一次是否允许") {
                    guard UIPasteboard.general.hasStrings, let text = UIPasteboard.general.string else {
                        session.showToast("剪贴板里没有文字")
                        return
                    }
                    session.insert(text)
                    if isEnabled {
                        session.kit.clipboard.add(text)
                    }
                    session.setPage(.keys)
                }
                ForEach(items, id: \.self) { text in
                    listRow(text, caption: nil) {
                        session.insert(text)
                        session.setPage(.keys)
                    }
                }
                if !isEnabled {
                    Text("想留下粘贴过的内容，到键盘设置里打开「剪贴板历史」。")
                        .font(.system(size: 13))
                        .foregroundColor(palette.secondary.color)
                        .padding(14)
                }
            }
        }
    }

    private func listRow(_ text: String, caption: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(palette.text.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundColor(palette.secondary.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                palette.line.color.frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", label: "返回") { session.setPage(.keys) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(KeyboardSession.SymbolTab.allCases) { tab in
                        Button {
                            session.symbolTab = tab
                        } label: {
                            Text(tab.title)
                                .font(.system(size: 13, weight: session.symbolTab == tab ? .semibold : .regular))
                                .foregroundColor(session.symbolTab == tab ? palette.text.color : palette.secondary.color)
                                .padding(.horizontal, 11)
                                .frame(height: 36)
                                .background(session.symbolTab == tab ? palette.key.color : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            iconButton("delete.left", label: "退格") { session.handle(.backspace) }
        }
        .padding(.horizontal, 3)
        .frame(height: 44)
        .overlay(alignment: .top) {
            palette.line.color.frame(height: 0.5)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundColor(palette.text.color)
                .frame(width: 46, height: 36)
                .background(palette.function.color)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 候选展开：看到更多候选，点一个就选。
@MainActor
struct CandidateGridView: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.palette) private var palette

    /// 按字数估算宽度，把候选排成一行行。
    private func rows(width: CGFloat) -> [[(index: Int, text: String)]] {
        var rows: [[(index: Int, text: String)]] = []
        var current: [(index: Int, text: String)] = []
        var used: CGFloat = 0
        for (index, candidate) in session.conversion.candidates.enumerated() {
            let cell = max(CGFloat(candidate.text.count) * 19 + 24, 56)
            if used + cell > width, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append((index, candidate.text))
            used += cell
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows(width: proxy.size.width).enumerated()), id: \.offset) { row in
                            HStack(spacing: 0) {
                                ForEach(row.element, id: \.index) { cell in
                                    Button {
                                        session.chooseCandidate(at: cell.index)
                                    } label: {
                                        Text(cell.text)
                                            .font(.system(size: 18, weight: cell.index == 0 ? .semibold : .regular))
                                            .foregroundColor(cell.index == 0 ? palette.accentText.color : palette.text.color)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .overlay(alignment: .trailing) {
                                        palette.line.color.frame(width: 0.5)
                                    }
                                }
                            }
                            .overlay(alignment: .bottom) {
                                palette.line.color.frame(height: 0.5)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                Button {
                    session.setPage(.keys)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 13))
                        Text("收起")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(palette.text.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(palette.function.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    session.handle(.backspace)
                    if !session.isComposing {
                        session.setPage(.keys)
                    }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.system(size: 16))
                        .foregroundColor(palette.text.color)
                        .frame(width: 66, height: 36)
                        .background(palette.function.color)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("退格")
            }
            .padding(.horizontal, 3)
            .frame(height: 44)
        }
    }
}
