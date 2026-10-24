//
//  KMSupport.swift
//  墨语（Moyu）键盘扩展 · 运行时支撑（完全访问探测 / 触感 / 图片缩略）
//
//  模块职责：为键盘 UI 提供三类与系统交互的薄封装：
//            ①`KMFullAccessProbe`：完全没有 `UIInputViewController.hasFullAccess` 时的启发式兜底；
//            ②`KMHaptics`：按键触感（按布局规范 §6 的音效/触感表）；
//            ③`KMImageThumbnail`：把生图结果压到 ≤512px 的缩略图，控制扩展内存峰值。
//  设计依据：docs/01 §6（内存硬约束）、design/键盘布局规范.md §6（触感）、§5 ⑥（生图结果）。
//  约束：扩展内禁止调用任何打开外部应用的接口，所有降级只做文字提示。
//

import UIKit

// MARK: - 完全访问探测

/// 完全访问权限探测。
///
/// 权威来源是 `UIInputViewController.hasFullAccess`（iOS 11+，由 `KeyboardViewController` 注入）；
/// 本类型只作为「拿不到控制器时」的启发式兜底：无完全访问时键盘扩展读取系统剪贴板会失败，
/// 因此「能读到剪贴板内容」可作为正例；读不到时不下结论（返回 `false`，由后续请求失败回填）。
enum KMFullAccessProbe {

    /// 启发式判断当前是否可能拥有完全访问权限。
    /// - Returns: 能读到剪贴板 → `true`；否则 `false`（不代表一定没有权限）。
    static func likelyAvailable() -> Bool {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasStrings { return true }
        if pasteboard.hasImages { return true }
        if pasteboard.hasURLs { return true }
        return false
    }
}

// MARK: - 触感

/// 键盘触感反馈（集中管理，避免各处重复创建发生器）。
enum KMHaptics {

    /// 是否启用触感（无完全访问时关闭，规避扩展内 Taptic 不可用的机型）。
    static var isEnabled: Bool = true

    /// 字母键：轻触。
    static func key() {
        impact(style: .light)
    }

    /// 功能键（Shift / 地球 / 表情 / 切换）：中触。
    static func function() {
        impact(style: .medium)
    }

    /// 退格 / 回车：刚性。
    static func rigid() {
        impact(style: .rigid)
    }

    /// 候选上屏：选择反馈。
    static func candidate() {
        guard isEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    /// AI chip 点击：轻触。
    static func chip() {
        impact(style: .light)
    }

    /// 插入成功：成功提示。
    static func success() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// 错误：警告提示。
    static func warning() {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// 统一的冲击反馈。
    /// - Parameter style: 冲击强度。
    private static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}

// MARK: - 图片缩略

/// 生图结果的缩略图处理。
///
/// 内存策略（docs/01 §6：扩展内存 ≤60MB）：键盘内不保留原图，
/// 只保留长边 ≤512px 的 PNG 缩略数据；复制到剪贴板时使用该缩略图，
/// 因此粘贴出的图片分辨率为 512px（已在 README「已知限制」中说明）。
enum KMImageThumbnail {

    /// 缩略图长边上限（像素）。
    static let maxPixelSize: CGFloat = 512

    /// 把原始图片数据压成缩略图数据。
    /// - Parameter data: 服务端返回的原始图片数据。
    /// - Returns: 长边 ≤512px 的 PNG 数据；解码失败时返回 `nil`。
    static func make(from data: Data) -> Data? {
        guard !data.isEmpty, let image = UIImage(data: data) else { return nil }
        return make(from: image)
    }

    /// 把图片压成缩略图数据。
    /// - Parameter image: 原始图片。
    /// - Returns: 长边 ≤512px 的 PNG 数据。
    static func make(from image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longSide = max(size.width, size.height)
        let ratio = longSide > maxPixelSize ? maxPixelSize / longSide : 1
        let target = CGSize(width: floor(size.width * ratio), height: floor(size.height * ratio))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.pngData()
    }

    /// 缩略数据 → 可放进剪贴板的图片。
    /// - Parameter data: 缩略图数据。
    /// - Returns: 解码后的图片。
    static func image(from data: Data) -> UIImage? {
        UIImage(data: data)
    }
}
