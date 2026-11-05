//
//  NotifyChannel.swift
//  墨语 · 不靠任何共享权限的小数据通道
//
//  系统通知中心给每个通知名存一个 64 位的「状态值」，任何进程都能读写，不需要 App Group。
//  一个名字存 8 个字节，把一小段数据拆开存进一串名字里，另一边再拼回来。
//  只适合几 KB 以内、App 和键盘都活着时的数据（语音结果、实时文字），不适合存配置。
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
            set(name + ".len", 0)
            return
        }
        let bytes = [UInt8](data)
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
        // 长度最后写：读的一方先看长度，长度对上了数据一定已经写完
        set(name + ".len", UInt64(bytes.count))
    }

    /// 读。没有就返回 nil。
    public static func read(name: String) -> Data? {
        let length = Int(get(name + ".len"))
        guard length > 0, length <= maxBytes else { return nil }
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
