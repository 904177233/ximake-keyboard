//
//  ImageRequest.swift
//  ios/Shared/Models
//
//  模块职责：一次生图请求的参数载体（提示词 + 尺寸 + 质量 + 张数）。
//  依赖：仅 Foundation。
//  使用方：Networking（ImageGenerating.generate 的入参）、UI（生图面板）。
//

import Foundation

/// 一次生图请求。
public struct ImageRequest: Sendable {
    /// 图片描述（中文或英文均可，由服务端模型能力决定）。
    public var prompt: String
    /// 尺寸字符串，统一用 OpenAI 风格 `宽x高`，例如 `1024x1024`、`864x1152`。
    ///
    /// 各客户端负责转成自家格式：DashScope（万相）使用 `1024*1024` 星号格式。
    public var size: String
    /// 质量档位，仅 OpenAI 兼容生图使用（`standard` / `hd` / `high` / `medium` / `low`）。
    public var quality: String
    /// 期望张数，默认 1。部分服务端只支持 1 张，客户端会忽略多余张数。
    public var count: Int

    /// 成员初始化。
    public init(
        prompt: String,
        size: String = "1024x1024",
        quality: String = "standard",
        count: Int = 1
    ) {
        self.prompt = prompt
        self.size = size
        self.quality = quality
        self.count = count
    }

    /// 裁剪后的提示词（去首尾空白，防止空 prompt 请求）。
    public var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 宽度（解析失败回退 1024）。
    public var width: Int {
        ImageRequest.dimensions(from: size)?.width ?? 1024
    }

    /// 高度（解析失败回退 1024）。
    public var height: Int {
        ImageRequest.dimensions(from: size)?.height ?? 1024
    }

    /// 把 `1024x1024` / `1024*1024` / `1024×1024` 统一解析成宽高。
    public static func dimensions(from size: String) -> (width: Int, height: Int)? {
        let normalized = size
            .replacingOccurrences(of: "*", with: "x")
            .replacingOccurrences(of: "×", with: "x")
            .lowercased()
        let parts = normalized.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else {
            return nil
        }
        return (width, height)
    }

    /// 转成 DashScope（万相）要求的星号格式，例如 `1024*1024`。
    public var dashScopeSize: String {
        "\(width)*\(height)"
    }
}
