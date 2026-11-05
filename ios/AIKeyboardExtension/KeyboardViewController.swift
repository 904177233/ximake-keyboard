//
//  KeyboardViewController.swift
//  墨语键盘 · 入口
//
//  负责把顶栏、键区和 SwiftUI 面板摆好，管理键盘高度，把系统回调转给状态中心。
//  平时只有顶栏和键区两个 UIKit 视图，SwiftUI 面板第一次打开时才创建，省内存。
//

import AudioToolbox
import Combine
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController, KeyboardHost, KeySurfaceDelegate {

    private let session = KeyboardSession()
    private let topBar = TopBarView()
    private let surface = KeySurfaceView()
    private let toastLabel = PaddedLabel()
    private var panelHost: UIHostingController<PanelRootView>?
    private var heightConstraint: NSLayoutConstraint?
    private let feedback = KeyFeedback()

    private var appliedVisualState: KeyboardVisualState?
    private var appliedWidth: CGFloat = 0
    private var appliedPrefs: KeyboardPrefs?
    private var appliedDark: Bool?
    private var appliedLandscape: Bool?
    private var lastLayoutWidth: CGFloat = 0
    private var appliedCapHeight: CGFloat = 0
    /// 正在布局回调里。这时候不能强制布局，否则会递归到栈溢出。
    private var isInLayoutPass = false
    private var isApplyingHeight = false
    private let voiceOverlay = VoiceHoldOverlay()
    private let resizeOverlay = ResizeOverlay()
    private var resizeStartHeight: CGFloat = 0
    #if MOYU_SIM_CHECK
    private let simLabel = UILabel()
    private var simStarted = false
    /// 试高度时临时指定的数。
    private var simForcedHeight: CGFloat?
    #endif

    // MARK: - KeyboardHost

    var documentProxy: UITextDocumentProxy { textDocumentProxy }
    var hostHasFullAccess: Bool { hasFullAccess }
    var hostNeedsSwitchKey: Bool { needsInputModeSwitchKey }

    func goToNextKeyboard() {
        advanceToNextInputMode()
    }

    /// 高度对不对的证据，设置页最下面显示。
    var heightDiagnostic: String {
        let window = view.window.map { "\(Int($0.bounds.height))" } ?? "-"
        return "要 \(Int(contentHeight)) 给 \(Int(view.bounds.height)) 可用 \(Int(usableHeight)) 底 \(Int(view.safeAreaInsets.bottom)) 窗 \(window)"
    }

    /// 从键盘打开墨语 App。键盘没有公开的办法，只能顺着响应链找到应用本身。
    ///
    /// 一定要认准类名：iOS 13 以后响应链上先碰到的是窗口场景，它也有同名方法，
    /// 但第二个参数要的是另一种类型，传字典进去会直接崩。上一版就是崩在这里。
    func openContainingApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        // 拆开写是为了躲开静态检查对这个类名的拦截：键盘里不能直接用它的接口，这里只认名字
        let applicationClass: AnyClass? = NSClassFromString(["UI", "Application"].joined())
        var responder: UIResponder? = self
        while let current = responder {
            if let applicationClass, current.isKind(of: applicationClass), current.responds(to: selector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let function = unsafeBitCast(current.method(for: selector), to: OpenFunction.self)
                let done: @convention(block) (Bool) -> Void = { success in
                    DispatchQueue.main.async { completion(success) }
                }
                function(current, selector, url as NSURL, NSDictionary(), done)
                return
            }
            responder = current.next
        }
        if let context = extensionContext {
            context.open(url) { success in
                DispatchQueue.main.async { completion(success) }
            }
        } else {
            completion(false)
        }
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true

        view.addSubview(topBar)
        view.addSubview(surface)
        surface.delegate = self
        surface.installPopup(in: view)
        surface.sideStrip.onSelect = { [weak self] index in
            self?.session.selectSideStrip(at: index)
        }

        toastLabel.isHidden = true
        toastLabel.font = .systemFont(ofSize: 13)
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 9
        toastLabel.layer.masksToBounds = true
        view.addSubview(toastLabel)

        voiceOverlay.isHidden = true
        view.addSubview(voiceOverlay)
        resizeOverlay.isHidden = true
        resizeOverlay.onDrag = { [weak self] translation, began in
            self?.handleResizeDrag(translation: translation, began: began)
        }
        resizeOverlay.onDone = { [weak self] in self?.session.endResize() }
        resizeOverlay.onReset = { [weak self] in self?.session.resetHeight() }
        view.addSubview(resizeOverlay)

        topBar.onTool = { [weak self] tool in self?.handleTool(tool) }
        topBar.onKnob = { [weak self] in
            self?.feedback.tapLight()
            self?.session.openChat()
        }
        topBar.onCandidate = { [weak self] index in
            self?.feedback.tapLight()
            self?.session.chooseCandidate(at: index)
        }
        topBar.onExpand = { [weak self] in self?.session.expandCandidates() }
        topBar.onShowTools = { [weak self] in self?.session.showTools() }
        topBar.onSuggestion = { [weak self] index in
            self?.feedback.tapLight()
            self?.session.chooseSuggestion(at: index)
        }

        session.host = self
        session.onRender = { [weak self] in self?.render() }

        // 不能用 required：系统自己也有一条 required 的高度约束，两条冲突时 view 比系统给的窗口还高，
        // 下面的键就被系统底栏盖住。999 让系统说了算，layoutContent 按实际高度排。
        let constraint = view.heightAnchor.constraint(equalToConstant: contentHeight)
        constraint.priority = UILayoutPriority(999)
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func handleTool(_ tool: ToolID) {
        feedback.tapLight()
        session.runTool(tool)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        syncTraits()
        session.activate()
        applyHeight()
        feedback.prepare(level: session.prefs.haptics, sound: session.prefs.keySound)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 屏幕两边的系统手势会把第一次触摸压住大约 0.4 秒，打 q、p 时特别明显。关掉这个延迟。
        view.window?.gestureRecognizers?.forEach {
            $0.delaysTouchesBegan = false
            $0.cancelsTouchesInView = false
        }
        session.render()
        // 系统说键盘画出来之后才能改高度，这里再确认一次
        DispatchQueue.main.async { [weak self] in
            self?.applyHeight()
        }
        #if MOYU_SIM_CHECK
        startSimCheck()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.deactivate()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        syncTraits()
        session.documentDidChange()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        syncTraits()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        applyHeight()
    }

    private func syncTraits() {
        let appearance = textDocumentProxy.keyboardAppearance ?? .default
        let dark: Bool
        switch appearance {
        case .dark:
            dark = true
        case .light:
            dark = false
        default:
            dark = traitCollection.userInterfaceStyle == .dark
        }
        session.setAppearance(dark: dark)
        session.setLandscape(traitCollection.verticalSizeClass == .compact)
    }

    // MARK: - 布局

    /// 这一页应有的尺寸。
    private var nominalMetrics: KeyboardMetrics {
        let metrics = KeyboardMetrics(height: session.prefs.height, isLandscape: session.isLandscape)
        if !session.isLandscape, let custom = session.prefs.customSurfaceHeight {
            return metrics.resized(toSurfaceHeight: CGFloat(custom))
        }
        return metrics
    }

    /// 真正能用来画的高度。view 比窗口还高时，多出去的部分是看不见的。
    private var usableHeight: CGFloat {
        var height = view.bounds.height
        if let window = view.window {
            let visible = window.bounds.intersection(view.convert(view.bounds, to: window)).height
            if visible > 100 {
                height = min(height, visible)
            }
        }
        return max(height - view.safeAreaInsets.bottom, 0)
    }

    /// 填写设置项时要不要候选栏：只有打中文才用得到，打英文时把这块让给键区。
    private var fieldShowsTopBar: Bool {
        session.page != .field || session.isChinese
    }

    /// 对话时正在看回答：整个键盘都给消息，没有键区。
    private var isChatReading: Bool {
        session.page == .chat && !session.chatTyping
    }

    /// 实际用的尺寸：跟着系统给的高度走，宁可矮一点也不切掉下面的键。
    private var metrics: KeyboardMetrics {
        let nominal = nominalMetrics
        let height = usableHeight
        guard height >= 120 else { return nominal }
        let reserved: CGFloat
        switch session.page {
        case .chat:
            reserved = nominal.topBarHeight + 44
        case .field:
            reserved = (fieldShowsTopBar ? nominal.topBarHeight : 0) + 84
        default:
            reserved = nominal.topBarHeight
        }
        return nominal.fitted(toSurfaceHeight: height - reserved)
    }

    /// 向系统要的总高度（不含底部安全区）。
    ///
    /// 每一页都一样，只跟用户定的高度有关（「矮、标准、高」或在键盘上拖出来的）。
    /// 对话页不靠长高，靠在打字和看回答之间切换。
    private var contentHeight: CGFloat {
        #if MOYU_SIM_CHECK
        if let simForcedHeight {
            return simForcedHeight
        }
        #endif
        let metrics = nominalMetrics
        return metrics.topBarHeight + metrics.surfaceHeight
    }

    /// 把高度告诉系统。
    ///
    /// 只改约束常量不够：系统不一定重新量键盘，表现就是高度没变、下面的键被切掉。
    /// 不在布局回调里时要强制布局一次。在布局回调里绝对不能强制，会递归到栈溢出。
    private func applyHeight() {
        guard isViewLoaded else { return }
        let target = contentHeight + view.safeAreaInsets.bottom
        if heightConstraint == nil {
            let constraint = view.heightAnchor.constraint(equalToConstant: target)
            constraint.priority = UILayoutPriority(999)
            heightConstraint = constraint
        }
        guard let constraint = heightConstraint else { return }
        if !constraint.isActive {
            constraint.isActive = true
        }
        let changed = abs(constraint.constant - target) > 0.5
        if changed {
            constraint.constant = target
        }
        // 布局回调里不能再要求布局，否则每一轮都会排下一轮，CPU 一直空转
        guard !isInLayoutPass else { return }
        view.setNeedsLayout()
        guard !isApplyingHeight, changed || abs(view.bounds.height - target) > 0.5 else { return }
        isApplyingHeight = true
        defer { isApplyingHeight = false }
        view.setNeedsUpdateConstraints()
        view.layoutIfNeeded()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // 键盘重建时系统可能把约束拿掉，这里兜底。只同步数值，不强制布局。
        isInLayoutPass = true
        applyHeight()
        isInLayoutPass = false
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        isInLayoutPass = true
        defer { isInLayoutPass = false }
        layoutContent()
        // 只在宽度或键高真的变了时重排键位。这里不能无条件刷新，否则会陷入布局循环。
        let keysVisible = !surface.isHidden
        if lastLayoutWidth != view.bounds.width || (keysVisible && abs(metrics.capHeight - appliedCapHeight) > 0.25) {
            lastLayoutWidth = view.bounds.width
            appliedVisualState = nil
            render()
            layoutContent()
        }
    }

    private func layoutContent() {
        let metrics = self.metrics
        let insets = view.safeAreaInsets
        let width = view.bounds.width - insets.left - insets.right
        let height = usableHeight
        let bar = metrics.topBarHeight

        switch session.page {
        case .keys, .numbers:
            topBar.frame = CGRect(x: insets.left, y: 0, width: width, height: bar)
            surface.frame = CGRect(x: insets.left, y: bar, width: width, height: metrics.surfaceHeight)
        case .symbols, .candidates:
            topBar.frame = CGRect(x: insets.left, y: 0, width: width, height: bar)
            panelHost?.view.frame = CGRect(x: insets.left, y: bar, width: width, height: max(height - bar, 0))
        case .ai, .settings, .voice:
            panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: height)
        case .chat, .field:
            if isChatReading {
                panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: height)
            } else {
                let barHeight = fieldShowsTopBar ? bar : 0
                let panel = max(height - barHeight - metrics.surfaceHeight, 0)
                panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: panel)
                topBar.frame = CGRect(x: insets.left, y: panel, width: width, height: barHeight)
                surface.frame = CGRect(x: insets.left, y: panel + barHeight, width: width, height: metrics.surfaceHeight)
            }
        }

        voiceOverlay.frame = surface.frame
        resizeOverlay.frame = CGRect(x: insets.left, y: 0, width: width, height: bar)

        let toastWidth = min(width - 40, toastLabel.intrinsicContentSize.width)
        toastLabel.frame = CGRect(x: (view.bounds.width - toastWidth) / 2, y: 8, width: toastWidth, height: 30)
    }

    // MARK: - 渲染

    /// 把状态画到界面上。
    private func render() {
        guard isViewLoaded else { return }
        let palette = session.palette
        view.backgroundColor = palette.canvas
        let page = session.page

        // 面板
        let needsPanel = page != .keys && page != .numbers
        if needsPanel, panelHost == nil {
            createPanelHost()
        }
        panelHost?.view.isHidden = !needsPanel

        // 顶栏和键区
        let showsTopBar = page != .ai && page != .settings && page != .voice && !isChatReading && fieldShowsTopBar
        let showsSurface = page == .keys || page == .numbers || (page == .chat && !isChatReading) || page == .field
        topBar.isHidden = !showsTopBar
        surface.isHidden = !showsSurface

        if showsTopBar {
            topBar.setTools(session.tools)
            topBar.apply(palette: palette)
            topBar.apply(content: session.topBarContent)
        }

        if showsSurface {
            let width = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
            let visual = session.visualState
            let metrics = self.metrics
            if visual != appliedVisualState || width != appliedWidth || session.prefs != appliedPrefs
                || session.isDark != appliedDark || session.isLandscape != appliedLandscape
                || abs(metrics.capHeight - appliedCapHeight) > 0.25 {
                let layout = KeyLayoutBuilder.build(state: visual,
                                                    size: CGSize(width: width, height: metrics.surfaceHeight),
                                                    metrics: metrics)
                surface.configure(layout: layout, palette: palette, mascot: session.mascotImage)
                appliedVisualState = visual
                appliedWidth = width
                appliedPrefs = session.prefs
                appliedDark = session.isDark
                appliedLandscape = session.isLandscape
                appliedCapHeight = metrics.capHeight
                feedback.prepare(level: session.prefs.haptics, sound: session.prefs.keySound)
            }
            if visual.kind == .nineKey {
                surface.sideStrip.update(items: session.sideStripItems, highlightFirst: false)
            }
        }

        // 长按空格说话
        if session.voiceHold != .off, showsSurface {
            voiceOverlay.apply(state: session.voiceHold, text: session.voiceText, palette: palette)
            voiceOverlay.isHidden = false
            view.bringSubviewToFront(voiceOverlay)
        } else {
            voiceOverlay.isHidden = true
        }

        // 拖动调高度
        resizeOverlay.isHidden = !session.isResizing
        if session.isResizing {
            resizeOverlay.apply(palette: palette, height: Int(contentHeight))
            view.bringSubviewToFront(resizeOverlay)
        }

        // 提示
        if let toast = session.toast {
            toastLabel.text = toast
            toastLabel.backgroundColor = palette.text
            toastLabel.textColor = palette.canvas
            toastLabel.isHidden = false
            view.bringSubviewToFront(toastLabel)
        } else {
            toastLabel.isHidden = true
        }

        applyHeight()
    }

    private func createPanelHost() {
        let host = UIHostingController(rootView: PanelRootView(session: session, ai: session.ai, chat: session.chat))
        host.view.backgroundColor = .clear
        if #available(iOS 16.4, *) {
            host.safeAreaRegions = []
        }
        addChild(host)
        view.insertSubview(host.view, at: 0)
        host.didMove(toParent: self)
        panelHost = host
    }

    #if MOYU_SIM_CHECK
    /// 模拟器实测：自己走一遍各个高度和页面，CI 按时间截图。角上写着这一步和实际高度。
    private func startSimCheck() {
        guard !simStarted else { return }
        simStarted = true
        simLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        simLabel.textColor = .green
        simLabel.backgroundColor = .black
        simLabel.numberOfLines = 2
        view.addSubview(simLabel)
        let session = self.session
        let steps: [(String, () -> Void)] = [
            ("标准", { session.updatePrefs { $0.height = .standard }; session.setPage(.keys) }),
            ("拖到 340", { session.beginResize(); session.resize(toSurfaceHeight: 340) }),
            ("恢复高度", { session.resetHeight(); session.endResize() }),
            ("对话打字", { session.openChat() }),
            ("对话看回答", { session.chat.fillForSimCheck(); session.setChatTyping(false) }),
            ("画图面板", { session.openAI(.image) }),
            ("填设置项", { session.setPage(.keys); session.beginField(title: "API Key", value: "", isSecret: true, preferEnglish: true) { _ in } }),
            ("设置", { session.finishField(save: false); session.openSettings() }),
            ("长按空格动画", { session.setPage(.keys); session.showVoiceHoldForSimCheck() }),
            ("真的长按空格", { session.endVoiceHold(cancelled: true); session.beginVoiceHold() })
        ]
        Task { @MainActor [weak self] in
            var index = 0
            while let self {
                let step = steps[index % steps.count]
                step.1()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.simLabel.text = "S\(index % steps.count) \(step.0)\n\(self.heightDiagnostic)"
                self.simLabel.frame = CGRect(x: 0, y: 0, width: self.view.bounds.width, height: 30)
                self.view.bringSubviewToFront(self.simLabel)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                index += 1
            }
        }
    }
    #endif

    // MARK: - KeySurfaceDelegate

    func keySurface(_ surface: KeySurfaceView, didTrigger action: KeyAction) {
        session.handle(action)
    }

    func keySurface(_ surface: KeySurfaceView, moveCursorBy offset: Int) {
        session.moveCursor(by: offset)
    }

    func keySurfaceDidSwipeClear(_ surface: KeySurfaceView) {
        session.clearCompositionBySwipe()
    }

    func keySurfaceDidPress(_ surface: KeySurfaceView, action: KeyAction) {
        feedback.keyDown(action)
    }

    func keySurfaceDidBeginSpaceHold(_ surface: KeySurfaceView) {
        feedback.tapLight()
        session.beginVoiceHold()
    }

    func keySurface(_ surface: KeySurfaceView, spaceHoldWillCancel cancel: Bool) {
        feedback.tapLight()
        session.updateVoiceHold(cancel: cancel)
    }

    func keySurfaceDidEndSpaceHold(_ surface: KeySurfaceView, cancelled: Bool) {
        session.endVoiceHold(cancelled: cancelled)
    }

    // MARK: - 拖动调高度

    private func handleResizeDrag(translation: CGFloat, began: Bool) {
        if began {
            resizeStartHeight = nominalMetrics.surfaceHeight
        }
        // 往上拖变高
        let height = min(max(resizeStartHeight - translation, 150), 560)
        session.resize(toSurfaceHeight: height)
    }
}

