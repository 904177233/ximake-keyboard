//
//  KMMemoryGovernor.swift
//  墨语（Moyu）键盘扩展 · 内存管家
//
//  模块职责：
//  ①按 2 秒周期采样本进程的「物理内存占用」（`phys_footprint`，不是设备总内存）；
//  ②按 30 / 40 / 48 MB 三档阈值分级，主动释放已注册的可回收资源；
//  ③记录最近一次释放的摘要，供诊断 / 日志排查使用。
//
//  为什么必须自己管：键盘扩展的内存上限远小于宿主 App（社区实测 30–66 MB，
//  40 MB 最常见）。超限时系统直接杀进程，**不产生崩溃日志**（App Store Connect
//  里看不到），只能靠键盘自己采样、自己降级。做法参考 OSGKeyboard 的实测策略：
//  键入过程中持续采样，到 40 MiB / 48 MiB 主动释放，正在拼字时推迟重度释放。
//
//  设计依据：docs/08-AI输入法能力调研报告.md（P0-3「内存压缩」）。
//  兼容性：iOS 16.0+。`task_info` / `task_vm_info` 属于 Mach 稳定接口，扩展进程内可用。
//
//  注意：**不要**注册 `UIApplication.didReceiveMemoryWarningNotification`——
//  键盘扩展里拿不到 `UIApplication`，那条通知在扩展里不会送达。
//

import Darwin
import Foundation
import os

/// 键盘扩展的内存管家（进程内全局唯一）。
///
/// 使用方式（宿主控制器里）：
/// ```swift
/// KMMemoryGovernor.shared.shouldDeferHeavyRelease = { [weak self] in
///     guard let self = self else { return true }
///     return !self.model.composing.isEmpty
/// }
/// KMMemoryGovernor.shared.register(name: "image-cache", estimatedBytes: 8 << 20) {
///     // 释放可重建的缓存
/// }
/// KMMemoryGovernor.shared.startMonitoring()
/// ```
final class KMMemoryGovernor: @unchecked Sendable {

    // MARK: - 档位

    /// 内存压力档位。
    ///
    /// 阈值取自 OSGKeyboard 的实测值（30 / 40 / 48 MB）：`elevated` 表示「可以开始
    /// 便宜地放」，`critical` 表示「必须放」，`terminal` 表示「再不放就被系统杀掉」。
    enum Pressure: Int, Comparable, CustomStringConvertible {
        /// < 30 MB。
        case normal = 0
        /// 30–40 MB：只释放便宜的可重建缓存。
        case elevated = 1
        /// 40–48 MB：必须释放，含「有代价」的资源，但仍尽量保住中文引擎。
        case critical = 2
        /// > 48 MB：释放一切能释放的（含引擎缓存）。
        case terminal = 3

        static func < (lhs: Pressure, rhs: Pressure) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// 日志 / 诊断用的英文标识。
        var identifier: String {
            switch self {
            case .normal: return "normal"
            case .elevated: return "elevated"
            case .critical: return "critical"
            case .terminal: return "terminal"
            }
        }

        /// 中文说明（日志 / 诊断展示用）。
        var localizedDescription: String {
            switch self {
            case .normal: return "正常"
            case .elevated: return "偏高"
            case .critical: return "紧张"
            case .terminal: return "临界"
            }
        }

        var description: String { identifier }
    }

    /// 资源释放代价分级。决定「哪一档压力下才值得动它」。
    enum ReclaimStage: Int, Comparable {
        /// 便宜：放掉几乎无感（可重建的缓存）。
        case cheap = 0
        /// 有代价：会丢用户数据或需要重新准备（如剪贴板历史、上下文索引）。
        case costly = 1
        /// 最后手段：重建需要 15–25 ms，会打断输入节奏（中文引擎）。
        case last = 2

