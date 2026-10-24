//
//  MascotImageCropper.swift
//  墨语 · 宿主 App
//
//  模块职责：把用户从相册/剪贴板导入的任意图片，居中裁成正方形并缩到固定边长，输出 PNG Data；
//  同时提供体积上限常量与「这张图是不是看不出内容」的粗判，供设置页做提示。
//  依赖：UIKit（UIGraphicsImageRenderer 绘图）、Foundation。
//  使用方：ThemeSettingsView。
//  规范依据：design/05-主题与小形象规范.md §4.2（居中裁切 512×512）、§4.3（>20MB 拒绝、纯色/全透明提示）。
//

import Foundation
import UIKit

/// 形象图片的裁切与校验工具。
///
/// 全部方法都是纯函数式的静态方法，不持有状态，可在任意线程被调用。
enum MascotImageCropper {

    // MARK: - 尺寸与体积上限

    /// 输出图片边长：512×512。
    static let side: CGFloat = 512

    /// 相册原图体积上限：20MB（规范 §4.3）。
    static let maxSourceBytes: Int = 20 * 1024 * 1024

    /// 裁切后 PNG 体积上限：4MB（512×512 PNG 通常远低于此，超了说明图片异常）。
    static let maxStoredBytes: Int = 4 * 1024 * 1024

    /// 「看不出内容」的 PNG 体积阈值。
    ///
    /// 512×512 的纯色或全透明图 PNG 编码后通常只有 1–3KB；
    /// 有内容的照片/插画一般在几十 KB 以上。取 8KB 做粗判，只用于提示，不阻断导入。
    private static let blankPNGThreshold: Int = 8 * 1024

    /// 原图上限的中文描述。
    static var maxSourceDescription: String {
        byteText(for: maxSourceBytes)
    }

    /// 存储上限的中文描述。
    static var maxStoredDescription: String {
        byteText(for: maxStoredBytes)
    }

    // MARK: - 裁切

    /// 把任意图片居中裁成 `side × side` 正方形并输出 PNG 数据。
    ///
    /// 采用 `scaleAspectFill` 语义：按较大比例缩放，铺满正方形后居中裁掉多余部分，
    /// 保证不变形。输出使用 `scale = 1`，避免在 3x 屏设备上生成 1536×1536 的大图。
    ///
    /// - Parameter image: 原始图片。
    /// - Returns: PNG 数据；图片尺寸异常时返回 nil。
    static func squarePNG(from image: UIImage) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let target = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            let scale = max(target.width / sourceSize.width, target.height / sourceSize.height)
            let drawSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            let drawOrigin = CGPoint(
                x: (target.width - drawSize.width) / 2,
                y: (target.height - drawSize.height) / 2
            )
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }

        return rendered.pngData()
    }

    // MARK: - 内容粗判

    /// 粗判「这张图是不是看不出内容」（纯色 / 全透明 / 近乎单色）。
    ///
    /// 做法：看裁切后 PNG 的体积。512×512 的纯色或全透明图压缩后只有几 KB，
    /// 有内容的图通常在几十 KB 以上。这里刻意不做逐像素采样，
    /// 避免为了一个提示引入整段 CoreGraphics 绘图代码。
    ///
    /// - Parameter pngData: `squarePNG(from:)` 的输出。
    /// - Returns: 看不出内容时返回 true。
    static func looksBlank(pngData: Data) -> Bool {
        pngData.count < blankPNGThreshold
    }

    // MARK: - 文案

    /// 体积的中文描述（1.2 MB / 512 KB 这种）。
    private static func byteText(for bytes: Int) -> String {
        let megabytes = Double(bytes) / (1024 * 1024)
        if megabytes >= 1 {
            return String(format: "%.0f MB", megabytes)
        }
        let kilobytes = Double(bytes) / 1024
        return String(format: "%.0f KB", kilobytes)
    }
}
