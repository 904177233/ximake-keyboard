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
    private static let commandKey = "moyu.voice.command"
    private static let pasteboardMarker = "com.moyu.voice.result"
    private static let plainTextType = "public.utf8-plain-text"

    /// 实时文字能不能传过去。
    public static var canShareLive: Bool {
        SharedStore.shared.isAppGroupAvailable || SharedVault.shared.isAvailable
    }

    private static func write(_ data: Data?, forKey key: String) {
        if SharedStore.shared.isAppGroupAvailable {
            SharedStore.shared.setData(data, forKey: key)
        } else if SharedVault.shared.isAvailable {
            SharedVault.shared.set(data, forKey: key)
        }
    }

    private static func read(forKey key: String) -> Data? {
        if SharedStore.shared.isAppGroupAvailable {
            return SharedStore.shared.data(forKey: key)
        }
        return SharedVault.shared.data(forKey: key)
    }

    // MARK: - App 写

    public static func publish(_ state: VoiceBridgeState) {
        write(try? JSONEncoder().encode(state), forKey: stateKey)
    }

    /// 说完了：共享存储和剪贴板都放一份。键盘取走任意一份后清掉两边。
    public static func publishFinished(_ text: String) {
        publish(VoiceBridgeState(status: .finished, text: text))
        UIPasteboard.general.setItems(
            [[plainTextType: text, pasteboardMarker: "1"]],
            options: [.expirationDate: Date().addingTimeInterval(300)]
        )
    }

    /// 取走键盘发来的命令。
    public static func takeCommand() -> Command? {
        guard let data = read(forKey: commandKey), let raw = String(data: data, encoding: .utf8) else { return nil }
        write(nil, forKey: commandKey)
        return Command(rawValue: raw)
    }

    public static func clear() {
        write(nil, forKey: stateKey)
        write(nil, forKey: commandKey)
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
            let text = pasteboard.string
            if result == nil {
                result = text
            }
            // 去掉标记，文字留在剪贴板，下次不会重复放
            if let text {
                pasteboard.string = text
            }
        }
        return result
    }
}
