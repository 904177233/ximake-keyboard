//
//  SignatureClock.swift
//  墨语 · 宿主 App
//
//  模块职责：估算免费 Apple ID 签名的剩余天数（7 天有效期）。
//  说明：iOS 不提供"当前签名还剩几天"的 API，只能记录首次运行日期做估算。
//       用户在设置页看到的「签名剩余 N 天」是**参考值**，实际以系统是否弹
//       「不受信任的开发者」为准。
//  依赖：SharedStore（共享偏好存储）。
//  使用方：SettingsView / InstallGuideView / DiagnosticsView / AboutView。
//

import Foundation

/// 签名剩余天数估算。
enum SignatureClock {

    /// 免费签名有效期（7 天）。
    static let validityDays = 7

    /// 首次运行日期在共享存储里的键。
    private static let firstRunKey = "moyu.host.firstRunAt"

    /// 估算结果。
    enum Remaining: Equatable {
        /// 还没记录首次运行日期。
        case unknown
        /// 已过期。
        case expired
        /// 还剩几天（0 表示今天到期）。
        case days(Int)
    }

    /// 记录首次运行日期（只在第一次调用时写入）。
    static func markFirstRunIfNeeded() {
        let defaults = SharedStore.shared.defaults
        guard defaults.double(forKey: firstRunKey) <= 0 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: firstRunKey)
    }

    /// 首次运行日期。
    static var firstRunDate: Date? {
        let raw = SharedStore.shared.defaults.double(forKey: firstRunKey)
        guard raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// 估算剩余天数。
    static func remainingDays() -> Remaining {
        guard let firstRun = firstRunDate else { return .unknown }
        let elapsed = Date().timeIntervalSince(firstRun)
        let usedDays = Int(elapsed / 86_400)
        let remaining = validityDays - usedDays
        if remaining < 0 {
            return .expired
        }
        return .days(remaining)
    }

    /// 一句话描述（用于诊断页与关于页）。
    static var summary: String {
        switch remainingDays() {
        case .unknown:
            return "还没有记录首次安装日期"
        case .expired:
            return "距首次安装已超过 \(validityDays) 天，签名可能已过期"
        case .days(let value):
            return "距首次安装 \(validityDays - value) 天，按 7 天有效期估算还剩 \(value) 天"
        }
    }
}
