//
//  VoiceBridge.swift
//  墨语 · 键盘和 App 之间传语音结果
//
//  苹果不给自定义键盘用麦克风，录音只能在 App 里。键盘点麦克风跳到 App，App 录音并转文字，
//  结果放到这里，键盘回来时取走、放进输入框。
//
//  两条路：
//  1. App 和键盘打通时（App Group 或钥匙串访问组）：实时文字和「说完了」都走共享存储。
//  2. 没打通时：只有最终结果，走系统剪贴板，带一个标记，键盘认标记才自动放进输入框。
//

import Foundation
import UIKit

/// 一次录音现在的样子。
public struct VoiceBridgeState: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// App 的语音会话开着，等键盘喊开始。
        case ready
        case listening, transcribing, finished, failed
    }

    public var status: Status
    /// 听到的字；失败时是原因。
    public var text: String
    public var updatedAt: Date
    /// 音量 0 到 1，键盘的动画用。
    public var level: Double?

    public init(status: Status, text: String, updatedAt: Date = Date(), level: Double? = nil) {
        self.status = status
        self.text = text
        self.updatedAt = updatedAt
        self.level = level
    }

    /// App 还活着。录音时每秒都会更新。
    public var isFresh: Bool {
        Date().timeIntervalSince(updatedAt) < 6
    }

    /// 结果还算这一次的，太久以前的不放进输入框。
    public var isRecent: Bool {
        Date().timeIntervalSince(updatedAt) < 300
    }
}

public enum VoiceBridge {

    /// 键盘让 App 做什么。
    public enum Command: String, Sendable {
        case start, stop, discard
    }

    private static let stateKey = "moyu.voice.state"
    private static let readerKey = "moyu.voice.keyboardReader"
    private static let commandKey = "moyu.voice.command"
    private static let pasteboardMarker = "com.moyu.voice.result"
    private static let plainTextType = "public.utf8-plain-text"
    /// 后台清一次旧版留在通知里的内容。中途退出会在下次启动时接着清。
    public static func cleanupLegacyNotifyData() {
        _ = legacyNotifyCleanup
    }

    private static let legacyNotifyCleanup: Void = {
        DispatchQueue.global(qos: .utility).async {
            let key = "moyu.legacyNotifyCleaned.v1"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            for name in [stateKey, commandKey, SharedSync.notifyName(SharedStoreKey.configSnapshot),
                         SharedSync.notifyName("moyu.ai.prefs.v1")] {
                NotifyChannel.clear(name: name)
            }
            UserDefaults.standard.set(true, forKey: key)
        }
    }()

    /// App 和键盘打通共享存储后才能传实时文字。
    public static var canShareLive: Bool {
        SharedStore.shared.isAppGroupAvailable || SharedVault.shared.isAvailable
    }

    /// 转写文字只写入 App 与键盘的共享存储。
    private static func write(_ data: Data?, forKey key: String) {
        if SharedStore.shared.isAppGroupAvailable {
            SharedStore.shared.setData(data, forKey: key)
        } else if SharedVault.shared.isAvailable {
            SharedVault.shared.set(data, forKey: key)
        }
    }

    private static func read(forKey key: String) -> Data? {
        if SharedStore.shared.isAppGroupAvailable, let data = SharedStore.shared.data(forKey: key) {
            return data
        }
        if SharedVault.shared.isAvailable, let data = SharedVault.shared.data(forKey: key) {
            return data
        }
        return nil
    }

    /// 键盘在自己选用的共享通道留下时间，App 可以确认两端是否用了同一条路。
    public static func registerKeyboardReader() {
        write(try? JSONEncoder().encode(Date()), forKey: readerKey)
    }

    private static var hasRecentReader: Bool {
        let data = SharedStore.shared.isAppGroupAvailable
            ? SharedStore.shared.data(forKey: readerKey)
            : SharedVault.shared.data(forKey: readerKey)
        guard let data, let date = try? JSONDecoder().decode(Date.self, from: data) else { return false }
        return (0..<300).contains(Date().timeIntervalSince(date))
    }

    // MARK: - App 写

    public static func publish(_ state: VoiceBridgeState) {
        write(try? JSONEncoder().encode(state), forKey: stateKey)
    }

    /// 键盘最近用过同一条共享通道时，结果只放在那里。
    public static func publishFinished(_ text: String) {
        publish(VoiceBridgeState(status: .finished, text: text))
        guard !hasRecentReader else { return }
        UIPasteboard.general.setItems(
            [[plainTextType: text, pasteboardMarker: "1"]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)]
        )
    }

    /// 取走键盘发来的命令。
    public static func takeCommand() -> Command? {
        guard let data = read(forKey: commandKey), let raw = String(data: data, encoding: .utf8) else { return nil }
        write(nil, forKey: commandKey)
        return Command(rawValue: raw)
    }

    public static func clear(keepingResult: Bool = false) {
        if !keepingResult || readState()?.status != .finished {
            write(nil, forKey: stateKey)
        }
        write(nil, forKey: commandKey)
        if !keepingResult { clearPasteboardFallback() }
    }

    // MARK: - 键盘读

    public static func readState() -> VoiceBridgeState? {
        guard let data = read(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(VoiceBridgeState.self, from: data)
    }

    public static func send(_ command: Command) {
        write(command.rawValue.data(using: .utf8), forKey: commandKey)
    }

    /// 有没说完的结果就取走。
    public static func takeFinishedText() -> String? {
        var result: String?
        if let state = readState(), state.status == .finished {
            if state.isRecent, !state.text.isEmpty {
                result = state.text
            }
            write(nil, forKey: stateKey)
        }
        let pasteboard = UIPasteboard.general
        if pasteboard.contains(pasteboardTypes: [pasteboardMarker]) {
            if result == nil { result = pasteboard.string }
            pasteboard.items = []
        }
        return result
    }

    private static func clearPasteboardFallback() {
        let pasteboard = UIPasteboard.general
        if pasteboard.contains(pasteboardTypes: [pasteboardMarker]) {
            pasteboard.items = []
        }
    }
}
