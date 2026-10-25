import Foundation
import CryptoKit

/// 在线词库包：清单模型。
///
/// **为什么只做「词库包下载」而不做「云候选」**：
/// 云候选意味着把用户**正在输入的每个字**上传到服务器（输入框里会出现密码、验证码、
/// 身份证号、私聊内容），延迟还要 300–800ms，等云端结果回来时本地候选早就显示了，
/// 算力白花。词库包只下载**一份静态词表文件**，永不上传任何输入内容，隐私成本≈0，
/// 却能直接解决「词库太老」这个真实问题 —— 这是权衡后的选择，不是能力不足。
///
/// 包的来源是「一个静态目录下的三个文件」：
/// ```
/// dict_manifest.json      ← 清单（版本、每个文件的 url / sha256 / 字节数）
/// base_dict.tsv           ← 基础词库（拼音\t词\t词频\tflags）
/// chat_priority.tsv       ← 聊天高频词权重（词\t权重）
/// ```
/// 默认托管在 jsDelivr 的 GitHub 镜像上（国内可达、带 CDN 缓存）：
/// `https://cdn.jsdelivr.net/gh/904177233/ximake-keyboard@main/ios/Shared/dict/`
/// 清单里的 `url` 是相对文件名，也允许写绝对地址（自建服务器）。
public struct DictionaryPackManifest: Codable, Equatable, Sendable {

    /// 清单格式版本。将来字段不兼容时用来拒绝旧包。
    public let manifestVersion: Int

    /// 词库包版本。与 `dict_meta.json` 的 `version` 对应，形如 `1.2.0`。
    public let packVersion: String

    /// 生成时间（ISO8601 字符串，仅用于展示与排查）。
    public let generatedAt: String

    /// 期望的词条数（下载后做一次粗校验，防止拿到半截文件）。
    public let entryCount: Int

    /// 文件清单。
    public let files: [DictionaryPackFile]

    /// 清单格式版本上限。
    public static let supportedManifestVersion = 1
}

/// 包内单个文件。
public struct DictionaryPackFile: Codable, Equatable, Sendable {

    /// 落盘用的文件名（`base_dict.tsv` / `chat_priority.tsv`）。
    public let name: String

    /// 下载地址：相对清单所在目录的文件名，或 `https://` 绝对地址。
    public let url: String

    /// 期望的 SHA-256（小写十六进制）。
    public let sha256: String

    /// 期望字节数。
    public let bytes: Int

    /// 允许落盘的文件名白名单（防止清单里塞 `../../` 之类路径穿越）。
    public static let allowedNames: Set<String> = ["base_dict.tsv", "chat_priority.tsv", "dict_meta.json"]
}

/// 已安装的词库包信息。
public struct DictionaryPackInfo: Equatable, Sendable {

    /// 词库包版本（来自包内 `dict_meta.json` 的 `version`）。
    public let version: String

    /// 词条数（来自包内 `dict_meta.json` 的 `count`）。
    public let entryCount: Int

    /// 安装时间（Unix 时间戳）。
    public let installedAt: TimeInterval

    /// 落盘目录（诊断用）。
    public let directory: String
}

/// 词库包错误。
public enum DictionaryPackError: LocalizedError, Equatable, Sendable {

    /// 清单地址无效。
    case invalidManifestURL

    /// 清单下载失败（网络）。
    case manifestUnreachable(String)

    /// 清单解析失败。
    case manifestDecoding(String)

    /// 清单格式版本不支持。
    case unsupportedManifestVersion(Int)

    /// 清单里出现不允许的文件名。
    case illegalFileName(String)

    /// 文件下载失败。
    case downloadFailed(String, String)

    /// 字节数不符（多半是拿到了半截响应或被中间层改写）。
    case sizeMismatch(String, expected: Int, actual: Int)

    /// SHA-256 不符（文件被篡改或包不完整）。
    case hashMismatch(String, expected: String, actual: String)

