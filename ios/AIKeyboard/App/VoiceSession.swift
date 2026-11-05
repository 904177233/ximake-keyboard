//
//  VoiceSession.swift
//  墨语 App · 语音会话
//
//  苹果不给自定义键盘用麦克风，所以录音在 App 里做。
//  会话打开后麦克风一直开着（开了后台音频，回到别的 App 也不停），键盘长按空格时喊一声「开始」，
//  松开喊「说完了」，这里把听到的字转好交给 VoiceBridge。一段时间没用就自动关掉。
//

import AVFoundation
import Combine
import Speech
import UIKit

/// 音频回调在别的线程，只通过它把声音交给当前的识别请求。
final class SpeechFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var level: Float = 0

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
        let value = Self.level(of: buffer)
        lock.lock()
        level = value
        lock.unlock()
    }

    var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// -50 dB 到 0 dB 映射到 0 到 1。
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<frames {
            sum += channel[index] * channel[index]
        }
        let decibels = 20 * log10f(max(sqrtf(sum / Float(frames)), 0.000_01))
        return min(max((decibels + 50) / 50, 0), 1)
    }
}

@MainActor
final class VoiceSession: ObservableObject {

    static let shared = VoiceSession()

    enum State: Equatable {
        case off, starting, ready, listening, transcribing
        case failed(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var text = ""
    @Published private(set) var lastResult = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var idleSince = Date()

    private let engine = AVAudioEngine()
    private let feed = SpeechFeed()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var finishTimeout: Task<Void, Never>?
    private var signalsReady = false

    private init() {}

    /// 会话开着（能接键盘的「开始」）。
    var isOpen: Bool {
        switch state {
        case .ready, .listening, .transcribing: return true
        default: return false
        }
    }

    /// 还剩几分钟自动关。
    var minutesLeft: Int {
        let total = Double(AIPrefs.load().voiceKeepAliveMinutes) * 60
        return max(Int(((total - Date().timeIntervalSince(idleSince)) / 60).rounded(.up)), 0)
    }

    // MARK: - 打开、关闭

    /// 打开会话。listenNow 为 true 时马上开始听（从键盘跳过来时）。
    func open(listenNow: Bool) {
        setUpSignals()
        switch state {
        case .ready:
            if listenNow { beginUtterance() }
            return
        case .listening, .transcribing, .starting:
            return
        case .off, .failed:
            break
        }
        state = .starting
        Self.requestPermissions { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.fail("还没允许麦克风或语音识别。到 设置 › 墨语 里打开。")
                return
            }
            self.startEngine()
            if self.state == .ready, listenNow {
                self.beginUtterance()
            }
        }
    }

    nonisolated private static func requestPermissions(_ done: @escaping @MainActor (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            SFSpeechRecognizer.requestAuthorization { status in
                Task { @MainActor in done(granted && status == .authorized) }
            }
        }
    }

    private func startEngine() {
        let session = AVAudioSession.sharedInstance()
        do {
            // 和音乐、视频一起放，不打断别的 App 的声音
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            fail("系统不让录音：\(error.localizedDescription)")
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("找不到麦克风。打电话或别的 App 占着麦克风时也会这样。")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTap(feed))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            fail("麦克风打不开：\(error.localizedDescription)")
            return
        }
        state = .ready
        idleSince = Date()
        startTimer()
        publish()
    }

    /// 回调在音频线程，不能是主线程隔离的闭包，单独在这里做。
    nonisolated private static func makeTap(_ feed: SpeechFeed) -> AVAudioNodeTapBlock {
        { buffer, _ in feed.append(buffer) }
    }

    /// 关掉会话，释放麦克风。
    func close() {
        timer?.invalidate()
        timer = nil
        finishTimeout?.cancel()
        task?.cancel()
        task = nil
        request = nil
        feed.set(nil)
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        state = .off
        text = ""
        VoiceBridge.clear()
    }

    private func fail(_ reason: String) {
        state = .failed(reason)
        VoiceBridge.publish(VoiceBridgeState(status: .failed, text: reason))
        VoiceSignals.post(.done)
    }