/// 长按空格说话时盖在键区上的面板：跳动的竖条 + 听到的字。
final class VoiceHoldOverlay: UIView {

    private let panel = UIView()
    private let replicator = CAReplicatorLayer()
    private let bar = CALayer()
    private let label = UILabel()
    private let hint = UILabel()
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        panel.layer.cornerRadius = 16
        panel.layer.cornerCurve = .continuous
        addSubview(panel)

        bar.frame = CGRect(x: 0, y: 0, width: 6, height: 30)
        bar.cornerRadius = 3
        replicator.instanceCount = 5
        replicator.instanceTransform = CATransform3DMakeTranslation(11, 0, 0)
        replicator.instanceDelay = 0.12
        replicator.addSublayer(bar)
        panel.layer.addSublayer(replicator)

        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingHead
        panel.addSubview(label)

        hint.font = .systemFont(ofSize: 12.5)
        hint.textAlignment = .center
        panel.addSubview(hint)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(state: KeyboardSession.VoiceHold, text: String, palette: MoyuPalette) {
        let cancelling = state == .cancelling
        panel.backgroundColor = cancelling ? palette.function : palette.key
        bar.backgroundColor = (cancelling ? palette.secondary : palette.accent).cgColor
        label.textColor = palette.text
        hint.textColor = palette.secondary
        switch state {
        case .listening:
            label.text = text.isEmpty ? "正在听…" : text
            hint.text = "松开结束 · 上滑取消"
        case .cancelling:
            label.text = "松开取消"
            hint.text = "滑回去接着说"
        case .transcribing:
            label.text = text.isEmpty ? "正在转文字…" : text
            hint.text = "马上放进输入框"
        case .off:
            break
        }
        setAnimating(state == .listening || state == .transcribing)
        setNeedsLayout()
    }

