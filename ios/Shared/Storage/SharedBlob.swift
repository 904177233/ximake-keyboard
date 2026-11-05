//
//  SharedBlob.swift
//  墨语 · App 和键盘共用的小块数据
//
//  能打通就放打通的地方（App Group 优先，其次钥匙串访问组），打不通就各存各的。
//  个人词库、AI 偏好、对话记录都走这里，App 里改了键盘能看到。
//

import Foundation

public struct SharedBlob: Sendable {

    public static let shared = SharedBlob(store: .shared)

    private let store: SharedStore
    private let useVault: Bool

    /// - Parameter store: 打不通时的落脚处。测试用的内存 store 不去碰钥匙串。
    public init(store: SharedStore) {
        self.store = store
        self.useVault = store.backing != .memory && !store.isAppGroupAvailable
    }

    /// 给人看的打通情况（设置页显示，出问题时截图回来）。
    public static var statusText: String {
        if let group = SharedStore.shared.groupIdentifier {
            return "App Group 已打通（\(group)）"
        }
        if SharedVault.shared.isAvailable {
            return "钥匙串共享已打通"
        }
        return "没打通（App Group 和钥匙串共享都不可用）"
    }

    /// App 和键盘看到的是不是同一份。
    public var isShared: Bool {
        store.isAppGroupAvailable || (useVault && SharedVault.shared.isAvailable)
    }

    public func data(forKey key: String) -> Data? {
        if useVault, SharedVault.shared.isAvailable {
            return SharedVault.shared.data(forKey: key)
        }
        return store.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        if useVault, SharedVault.shared.isAvailable {
            SharedVault.shared.set(data, forKey: key)
        } else {
            store.setData(data, forKey: key)
        }
    }
}