    // MARK: - 一段话

    func beginUtterance() {
        guard state == .ready else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail("语音识别现在用不了，检查一下网络。")
            return
        }
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            next.requiresOnDeviceRecognition = true
        }
        text = ""
        task?.cancel()
        request = next
        task = recognizer.recognitionTask(with: next, resultHandler: Self.makeResultHandler())
        feed.set(next)
        state = .listening
        publish()
    }

    nonisolated private static func makeResultHandler() -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let words = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                VoiceSession.shared.handle(words: words, isFinal: isFinal, failed: failed)
            }
        }
    }

    private func handle(words: String?, isFinal: Bool, failed: Bool) {
        guard state == .listening || state == .transcribing else { return }
        if let words {
            text = words
        }
        if isFinal || (failed && state == .transcribing) {
            finishUtterance()
        } else if failed {
            // 听的时候出错（比如一直没声音），当成说完了
            finishUtterance()
        }
    }

    /// 说完了。
    func endUtterance() {
        guard state == .listening else { return }
        state = .transcribing
        request?.endAudio()
        feed.set(nil)
        publish()
        finishTimeout?.cancel()
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.finishUtterance()
        }
    }

    /// 不要了。
    func discard() {
        guard state == .listening || state == .transcribing else { return }
        finishTimeout?.cancel()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        feed.set(nil)
        text = ""
        state = .ready
        idleSince = Date()
        VoiceBridge.publish(VoiceBridgeState(status: .ready, text: ""))
    }

    private func finishUtterance() {
        guard state == .listening || state == .transcribing else { return }
        finishTimeout?.cancel()
        task?.finish()
        task = nil
        request = nil
        feed.set(nil)
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .ready
        idleSince = Date()
        if result.isEmpty {
            VoiceBridge.publish(VoiceBridgeState(status: .failed, text: "没听清，再说一次。"))
        } else {
            lastResult = result
            VoiceBridge.publishFinished(result)
        }
        VoiceSignals.post(.done)
    }

    // MARK: - 和键盘说话

    private func setUpSignals() {
        guard !signalsReady else { return }
        signalsReady = true
        VoiceSignals.observe(.start) { VoiceSession.shared.handle(.start) }
        VoiceSignals.observe(.stop) { VoiceSession.shared.handle(.stop) }
        VoiceSignals.observe(.discard) { VoiceSession.shared.handle(.discard) }
        VoiceSignals.observe(.ping) {
            if VoiceSession.shared.isOpen {
                VoiceSignals.post(.pong)
            }
        }
    }

    private func handle(_ command: VoiceBridge.Command) {
        switch command {
        case .start:
            if state == .ready { beginUtterance() }
        case .stop:
            endUtterance()
        case .discard:
            discard()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in VoiceSession.shared.tick() }
        }
    }

    private func tick() {
        // 没打通共享存储时命令只能走信号；打通时两条路都看，重复了也没关系
        if let command = VoiceBridge.takeCommand() {
            handle(command)
        }
        level = feed.currentLevel
        publish()
        let keepAlive = Double(AIPrefs.load().voiceKeepAliveMinutes) * 60
        if state == .ready, Date().timeIntervalSince(idleSince) > keepAlive {
            close()
        }
    }

    /// 告诉键盘现在怎样了。刚出的结果还没被键盘取走时不覆盖。
    private func publish() {
        switch state {
        case .listening:
            VoiceBridge.publish(VoiceBridgeState(status: .listening, text: text, level: Double(feed.currentLevel)))
        case .transcribing:
            VoiceBridge.publish(VoiceBridgeState(status: .transcribing, text: text))
        case .ready:
            if let current = VoiceBridge.readState(), current.status == .finished || current.status == .failed, current.isRecent,
               Date().timeIntervalSince(current.updatedAt) < 8 {
                return
            }
            VoiceBridge.publish(VoiceBridgeState(status: .ready, text: ""))
        default:
            break
        }
    }
}