        static func < (lhs: ReclaimStage, rhs: ReclaimStage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - 常量

    /// 全局唯一实例。
    static let shared = KMMemoryGovernor()

    /// 采样间隔（秒）。2 秒一次：足够及时，又不至于额外耗电。
    private static let sampleInterval: TimeInterval = 2.0

    /// 两次自动释放之间的最小间隔（秒）。`terminal` 档位与手动释放不受此限。
    private static let minimumReliefInterval: TimeInterval = 10.0

    /// 偏高阈值（MB）。
    static let elevatedThresholdMB: Double = 30
    /// 紧张阈值（MB）。
    static let criticalThresholdMB: Double = 40
    /// 临界阈值（MB）。
    static let terminalThresholdMB: Double = 48

    /// 释放优先级（与注册顺序无关）：先放便宜且可重建的，最后才动引擎。
    private static let releaseOrder: [String] = [
        "image-cache",
        "clipboard-history",
        "contextual-suggestion-cache",
        "pinyin-engine",
    ]

    // MARK: - 注册项

    /// 一条「可释放资源」登记。
    private struct Reclaimer {
        let token: UUID
        let name: String
        let estimatedBytes: Int
        let stage: ReclaimStage
        let sequence: Int
        let release: () -> Void
    }

    // MARK: - 状态

    /// 串行队列保护下面所有可变状态（`Timer` 除外：它只在主线程创建 / 销毁）。
    private let queue = DispatchQueue(label: "com.moyu.keyboard.memory-governor")

    private let log = Logger(subsystem: "com.moyu.keyboard", category: "memory")

    private var reclaimers: [UUID: Reclaimer] = [:]
    private var sequence: Int = 0
    private var lastSampleMB: Double = 0
    private var lastPressure: Pressure = .normal
    private var lastRelief: String?
    private var lastReliefDate: Date?
    private var isRelieving: Bool = false
    private var timer: Timer?

    /// 是否应推迟「重度释放」（中文引擎）。
    ///
    /// 由 `KeyboardViewModel` 侧注入：正在拼字（`composing` 非空）时返回 `true`，
    /// 避免用户打字打到一半引擎被回收导致 15–25 ms 卡顿。
    /// 未注入时视为「不推迟」。
    var shouldDeferHeavyRelease: (() -> Bool)?

    // MARK: - 只读状态

    /// 当前占用（MB，保留 1 位小数）。
    var currentMemoryMB: Double {
        queue.sync { lastSampleMB }
    }

    /// 当前档位。
    var pressure: Pressure {
        queue.sync { lastPressure }
    }

    /// 最近一次释放记录（没有释放过时为 nil）。
    var lastReliefDescription: String? {
        queue.sync { lastRelief }
    }

    /// 最近一次释放的时间。
    var lastReliefAt: Date? {
        queue.sync { lastReliefDate }
    }

    /// 已注册的可释放资源数量。
    var registeredCount: Int {
        queue.sync { reclaimers.count }
    }

    /// 一行摘要（日志 / 诊断用）。
    var diagnosticsLine: String {
        let megabytes = currentMemoryMB
        let level = pressure
        let count = registeredCount
        return "内存 \(Self.formatMB(megabytes)) MB（\(level.localizedDescription)）"
            + " · 阈值 \(Int(Self.elevatedThresholdMB))/\(Int(Self.criticalThresholdMB))/"
            + "\(Int(Self.terminalThresholdMB)) MB · 已注册 \(count) 项"
    }

    /// 单例：禁止外部创建，避免出现两个采样器。
    private init() {}

    // MARK: - 采样

    /// 开始周期采样（键盘 `viewDidLoad` / `activate` 时调用，可重复调用）。
    func startMonitoring() {
        let start: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.stopMonitoring()
            let timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) {
                [weak self] _ in
                self?.sampleAndReact()
            }
            // 容差 25%：系统可以合并唤醒，省电且不影响判断。
            timer.tolerance = Self.sampleInterval * 0.25
            // 键盘弹出时主线程处于 tracking 模式，只挂 default 模式的 Timer 会被暂停。
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            self.sampleAndReact()
            self.log.info("开始内存采样（间隔 \(Self.sampleInterval, privacy: .public) 秒）")
        }
        if Thread.isMainThread {
            start()
        } else {
            DispatchQueue.main.async(execute: start)
        }
    }

