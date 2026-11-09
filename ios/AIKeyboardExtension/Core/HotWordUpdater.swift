//
//  HotWordUpdater.swift
//  墨语 · 键盘
//
//  每天从仓库拉一次新词表（ios/Shared/dict/hot_words.tsv），存在键盘自己的缓存目录。
//  国内先试 jsDelivr 的镜像，不行再试 GitHub。拉到的内容格式不对或太大就不用。
//  只在打开了「完全访问」、设置里没关掉时才拉。
//

import Foundation

enum HotWordUpdater {

    static let sources = [
        "https://cdn.jsdelivr.net/gh/904177233/ximake-keyboard@main/ios/Shared/dict/hot_words.tsv",
        "https://raw.githubusercontent.com/904177233/ximake-keyboard/main/ios/Shared/dict/hot_words.tsv"
    ]

    private static let lastCheckKey = "moyu.hotwords.lastCheck"
    private static let lastSuccessKey = "moyu.hotwords.lastSuccess"
    private static let interval: TimeInterval = 24 * 3600

    /// 上次成功更新的时间。
    static var lastSuccess: Date? {
        UserDefaults.standard.object(forKey: lastSuccessKey) as? Date
    }

    /// 超过一天没查过就去拉。force 为 true 时不管上次什么时候查的。
    /// - Parameter completion: 在主线程回调，拉到并存好了给新词个数，失败给 nil。
    static func updateIfNeeded(force: Bool = false, completion: @escaping (Int?) -> Void) {
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < interval {
            return
        }
        defaults.set(Date(), forKey: lastCheckKey)
        fetch(from: sources[...], completion: completion)
    }

    private static func fetch(from remaining: ArraySlice<String>, completion: @escaping (Int?) -> Void) {
        guard let first = remaining.first, let url = URL(string: first), let target = HotWordStore.cacheURL else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Moyu-Keyboard", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data, data.count <= HotWordStore.maximumBytes,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("# 墨语新词表"),
                  HotWordStore(text: text).count > 0 else {
                fetch(from: remaining.dropFirst(), completion: completion)
                return
            }
            do {
                try data.write(to: target, options: .atomic)
                UserDefaults.standard.set(Date(), forKey: lastSuccessKey)
                let count = HotWordStore(text: text).count
                DispatchQueue.main.async { completion(count) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }
}
