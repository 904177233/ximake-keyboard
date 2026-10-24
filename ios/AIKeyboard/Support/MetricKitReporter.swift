//
//  MetricKitReporter.swift
//  墨语（Moyu）· 宿主 App 侧 MetricKit 采集器
//
//  模块职责：
//  ①订阅 MetricKit 的「指标包」（MXMetricPayload）与「诊断包」（MXDiagnosticPayload）；
//  ②把最近 7 天的崩溃 / 卡顿 / CPU 累计时间 / 峰值内存落盘到本 App 的 UserDefaults；
//  ③给诊断页提供一行摘要（`summary()`）。
//
//  为什么需要它：键盘扩展被系统因内存超限杀掉（`0xdead10cc` / `EXC_CRASH`）时，
//  **不会**在 App Store Connect 里显示成崩溃，本机不主动采集就永远不知道。
//  MetricKit 是 iOS 13/14 起系统自带的采集通道，零第三方依赖。
//
//  注意：MetricKit 的回调由系统按「使用节奏」投递（通常每天最多一次，且需要 App
//  被正常使用过）。因此这里的数据是**滞后统计**，不是实时监控——实时内存请看键盘
//  扩展侧的 `KMMemoryGovernor`（`ios/AIKeyboardExtension/Support/KMMemoryGovernor.swift`）。
//
//  兼容性：iOS 16.0+。`MXMetricPayload` 为 iOS 13+，`MXDiagnosticPayload` 为 iOS 14+，
//  均低于本工程的最低版本，无需 @available 分支。
//

import Foundation
import MetricKit
import os

/// MetricKit 采集器（宿主 App 侧，进程内单例）。
///
/// 使用方式：在 `AIKeyboardApp.init()` 里调用 `MetricKitReporter.shared.start()` 一次即可。
final class MetricKitReporter: NSObject, MXMetricManagerSubscriber {

    // MARK: - 单例

    /// 全局唯一实例。
    static let shared = MetricKitReporter()

    // MARK: - 常量

    /// 统计窗口（天）。MetricKit 回调稀疏，取 7 天足够看出趋势。
    static let retentionDays: Int = 7

    /// 落盘键（本 App 自己的 UserDefaults 域，与共享层 `SharedStore` 无关）。
    private enum Keys {
        static let daily = "moyu.metrickit.daily.v1"
        static let lastPayloadAt = "moyu.metrickit.lastPayloadAt.v1"
        static let started = "moyu.metrickit.started.v1"
    }

    /// 一天的聚合值。
    private struct DayBucket: Codable {
        var day: String
        var crashCount: Int = 0
        var hangCount: Int = 0
        var cpuSeconds: Double = 0
        var peakMemoryMB: Double = 0
    }

    // MARK: - 状态

    private let queue = DispatchQueue(label: "com.moyu.app.metrickit")
    private let log = Logger(subsystem: "com.moyu.app", category: "metrickit")
    private var buckets: [String: DayBucket] = [:]
    private var loaded = false

    /// 系统日历（用于生成 `yyyy-MM-dd` 的日期键）。
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 单例：禁止外部创建。
    private override init() {
        super.init()
        loadFromDisk()
    }

    // MARK: - 订阅

