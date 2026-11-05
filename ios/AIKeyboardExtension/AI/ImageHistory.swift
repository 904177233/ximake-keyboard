//
//  ImageHistory.swift
//  墨语键盘 · 画过的图
//
//  每张画出来的图都存一份在键盘自己的目录里，最多留 30 张。
//  不小心关掉面板也找得回来；显示时只解码小图，省内存。
//

import ImageIO
import Photos
import UIKit

@MainActor
final class ImageHistory {

    struct Item: Codable, Identifiable, Equatable {
        let id: String
        let prompt: String
        let date: Date
    }

    static let shared = ImageHistory()
    private static let limit = 30
    private static let indexKey = "moyu.imageHistory.index"

    private(set) var items: [Item]
    private let folder: URL?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        folder = base?.appendingPathComponent("images", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        if let data = UserDefaults.standard.data(forKey: Self.indexKey),
           let decoded = try? JSONDecoder().decode([Item].self, from: data) {
            items = decoded
        } else {
            items = []
        }
    }

    private func url(for id: String) -> URL? {
        folder?.appendingPathComponent(id + ".img")
    }

    /// 存一张，返回它的记录。
    @discardableResult
    func add(_ data: Data, prompt: String) -> Item? {
        let item = Item(id: UUID().uuidString, prompt: prompt, date: Date())
        guard let target = url(for: item.id), (try? data.write(to: target)) != nil else { return nil }
        items.insert(item, at: 0)
        while items.count > Self.limit {
            let removed = items.removeLast()
            if let old = url(for: removed.id) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        saveIndex()
        return item
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        if let target = url(for: id) {
            try? FileManager.default.removeItem(at: target)
        }
        saveIndex()
    }

    private func saveIndex() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.indexKey)
    }

    func data(for id: String) -> Data? {
        url(for: id).flatMap { try? Data(contentsOf: $0) }
    }

    /// 只解码小图。
    func thumbnail(for id: String, side: CGFloat) -> UIImage? {
        guard let target = url(for: id), let source = CGImageSourceCreateWithURL(target as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side * UIScreen.main.scale
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// 存到相册。键盘里弹不了授权框，没授权时让人去 App 里点一下。
    static func saveToPhotos(_ data: Data, done: @escaping @MainActor (String) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited else {
            done(status == .notDetermined
                 ? "先到墨语 App 的「键盘」页点「允许存图片」，再回来存"
                 : "没有存相册的权限。到 设置 › 墨语 › 照片 里打开")
            return
        }
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }, completionHandler: { success, _ in
            Task { @MainActor in done(success ? "已存到相册" : "没存上，再试一次") }
        })
    }
}
