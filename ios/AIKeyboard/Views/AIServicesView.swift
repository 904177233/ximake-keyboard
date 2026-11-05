//
//  AIServicesView.swift
//  墨语 App · AI 服务
//

import SwiftUI
import UIKit

@MainActor
struct AIServicesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var editing: ProviderEditTarget?
    @State private var showsAdd = false

    private var chatProviders: [AIProviderConfig] { model.snapshot.providers.filter { $0.supportsChat } }
    private var imageProviders: [AIProviderConfig] { model.snapshot.providers.filter { !$0.supportsChat && $0.supportsImage } }

    var body: some View {
        AppPage(title: "AI", subtitle: "填好后点「测试」，当场告诉你通没通。不通会把服务器的原话显示出来。") {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "写字用哪家")
                ForEach(chatProviders) { provider in
                    row(provider, isDefault: model.snapshot.defaultProvider?.id == provider.id)
                }
                SectionLabel(text: "画图用哪家")
                ForEach(imageProviders) { provider in
                    row(provider, isDefault: model.snapshot.imageProvider?.id == provider.id)
                }
                PrimaryButton(title: "添加服务") { showsAdd = true }
                    .padding(.top, 16)

                SectionLabel(text: "默认语气")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["自然", "简洁", "礼貌", "正式", "热情", "幽默"], id: \.self) { tone in
                            Button {
                                model.update { $0.defaultTone = tone }
                            } label: {
                                Text(tone)
                                    .font(.system(size: 14, weight: model.snapshot.defaultTone == tone ? .semibold : .regular))
                                    .foregroundColor(model.snapshot.defaultTone == tone ? palette.onAccent.color : palette.text.color)
                                    .padding(.horizontal, 13)
                                    .frame(height: 34)
                                    .background(model.snapshot.defaultTone == tone ? palette.accent.color : palette.surface.color)
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                SectionLabel(text: "打字时")
                LineRow(title: "AI 猜下一句", detail: "打完一句后，根据输入框里的话猜你接下来想说什么。会用掉一点额度。") {
                    Toggle("", isOn: Binding(get: { model.snapshot.enableAISuggestion },
                                             set: { value in model.update { $0.enableAISuggestion = value } }))
                        .labelsHidden()
                        .tint(palette.accent.color)
                }
                LineRow(title: "回复给几条") {
                    Stepper("\(model.snapshot.replyCount) 条",
                            value: Binding(get: { model.snapshot.replyCount },
                                           set: { value in model.update { $0.replyCount = value } }),
                            in: 1...5)
                        .font(.system(size: 14))
                        .fixedSize()
                }
                if !model.isSharedWithKeyboard {
                    SecondaryButton(title: "把这些配置发给键盘") { model.sendConfigToKeyboard() }
                        .padding(.top, 16)
                }
            }
        }
        .sheet(item: $editing) { target in
            ProviderEditorView(target: target)
                .environmentObject(model)
                .environment(\.palette, palette)
        }
        .confirmationDialog("添加哪一家", isPresented: $showsAdd, titleVisibility: .visible) {
            ForEach(PresetProviders.all.filter { preset in
                !model.snapshot.providers.contains { $0.id == preset.id }
            }) { preset in
                Button(preset.name) {
                    editing = ProviderEditTarget(config: preset.makeProvider(), isNew: true, preset: preset)
                }
            }
            Button("自定义（中转站、自建服务）") {
                editing = ProviderEditTarget(config: AIProviderConfig(name: "自定义服务"), isNew: true, preset: nil)
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ provider: AIProviderConfig, isDefault: Bool) -> some View {
        Button {
            editing = ProviderEditTarget(config: provider, isNew: false, preset: PresetProviders.preset(id: provider.id))
        } label: {
            LineRow(title: provider.name, detail: provider.supportsChat ? provider.model : (provider.imageModel ?? "")) {
                if !model.hasKey(provider) {
                    StateText(text: "没填 Key")
                } else if isDefault {
                    StateText(text: "正在用", isGood: true)
                } else {
                    StateText(text: "已填")
                }
                Chevron()
            }
        }
        .buttonStyle(.plain)
    }
}

/// 正在编辑的服务。
struct ProviderEditTarget: Identifiable {
    let id = UUID()
    let config: AIProviderConfig
    let isNew: Bool
    let preset: PresetProviders.Preset?
}

