//
//  WebSearch.swift
//  ios/Shared/Networking
//
//  对话的联网搜索：自己去必应搜，把前几条结果交给模型。不依赖服务商，DeepSeek、豆包都能用。
//  国内先用 cn.bing.com，搜不到再试 www.bing.com。网页结构变了会搜不到结果，那时按不联网回答。
//

import Foundation

public struct WebSearchResult: Equatable, Sendable, Identifiable {
    public var title: String
    public var snippet: String
    public var url: String
    public var id: String { url }

    public init(title: String, snippet: String, url: String) {
        self.title = title
        self.snippet = snippet
        self.url = url
    }
}

public enum WebSearch {

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 搜。失败或没结果返回空数组，不抛错：联网只是锦上添花。
    public static func search(_ query: String, limit: Int = 5, session: URLSession? = nil) async -> [WebSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let urlSession = session ?? HTTPTransport.makeSession(timeout: 10)
        for base in ["https://cn.bing.com/search", "https://www.bing.com/search"] {
            guard var components = URLComponents(string: base) else { continue }
            components.queryItems = [
                URLQueryItem(name: "q", value: String(trimmed.prefix(120))),
                URLQueryItem(name: "setlang", value: "zh-Hans"),
                URLQueryItem(name: "count", value: "10")
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            guard let (data, _) = try? await HTTPTransport.send(request, session: urlSession) else { continue }
            let results = parseBing(String(decoding: data, as: UTF8.self))
            if !results.isEmpty {
                return Array(results.prefix(limit))
            }
        }
        return []
    }

    /// 从必应的结果页里取标题、摘要、网址。
    static func parseBing(_ html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        let blocks = html.components(separatedBy: "<li class=\"b_algo\"").dropFirst()
        for block in blocks {
            guard let link = firstMatch(#"<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block),
                  link.count == 2 else { continue }
            let title = clean(link[1])
            guard !title.isEmpty else { continue }
            let snippet = firstMatch(#"<p[^>]*>(.*?)</p>"#, in: block).map { clean($0[0]) } ?? ""
            results.append(WebSearchResult(title: title, snippet: snippet, url: realURL(decodeEntities(link[0]))))
        }
        return results
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    /// 去标签、解实体、压空白。
    static func clean(_ html: String) -> String {
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return decodeEntities(noTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&lt;", "<"),
                                ("&gt;", ">"), ("&nbsp;", " "), ("&ensp;", " "), ("&#0183;", "·"), ("&middot;", "·")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    /// 必应有时把网址包成跳转链接（bing.com/ck/a?...&u=a1<base64>），解出真实网址。
    static func realURL(_ url: String) -> String {
        guard url.contains("bing.com/ck/a"), let components = URLComponents(string: url),
              let encoded = components.queryItems?.first(where: { $0.name == "u" })?.value, encoded.hasPrefix("a1") else {
            return url
        }
        var base64 = String(encoded.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf8) else { return url }
        return decoded
    }

    /// 「自动」时哪些问题要联网：问的是新的、会变的东西。
    public static func looksTimeSensitive(_ text: String) -> Bool {
        let words = ["今天", "昨天", "明天", "最新", "新闻", "现在", "最近", "近期", "天气", "价格", "多少钱", "股价", "汇率",
                     "比分", "几号", "上映", "发布", "官网", "搜一下", "查一下", "搜搜", "查查", "联网", "实时", "今年", "热搜"]
        if words.contains(where: { text.contains($0) }) {
            return true
        }
        return text.range(of: "20[2-3][0-9]", options: .regularExpression) != nil
    }

    /// 交给模型的那段话。
    public static func promptBlock(_ results: [WebSearchResult], date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        var lines = ["以下是刚刚联网搜到的结果（今天是\(formatter.string(from: date))）。回答时优先用这些信息，说不准的不要编；用到的在句末标上编号，比如 [1]。"]
        for (index, result) in results.enumerated() {
            lines.append("[\(index + 1)] \(result.title)：\(result.snippet)（\(result.url)）")
        }
        return lines.joined(separator: "\n")
    }
}
