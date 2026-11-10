//
//  KeyboardPrefsView.swift
//  墨语 App · 键盘
//

import AVFoundation
import Photos
import PhotosUI
import Speech
import SwiftUI
import UIKit

@MainActor
struct KeyboardPrefsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme
    @State private var photoItem: PhotosPickerItem?
    @State private var voiceStatus = ""
    @State private var photoStatus = ""
    @State private var voiceMinutes = AIPrefs.load().voiceKeepAliveMinutes

    var body: some View {
        AppPage(title: "键盘", subtitle: "颜色只用两种，一种底色，一种主色。") {
            VStack(alignment: .leading, spacing: 0) {
                themeGrid
                    .padding(.top, 8)

                SectionLabel(text: "小形象（在空格键右边）")
                mascotPicker

                SectionLabel(text: "打字")
                pickerRow("默认布局", items: KeyboardPrefs.Layout.allCases.map { ($0.title, model.prefs.layout == $0) }) { index in
                    model.updatePrefs { $0.layout = KeyboardPrefs.Layout.allCases[index] }
                }
                pickerRow("键盘高度", items: KeyboardPrefs.Height.allCases.map {
                    ($0.title, model.prefs.customSurfaceHeight == nil && model.prefs.height == $0)
                }) { index in
                    model.updatePrefs {
                        $0.height = KeyboardPrefs.Height.allCases[index]
                        $0.customSurfaceHeight = nil
                    }
                }
                if model.prefs.customSurfaceHeight != nil {
                    Text("现在用的是在键盘上拖出来的高度。要再调，到键盘的设置里点「拖动」。")
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.secondary.color)
                        .padding(.vertical, 4)
                }
                toggle("模糊音", detail: "z/zh、c/ch、s/sh、in/ing、l/n 不分也能打对", isOn: model.prefs.fuzzyPinyin) { value in
                    model.updatePrefs { $0.fuzzyPinyin = value }
                }
                toggle("打错字时帮我猜", detail: "句子里有一个字母打错时帮你纠正，候选上标「纠错」", isOn: model.snapshot.enableTypoCorrection) { value in
                    model.update { $0.enableTypoCorrection = value }
                }
                toggle("背景跟随系统", detail: "打开后键盘底色透明、按键用系统那种灰，和下面地球键那一排连成一片；默认用主题颜色", isOn: model.prefs.systemBackground) { value in
                    model.updatePrefs { $0.systemBackground = value }
                }
                toggle("英文联想", detail: "英文模式下打字时在候选栏给补全，点一下换成整个词", isOn: model.prefs.englishSuggestions) { value in
                    model.updatePrefs { $0.englishSuggestions = value }
                }
                toggle("每天更新新词", detail: "打开完全访问后，键盘每天从项目仓库下载一次新词表，只下载不上传", isOn: model.prefs.autoUpdateHotWords) { value in
                    model.updatePrefs { $0.autoUpdateHotWords = value }
                }
                pickerRow("按键震动", items: KeyboardPrefs.HapticLevel.allCases.map { ($0.title, model.prefs.haptics == $0) }) { index in
                    model.updatePrefs { $0.haptics = KeyboardPrefs.HapticLevel.allCases[index] }
                }
                toggle("按键声音", detail: "手机静音时听不到", isOn: model.prefs.keySound) { value in
                    model.updatePrefs { $0.keySound = value }
                }

                SectionLabel(text: "内容")
                NavigationLink {
                    PhrasesView()
                        .environmentObject(model)
                        .environment(\.palette, palette)
                } label: {
                    LineRow(title: "常用短语", detail: "地址、邮箱这种，打几个字母就能出来") {
                        StateText(text: "\(model.phrases.count) 条")
                        Chevron()
                    }
                }
                .buttonStyle(.plain)
                toggle("剪贴板历史", detail: "留下在键盘里粘贴过的内容，最多 20 条，只存在这台手机", isOn: model.snapshot.enableClipboardHistory) { value in
                    model.update { $0.enableClipboardHistory = value }
                }
                toggle("记住我打过的词", detail: "选过的词下次排第一个，只存在这台手机", isOn: model.snapshot.enableLearning) { value in
                    model.update { $0.enableLearning = value }
                }
                NavigationLink {
                    PersonalDictionaryView()
                        .environment(\.palette, palette)
                } label: {
                    LineRow(title: "个人词库", detail: "看、加、删、清空记下的词") {
                        Chevron()
                    }
                }
                .buttonStyle(.plain)

                SectionLabel(text: "语音输入")
                NavigationLink {
                    VoiceSessionView()
                        .environmentObject(model)
                        .environment(\.palette, palette)
                } label: {
                    LineRow(title: "说话转文字", detail: "第一次在键盘上长按空格会跳到这里。打开后回到聊天框，长按空格就能直接说。") {
                        Chevron()
                    }
                }
                .buttonStyle(.plain)
                pickerRow("麦克风开着多久", items: [1, 5, 15, 30].map { ("\($0) 分", voiceMinutes == $0) }) { index in
                    var prefs = AIPrefs.load()
                    prefs.voiceKeepAliveMinutes = [1, 5, 15, 30][index]
                    prefs.save()
                    voiceMinutes = prefs.voiceKeepAliveMinutes
                }
                LineRow(title: "允许麦克风和语音识别", detail: voiceStatus.isEmpty ? "键盘里不能弹权限框，要在这里先允许。" : voiceStatus) {
                    Button("允许") { requestVoicePermission() }
                        .font(.system(size: 14, weight: .semibold))
                }

                SectionLabel(text: "图片")
                LineRow(title: "允许存图片", detail: photoStatus.isEmpty ? "键盘里画的图要存到相册，得先在这里允许一次" : photoStatus) {
                    Button("允许") { requestPhotoPermission() }
                        .font(.system(size: 14, weight: .semibold))
                }

                if !model.isSharedWithKeyboard {
                    Text("这台手机上 App 和键盘的配置没打通，这页的改动键盘看不到。主题和布局可以直接在键盘的设置里改。")
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.secondary.color)
                        .lineSpacing(2)
                        .padding(.top, 16)
                }
            }
        }
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task {
                await loadMascot(from: item)
            }
        }
    }

    // MARK: - 主题

    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
            ForEach(MoyuThemeID.allCases) { theme in
                Button {
                    model.updatePrefs { $0.theme = theme }
                } label: {
                    VStack(spacing: 5) {
                        KeyboardThumbnail(palette: MoyuPalette(theme: theme, dark: colorScheme == .dark))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(palette.text.color, lineWidth: model.prefs.theme == theme ? 2 : 0)
                                    .padding(-3)
                            )
                        Text(theme.title)
                            .font(.system(size: 12.5, weight: model.prefs.theme == theme ? .semibold : .regular))
                            .foregroundColor(palette.text.color)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 小形象

    private var mascotPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(MascotSymbol.allCases.filter { $0 != .custom }) { symbol in
                    Button {
                        model.updatePrefs { $0.mascot = symbol }
                    } label: {
                        Image(systemName: symbol.systemName ?? "drop.fill")
                            .font(.system(size: 19))
                            .foregroundColor(palette.accentText.color)
                            .frame(width: 46, height: 46)
                            .background(palette.surface.color)
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(palette.text.color, lineWidth: model.prefs.mascot == symbol ? 1.5 : 0)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(symbol.title)
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Group {
                        if model.prefs.mascot == .custom,
                           let data = SharedStore.shared.data(forKey: SharedStoreKey.customMascot),
                           let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 18))
                                .foregroundColor(palette.secondary.color)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .background(palette.surface.color)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(palette.text.color, lineWidth: model.prefs.mascot == .custom ? 1.5 : 0)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .accessibilityLabel("用我自己的图")
            }
            .padding(.vertical, 2)
        }
    }

    private func loadMascot(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            model.showToast("这张图读不出来，换一张试试")
            return
        }
        let side: CGFloat = 96
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let png = renderer.pngData { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        SharedStore.shared.setData(png, forKey: SharedStoreKey.customMascot)
        model.updatePrefs { $0.mascot = .custom }
    }

    // MARK: - 小部件

    private func toggle(_ title: String, detail: String?, isOn: Bool, action: @escaping (Bool) -> Void) -> some View {
        LineRow(title: title, detail: detail) {
            Toggle("", isOn: Binding(get: { isOn }, set: { action($0) }))
                .labelsHidden()
                .tint(palette.accent.color)
        }
    }

    private func pickerRow(_ title: String, items: [(String, Bool)], action: @escaping (Int) -> Void) -> some View {
        LineRow(title: title) {
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { pair in
                    Button {
                        action(pair.offset)
                    } label: {
                        Text(pair.element.0)
                            .font(.system(size: 13, weight: pair.element.1 ? .semibold : .regular))
                            .foregroundColor(pair.element.1 ? palette.onAccent.color : palette.secondary.color)
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(pair.element.1 ? palette.accent.color : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(palette.surface.color)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func requestPhotoPermission() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor in
                photoStatus = status == .authorized || status == .limited
                    ? "已经允许了，键盘里画的图可以存相册了"
                    : "没有允许。到 设置 › 墨语 › 照片 里打开"
            }
        }
    }

    private func requestVoicePermission() {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in
                    if granted, status == .authorized {
                        voiceStatus = "已经允许了，回到键盘试试工具栏里的麦克风。"
                    } else {
                        voiceStatus = "没有允许。到 设置 › 墨语 里打开麦克风和语音识别。"
                    }
                }
            }
        }
    }
}