    /// 词条数粗校验不符。
    case entryCountMismatch(expected: Int, actual: Int)

    /// 写盘失败。
    case writeFailed(String)

    /// 没有可回滚的用户词库。
    case nothingToRollback

    public var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            return "词库清单地址无效"
        case let .manifestUnreachable(detail):
            return "下载词库清单失败：\(detail)"
        case let .manifestDecoding(detail):
            return "词库清单格式错误：\(detail)"
        case let .unsupportedManifestVersion(version):
            return "词库清单版本 \(version) 太新，当前版本不认识"
        case let .illegalFileName(name):
            return "词库清单里有不合法的文件名：\(name)"
        case let .downloadFailed(name, detail):
            return "下载 \(name) 失败：\(detail)"
        case let .sizeMismatch(name, expected, actual):
            return "\(name) 大小不符（期望 \(expected) 字节，实际 \(actual) 字节）"
        case .hashMismatch:
            return "词库文件校验失败，已放弃安装"
        case let .entryCountMismatch(expected, actual):
            return "词库条数不符（期望 \(expected)，实际 \(actual)）"
        case let .writeFailed(detail):
            return "写入词库失败：\(detail)"
        case .nothingToRollback:
            return "当前没有更新过的词库可以回滚"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .manifestUnreachable, .downloadFailed:
            return "检查网络后重试；离线时键盘会继续用安装包内置的词库，不影响打字。"
        case .hashMismatch, .sizeMismatch, .entryCountMismatch:
            return "可能是下载被中断或经过的代理改写了内容，重试一次即可。"
        case .unsupportedManifestVersion:
            return "更新 App 后再试。"
        default:
            return nil
        }
    }
}

/// 在线词库包的「检查 / 下载 / 安装 / 回滚」。
///
/// ## 落盘位置与「为什么在键盘扩展里下载，而不是在宿主 App 里」
///
/// 免费签名没有 App Group，宿主 App 与键盘扩展是**两个独立沙盒**：
/// 宿主 App 下载到自己的 Documents，扩展读不到。
/// 所以真正的下载发生在**扩展的进程里**（`Library/Application Support/MoyuDict/`），
/// 只有开了「完全访问」才有网络权限 —— 这正是词库更新需要完全访问的原因。
/// 宿主 App 里也有同一套 UI，但它下载的那份只用于预览与诊断，`isHostSide == true`。
///
/// ## 校验
///
/// 三层：①字节数 ②SHA-256（逐文件）③解析后的词条数。任一层不过就整体放弃，
/// 旧词库原样保留 —— **宁可更新失败，也不能让用户开不了键盘**。
/// 但宿主 App 那一层做不到（无 App Group），所以宿主侧更保守：只展示状态，不提供下载按钮。
public final class DictionaryPackStore {

    /// 共享单例。
    public static let shared = DictionaryPackStore()

    /// 用户词库目录文件名。
    public static let directoryName = "MoyuDict"

    /// 默认清单地址（jsDelivr 的 GitHub 镜像，国内可达）。
    public static let defaultManifestURL =
        "https://cdn.jsdelivr.net/gh/904177233/ximake-keyboard@main/ios/Shared/dict/dict_manifest.json"

    /// 备选清单地址（GitHub raw，jsDelivr 挂了时兜底）。
    public static let fallbackManifestURL =
        "https://raw.githubusercontent.com/904177233/ximake-keyboard/main/ios/Shared/dict/dict_manifest.json"

    /// 存储键：清单地址（用户可改）。
    public static let manifestURLKey = "moyu.dict.manifestURL"

    /// 存储键：自动检查开关。
    public static let autoUpdateKey = "moyu.dict.autoUpdate"

    /// 存储键：上次检查时间。
    public static let lastCheckKey = "moyu.dict.lastCheckAt"

    /// 存储键：上次检查结果（给 UI 展示）。
    public static let lastResultKey = "moyu.dict.lastResult"