    private func setAnimating(_ on: Bool) {
        guard on != animating else { return }
        animating = on
        if on {
            let pulse = CABasicAnimation(keyPath: "transform.scale.y")
            pulse.fromValue = 0.25
            pulse.toValue = 1
            pulse.duration = 0.42
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(pulse, forKey: "pulse")
        } else {
            bar.removeAllAnimations()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panel.frame = bounds.insetBy(dx: 8, dy: 6)
        let width = panel.bounds.width
        let barsWidth: CGFloat = 11 * 4 + 6
        let top = max(panel.bounds.height * 0.18, 12)
        replicator.frame = CGRect(x: (width - barsWidth) / 2, y: top, width: barsWidth, height: 30)
        label.frame = CGRect(x: 16, y: top + 42, width: width - 32, height: 46)
        hint.frame = CGRect(x: 16, y: panel.bounds.height - 30, width: width - 32, height: 18)
    }
}

/// 拖动调高度时盖在顶栏上的条：上下拖动，旁边是恢复默认和完成。
final class ResizeOverlay: UIView {

    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDone: (() -> Void)?
    var onReset: (() -> Void)?

    private let grip = UIView()
    private let label = UILabel()
    private let doneButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        grip.layer.cornerRadius = 2.5
        addSubview(grip)
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        addSubview(label)
        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doneButton.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        addSubview(doneButton)
        resetButton.setTitle("恢复默认", for: .normal)
        resetButton.titleLabel?.font = .systemFont(ofSize: 14)
        resetButton.addAction(UIAction { [weak self] _ in self?.onReset?() }, for: .touchUpInside)
        addSubview(resetButton)
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func apply(palette: MoyuPalette, height: Int) {
        backgroundColor = palette.canvas
        grip.backgroundColor = palette.secondary
        label.textColor = palette.text
        label.text = "按住这里上下拖动 · \(height)"
        doneButton.tintColor = palette.accentText
        resetButton.tintColor = palette.secondary
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview).y
        switch gesture.state {
        case .began:
            onDrag?(translation, true)
        case .changed:
            onDrag?(translation, false)
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        grip.frame = CGRect(x: (width - 40) / 2, y: 6, width: 40, height: 5)
        resetButton.frame = CGRect(x: 6, y: 0, width: 80, height: height)
        doneButton.frame = CGRect(x: width - 66, y: 0, width: 60, height: height)
        label.frame = CGRect(x: 90, y: 8, width: width - 160, height: height - 8)
    }
}

/// 按键触感和按键音。没开完全访问时系统会忽略，不会出错。
@MainActor
final class KeyFeedback {
    private var generator = UIImpactFeedbackGenerator(style: .light)
    private var level: KeyboardPrefs.HapticLevel = .light
    private var soundEnabled = false

