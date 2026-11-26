//
//  NotifyChannel.swift
//  墨语 · 不靠任何共享权限的小数据通道
//
//  系统通知中心给每个通知名存一个 64 位的「状态值」，任何进程都能读写，不需要 App Group。
//  一个名字存 8 个字节，把一小段数据拆开存进一串名字里，另一边再拼回来。
//  只适合几 KB 以内、不含用户输入和密钥的临时状态值，不适合存配置。
//

import Foundation
#if canImport(notify)
import notify
#endif

public enum NotifyChannel {

    nonisolated(unsafe) private static var tokens: [String: Int32] = [:]
    private static let lock = NSLock()
    /// 最多传这么多字节。
    public static let maxBytes = 6000

    private static func token(_ name: String) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = tokens[name] {
            return cached
        }
        var token: Int32 = 0
        guard notify_register_check(name, &token) == 0 else { return nil }
        tokens[name] = token
        return token
    }

    private static func set(_ name: String, _ value: UInt64) {
        guard let token = token(name) else { return }
        _ = notify_set_state(token, value)
    }

    private static func get(_ name: String) -> UInt64 {
        guard let token = token(name) else { return 0 }
        var value: UInt64 = 0
        _ = notify_get_state(token, &value)
        return value
    }

    /// 写（nil 或空表示清掉）。
    public static func write(_ data: Data?, name: String) {
        guard let data, !data.isEmpty, data.count <= maxBytes else {
            clearCurrentValue(name: name)
            return
        }
        let bytes = [UInt8](data)
        let previousLength = get(name + ".len")
        let previousChunks = previousLength > 0 && previousLength <= UInt64(maxBytes)
            ? (Int(previousLength) + 7) / 8 : 0
        var chunk = 0
        var index = 0
        while index < bytes.count {
            var value: UInt64 = 0
            for offset in 0..<8 where index + offset < bytes.count {
                value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset))
            }
            set("\(name).\(chunk)", value)
            index += 8
            chunk += 1
        }
        // 先写内容，最后公布长度。
        set(name + ".len", UInt64(bytes.count))
        let newChunks = (bytes.count + 7) / 8
        if previousChunks > newChunks {
            for staleChunk in newChunks..<previousChunks {
                set("\(name).\(staleChunk)", 0)
            }
        }
    }

    /// 清掉指定通道曾经能容纳的全部数据，包括旧版留下的尾块。
    public static func clear(name: String) {
        set(name + ".len", 0)
        for chunk in 0..<((maxBytes + 7) / 8) {
            var temporary: Int32 = 0
            if notify_register_check("\(name).\(chunk)", &temporary) == 0 {
                _ = notify_set_state(temporary, 0)
                _ = notify_cancel(temporary)
            }
        }
    }

    private static func clearCurrentValue(name: String) {
        let storedLength = get(name + ".len")
        set(name + ".len", 0)
        guard storedLength > 0, storedLength <= UInt64(maxBytes) else { return }
        let length = Int(storedLength)
        for chunk in 0..<((length + 7) / 8) {
            set("\(name).\(chunk)", 0)
        }
    }

    /// 读。没有就返回 nil。
    public static func read(name: String) -> Data? {
        let storedLength = get(name + ".len")
        guard storedLength > 0, storedLength <= UInt64(maxBytes) else { return nil }
        let length = Int(storedLength)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        var chunk = 0
        while bytes.count < length {
            let value = get("\(name).\(chunk)")
            for offset in 0..<8 where bytes.count < length {
                bytes.append(UInt8((value >> (8 * UInt64(offset))) & 0xFF))
            }
            chunk += 1
        }
        return Data(bytes)
    }
}