    /// 单文件体积上限（20 MB）。词库再大也不该超过这个数，超过视为异常包。
    public static let maximumFileBytes = 20 * 1024 * 1024

    /// 自动检查的最小间隔（24 小时）。
    public static let minimumCheckInterval: TimeInterval = 24 * 60 * 60

    private let session: URLSession
    private let store: SharedStore

    /// 初始化。
    /// - Parameters:
    ///   - store: 键值存储（默认共享实例；注入便于自测）。
    ///   - session: 网络会话（默认短超时的 ephemeral 会话）。
    public init(store: SharedStore = .shared,
                session: URLSession? = nil) {
        self.store = store
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - 目录

    /// 用户词库目录（不存在返回 nil，不创建）。
    public var installedDirectory: URL? {
        guard let base = Self.applicationSupportDirectory() else { return nil }
        let directory = base.appendingPathComponent(Self.directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return directory
    }

    /// 用户 `base_dict.tsv` 路径（存在即优先于安装包内置）。
    public var userDictionaryPath: String? {
        existingPath(for: "base_dict.tsv")
    }

    /// 用户 `chat_priority.tsv` 路径。
    public var userChatPriorityPath: String? {
        existingPath(for: "chat_priority.tsv")
    }

    /// 是否已安装过在线词库包。
    public var isInstalled: Bool {
        userDictionaryPath != nil
    }

    /// 已安装版本信息（读用户目录里的 `dict_meta.json`）。
    public var installedInfo: DictionaryPackInfo? {
        guard let directory = installedDirectory else { return nil }
        let metaURL = directory.appendingPathComponent("dict_meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // 没有 meta 也认（只要 base_dict 在），版本号用「未知」
            guard isInstalled else { return nil }
            return DictionaryPackInfo(version: "未知",
                                      entryCount: 0,
                                      installedAt: directoryCreationTime(directory),
                                      directory: directory.path)
        }
        let version = object["version"] as? String ?? "未知"
        let count = object["count"] as? Int ?? 0
        return DictionaryPackInfo(version: version,
                                  entryCount: count,
                                  installedAt: directoryCreationTime(directory),
                                  directory: directory.path)
    }

    /// 清单地址（用户可在设置里改）。
    public var manifestURLString: String {
        get { store.string(forKey: Self.manifestURLKey) ?? Self.defaultManifestURL }
        set { store.set(newValue, forKey: Self.manifestURLKey) }
    }

    /// 是否允许自动检查（默认开）。
    public var isAutoUpdateEnabled: Bool {
        get { store.bool(forKey: Self.autoUpdateKey, default: true) }
        set { store.setBool(newValue, forKey: Self.autoUpdateKey) }
    }

    /// 上次检查时间。
    public var lastCheckAt: TimeInterval {
        get { store.double(forKey: Self.lastCheckKey) ?? 0 }
        set { store.setDouble(newValue, forKey: Self.lastCheckKey) }
    }

    /// 上次检查结果（给 UI 直接显示的一句话）。
    public var lastResult: String {
        get { store.string(forKey: Self.lastResultKey) ?? "" }
        set { store.set(newValue, forKey: Self.lastResultKey) }
    }

    // MARK: - 检查与安装

    /// 检查并安装最新词库包。
    ///
    /// - Parameter forced: `true` 表示用户手动点了「检查更新」（忽略 24 小时间隔；
    ///   已是最新版本时也回一句「已是最新」，而不是静默返回）。
    /// - Returns: 面向用户的一句话（中文）。
    /// - Throws: `DictionaryPackError`（调用方负责 `AIError` 式的降级展示）。
    public func checkAndInstall(forced: Bool) async throws -> String {
        let manifestURLs = candidateManifestURLs()
        guard !manifestURLs.isEmpty else { throw DictionaryPackError.invalidManifestURL }

        var lastError: Error?
        for manifestURL in manifestURLs {
            do {
                let manifest = try await fetchManifest(from: manifestURL)
                let message = try await install(manifest: manifest,
                                                baseURL: manifestURL.deletingLastPathComponent(),
                                                forced: forced)
                finishCheck(message)
                return message
            } catch {
                lastError = error
                continue
            }
        }
        let message = (lastError as? DictionaryPackError)?.errorDescription ?? "检查更新失败"
        finishCheck(message)
        throw lastError ?? DictionaryPackError.manifestUnreachable("未知错误")
    }

    /// 自动检查：满足「开关开 + 距上次检查超过 24 小时」才真的发请求。
    ///
    /// 键盘扩展的 `activate()` 会调它，**失败完全静默**（用户不需要知道词库更新失败，
    /// 它不影响打字）。返回 `true` 表示确实做了一次检查。
    @discardableResult
    public func autoCheckIfNeeded() async -> Bool {
        guard isAutoUpdateEnabled else { return false }
        guard Date().timeIntervalSince1970 - lastCheckAt > Self.minimumCheckInterval else { return false }
        do {
            _ = try await checkAndInstall(forced: false)
            return true
        } catch {
            return true
        }
    }

    /// 回滚到安装包内置词库（删掉用户目录）。
    public func rollback() throws {
        guard let directory = installedDirectory else { throw DictionaryPackError.nothingToRollback }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw DictionaryPackError.writeFailed(error.localizedDescription)
        }
        lastResult = "已回滚到内置词库"
    }

    // MARK: - 内部：清单

    /// 依次尝试「用户配置地址 → 默认 jsDelivr → GitHub raw」。
    private func candidateManifestURLs() -> [URL] {
        let custom = manifestURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        var strings: [String] = []
        if !custom.isEmpty { strings.append(custom) }
        strings.append(Self.defaultManifestURL)
        strings.append(Self.fallbackManifestURL)
        var seen = Set<String>()
        return strings.compactMap { value in
            guard seen.insert(value).inserted, let url = URL(string: value), url.scheme != nil else { return nil }
            return url
        }
    }

    /// 下载并解析清单。
    private func fetchManifest(from url: URL) async throws -> DictionaryPackManifest {
        let data: Data
        do {
            let (payload, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw DictionaryPackError.manifestUnreachable("非 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DictionaryPackError.manifestUnreachable("HTTP \(http.statusCode)")
            }
            data = payload
        } catch let error as DictionaryPackError {
            throw error
        } catch {
            throw DictionaryPackError.manifestUnreachable(error.localizedDescription)
        }
        do {
            let manifest = try JSONDecoder().decode(DictionaryPackManifest.self, from: data)
            guard manifest.manifestVersion <= DictionaryPackManifest.supportedManifestVersion else {
                throw DictionaryPackError.unsupportedManifestVersion(manifest.manifestVersion)
            }
            return manifest
        } catch let error as DictionaryPackError {
            throw error
        } catch {
            throw DictionaryPackError.manifestDecoding(error.localizedDescription)
        }
    }

    // MARK: - 内部：安装

    /// 下载 + 校验 + 原子替换。
    private func install(manifest: DictionaryPackManifest,
                         baseURL: URL,
                         forced: Bool) async throws -> String {
        if !forced, let installed = installedInfo, installed.version == manifest.packVersion {
            return "词库已是最新（v\(manifest.packVersion)）"
        }
        if forced, let installed = installedInfo, installed.version == manifest.packVersion {
            return "词库已是最新（v\(manifest.packVersion)）"
        }

        // 先下到临时目录，全部通过校验后才搬到正式目录 —— 中途失败不会让键盘没词库可用。
        guard let base = Self.applicationSupportDirectory() else {
            throw DictionaryPackError.writeFailed("拿不到 Application Support 目录")
        }
        let stagingName = "\(Self.directoryName).staging"
        let staging = base.appendingPathComponent(stagingName, isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw DictionaryPackError.writeFailed(error.localizedDescription)
        }

        var downloadedNames: [String] = []
        for file in manifest.files {
            guard DictionaryPackFile.allowedNames.contains(file.name) else {
                throw DictionaryPackError.illegalFileName(file.name)
            }
            if file.bytes > Self.maximumFileBytes {
                throw DictionaryPackError.sizeMismatch(file.name, expected: file.bytes, actual: 0)
            }
            let data = try await download(file: file, baseURL: baseURL)
            guard data.count == file.bytes else {
                throw DictionaryPackError.sizeMismatch(file.name, expected: file.bytes, actual: data.count)
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.lowercased() == file.sha256.lowercased() else {
                throw DictionaryPackError.hashMismatch(file.name,
                                                      expected: file.sha256,
                                                      actual: digest)
            }
            let target = staging.appendingPathComponent(file.name)
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                throw DictionaryPackError.writeFailed(error.localizedDescription)
            }
            downloadedNames.append(file.name)
        }

        // 词条数粗校验：解析首列行数，和清单对不上就整体放弃。
        if manifest.entryCount > 0, downloadedNames.contains("base_dict.tsv") {
            let dictionaryURL = staging.appendingPathComponent("base_dict.tsv")
            let actual = Self.countEntries(at: dictionaryURL)
            if actual != manifest.entryCount {
                throw DictionaryPackError.entryCountMismatch(expected: manifest.entryCount, actual: actual)
            }
        }

        // 原子替换：先删旧的，再把 staging 改名过去。
        if let existing = installedDirectory {
            try? fileManager.removeItem(at: existing)
        }
        let destination = base.appendingPathComponent(Self.directoryName, isDirectory: true)
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            throw DictionaryPackError.writeFailed(error.localizedDescription)
        }
        return "词库已更新到 v\(manifest.packVersion)（\(manifest.entryCount) 条）"
    }

    /// 下载单个文件（跟随清单里的相对/绝对地址）。
    private func download(file: DictionaryPackFile, baseURL: URL) async throws -> Data {
        let url: URL?
        if file.url.hasPrefix("http://") || file.url.hasPrefix("https://") {
            url = URL(string: file.url)
        } else {
            url = baseURL.appendingPathComponent(file.url)
        }
        guard let url else {
            throw DictionaryPackError.downloadFailed(file.name, "地址无效")
        }
        do {
            let (payload, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw DictionaryPackError.downloadFailed(file.name, "HTTP \(http.statusCode)")
            }
            return payload
        } catch let error as DictionaryPackError {
            throw error
        } catch {
            throw DictionaryPackError.downloadFailed(file.name, error.localizedDescription)
        }
    }

    /// 记录本次检查结果（时间 + 一句话，给 UI 用）。
    private func finishCheck(_ message: String) {
        lastCheckAt = Date().timeIntervalSince1970
        lastResult = message
    }

    // MARK: - 内部：工具

    /// 某个文件在用户目录里的路径（存在才有值）。
    private func existingPath(for name: String) -> String? {
        guard let directory = installedDirectory else { return nil }
        let path = directory.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// 目录创建时间（当作安装时间）。
    private func directoryCreationTime(_ directory: URL) -> TimeInterval {
        let values = try? directory.resourceValues(forKeys: [.creationDateKey])
        return values?.creationDate?.timeIntervalSince1970 ?? 0
    }

    /// 词库条数（跳过 `#` 注释行与空行）。
    static func countEntries(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            count += 1
        }
        return count
    }

    /// `Application Support` 目录（不存在则创建）。
    ///
    /// 扩展里拿到的是**扩展自己**的容器，宿主 App 里拿到的是宿主自己的 ——
    /// 这正是「免费签名没有 App Group」时唯一能落盘的地方。
    static func applicationSupportDirectory() -> URL? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first else { return nil }
        if !fileManager.fileExists(atPath: base.path) {
            try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base
    }
}
