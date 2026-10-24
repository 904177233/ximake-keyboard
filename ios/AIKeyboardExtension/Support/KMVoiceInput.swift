//
//  KMVoiceInput.swift
//  AIKeyboardExtension
//
//  键盘内语音输入（录音 + 端侧转写）。
//
//  ## 为什么用 SFSpeechRecognizer 而不是 SpeechAnalyzer
//  iOS 26 的 `SpeechAnalyzer` / `DictationTranscriber` 在当前环境无法核对真实 API
//  签名（没有 Xcode / SDK 头文件），凭记忆写会在 Xcode 26 上编译失败。因此统一走
//  iOS 10+ 就存在、iOS 26 依然可用的 `SFSpeechRecognizer` + `AVAudioEngine` 路线，
//  并封装在 `KMVoiceInput` 里：将来升级只需替换 `beginRecording()` 与转写回调两处，
//  `KMVoiceState` 与 UI 完全不用动。
//
//  ## 权限与失败路径
//  · 麦克风：iOS 17+ 用 `AVAudioApplication.requestRecordPermission`，
//    iOS 16 用 `AVAudioSession.sharedInstance().requestRecordPermission`。
//  · 语音识别：`SFSpeechRecognizer.requestAuthorization`。
//  · 键盘扩展未开完全访问时通常拿不到麦克风，任何一步失败都落到
//    `.failed(isPlatformUnsupported:)` 而不是崩溃，UI 侧据此给出备选路径。
//  · 所有 `AVAudioSession` / `AVAudioEngine` 调用都包 try/catch。
//
//  ## 内存
//  音频 tap 每帧只取 RMS 后立刻丢弃，不缓存 PCM；转写只保留文本，
//  符合键盘扩展 40–60MB 的内存预算。
//

import AVFoundation
import Combine
import Foundation
import Speech

// MARK: - 状态

/// 语音输入状态机。
public enum KMVoiceState: Equatable {
    /// 空闲。
    case idle
    /// 正在申请权限。
    case requestingPermission
    /// 正在录音：`level` 为 0–1 归一化音量，`elapsed` 为已录秒数。
    case recording(level: Float, elapsed: TimeInterval)
    /// 录音已停止，等待最终转写。
    case transcribing
    /// 完成，`text` 是最终结果。
    case finished(text: String)
    /// 失败；`isPlatformUnsupported` 表示环境不支持而非临时错误。
    case failed(reason: String, isPlatformUnsupported: Bool)

    /// 是否处于进行中（录音或转写）。
    public var isActive: Bool {
        switch self {
        case .requestingPermission, .recording, .transcribing: return true
        case .idle, .finished, .failed: return false
        }
    }
}

// MARK: - 控制器

/// 键盘内语音输入控制器（扩展内全局唯一）。
@MainActor
public final class KMVoiceInput: ObservableObject {

    /// 全局单例。
    public static let shared = KMVoiceInput()

    /// 当前状态。
    @Published public private(set) var state: KMVoiceState = .idle

    /// 实时中间结果（录音中逐字更新）。
    @Published public private(set) var partialText: String = ""

    /// 最长录音时长（60 秒自动停）。
    public static let maximumDuration: TimeInterval = 60

    /// 音量刷新间隔 100ms。
    private static let levelInterval: TimeInterval = 0.1

    /// 转写语言。
    public static let localeIdentifier = "zh-CN"

    // MARK: 内部状态

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var audioEngine: AVAudioEngine?
    private var tickTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var startedAt: Date?
    private var isFinishing: Bool = false