    /// 停止采样（键盘 `deactivate` / `viewWillDisappear` 时调用）。
    func stopMonitoring() {
        let stop: () -> Void = { [weak self] in
            guard let self = self else { return }
            guard self.timer != nil else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.log.info("停止内存采样")
        }
        if Thread.isMainThread {
            stop()
        } else {
            DispatchQueue.main.async(execute: stop)
        }
    }

    /// 采样一次并按需释放。
    private func sampleAndReact() {
        let megabytes = Self.currentFootprintMB()
        let level = Self.pressure(forMemoryMB: megabytes)
        let changed: Bool = queue.sync {
            lastSampleMB = megabytes
            let changed = level != lastPressure
            lastPressure = level
            return changed
        }
        if changed {
            log.info("内存档位 → \(level.identifier, privacy: .public)（\(Self.formatMB(megabytes), privacy: .public) MB）")
        }
        if level >= .elevated {
            relieve(aggressive: false)
        }
    }

    /// 把「占用 MB」映射为档位（纯函数，便于审阅与自测）。
    static func pressure(forMemoryMB megabytes: Double) -> Pressure {
        if megabytes >= terminalThresholdMB { return .terminal }
        if megabytes >= criticalThresholdMB { return .critical }
        if megabytes >= elevatedThresholdMB { return .elevated }
        return .normal
    }

    /// 当前进程的物理内存占用（MB）。取不到时返回 0（当作 normal，不误释放）。
    static func currentFootprintMB() -> Double {
        guard let bytes = currentFootprintBytes() else { return 0 }
        return Double(bytes) / (1024 * 1024)
    }

    /// 读取 `phys_footprint`；退化时用 `resident_size`。
    ///
    /// 注意：**不要**用 `ProcessInfo.processInfo.physicalMemory`——那是设备总内存，
    /// 与扩展可用内存无关。`phys_footprint` 才是系统判断「这个进程用了多少」的口径。
    private static func currentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        if result == KERN_SUCCESS, info.phys_footprint > 0 {
            return UInt64(info.phys_footprint)
        }

