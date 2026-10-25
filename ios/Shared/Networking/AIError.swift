//
//  AIError.swift
//  ios/Shared/Networking
//
//  模块职责：把网络层与解析层所有失败原因收敛成一个面向用户的错误类型，
//            提供中文 errorDescription（一句话说清发生什么）与
//            recoverySuggestion（一句话说清下一步该做什么）。
//  依赖：仅 Foundation（本文件 import Foundation，不 import UIKit/SwiftUI）。
//  使用方：Networking 全部客户端、键盘扩展（AI 结果卡片错误态）、宿主 App（测试连接按钮）。
//

import Foundation

/// AI 服务调用的统一错误。
///
/// 展示约定：
/// - `errorDescription` 只描述现象，不含技术名词，例如「API Key 无效或已过期」。
/// - `recoverySuggestion` 必须是可执行动作，例如「去 设置 › AI 服务 填写正确的 API Key」。
public enum AIError: LocalizedError, Equatable, Sendable {
    /// 尚未配置服务商（没有可选 Provider，或 baseURL/模型为空）。
    case notConfigured
    /// 该服务商还没有填写 API Key。
    case missingAPIKey
    /// 鉴权失败（HTTP 401 / 403，或服务端返回 invalid_api_key）。
    case unauthorized
    /// 触发限流（HTTP 429）。`retryAfter` 为服务端建议的等待秒数（读 `Retry-After`）。
    case rateLimited(retryAfter: TimeInterval?)
    /// 服务端错误（HTTP 5xx 或其它非 2xx）。`code` 为状态码，`message` 为提取出的中文/英文提示。
    case server(code: Int, message: String?)
    /// 网络不可达（无网络、DNS 失败、TLS 失败、连接被拒）。
    case network(String)
    /// 请求超时。
    case timeout
    /// 响应解析失败（JSON 结构不符、SSE 数据畸形）。
    case decoding(String)
    /// 内容被服务端拒绝（风控 / safety / `content_filter`，或返回空文本）。
    case contentRejected(String?)
    /// 任务被用户取消。
    case cancelled
    /// 未归类的错误。
    case unknown(String)

    /// 中文一句话描述（现象）。
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有配置 AI 服务商"
        case .missingAPIKey:
            return "这个服务商还没有填写 API Key"
        case .unauthorized:
            return "API Key 无效或已过期"
        case let .rateLimited(retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "请求太频繁，被服务端限流（约 \(Int(retryAfter.rounded(.up))) 秒后重试）"
            }
            return "请求太频繁，被服务端限流"
        case let .server(code, message):
            if let message, !message.isEmpty {
                return "服务端返回错误（\(code)）：\(message)"
            }
            return "服务端返回错误（HTTP \(code)）"
        case .network:
            return "网络连接失败"
        case .timeout:
            return "请求超时"
        case .decoding:
            return "返回数据格式无法识别"
        case let .contentRejected(reason):
            // v2：**不要把 reason 拼在「内容被拒绝：」后面**。
            // `contentRejected` 现在被复用为「正文为空」的兜底错误（推理模型把
            // token 预算全烧在思维链上、finish_reason=length 等），那些 reason
            // 讲的是长度/token 问题，前面加「内容被拒绝：」会让人以为说了敏感话。
            // 直接透传 reason，没有 reason 时才用通用文案。
            if let reason, !reason.isEmpty {
                return reason
            }
            return "服务端没有返回内容"
        case .cancelled:
            return "已取消"
        case let .unknown(message):
            // v2.3：**把 message 透出来**。之前这里固定返回「发生了未知错误」，
            // 把调用方精心构造的那句话（比如「模型没有返回内容」）整个丢掉了，
            // 用户只看到一句无信息量的「未知错误」，根本没法判断该改什么。
            if !message.isEmpty {
                return message
            }
            return "发生了未知错误"
        }
    }

    /// 中文可执行建议（下一步做什么）。
    public var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "去 设置 › AI 服务 添加一个服务商（推荐 DeepSeek），填入 API Key 后即可使用。"
        case .missingAPIKey:
            return "去 设置 › AI 服务 选择该服务商，填写 API Key（通常以 sk- 开头）。"
        case .unauthorized:
            return "去 设置 › AI 服务 检查 API Key 是否复制完整、是否已被删除，必要时重新生成一个。"
        case .rateLimited:
            return "稍等十几秒再试；如果经常限流，去服务商控制台确认额度或换一个模型。"
        case let .server(code, _):
            if code == 404 {
                return "检查 设置 › AI 服务 里的 baseURL 与模型名是否写对（baseURL 一般以 /v1 结尾）。"
            }
            if code == 400 {
                return "检查模型名是否可用、请求是否超长；也可以换一个模型再试。"
            }
            return "这是服务商侧的问题，稍后重试；若持续失败，去服务商控制台看服务状态。"
        case .network:
            return "检查手机是否联网；键盘需要开启「允许完全访问」才能联网（设置 › 通用 › 键盘）。"
        case .timeout:
            return "网络较慢，稍后重试；或在 设置 › AI 服务 里把超时时间调大。"
        case .decoding:
            return "该服务商的返回格式可能不兼容，试试把协议类型改成「OpenAI 兼容」或换一家服务商。"
        case let .contentRejected(reason):
            // 只有当 reason 为空（真正的「被拒绝但没给理由」）才给敏感话题建议；
            // 有 reason 时说明原因已经写在 errorDescription 里，再补一句固定的
            // 「涉及敏感话题」只会误导（用户遇到的是 token 预算问题）。
            if let reason, !reason.isEmpty {
                return nil
            }
            return "换个说法或缩短内容后再试；涉及敏感话题时模型会拒绝回答。"
        case .cancelled:
            return "已停止本次生成，可以重新点击 AI 按钮。"
        case .unknown:
            return "重试一次；若仍然失败，请到 设置 › 关于 里反馈问题。"
        }
    }

    /// 是否值得自动重试（仅网络抖动与 5xx）。
    public var isRetryable: Bool {
        switch self {
        case .timeout, .network:
            return true
        case let .server(code, _):
            return code >= 500
        case .rateLimited:
            return true
        case .notConfigured, .missingAPIKey, .unauthorized, .decoding,
             .contentRejected, .cancelled, .unknown:
            return false
        }
    }

    /// 统一从 `Error` 里抽出 `AIError`（非 AIError 的一律包成 `.unknown`）。
    public static func wrap(_ error: Error) -> AIError {
        if let aiError = error as? AIError {
            return aiError
        }
        if error is CancellationError {
            return .cancelled
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorDNSLookupFailed:
                return .network(nsError.localizedDescription)
            default:
                return .network(nsError.localizedDescription)
            }
        }
        return .unknown(error.localizedDescription)
    }

    /// 把 HTTP 状态码映射成合适的 `AIError`。
    public static func fromHTTPStatus(
        _ statusCode: Int,
        message: String?,
        retryAfter: TimeInterval? = nil
    ) -> AIError {
        switch statusCode {
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400..<500:
            return .server(code: statusCode, message: message)
        default:
            return .server(code: statusCode, message: message)
        }
    }
}
