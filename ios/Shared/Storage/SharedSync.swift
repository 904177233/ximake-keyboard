//
//  SharedSync.swift
//  墨语 · App 和键盘之间同步设置
//
//  以前每一边各自判断「能不能共享」，判断完只走一条路：有 App Group 就只写 App Group，
//  没有就只写钥匙串。只要两边判断得不一样（比如签名工具只给了 App 开 App Group），
//  一边写的地方另一边根本不读，设置就永远同步不过去。
//
//  现在一份设置同时写进每一条走得通的路，每份都带上写的时间；读的时候把每条路上的都拿出来，用最新的：
//  1. 本地存储（有 App Group 时就是 App Group）
//  2. 钥匙串访问组（SharedVault）
//  3. 系统通知的状态值（NotifyChannel）：不需要任何权限，App 和键盘一定都能读写。
//     只放小的、不含密钥的设置（键盘偏好、AI 对话偏好、服务列表），重启手机后清空，打开一次 App 又会写上。
//

import Foundation

enum SharedSync {

    /// 走系统通知的设置。这条路上别的 App 理论上也能读到，所以不放 API Key、短语这类东西。
    static let notifyKeys: Set<String> = [
        SharedStoreKey.keyboardPrefs,
        SharedStoreKey.configSnapshot,
        "moyu.ai.prefs.v1"
    ]

    private static let magic = Data("MYS1".utf8)

    /// 带时间的一份数据：MYS1 + 8 字节时间（毫秒）+ 原数据。
    static func wrap(_ data: Data, revision: UInt64) -> Data {
        var out = magic
        withUnsafeBytes(of: revision.bigEndian) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    /// 拆开。不是这个格式的（旧版写的）当作时间 0。
    static func unwrap(_ data: Data) -> (revision: UInt64, payload: Data) {
        guard data.count >= magic.count + 8, data.prefix(magic.count) == magic else { return (0, data) }
        var revision: UInt64 = 0
        for byte in data.dropFirst(magic.count).prefix(8) {
            revision = revision << 8 | UInt64(byte)
        }
        return (revision, Data(data.dropFirst(magic.count + 8)))
    }

    static func now() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }

    /// 配置里有自定义请求头时不走系统通知（请求头里可能有密钥）。
    static func safeForNotify(_ data: Data, key: String) -> Bool {
        guard notifyKeys.contains(key) else { return false }
        if key == SharedStoreKey.configSnapshot,
           let text = String(data: data, encoding: .utf8),
           text.contains("\"extraHeaders\":{\"") {
            return false
        }
        return true
    }

    static func notifyName(_ key: String) -> String {
        "moyu.sync." + key
    }

    static func compress(_ data: Data) -> Data? {
        if #available(iOS 13.0, macOS 10.15, *) {
            return try? (data as NSData).compressed(using: .zlib) as Data
        }
        return nil
    }

    static func decompress(_ data: Data) -> Data? {
        if #available(iOS 13.0, macOS 10.15, *) {
            return try? (data as NSData).decompressed(using: .zlib) as Data
        }
        return nil
    }

    /// 写进系统通知：压缩后放得下才放。
    static func writeNotify(_ data: Data?, key: String, revision: UInt64) {
        guard let data else {
            NotifyChannel.write(nil, name: notifyName(key))
            return
        }
        guard safeForNotify(data, key: key), let packed = compress(data) else { return }
        let envelope = wrap(packed, revision: revision)
        guard envelope.count <= NotifyChannel.maxBytes else { return }
        NotifyChannel.write(envelope, name: notifyName(key))
    }

    static func readNotify(key: String) -> (revision: UInt64, payload: Data)? {
        guard notifyKeys.contains(key), let raw = NotifyChannel.read(name: notifyName(key)) else { return nil }
        let unpacked = unwrap(raw)
        guard unpacked.revision > 0, let payload = decompress(unpacked.payload) else { return nil }
        return (unpacked.revision, payload)
    }
}

/// App 和键盘各自报一下自己能用哪几条路，两边都在界面上显示出来。出问题时截这一行就知道卡在哪。
public enum SyncStatus {

    public enum Role: String {
        case app, keyboard
    }

    private static func name(_ role: Role) -> String {
        "moyu.status." + role.rawValue
    }

    /// 这一边现在的情况。
    private static func current() -> String {
        let group = SharedStore.shared.isAppGroupAvailable ? "1" : "0"
        let vault = SharedVault.shared.isAvailable ? "1" : "0"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "\(group)|\(vault)|\(version)|\(SharedSync.now() / 1000)"
    }

    /// 报一下自己的情况（App 启动和回到前台、键盘弹出时调）。
    public static func publish(_ role: Role) {
        NotifyChannel.write(Data(current().utf8), name: name(role))
    }

    private struct Side {
        let group: Bool
        let vault: Bool
        let version: String
    }

    private static func read(_ role: Role) -> Side? {
        guard let data = NotifyChannel.read(name: name(role)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "|").map(String.init)
        guard parts.count >= 3 else { return nil }
        return Side(group: parts[0] == "1", vault: parts[1] == "1", version: parts[2])
    }

    private static func describe(_ side: Side) -> String {
        "App Group \(side.group ? "✓" : "✗") 钥匙串 \(side.vault ? "✓" : "✗")（\(side.version)）"
    }

    /// 两边的情况，加上结论。
    public static func summary(for role: Role) -> String {
        let mine = read(role) ?? { publish(role); return read(role) }()
        let other = read(role == .app ? .keyboard : .app)
        let mineText = mine.map(describe) ?? "读不到"
        let otherName = role == .app ? "键盘" : "App"
        let selfName = role == .app ? "App" : "键盘"
        guard let other else {
            return "\(selfName)：\(mineText)｜\(otherName)：还没报到（打开一次\(otherName)再看）"
        }
        let route: String
        if let mine, mine.group && other.group {
            route = "走 App Group 同步"
        } else if let mine, mine.vault && other.vault {
            route = "走钥匙串同步"
        } else {
            route = "只能走系统通知同步（API Key 要在键盘里再填一次）"
        }
        return "\(selfName)：\(mineText)｜\(otherName)：\(describe(other))｜\(route)"
    }
}