        // 兜底：老途径 `MACH_TASK_BASIC_INFO` 的 `resident_size`（不含压缩页，偏小）。
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let basicResult: kern_return_t = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &basicCount)
            }
        }
        if basicResult == KERN_SUCCESS {
            return UInt64(basic.resident_size)
        }
        return nil
    }

    // MARK: - 注册

    /// 注册一个「可释放资源」。
    /// - Parameters:
    ///   - name: 资源名（诊断用，建议用 `image-cache` / `pinyin-engine` 这类短横线命名）。
    ///   - estimatedBytes: 估算占用字节数，仅用于诊断显示，不参与决策。
    ///   - stage: 释放代价分级，默认「便宜」。
    ///   - release: 释放闭包。**必须幂等**，可能被连续调用多次。
    /// - Returns: 注销用的 token。
    @discardableResult
    func register(
        name: String,
        estimatedBytes: Int,
        stage: ReclaimStage = .cheap,
        release: @escaping () -> Void
    ) -> UUID {
        let token = UUID()
        queue.sync {
            sequence += 1
            reclaimers[token] = Reclaimer(
                token: token,
                name: name,
                estimatedBytes: estimatedBytes,
                stage: stage,
                sequence: sequence,
                release: release
            )
        }
        log.debug("注册可释放资源 \(name, privacy: .public)（约 \(estimatedBytes, privacy: .public) B）")
        return token
    }

    /// 注销一个注册项。
    func unregister(_ token: UUID) {
        queue.sync {
            _ = reclaimers.removeValue(forKey: token)
        }
    }

    /// 注销全部注册项（视图控制器重建前清场，避免残留闭包）。
    func unregisterAll() {
        queue.sync {
            reclaimers.removeAll()
        }
    }

    // MARK: - 释放

    /// 手动触发一次降级。
    /// - Parameter aggressive: `true` 时即使处于 `normal` 档位也释放全部资源。
    func relieve(aggressive: Bool) {
        let deferHeavy = shouldDeferHeavyRelease?() ?? false
        let decision: (plan: [Reclaimer], megabytes: Double, level: Pressure)? = queue.sync {
            guard !isRelieving else { return nil }
            let now = Date()
            if !aggressive, let last = lastReliefDate,
               now.timeIntervalSince(last) < Self.minimumReliefInterval,
               lastPressure < .terminal {
                return nil
            }
            let ordered = orderedReclaimersLocked()
            let names = Self.releasePlan(
                pressure: lastPressure,
                aggressive: aggressive,
                deferHeavy: deferHeavy,
                reclaimables: ordered.map { (name: $0.name, stage: $0.stage) }
            )
            let chosen = ordered.filter { names.contains($0.name) }
            guard !chosen.isEmpty else { return nil }
            isRelieving = true
            return (chosen, lastSampleMB, lastPressure)
        }
        guard let decision = decision else { return }

        let began = Date()
        for reclaimer in decision.plan {
            reclaimer.release()
        }
        let names = decision.plan.map(\.name).joined(separator: "、")
        let description = "释放 \(decision.plan.count) 项（\(names)）"
            + " · \(Self.formatMB(decision.megabytes)) MB · \(decision.level.identifier)"
        queue.sync {
            isRelieving = false
            lastReliefDate = began
            lastRelief = description
        }
        log.info("\(description, privacy: .public)")
    }

    /// 计算本次该释放哪些资源（纯函数，便于审阅与自测）。
    ///
    /// 规则：
    /// - `normal`：什么都不放（`aggressive` 手动释放除外）；
    /// - `elevated`：只放 `cheap`；
    /// - `critical`：放 `cheap` + `costly`，**保住引擎**；
    /// - `terminal`：全放（系统已在杀进程边缘，来不及讲究）；
    /// - 正在拼字（`deferHeavy`）且未到 `terminal`：不碰 `last`（引擎）；
    ///   若此时还不到 `critical`，进一步只放 `cheap`。
    /// - Parameters:
    ///   - pressure: 当前档位。
    ///   - aggressive: 是否手动强制。
    ///   - deferHeavy: 是否正在拼字。
    ///   - reclaimables: 已注册资源（需按释放优先级排好序）。
    /// - Returns: 需要释放的资源名，按传入顺序。
    static func releasePlan(
        pressure: Pressure,
        aggressive: Bool,
        deferHeavy: Bool,
        reclaimables: [(name: String, stage: ReclaimStage)]
    ) -> [String] {
        guard !reclaimables.isEmpty else { return [] }
        var allowed: Set<ReclaimStage>
        if aggressive {
            allowed = [.cheap, .costly, .last]
        } else {
            switch pressure {
            case .normal:
                return []
            case .elevated:
                allowed = [.cheap]
            case .critical:
                allowed = [.cheap, .costly]
            case .terminal:
                allowed = [.cheap, .costly, .last]
            }
        }
        if deferHeavy, !aggressive, pressure < .terminal {
            allowed.remove(.last)
            if pressure < .critical {
                allowed = [.cheap]
            }
        }
        return reclaimables.filter { allowed.contains($0.stage) }.map(\.name)
    }

    /// 按释放优先级 + 注册顺序排好的注册项（调用方必须已持有 `queue`）。
    private func orderedReclaimersLocked() -> [Reclaimer] {
        reclaimers.values.sorted { lhs, rhs in
            let left = Self.releasePriority(named: lhs.name)
            let right = Self.releasePriority(named: rhs.name)
            if left != right { return left < right }
            return lhs.sequence < rhs.sequence
        }
    }

    /// 释放优先级：名单内的按名单顺序，未登记的排在最后。
    private static func releasePriority(named name: String) -> Int {
        if let index = releaseOrder.firstIndex(of: name) { return index }
        return releaseOrder.count
    }

    /// 统一的 MB 格式化（保留 1 位小数）。
    private static func formatMB(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