/// 主题缩略图：一个迷你键盘。
struct KeyboardThumbnail: View {
    let palette: MoyuPalette

    var body: some View {
        VStack(spacing: 3) {
            row(count: 6)
            row(count: 5)
            HStack(spacing: 2.5) {
                palette.function.color.frame(width: 14).clipShape(RoundedRectangle(cornerRadius: 2))
                palette.key.color.clipShape(RoundedRectangle(cornerRadius: 2))
                palette.accent.color.frame(width: 22).clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .padding(6)
        .frame(height: 68)
        .background(palette.canvas.color)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func row(count: Int) -> some View {
        HStack(spacing: 2.5) {
            ForEach(0..<count, id: \.self) { _ in
                palette.key.color.clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }
}

/// 常用短语。
@MainActor
struct PhrasesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.palette) private var palette
    @State private var newKey = ""
    @State private var newText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("写上快捷字母的话，打这几个字母就会出现在候选第一个。可以用 {date} 和 {time} 代表今天的日期和现在的时间。")
                    .font(.system(size: 13))
                    .foregroundColor(palette.secondary.color)
                    .lineSpacing(2)
                    .padding(.bottom, 10)

                TextField("短语内容", text: $newText, axis: .vertical)
                    .font(.system(size: 15))
                    .lineLimit(1...4)
                    .padding(11)
                    .background(palette.surface.color)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 10) {
                    TextField("快捷字母（可不填），比如 dz", text: $newKey)
                        .font(.system(size: 15))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(11)
                        .background(palette.surface.color)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("添加") {
                        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        model.savePhrase(PhraseItem(key: newKey.trimmingCharacters(in: .whitespaces).lowercased(), text: text))
                        newText = ""
                        newKey = ""
                    }
                    .font(.system(size: 15, weight: .semibold))
                }
                .padding(.top, 8)

                SectionLabel(text: "已有的")
                ForEach(model.phrases) { item in
                    LineRow(title: item.text, detail: item.key.isEmpty ? nil : "打 \(item.key)") {
                        Button {
                            model.removePhrase(id: item.id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(palette.secondary.color)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除")
                    }
                }
            }
            .padding(20)
        }
        .background(palette.page.color.ignoresSafeArea())
        .navigationTitle("常用短语")
        .navigationBarTitleDisplayMode(.inline)
    }
}
