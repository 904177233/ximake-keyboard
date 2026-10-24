//
//  DiagnosticsFormat.swift
//  墨语 · 宿主 App
//
//  模块职责：诊断页的纯格式化工具 —— 时间、设备、状态名、JSON、字节数、秒数、截断。
//            全部为无状态静态方法，方便单测与复用（诊断报告 / 导出）。
//  依赖：UIKit（UIDevice）、Shared（ConfigSnapshot）。
//  使用方：DiagnosticsView / DiagnosticsChecklist。
//

import UIKit

/// 诊断页的格式化工具集合。
enum DiagnosticsFormat {

    /// 报告里的时间格式。
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// 设备描述。
    static var deviceDescription: String {
        let device = UIDevice.current
        return "\(device.model) · \(device.systemName) \(device.systemVersion)"
    }

    /// 配置快照 JSON（API 密钥不在快照里，天然安全）。
    static func snapshotJSON(_ snapshot: ConfigSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(snapshot) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 字节数描述。
    static func byteDescription(_ text: String) -> String {
        let bytes = text.utf8.count
        if bytes >= 1024 {
            let kb = Double(bytes) / 1024
            return String(format: "%.1f KB", kb)
        }
        return "\(bytes) B"
    }

    /// 秒数描述。
    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f 秒", value)
    }

    /// 截断文本（把换行压成空格）。
    static func truncate(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= limit { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}