    /// 开始接收 MetricKit 数据（幂等，重复调用无副作用）。
    func start() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Keys.started) {
            log.debug("MetricKit 已订阅过，跳过重复注册")
            return
        }
        MXMetricManager.shared.add(self)
        defaults.set(true, forKey: Keys.started)
        log.info("已订阅 MetricKit（指标包 + 诊断包）")
    }

    /// 停止接收（仅调试 / 隐私开关用；正常流程不需要调用）。
    func stop() {
        MXMetricManager.shared.remove(self)
        UserDefaults.standard.set(false, forKey: Keys.started)
        log.info("已取消 MetricKit 订阅")
    }

    // MARK: - MXMetricManagerSubscriber

    /// 收到指标包（崩溃之外的健康数据：CPU、内存峰值等）。
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        var updates: [(day: String, cpuSeconds: Double, peakMemoryMB: Double)] = []
        for payload in payloads {
            let day = dayKey(for: payload.timeStampEnd)
            let cpu = payload.cpuMetrics?.cumulativeCPUTime.converted(to: .seconds).value ?? 0
            let peak = payload.memoryMetrics?.peakMemoryUsage
                .converted(to: .mebibytes).value ?? 0
            updates.append((day: day, cpuSeconds: cpu, peakMemoryMB: peak))
        }
        applyMetricUpdates(updates)
        log.info("收到 \(payloads.count, privacy: .public) 个 MetricKit 指标包")
    }

    /// 收到诊断包（崩溃、卡顿、CPU 异常、磁盘写入异常）。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        var updates: [(day: String, crashCount: Int, hangCount: Int, peakMemoryMB: Double)] = []
        for payload in payloads {
            // `timeStampEnd` 走协议统一属性；诊断包与指标包都提供。
            let day = dayKey(for: payload.timeStampEnd)
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            // 诊断包里没有内存指标，峰值交给指标包；这里只补崩溃/卡顿。
            updates.append((day: day, crashCount: crashes, hangCount: hangs, peakMemoryMB: 0))
        }
        applyDiagnosticUpdates(updates)
        log.info("收到 \(payloads.count, privacy: .public) 个 MetricKit 诊断包")
    }

    // MARK: - 写入

    private func applyMetricUpdates(
        _ updates: [(day: String, cpuSeconds: Double, peakMemoryMB: Double)]
    ) {
        queue.sync {
            ensureLoadedLocked()
            for update in updates {
                mutateBucketLocked(day: update.day) { bucket in
                    bucket.cpuSeconds += update.cpuSeconds
                    bucket.peakMemoryMB = max(bucket.peakMemoryMB, update.peakMemoryMB)
                }
            }
            pruneLocked()
            persistLocked()
            UserDefaults.standard.set(Date(), forKey: Keys.lastPayloadAt)
        }
    }

    private func applyDiagnosticUpdates(
        _ updates: [(day: String, crashCount: Int, hangCount: Int, peakMemoryMB: Double)]
    ) {
        queue.sync {
            ensureLoadedLocked()
            for update in updates {
                mutateBucketLocked(day: update.day) { bucket in
                    bucket.crashCount += update.crashCount
                    bucket.hangCount += update.hangCount
                    bucket.peakMemoryMB = max(bucket.peakMemoryMB, update.peakMemoryMB)
                }
            }
            pruneLocked()
            persistLocked()
            UserDefaults.standard.set(Date(), forKey: Keys.lastPayloadAt)
        }
    }

    /// 修改某一天的聚合值（不存在则新建）。
    private func mutateBucketLocked(day: String, _ body: (inout DayBucket) -> Void) {
        var bucket = buckets[day] ?? DayBucket(day: day)
        body(&bucket)
        buckets[day] = bucket
    }

    // MARK: - 持久化

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loadLocked()
        loaded = true
    }

    /// 从 UserDefaults 载入（失败则从空开始，不影响功能）。
    private func loadFromDisk() {
        queue.sync {
            loadLocked()
            loaded = true
        }
    }

    private func loadLocked() {
        guard let data = UserDefaults.standard.data(forKey: Keys.daily),
              let decoded = try? JSONDecoder().decode([String: DayBucket].self, from: data) else {
            buckets = [:]
            return
        }
        buckets = decoded
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(buckets) else { return }
        UserDefaults.standard.set(data, forKey: Keys.daily)
    }

    /// 丢掉统计窗口之外的记录。
    private func pruneLocked() {
        let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -Self.retentionDays,
            to: Date()
        ) ?? Date()
        let cutoffKey = dayFormatter.string(from: cutoff)
        buckets = buckets.filter { $0.key >= cutoffKey }
    }

    private func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    // MARK: - 读取（诊断页）

    /// 最近 7 天的聚合结果。
    struct Snapshot {
        var crashCount: Int
        var hangCount: Int
        var cpuSeconds: Double
        var peakMemoryMB: Double
        var daysCovered: Int
        var lastPayloadAt: Date?
    }

    /// 读取聚合快照（线程安全，可在主线程直接调用）。
    static func snapshot() -> Snapshot {
        shared.makeSnapshot()
    }

    private func makeSnapshot() -> Snapshot {
        let lastPayload = UserDefaults.standard.object(forKey: Keys.lastPayloadAt) as? Date
        return queue.sync {
            ensureLoadedLocked()
            let cutoff = Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: -Self.retentionDays,
                to: Date()
            ) ?? Date()
            let cutoffKey = dayFormatter.string(from: cutoff)
            let recent = buckets.values.filter { $0.day >= cutoffKey }
            return Snapshot(
                crashCount: recent.reduce(0) { $0 + $1.crashCount },
                hangCount: recent.reduce(0) { $0 + $1.hangCount },
                cpuSeconds: recent.reduce(0) { $0 + $1.cpuSeconds },
                peakMemoryMB: recent.map(\.peakMemoryMB).max() ?? 0,
                daysCovered: recent.count,
                lastPayloadAt: lastPayload
            )
        }
    }

    /// 给诊断页 / 报告用的键值对（都是中文可直接显示的值）。
    static func summary() -> [String: String] {
        let snapshot = shared.makeSnapshot()
        var result: [String: String] = [:]
        result["统计窗口"] = "最近 \(retentionDays) 天"
        result["崩溃"] = "\(snapshot.crashCount) 次"
        result["卡顿"] = "\(snapshot.hangCount) 次"
        result["CPU 累计"] = String(format: "%.1f 秒", snapshot.cpuSeconds)
        result["峰值内存"] = snapshot.peakMemoryMB > 0
            ? String(format: "%.1f MB", snapshot.peakMemoryMB)
            : "暂无数据"
        if let last = snapshot.lastPayloadAt {
            result["最近上报"] = Self.relativeDescription(for: last)
        } else {
            result["最近上报"] = "尚未收到系统数据"
        }
        return result
    }

    /// 一行摘要（用于导出报告 / 日志）。
    static func summaryLine() -> String {
        let values = summary()
        let order = ["统计窗口", "崩溃", "卡顿", "CPU 累计", "峰值内存", "最近上报"]
        return order.compactMap { key in
            guard let value = values[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: " · ")
    }

    /// 相对时间描述（「3 小时前」这类）。
    private static func relativeDescription(for date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }
}