/// 编辑一个服务。
@MainActor
struct ProviderEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let target: ProviderEditTarget

    @State private var draft = AIProviderConfig()
    @State private var key = ""
    @State private var headers = ""
    @State private var testMessage: String?
    @State private var testFailed = false
    @State private var isTesting = false
    @State private var didLoad = false

    private var isImageOnly: Bool { PresetProviders.isImageOnly(id: draft.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let note = target.preset?.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundColor(palette.secondary.color)
                            .lineSpacing(2)
                            .padding(.bottom, 6)
                    }
                    if let url = target.preset?.consoleURL {
                        Link("去申请 Key", destination: url)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.bottom, 8)
                    }
                    field("名字", text: $draft.name, placeholder: "随便起")
                    field("地址", text: $draft.baseURL, placeholder: "https://api.example.com/v1", isURL: true)
                    if !isImageOnly {
                        field("模型", text: $draft.model, placeholder: "deepseek-chat", isURL: true)
                        modelChoices
                    }
                    if isImageOnly || draft.supportsImage {
                        field("画图模型", text: Binding(get: { draft.imageModel ?? "" },
                                                    set: { draft.imageModel = $0 }), placeholder: "", isURL: true)
                    }
                    keyField
                    SectionLabel(text: "额外请求头（中转站要的话才填，一行一个 名字: 值）")
                    TextField("HTTP-Referer: https://example.com", text: $headers, axis: .vertical)
                        .font(.system(size: 14))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...5)
                        .padding(10)
                        .background(palette.surface.color)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    SecondaryButton(title: isTesting ? "测试中…" : "测试") { test() }
                        .padding(.top, 18)
                    if let testMessage {
                        Text(testMessage)
                            .font(.system(size: 13.5))
                            .foregroundColor(testFailed ? palette.text.color : palette.accentText.color)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.top, 10)
                    }
                    if !target.isNew {
                        Button(role: .destructive) {
                            delete()
                        } label: {
                            Text("删除这个服务")
                                .font(.system(size: 14.5))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(palette.page.color.ignoresSafeArea())
            .navigationTitle(target.isNew ? "添加服务" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = target.config
            key = KeychainStore.shared.apiKey(for: target.config.id) ?? ""
            headers = target.config.extraHeaders
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, isURL: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
            TextField(placeholder, text: text)
                .font(.system(size: 15.5))
                .textInputAutocapitalization(isURL ? TextInputAutocapitalization.never : TextInputAutocapitalization.sentences)
                .autocorrectionDisabled(isURL)
                .keyboardType(isURL ? .URL : .default)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var modelChoices: some View {
        let models = PresetProviders.knownModels(forBaseURL: draft.baseURL)
        if !models.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(models, id: \.self) { name in
                        Button {
                            draft.model = name
                        } label: {
                            Text(name)
                                .font(.system(size: 12.5))
                                .foregroundColor(draft.model == name ? palette.onAccent.color : palette.text.color)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(draft.model == name ? palette.accent.color : palette.surface.color)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key")
                .font(.system(size: 12.5))
                .foregroundColor(palette.secondary.color)
            HStack(spacing: 10) {
                SecureField("sk-…", text: $key)
                    .font(.system(size: 15.5))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("粘贴") {
                    if let text = UIPasteboard.general.string {
                        key = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
    }

    private func parsedHeaders() -> [String: String] {
        var result: [String: String] = [:]
        for line in headers.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result[name] = value
            }
        }
        return result
    }

    private func test() {
        var config = draft
        config.extraHeaders = parsedHeaders()
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            testFailed = true
            testMessage = "先填 Key"
            return
        }
        isTesting = true
        testMessage = nil
        Task {
            let started = Date()
            let request = ChatRequest(messages: [.user("hi")], temperature: 0, maxTokens: 1024, stream: false)
            do {
                let result = try await AIClientFactory.makeLLM(config: config, apiKey: apiKey).complete(request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let sample = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                testFailed = false
                testMessage = sample.isEmpty
                    ? "连上了（\(ms) 毫秒），但模型没有返回文字，换个模型名试试。"
                    : "能用（\(ms) 毫秒）：\(String(sample.prefix(60)))"
            } catch {
                testFailed = true
                testMessage = AIError.wrap(error).errorDescription ?? error.localizedDescription
            }
            isTesting = false
        }
    }

    private func save() {
        draft.extraHeaders = parsedHeaders()
        let saved = draft
        model.update { snapshot in
            if let index = snapshot.providers.firstIndex(where: { $0.id == saved.id }) {
                snapshot.providers[index] = saved
            } else {
                snapshot.providers.append(saved)
            }
            if snapshot.defaultProviderID == nil, saved.supportsChat {
                snapshot.defaultProviderID = saved.id
            }
            if snapshot.imageProviderID == nil, saved.supportsImage {
                snapshot.imageProviderID = saved.id
            }
        }
        let apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if apiKey.isEmpty {
                try KeychainStore.shared.deleteAPIKey(for: saved.id)
            } else {
                try KeychainStore.shared.setAPIKey(apiKey, for: saved.id)
            }
            model.showToast("已保存")
        } catch {
            model.showToast("Key 没存上：\(error.localizedDescription)")
        }
        dismiss()
    }

    private func delete() {
        let id = draft.id
        model.update { snapshot in
            snapshot.providers.removeAll { $0.id == id }
            if snapshot.defaultProviderID == id {
                snapshot.defaultProviderID = snapshot.providers.first { $0.supportsChat }?.id
            }
            if snapshot.imageProviderID == id {
                snapshot.imageProviderID = snapshot.providers.first { $0.supportsImage }?.id
            }
        }
        try? KeychainStore.shared.deleteAPIKey(for: id)
        dismiss()
    }
}
