//
//  SettingsPanelView.swift
//  墨语键盘 · 键盘里的设置
//
//  App 和键盘的配置打不通时，AI 服务也能在这里直接配好。
//  键盘里不能放系统输入框，要填字时进入 FieldEditView，用自己的键区往里打。
//

import Combine
import SwiftUI
import UIKit

/// 设置页路由。
enum SettingsRoute: Equatable {
    case home, providers, provider
}

/// 设置页的数据和动作。
@MainActor
final class SettingsModel: ObservableObject {

    @Published var draft = AIProviderConfig()
    @Published var keyDraft = ""
    @Published var isNew = false
    @Published var testMessage: String?
    @Published var testFailed = false
    @Published var isTesting = false
    @Published var showsAdvanced = false
    /// 查出来的这家现在的模型。
    @Published var liveModels: [String] = []

    private unowned let session: KeyboardSession
    private var testTask: Task<Void, Never>?

    init(session: KeyboardSession) {
        self.session = session
    }

    var providers: [AIProviderConfig] { session.snapshot.providers }

    func hasKey(_ provider: AIProviderConfig) -> Bool {
        KeychainStore.shared.hasAPIKey(for: provider.id)
    }

    /// 编辑已有的服务。
    func edit(_ provider: AIProviderConfig) {
        draft = provider
        keyDraft = KeychainStore.shared.apiKey(for: provider.id) ?? ""
        isNew = false
        testMessage = nil
        showsAdvanced = false
        liveModels = []
        session.settingsRoute = .provider
    }

    /// 从预设新建。
    func add(preset: PresetProviders.Preset?) {
        var provider = preset?.makeProvider() ?? AIProviderConfig(name: "自定义服务")
        if session.snapshot.providers.contains(where: { $0.id == provider.id }) {
            provider.id = UUID().uuidString
        }
        draft = provider
        keyDraft = ""
        isNew = true
        testMessage = nil
        showsAdvanced = false
        liveModels = []
        session.settingsRoute = .provider
    }

    /// 保存。
    func save(toast: String = "已保存") {
        var snapshot = session.snapshot
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let partner = PresetProviders.adopt(draft, keyIsSet: !key.isEmpty, isNew: isNew, into: &snapshot) {
            KeychainStore.shared.hasAPIKey(for: $0)
        }
        session.saveConfig(snapshot)
        if key.isEmpty {
            try? KeychainStore.shared.deleteAPIKey(for: draft.id)
        } else {
            do {
                try KeychainStore.shared.setAPIKey(key, for: draft.id)
                if let partner {
                    try KeychainStore.shared.setAPIKey(key, for: partner.id)
                }
            } catch {
                session.showToast("Key 没存上：\(error.localizedDescription)")
                return
            }
        }
        if let partner {
            session.showToast("已保存。同一个 Key 也配好了\(PresetProviders.shortName(id: partner.id))")
        } else {
            session.showToast(toast)
        }
        session.settingsRoute = .providers
    }

    /// 删除。
    func delete() {
        var snapshot = session.snapshot
        snapshot.providers.removeAll { $0.id == draft.id }
        if snapshot.defaultProviderID == draft.id {
            snapshot.defaultProviderID = snapshot.providers.first { $0.supportsChat }?.id
        }
        if snapshot.imageProviderID == draft.id {
            snapshot.imageProviderID = snapshot.providers.first { $0.supportsImage }?.id
        }
        try? KeychainStore.shared.deleteAPIKey(for: draft.id)
        session.saveConfig(snapshot)
        session.settingsRoute = .providers
    }

    /// 设为默认。
    func setDefault(_ provider: AIProviderConfig) {
        var snapshot = session.snapshot
        if provider.supportsChat {
            snapshot.defaultProviderID = provider.id
        } else if provider.supportsImage {
            snapshot.imageProviderID = provider.id
        }
        session.saveConfig(snapshot)
    }

    /// 真发一次。通了就保存；不通留在这页，把原因写出来。
    func testAndSave() {
        testTask?.cancel()
        let config = draft
        let key = keyDraft
        isTesting = true
        testMessage = nil
        testTask = Task { [weak self] in
            let result = await ProviderCheck.run(config: config, apiKey: key)
            guard let self, !Task.isCancelled else { return }
            self.isTesting = false
            self.draft = result.config
            self.liveModels = result.models
            self.testFailed = !result.isUsable
            self.testMessage = result.message
            if result.isUsable {
                self.save(toast: result.message)
            }
        }
    }

