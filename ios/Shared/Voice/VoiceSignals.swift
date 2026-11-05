//
//  VoiceSignals.swift
//  墨语 · 键盘和 App 之间的即时信号
//
//  系统级通知（Darwin notification）不需要 App Group，键盘和 App 一定收得到，但不能带数据。
//  用来喊「开始」「说完了」「在吗」，文字结果走 VoiceBridge。
//

import Foundation

public enum VoiceSignal: String, CaseIterable, Sendable {
    /// 键盘：开始听。
    case start
    /// 键盘：说完了，出结果。
    case stop
    /// 键盘：不要了。
    case discard
    /// 键盘：App 的语音会话还开着吗？
    case ping
    /// App：开着。
    case pong
    /// App：结果放好了。
    case done

    var notificationName: String { "com.moyu.voice." + rawValue }
}

public enum VoiceSignals {

    nonisolated(unsafe) private static var handlers: [String: [() -> Void]] = [:]
    private static let token = NSObject()

    /// 发一个信号。
    public static func post(_ signal: VoiceSignal) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(signal.notificationName as CFString), nil, nil, true)
    }

    /// 收到信号时在主线程调 handler。同一个信号可以登记多次。
    public static func observe(_ signal: VoiceSignal, _ handler: @escaping () -> Void) {
        let name = signal.notificationName
        let isFirst = handlers[name] == nil
        handlers[name, default: []].append(handler)
        guard isFirst else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, _, cfName, _, _ in
            guard let raw = cfName?.rawValue as String? else { return }
            DispatchQueue.main.async {
                VoiceSignals.dispatch(raw)
            }
        }, name as CFString, nil, .deliverImmediately)
    }

    private static func dispatch(_ name: String) {
        for handler in handlers[name] ?? [] {
            handler()
        }
    }
}
