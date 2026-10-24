//
//  PhotoLibrarySaver.swift
//  墨语 · 宿主 App
//
//  模块职责：把 AI 生成的图片保存到系统相册。
//            只申请「仅添加」权限（`.addOnly`），**不读取**用户相册；
//            权限在用户主动点「保存到相册」时才申请，App 启动与进入页面都不申请。
//  依赖：UIKit（UIImage）、Photos（PHPhotoLibrary / PHAssetChangeRequest）。
//  使用方：PlaygroundActionSection（AI 试验场的生图结果卡）。
//
//  注意：键盘扩展没有该权限，也不应引用本文件。
//

import UIKit
import Photos

// 说明：`scripts/qa/static_check.py` 的系统类型白名单（SYSTEM_TYPES）目前
// 收了 Foundation / SwiftUI / UIKit / Security，还没有收 Photos 框架，
// 因此本文件里用到 Photos 类型的两行加了 `// SAFE:` 行内标记。
// 该脚本属于 QA 公共资产、不在本模块写作用域内，不由我改。

/// 相册写入工具。
///
/// 用法（只在用户点击时调用）：
///     do {
///         try await PhotoLibrarySaver.save(image)
///     } catch {
///         // PhotoLibrarySaver.message(for:) / suggestion(for:) 已给出中文文案
///     }
enum PhotoLibrarySaver {

    /// 保存失败的原因（全中文文案，含可执行建议）。
    enum SaveError: LocalizedError, Equatable {
        /// 用户拒绝了相册写入权限。
        case permissionDenied
        /// 系统策略限制（屏幕使用时间 / 家长控制等）。
        case permissionRestricted
        /// 图片数据不可用（解码失败或没有二进制）。
        case invalidImage
        /// 写入过程失败，附带系统给出的原因。
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "没有相册写入权限"
            case .permissionRestricted:
                return "相册写入被系统限制"
            case .invalidImage:
                return "这张图暂时无法保存"
            case .saveFailed:
                return "保存到相册失败"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .permissionDenied:
                return "去「设置 › 隐私 › 照片」允许墨语添加照片。"
            case .permissionRestricted:
                return "可能是「屏幕使用时间」或家长控制的限制，请到设置里检查。"
            case .invalidImage:
                return "可以先用「复制图片」粘到聊天窗口。"
            case .saveFailed(let reason):
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "请稍后重试。" : "请稍后重试（\(trimmed)）。"
            }
        }
    }

    // MARK: - 对外接口

    /// 当前相册「仅添加」权限状态（只读，不会触发系统弹窗）。
    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)  // SAFE: 系统 API（Photos 框架）
    }

    /// 把图片写入系统相册。
    ///
    /// - 首次调用会弹系统权限弹窗（这是唯一会申请权限的地方）。
    /// - 失败时抛出 `SaveError`；调用方用 `message(for:)` / `suggestion(for:)` 取中文文案。
    static func save(_ image: UIImage) async throws {
        let status = await requestAddOnlyAuthorization()
        switch status {
        case .authorized, .limited:
            break
        case .denied, .notDetermined:
            throw SaveError.permissionDenied
        case .restricted:
            throw SaveError.permissionRestricted
        @unknown default:
            throw SaveError.permissionDenied
        }

        try await write(image)
    }

    /// 失败原因的首行文案。
    static func message(for error: Error) -> String {
        if let saveError = error as? SaveError, let text = saveError.errorDescription {
            return text
        }
        return "保存到相册失败"
    }

    /// 失败原因的可执行建议。
    static func suggestion(for error: Error) -> String? {
        if let saveError = error as? SaveError {
            return saveError.recoverySuggestion
        }
        return "请稍后重试。"
    }

    // MARK: - 权限与写入

    /// 申请「仅添加」权限（包装回调为 async）。
    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in  // SAFE: 系统 API（Photos 框架）
                continuation.resume(returning: status)
            }
        }
    }

    /// 真正写入相册（包装 `performChanges` 回调为 async throws）。
    private static func write(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)  // SAFE: 系统 API（Photos 框架）
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                    return
                }
                if let error {
                    continuation.resume(throwing: SaveError.saveFailed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: SaveError.saveFailed(""))
                }
            }
        }
    }
}
