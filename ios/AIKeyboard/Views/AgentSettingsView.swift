//
//  AgentSettingsView.swift
//  墨语 App · AI 对话设置
//
//  键盘里 AI 对话的人设、推理、回答长短、带几轮上下文、画图偏好，以及对话记录。
//

import SwiftUI

@MainActor
struct AgentSettingsView: View {
    @Environment(\.palette) private var palette
    @State private var prefs = AIPrefs.load()
    @State private var historyCount = ChatHistoryStore.load().count

    var body: some View {
        Form {
            if !SharedBlob.shared.isShared {
                Section {
                    Text("这台手机上 App 和键盘没打通：这里的设置键盘看不到，键盘的对话记录这里也看不到。键盘对话时顶上那排开关可以直接改推理、长短和人设。")
                        .font(.system(size: 13))
                        .foregroundColor(palette.secondary.color)
                }
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AIPrefs.personaPresets, id: \.title) { preset in
                            Button(preset.title) { prefs.persona = preset.text }
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(prefs.persona == preset.text ? palette.accent.color : palette.surface.color)
                                .foregroundColor(prefs.persona == preset.text ? palette.onAccent.color : palette.text.color)
                                .clipShape(Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                }
                TextField("比如：说话直接，先给结论", text: $prefs.persona, axis: .vertical)
                    .lineLimit(2...6)
            } header: {
                Text("人设")
            } footer: {
                Text("写给 AI 的话，每次对话都会带上。空着就是默认。")
            }

            Section {
                Picker("推理", selection: $prefs.reasoning) {
                    ForEach(AIPrefs.Reasoning.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("回答长短", selection: $prefs.length) {
                    ForEach(AIPrefs.Length.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("联网搜索", selection: $prefs.webSearch) {
                    ForEach(AIPrefs.WebSearchMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Stepper("带上前面 \(prefs.contextTurns) 轮对话", value: $prefs.contextTurns, in: 0...20)
            } header: {
                Text("回答")
            } footer: {
                Text("联网选「自动」时，问到新闻、价格、天气这类会先上网搜（用必应）。深度思考会慢一些，适合难题；不支持的服务会自动按默认回答。带的轮数越多，越记得前面说过什么，也越费额度。")
            }

            Section {
                Picker("画幅", selection: $prefs.imageShape) {
                    ForEach(AIPrefs.ImageShape.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("风格", selection: $prefs.imageStyle) {
                    ForEach(AIPrefs.ImageStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("画之前先把描述写具体", isOn: $prefs.polishImagePrompt)
                    .tint(palette.accent.color)
                Toggle("画不出来时自动换别的模型", isOn: $prefs.imageModelAuto)
                    .tint(palette.accent.color)
            } header: {
                Text("画图")
            } footer: {
                Text("对话里说「画一只猫」就会去画图，回答下面也有「画成图」。只有某个模型有额度时，关掉「自动换」，再到「AI」页的画图服务里选那个模型。")
            }

            Section {
                Toggle("保存对话记录", isOn: $prefs.keepHistory)
                    .tint(palette.accent.color)
                NavigationLink {
                    ChatHistoryView()
                        .environment(\.palette, palette)
                } label: {
                    HStack {
                        Text("对话记录")
                        Spacer()
                        Text("\(historyCount) 条")
                            .foregroundColor(palette.secondary.color)
                    }
                }
            } header: {
                Text("记录")
            } footer: {
                Text("只存在这台手机上，最多留 \(ChatHistoryStore.limit) 条。")
            }
        }
        .navigationTitle("AI 对话")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: prefs) { value in value.save() }
        .onAppear {
            prefs = AIPrefs.load()
            historyCount = ChatHistoryStore.load().count
        }
    }
}

@MainActor
struct ChatHistoryView: View {
    @Environment(\.palette) private var palette
    @State private var entries = ChatHistoryStore.load()
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if entries.isEmpty {
                    Text("还没有记录。在键盘里点墨水滴开始对话。")
                        .font(.system(size: 14))
                        .foregroundColor(palette.secondary.color)
                        .padding(.top, 20)
                }
                ForEach(entries) { entry in
                    HStack {
                        if entry.isUser { Spacer(minLength: 50) }
                        VStack(alignment: entry.isUser ? .trailing : .leading, spacing: 3) {
                            Text(entry.text)
                                .font(.system(size: 15))
                                .foregroundColor(entry.isUser ? palette.onAccent.color : palette.text.color)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(entry.isUser ? palette.accent.color : palette.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5))
                                .foregroundColor(palette.secondary.color)
                        }
                        if !entry.isUser { Spacer(minLength: 50) }
                    }
                }
            }
            .padding(16)
        }
        .background(palette.page.color.ignoresSafeArea())
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !entries.isEmpty {
                Button("清空") { confirmsClear = true }
            }
        }
        .confirmationDialog("清空全部对话记录？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                ChatHistoryStore.save([])
                entries = []
            }
            Button("取消", role: .cancel) {}
        }
        .onAppear { entries = ChatHistoryStore.load() }
    }
}
