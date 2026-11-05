//
//  tools/apicheck/main.swift
//
//  AI 服务调用逻辑的检查：用假的服务器回应把常见情况走一遍（模型没开通、下线、Key 错、参数不对）。
//  不联网，不花钱。CI 的「API logic check」一步编译运行。
//

import Foundation

// MARK: - 假的服务器

struct Reply {
    var status: Int
    var body: String
}

final class FakeServer: URLProtocol {
    /// 按请求决定回什么。参数：路径、请求体里的 model、整个请求体。
    nonisolated(unsafe) static var route: (String, String, [String: Any]) -> Reply = { _, _, _ in Reply(status: 500, body: "{}") }
    nonisolated(unsafe) static var bodies: [(path: String, body: [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let path = request.url?.path ?? ""
        FakeServer.bodies.append((path, json))
        let reply = FakeServer.route(path, json["model"] as? String ?? "", json)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

HTTPTransport.testProtocolClasses = [FakeServer.self]

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)  \(detail())")
    }
}

let notOpen = #"{"error":{"code":"ModelNotOpen","message":"Your account has not activated the model."}}"#
let notFound = #"{"error":{"code":"InvalidEndpointOrModel.NotFound","message":"The model or endpoint does not exist."}}"#
let okImage = #"{"data":[{"b64_json":"aGVsbG8="}]}"#
let pro = "doubao-seedream-5-0-pro-260628"
let old = "doubao-seedream-3-0-t2i-250415"

var seedream = PresetProviders.preset(id: "preset-seedream")!.makeProvider()
seedream.imageModel = old

print("即梦")
UserDefaults.standard.removeObject(forKey: "moyu.seedream.lastGoodModel")
FakeServer.route = { path, model, _ in
    guard path.hasSuffix("/images/generations") else { return Reply(status: 404, body: "{}") }
    return model == pro ? Reply(status: 200, body: okImage) : Reply(status: 404, body: notOpen)
}
do {
    let images = try await SeedreamImageClient(config: seedream, apiKey: "k").generate(ImageRequest(prompt: "猫", size: "1024x1024"))
    check("3.0 没开通时自动换到 5.0 Pro", images.first?.model == pro, "\(images.first?.model ?? "nil")")
} catch {
    check("3.0 没开通时自动换到 5.0 Pro", false, "\(error)")
}

FakeServer.route = { _, _, _ in Reply(status: 404, body: notOpen) }
do {
    _ = try await SeedreamImageClient(config: seedream, apiKey: "k").generate(ImageRequest(prompt: "猫", size: "1024x1024"))
    check("都没开通要报错", false)
} catch {
    let text = AIError.wrap(error).errorDescription ?? ""
    check("都没开通时列出试过的模型，不只说 3.0", text.contains("5.0 Pro") && text.contains("开通管理"), text)
}

FakeServer.route = { _, model, _ in
    if model == pro {
        return Reply(status: 400, body: #"{"error":{"code":"InvalidParameter","message":"The parameter `size` specified in the request is not valid"}}"#)
    }
    return Reply(status: 404, body: notOpen)
}
do {
    _ = try await SeedreamImageClient(config: seedream, apiKey: "k").generate(ImageRequest(prompt: "猫", size: "1024x1024"))
    check("参数错要报错", false)
} catch {
    let text = AIError.wrap(error).errorDescription ?? ""
    check("有别的错时报真正的原因（尺寸），不报「没开通」", text.contains("size") && !text.contains("3.0"), text)
}

FakeServer.route = { _, model, _ in
    model == pro ? Reply(status: 400, body: #"{"error":{"code":"MissingParameter","message":"prompt is required"}}"#)
        : Reply(status: 404, body: notOpen)
}
let probe = await SeedreamImageClient.probe(config: seedream, apiKey: "k")
check("保存时探测：找到开通的 5.0 Pro", probe == .usable(pro), "\(probe)")
let checked = await ProviderCheck.run(config: seedream, apiKey: "k")
check("保存时把画图模型换成能用的", checked.isUsable && checked.config.imageModel == pro, "\(checked.message)")

FakeServer.route = { _, _, _ in Reply(status: 401, body: #"{"error":{"message":"invalid api key"}}"#) }
let wrongKey = await SeedreamImageClient.probe(config: seedream, apiKey: "k")
check("Key 错时说 Key 错", wrongKey == .unauthorized, "\(wrongKey)")

print("写字")
var deepseek = PresetProviders.preset(id: "preset-deepseek")!.makeProvider()
deepseek.model = "deepseek-chat"
FakeServer.route = { path, model, _ in
    if path.hasSuffix("/models") {
        return Reply(status: 200, body: #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"}]}"#)
    }
    if model == "deepseek-flash" {
        return Reply(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"你好"}}]}"#)
    }
    return Reply(status: 400, body: #"{"error":{"message":"Model Not Exist"}}"#)
}
let deepseekResult = await ProviderCheck.run(config: deepseek, apiKey: "k")
check("模型下线时查列表换成能用的", deepseekResult.isUsable && deepseekResult.config.model == "deepseek-flash",
      "\(deepseekResult.config.model) \(deepseekResult.message)")

var ark = PresetProviders.preset(id: "preset-ark")!.makeProvider()
ark.model = "doubao-1-5-pro-32k"
FakeServer.route = { path, model, _ in
    if path.hasSuffix("/models") { return Reply(status: 404, body: notFound) }
    if model == "doubao-seed-2-1-pro-260915" {
        return Reply(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"在"}}]}"#)
    }
    return Reply(status: 404, body: notOpen)
}
let arkResult = await ProviderCheck.run(config: ark, apiKey: "k")
check("豆包查不到列表时按预设挨个试", arkResult.isUsable && arkResult.config.model == "doubao-seed-2-1-pro-260915",
      "\(arkResult.config.model) \(arkResult.message)")

FakeServer.route = { _, _, _ in Reply(status: 401, body: #"{"error":{"message":"Authentication Fails"}}"#) }
let badKey = await ProviderCheck.run(config: deepseek, apiKey: "k")
check("Key 错时不乱换模型", !badKey.isUsable && badKey.config.model == "deepseek-chat", badKey.message)

print("推理参数")
func bodyFor(base: String, level: ReasoningLevel?) async -> [String: Any] {
    var config = PresetProviders.preset(id: "preset-deepseek")!.makeProvider()
    config.baseURL = base
    FakeServer.bodies = []
    FakeServer.route = { _, _, _ in Reply(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"好"}}]}"#) }
    let request = ChatRequest(messages: [.user("hi")], maxTokens: 100, stream: false, reasoning: level)
    _ = try? await AIClientFactory.makeLLM(config: config, apiKey: "k").complete(request)
    return FakeServer.bodies.last?.body ?? [:]
}
let arkBody = await bodyFor(base: "https://ark.cn-beijing.volces.com/api/v3", level: .deep)
check("豆包深度思考用 thinking", (arkBody["thinking"] as? [String: Any])?["type"] as? String == "enabled", "\(arkBody)")
let qwenBody = await bodyFor(base: "https://dashscope.aliyuncs.com/compatible-mode/v1", level: .fast)
check("通义快速用 enable_thinking=false", qwenBody["enable_thinking"] as? Bool == false, "\(qwenBody)")
let openAIBody = await bodyFor(base: "https://api.openai.com/v1", level: .deep)
check("OpenAI 用 reasoning_effort", openAIBody["reasoning_effort"] as? String == "high", "\(openAIBody)")
let plainBody = await bodyFor(base: "https://api.deepseek.com/v1", level: nil)
check("没选推理时不加参数", plainBody["thinking"] == nil && plainBody["reasoning_effort"] == nil, "\(plainBody)")

print("配置")
var oldImage = PresetProviders.preset(id: "preset-seedream")!.makeProvider()
oldImage.imageModel = old
PresetProviders.migrateRetiredModels(&oldImage)
check("老配置里的 Seedream 3.0 换成 5.0 Pro", oldImage.imageModel == pro, oldImage.imageModel ?? "nil")
var custom = AIProviderConfig(name: "中转")
custom.model = "deepseek-chat"
PresetProviders.migrateRetiredModels(&custom)
check("自定义服务的模型名不动", custom.model == "deepseek-chat")

var snapshot = ConfigSnapshot.defaultValue()
let qwen = PresetProviders.preset(id: "preset-qwen")!.makeProvider()
let partner = PresetProviders.adopt(qwen, keyIsSet: true, isNew: true, into: &snapshot) { _ in false }
check("新加的有 Key 的服务成为默认", snapshot.defaultProviderID == "preset-qwen")
check("同一个 Key 顺手配上万相", partner?.id == "preset-wanx" && snapshot.imageProviderID == "preset-wanx",
      "\(partner?.id ?? "nil") \(snapshot.imageProviderID ?? "nil")")

var stale = ConfigSnapshot.defaultValue()
stale.providers.append(PresetProviders.preset(id: "preset-kimi")!.makeProvider())
PresetProviders.repairDefaults(&stale) { $0 == "preset-kimi" }
check("默认的没 Key、别的有 Key 时用有 Key 的", stale.defaultProviderID == "preset-kimi", stale.defaultProviderID ?? "nil")

let claude = PresetProviders.preset(id: "preset-anthropic")!.makeProvider()
check("Claude 的模型列表地址", ModelCatalog.listURL(for: claude)?.absoluteString == "https://api.anthropic.com/v1/models?limit=100",
      ModelCatalog.listURL(for: claude)?.absoluteString ?? "nil")

print(failures == 0 ? "全部通过" : "\(failures) 项失败")
exit(failures == 0 ? 0 : 1)
