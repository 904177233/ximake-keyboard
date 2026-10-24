//
//  GeneratedImage.swift
//  ios/Shared/Models
//
//  模块职责：一张生成完成图片的数据载体（二进制 + 远端地址 + MIME 类型）。
//  依赖：仅 Foundation。
//  使用方：Networking（ImageGenerating.generate 的返回值）、键盘扩展（写入 UIPasteboard.general.image）。
//

import Foundation

/// 一张生成完成的图片。
public struct GeneratedImage: Sendable {
    /// 图片二进制数据。键盘扩展限制 4 MB 以内。
    public var data: Data
    /// 远端图片地址（若服务端返回 URL）。注意：万相返回的 URL 有效期约 24 小时。
    public var remoteURL: URL?
    /// MIME 类型，例如 `image/png`、`image/jpeg`。
    public var mimeType: String

    /// 成员初始化。
    public init(data: Data, remoteURL: URL? = nil, mimeType: String = "image/png") {
        self.data = data
        self.remoteURL = remoteURL
        self.mimeType = mimeType
    }

    /// 数据是否为空。
    public var isEmpty: Bool {
        data.isEmpty
    }

    /// 人类可读的文件大小，例如 `1.2 MB`。
    public var sizeDescription: String {
        let bytes = Double(data.count)
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
        return String(format: "%.0f KB", max(bytes / 1024, 0.1))
    }
}