    /// 导入 App 发来的配置。
    func importFromApp() {
        guard let payload = PasteboardBridge.importEnvelope() else {
            session.showToast("没找到配置。先在墨语 App 里点「把配置发给键盘」")
            return
        }
        session.saveConfig(payload.snapshot)
        for (id, key) in payload.apiKeys ?? [:] {
            try? KeychainStore.shared.setAPIKey(key, for: id)
        }
        session.showToast("配置已导入")
    }
}

/// 设置面板。
@MainActor
struct SettingsPanelView: View {
    @ObservedObject var session: KeyboardSession
    @ObservedObject var settings: SettingsModel
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    switch session.settingsRoute {
                    case .home:
                        homeRows
                    case .providers:
                        providerRows
                    case .provider:
                        providerEditor
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            if session.settingsRoute != .home {
                Button {
                    session.settingsRoute = session.settingsRoute == .provider ? .providers : .home
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15))
                        .foregroundColor(palette.text.color)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.text.color)
                .padding(.leading, session.settingsRoute == .home ? 14 : 0)
            Spacer(minLength: 0)
            PanelCloseButton { session.setPage(.keys) }
                .padding(.trailing, 4)
        }
        .frame(height: 44)
    }

    private var title: String {
        switch session.settingsRoute {
        case .home: return "设置"
        case .providers: return "AI 服务"
        case .provider: return settings.draft.name.isEmpty ? "服务" : settings.draft.name
        }
    }

    // MARK: - 首页

    private var homeRows: some View {
        VStack(spacing: 0) {
            Button {
                session.settingsRoute = .providers
            } label: {
                row("AI 服务") {
                    HStack(spacing: 4) {
                        Text(providerSummary)
                            .font(.system(size: 13))
                            .foregroundColor(palette.secondary.color)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondary.color)
                    }
                }
            }
            .buttonStyle(.plain)

            row("主题") {
                HStack(spacing: 7) {
                    ForEach(MoyuThemeID.allCases) { theme in
                        Button {
                            session.updatePrefs { $0.theme = theme }
                        } label: {
                            Circle()
                                .fill(MoyuPalette(theme: theme, dark: session.isDark).accent.color)
                                .frame(width: 20, height: 20)
                                .overlay(Circle().strokeBorder(palette.text.color, lineWidth: session.prefs.theme == theme ? 1.5 : 0).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(theme.title)
                    }
                }
            }

            row("键盘布局") {
                segmented(KeyboardPrefs.Layout.allCases.map { ($0.title, session.prefs.layout == $0) }) { index in
                    session.updatePrefs { $0.layout = KeyboardPrefs.Layout.allCases[index] }
                }
            }
            row("键盘高度") {
                HStack(spacing: 6) {
                    segmented(KeyboardPrefs.Height.allCases.map {
                        ($0.title, session.prefs.customSurfaceHeight == nil && session.prefs.height == $0)
                    }) { index in
                        session.updatePrefs {
                            $0.height = KeyboardPrefs.Height.allCases[index]
                            $0.customSurfaceHeight = nil
                        }
                    }
                    PanelChip(title: "拖动", isSelected: session.prefs.customSurfaceHeight != nil) { session.beginResize() }
                }
            }
            toggleRow("模糊音", isOn: session.prefs.fuzzyPinyin) { value in
                _ = FuzzyPinyinSettings.shared.setEnabled(value)
                session.updatePrefs { $0.fuzzyPinyin = value }
            }
            row("按键震动") {
                segmented(KeyboardPrefs.HapticLevel.allCases.map { ($0.title, session.prefs.haptics == $0) }) { index in
                    session.updatePrefs { $0.haptics = KeyboardPrefs.HapticLevel.allCases[index] }
                }
            }
            toggleRow("按键声音", isOn: session.prefs.keySound) { value in
                session.updatePrefs { $0.keySound = value }
            }
            toggleRow("AI 猜下一句", isOn: session.snapshot.enableAISuggestion) { value in
                var snapshot = session.snapshot
                snapshot.enableAISuggestion = value
                session.saveConfig(snapshot)
            }
            toggleRow("剪贴板历史", isOn: session.snapshot.enableClipboardHistory) { value in
                var snapshot = session.snapshot
                snapshot.enableClipboardHistory = value
                session.saveConfig(snapshot)
                session.kit.clipboard.setEnabled(value)
            }
            toggleRow("记住我打过的词", isOn: session.snapshot.enableLearning) { value in
                var snapshot = session.snapshot
                snapshot.enableLearning = value
                session.saveConfig(snapshot)
            }
            row("个人词库") {
                Text("\(session.kit.learning.learnedWordCount) 条 · 在墨语 App 里管理")
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondary.color)
            }
            row("版本") {
                Text(Self.versionText)
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondary.color)
            }
            row("App 和键盘") {
                Text(SharedBlob.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            row("键盘高度情况") {
                Text(session.host?.heightDiagnostic ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(palette.secondary.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// 版本号。「改了看不到效果」时先看这里，iOS 会缓存键盘进程。
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private var providerSummary: String {
        guard let provider = session.snapshot.defaultProvider else { return "还没配" }
        return settings.hasKey(provider) ? provider.name : "\(provider.name) · 没填 Key"
    }

    // MARK: - 服务列表

    private var providerRows: some View {
        VStack(spacing: 0) {
            ForEach(settings.providers) { provider in
                HStack(spacing: 8) {
                    Button {
                        settings.setDefault(provider)
                    } label: {
                        Image(systemName: isDefault(provider) ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18))
                            .foregroundColor(isDefault(provider) ? palette.accentText.color : palette.secondary.color)
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isDefault(provider) ? "正在用" : "设为默认")

                    Button {
                        settings.edit(provider)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(provider.name)
                                    .font(.system(size: 14.5))
                                    .foregroundColor(palette.text.color)
                                Text(provider.supportsChat ? provider.model : "画图")
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.secondary.color)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(settings.hasKey(provider) ? "" : "没填 Key")
                                .font(.system(size: 12))
                                .foregroundColor(palette.secondary.color)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundColor(palette.secondary.color)
                        }
                        .frame(height: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .overlay(alignment: .bottom) {
                    palette.line.color.frame(height: 0.5)
                }
            }

            addRow("添加写字的", presets: PresetProviders.chatPresetTemplates, showsCustom: true)
            addRow("添加画图的", presets: PresetProviders.imagePresetTemplates, showsCustom: false)
            HStack {
                Spacer(minLength: 0)
                PanelButton(title: "导入 App 里的配置") { settings.importFromApp() }
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func addRow(_ title: String, presets: [PresetProviders.Preset], showsCustom: Bool) -> some View {
        let rest = presets.filter { preset in !settings.providers.contains { $0.id == preset.id } }
        if !rest.isEmpty || showsCustom {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(palette.secondary.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(rest) { preset in
                        PanelChip(title: PresetProviders.shortName(id: preset.id), isSelected: false) { settings.add(preset: preset) }
                    }
                    if showsCustom {
                        PanelChip(title: "自定义", isSelected: false) { settings.add(preset: nil) }
                    }
                }
            }
        }
    }

    private func isDefault(_ provider: AIProviderConfig) -> Bool {
        provider.supportsChat
            ? session.snapshot.defaultProvider?.id == provider.id
            : session.snapshot.imageProvider?.id == provider.id
    }

    // MARK: - 编辑

    private var providerEditor: some View {
        VStack(spacing: 0) {
            if let preset = PresetProviders.preset(id: settings.draft.id) {
                Text(preset.note)
                    .font(.system(size: 12))
                    .foregroundColor(palette.secondary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            keyRow
            modelChips
            if PresetProviders.preset(id: settings.draft.id) != nil {
                Button {
                    settings.showsAdvanced.toggle()
                } label: {
                    row("高级设置") {
                        Image(systemName: settings.showsAdvanced ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11))
                            .foregroundColor(palette.secondary.color)
                    }
                }
                .buttonStyle(.plain)
            }
            if PresetProviders.preset(id: settings.draft.id) == nil || settings.showsAdvanced {
                fieldRow("名字", value: settings.draft.name, preferEnglish: false) { settings.draft.name = $0 }
                fieldRow("地址", value: settings.draft.baseURL, preferEnglish: true) { settings.draft.baseURL = $0 }
                if settings.draft.supportsImage || PresetProviders.isImageOnly(id: settings.draft.id) {
                    fieldRow("画图模型", value: settings.draft.imageModel ?? "", preferEnglish: true) { settings.draft.imageModel = $0 }
                }
                if !PresetProviders.isImageOnly(id: settings.draft.id) {
                    fieldRow("模型", value: settings.draft.model, preferEnglish: true) { settings.draft.model = $0 }
                }
            }

            if let message = settings.testMessage {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(settings.testFailed ? palette.text.color : palette.accentText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                if !settings.isNew {
                    PanelButton(title: "删除") { settings.delete() }
                }
                Spacer(minLength: 0)
                PanelButton(title: "只保存") { settings.save() }
                PanelButton(title: settings.isTesting ? "正在试…" : "试一下并保存", isPrimary: true) { settings.testAndSave() }
            }
            .padding(.top, 10)
        }
    }

    private var modelChips: some View {
        let isImage = PresetProviders.isImageOnly(id: settings.draft.id)
        let current = isImage ? (settings.draft.imageModel ?? "") : settings.draft.model
        let preset = PresetProviders.preset(id: settings.draft.id)?.availableModels.map(\.modelID)
            ?? PresetProviders.knownModels(forBaseURL: settings.draft.baseURL)
        var models = settings.liveModels.isEmpty ? preset : settings.liveModels
        if !current.isEmpty, !models.contains(current) {
            models.insert(current, at: 0)
        }
        return Group {
            if !models.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(models, id: \.self) { model in
                            PanelChip(title: model, isSelected: current == model) {
                                if isImage {
                                    settings.draft.imageModel = model
                                } else {
                                    settings.draft.model = model
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func fieldRow(_ title: String, value: String, preferEnglish: Bool,
                          onDone: @escaping (String) -> Void) -> some View {
        Button {
            session.beginField(title: title, value: value, isSecret: false, preferEnglish: preferEnglish, onDone: onDone)
        } label: {
            row(title) {
                Text(value.isEmpty ? "点这里填" : value)
                    .font(.system(size: 13))
                    .foregroundColor(value.isEmpty ? palette.secondary.color : palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
    }

    private var keyRow: some View {
        Button {
            session.beginField(title: "API Key", value: settings.keyDraft, isSecret: true, preferEnglish: true) { value in
                settings.keyDraft = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } label: {
            row("API Key") {
                Text(maskedKey)
                    .font(.system(size: 13))
                    .foregroundColor(settings.keyDraft.isEmpty ? palette.secondary.color : palette.text.color)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private var maskedKey: String {
        let key = settings.keyDraft
        guard !key.isEmpty else { return "点这里粘贴" }
        return "••••••" + String(key.suffix(4))
    }

    // MARK: - 小部件

    private func row<Accessory: View>(_ title: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14.5))
                .foregroundColor(palette.text.color)
            Spacer(minLength: 8)
            accessory()
        }
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            palette.line.color.frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    private func toggleRow(_ title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        row(title) {
            Toggle("", isOn: Binding(get: { isOn }, set: { action($0) }))
                .labelsHidden()
                .tint(palette.accent.color)
                .scaleEffect(0.85)
        }
    }

    private func segmented(_ items: [(String, Bool)], action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                Button {
                    action(pair.offset)
                } label: {
                    Text(pair.element.0)
                        .font(.system(size: 12.5, weight: pair.element.1 ? .semibold : .regular))
                        .foregroundColor(pair.element.1 ? palette.text.color : palette.secondary.color)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(pair.element.1 ? palette.key.color : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(palette.function.color)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 填写设置项：上面是内容，下面是键盘自己的键区。
@MainActor
struct FieldEditView: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(session.fieldEdit?.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(palette.text.color)
                Spacer(minLength: 0)
                smallButton("粘贴") { session.pasteIntoDraft() }
                smallButton("清空") { session.clearDraft() }
                smallButton("取消") { session.finishField(save: false) }
            }
            HStack(spacing: 0) {
                Text(display)
                    .font(.system(size: 14.5))
                    .foregroundColor(palette.text.color)
                    .lineLimit(1)
                    .truncationMode(.head)
                palette.accent.color.frame(width: 1.5, height: 17)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(palette.key.color)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var display: String {
        if session.fieldEdit?.isSecret == true, session.draft.count > 8 {
            return String(repeating: "•", count: 6) + String(session.draft.suffix(4))
        }
        return session.draft.isEmpty ? " " : session.draft
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundColor(palette.text.color)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(palette.function.color)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 语音输入面板。录音在 App 里，这里显示听到的字。
@MainActor
struct VoicePanelView: View {
    @ObservedObject var session: KeyboardSession
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("语音输入")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(palette.text.color)
                    .padding(.leading, 14)
                Spacer(minLength: 0)
                PanelCloseButton { session.setPage(.keys) }
                    .padding(.trailing, 4)
            }
            .frame(height: 44)

            ScrollView(.vertical, showsIndicators: false) {
                Text(bodyText)
                    .font(.system(size: 16))
                    .foregroundColor(session.voiceText.isEmpty ? palette.secondary.color : palette.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.key.color)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.horizontal, 8)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch session.voiceState {
                case .listening:
                    PanelButton(title: "说完了", isPrimary: true) { session.finishVoice() }
                case .failed:
                    PanelButton(title: "再试一次", isPrimary: true) { session.openVoice() }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
        }
    }

    private var bodyText: String {
        switch session.voiceState {
        case .opening:
            return "正在打开墨语…"
        case .listening:
            return session.voiceText.isEmpty ? "正在听，说吧…" : session.voiceText
        case .transcribing:
            return session.voiceText.isEmpty ? "正在转文字…" : session.voiceText
        case .waitingInApp:
            return "在墨语里说完点「说完了」，回到这里文字会自动放进输入框。"
        case let .failed(reason):
            return reason
        }
    }
}