    /// 私有初始化（只允许 `shared`）。
    private init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.localeIdentifier))
    }

    // MARK: 能力探测

    /// 当前环境是否「可能可用」。
    ///
    /// 键盘扩展未开完全访问时这里仍可能返回 true，真正失败会落到 `.failed`，
    /// 所以 UI 不要只依赖它做硬判断。
    public var isAvailable: Bool {
        guard isPlatformSupported else { return false }
        return SFSpeechRecognizer.authorizationStatus() != .denied
    }

    /// 当前系统/设备是否支持语音输入（模拟器与部分地区会返回 false）。
    public var isPlatformSupported: Bool {
        guard let recognizer else { return false }
        return recognizer.isAvailable || SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    // MARK: 公开动作

    /// 开始录音（先申请权限）。
    public func start() {
        guard !state.isActive else { return }
        resetInternalState()
        partialText = ""
        state = .requestingPermission

        guard isPlatformSupported, recognizer != nil else {
            state = .failed(
                reason: "当前系统不支持键盘内语音，可以到「墨语」App 里用语音输入再回来粘贴",
                isPlatformUnsupported: true
            )
            return
        }

        requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.state = .failed(
                    reason: "没有麦克风或语音识别权限。请到系统「设置 › 墨语」里允许，或在宿主 App 内使用语音",
                    isPlatformUnsupported: false
                )
                return
            }
            self.beginRecording()
        }
    }

    /// 停止录音并等待最终转写结果。
    public func stop() {
        guard case .recording = state else {
            if state == .requestingPermission { state = .idle }
            return
        }
        state = .transcribing
        tickTask?.cancel()
        tickTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        stopEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
    }

    /// 取消录音（丢弃结果）。
    public func cancel() {
        resetInternalState()
        partialText = ""
        state = .idle
    }

    /// 复位到空闲。
    public func reset() {
        resetInternalState()
        partialText = ""
        state = .idle
    }

    // MARK: 权限

    /// 依次申请麦克风与语音识别权限。
    private func requestPermissions(_ completion: @escaping (Bool) -> Void) {
        requestMicrophonePermission { micGranted in
            guard micGranted else {
                completion(false)
                return
            }
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        }
    }

    /// 申请麦克风权限（iOS 17+ 走新 API，iOS 16 走旧 API）。
    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: 录音

    /// 配置音频会话并开始录音 + 识别。
    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            state = .failed(
                reason: "无法启动麦克风（键盘扩展内常被限制）。请到宿主 App 里使用语音输入",
                isPlatformUnsupported: false
            )
            return
        }

        guard let recognizer else {
            state = .failed(reason: "语音识别不可用", isPlatformUnsupported: true)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // 端侧识别优先：键盘扩展网络受限，且端侧更快更省流量。
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        // 缓冲区 1024 帧（约 20ms）：既能算 RMS 又不至于太频繁。
        // 注意：回调在音频线程，只捕获局部 `request`，不碰 @MainActor 状态。
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            Task { @MainActor [weak self] in self?.updateLevel(level) }
        }

        recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in self?.handleRecognition(result: result, error: error) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stopEngine()
            state = .failed(reason: "麦克风启动失败：\(error.localizedDescription)",
                            isPlatformUnsupported: false)
            return
        }

        startedAt = Date()
        partialText = ""
        state = .recording(level: 0, elapsed: 0)
        startTicking()
        scheduleAutoStop()
    }

    /// 停止音频引擎并释放麦克风。
    private func stopEngine() {
        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
    }

    // MARK: 计时

    /// 秒表：每 100ms 刷新 elapsed。
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.levelInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard case let .recording(level, _) = self.state else { return }
                let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.state = .recording(level: level, elapsed: elapsed)
            }
        }
    }

    /// 60 秒自动停止。
    private func scheduleAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maximumDuration * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if case .recording = self.state { self.stop() }
        }
    }

    /// 更新当前音量（只在录音态生效）。
    private func updateLevel(_ level: Float) {
        guard case let .recording(_, elapsed) = state else { return }
        state = .recording(level: level, elapsed: elapsed)
    }

    // MARK: 识别回调

    /// 处理识别结果 / 错误。
    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            partialText = text
            if result.isFinal {
                finish(text: text)
                return
            }
            // 已停止录音但系统迟迟不给 final 时，用当前文本兜底。
            if case .transcribing = state, !text.isEmpty {
                finish(text: text)
            }
            return
        }

        if let error {
            // 用户主动取消时系统会抛 216/301 之类错误，不当失败。
            if state == .idle || isFinishing { return }
            state = .failed(reason: "语音识别失败：\(error.localizedDescription)",
                            isPlatformUnsupported: false)
            resetInternalState()
        }
    }

    /// 收尾：写入最终文本。
    private func finish(text: String) {
        guard !isFinishing else { return }
        isFinishing = true
        stopEngine()
        tickTask?.cancel()
        tickTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state = .failed(reason: "没有识别到内容，请再说一次", isPlatformUnsupported: false)
        } else {
            partialText = trimmed
            state = .finished(text: trimmed)
        }
        startedAt = nil
        isFinishing = false
    }

    /// 释放所有内部资源并回到 idle。
    private func resetInternalState() {
        stopEngine()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        tickTask?.cancel()
        tickTask = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        startedAt = nil
        isFinishing = true
        DispatchQueue.main.async { [weak self] in self?.isFinishing = false }
    }

    // MARK: 音量

    /// 从 PCM 缓冲计算归一化 RMS（0–1），-50dB…0dB 映射到 0…1。
    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frameLength))
        let decibels = 20 * log10f(max(rms, 0.000_01))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
