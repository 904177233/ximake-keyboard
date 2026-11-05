//
//  AppModel.swift
//  墨语 App · 数据
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var snapshot: ConfigSnapshot
    @Published private(set) var prefs: KeyboardPrefs
    @Published private(set) var phrases: [PhraseItem] = []
    @Published var toast: String?

    private let configStore = ConfigStore()
    private var phraseLibrary = PhraseLibrary(store: .shared)
    private var toastTask: Task<Void, Never>?

    init() {
        snapshot = ConfigStore().load()
        prefs = KeyboardPrefs.load()
        phrases = phraseLibrary.items
    }

    /// 重新读取（键盘里可能改过）。
    func reload() {
        snapshot = configStore.load()
        prefs = KeyboardPrefs.load()
        phraseLibrary = PhraseLibrary(store: .shared)
        phrases = phraseLibrary.items
        objectWillChange.send()
    }

    // MARK: - 配置

    func save(_ updated: ConfigSnapshot) {
        configStore.save(updated)
        snapshot = updated
    }

    func update(_ change: (inout ConfigSnapshot) -> Void) {
        var copy = snapshot
        change(&copy)
        save(copy)
    }

    func updatePrefs(_ change: (inout KeyboardPrefs) -> Void) {
        change(&prefs)
        prefs.save()
    }

    func hasKey(_ provider: AIProviderConfig) -> Bool {
        KeychainStore.shared.hasAPIKey(for: provider.id)
    }

    /// 写字用的服务是否配好了。
    var isChatReady: Bool {
        guard let provider = snapshot.defaultProvider else { return false }
        return provider.isChatConfigured && hasKey(provider)
    }

    /// App 和键盘的配置是否打通。
    var isSharedWithKeyboard: Bool {
        SharedStore.shared.isAppGroupAvailable || SharedVault.shared.isAvailable
    }

    /// 把配置连同 Key 发给键盘（没打通时用）。
    func sendConfigToKeyboard() {
        do {
            try PasteboardBridge.export(snapshot, includeAPIKeys: true)
            showToast("已复制。去键盘的 设置 › AI 服务，点「导入 App 里的配置」")
        } catch {
            showToast("没发出去：\(error.localizedDescription)")
        }
    }

    // MARK: - 短语

    func savePhrase(_ item: PhraseItem) {
        phraseLibrary.upsert(item)
        phrases = phraseLibrary.items
    }

    func removePhrase(id: String) {
        phraseLibrary.remove(id: id)
        phrases = phraseLibrary.items
    }

    // MARK: - 手机上的状态

    /// 键盘是否已添加。系统没有公开接口，读不到时返回 nil。
    var isKeyboardAdded: Bool? {
        guard let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String],
              let bundleID = Bundle.main.bundleIdentifier else {
            return nil
        }
        return keyboards.contains { $0.hasPrefix(bundleID + ".") }
    }

    /// 免费签名还剩几天，读安装包里的描述文件。
    var signatureDaysLeft: Int? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>ExpirationDate</key>"),
              let start = text.range(of: "<date>", range: keyRange.upperBound..<text.endIndex),
              let end = text.range(of: "</date>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: String(text[start.upperBound..<end.lowerBound])) else {
            return nil
        }
        return max(0, Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0)
    }

    /// 版本号。
    var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: - 提示

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