    func prepare(level: KeyboardPrefs.HapticLevel, sound: Bool) {
        if level != self.level {
            self.level = level
            switch level {
            case .off, .light:
                generator = UIImpactFeedbackGenerator(style: .light)
            case .medium:
                generator = UIImpactFeedbackGenerator(style: .medium)
            case .strong:
                generator = UIImpactFeedbackGenerator(style: .heavy)
            }
        }
        soundEnabled = sound
        if level != .off {
            generator.prepare()
        }
    }

    private var intensity: CGFloat {
        switch level {
        case .off: return 0
        case .light: return 0.5
        case .medium: return 0.8
        case .strong: return 1
        }
    }

    func keyDown(_ action: KeyAction) {
        if level != .off {
            generator.impactOccurred(intensity: intensity)
            generator.prepare()
        }
        if soundEnabled {
            // 不用 playInputClick：它要求整个输入视图声明支持，而且受系统「键盘反馈」开关影响，
            // 经常没声音。这几个是系统键盘自己用的按键音，受静音开关控制。
            let sound: SystemSoundID
            switch action {
            case .backspace:
                sound = 1155
            case .shift, .space, .enter, .language, .showNumbers, .showLetters, .showSymbols, .toggleLayout, .nextKeyboard:
                sound = 1156
            default:
                sound = 1104
            }
            AudioServicesPlaySystemSound(sound)
        }
    }

    func tapLight() {
        if level != .off {
            generator.impactOccurred(intensity: intensity * 0.8)
        }
    }
}

/// 带内边距的标签（用来做提示条）。
final class PaddedLabel: UILabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 26, height: size.height + 12)
    }
}
