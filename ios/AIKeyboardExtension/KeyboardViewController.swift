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

    // MARK: - KeyboardHost

    var documentProxy: UITextDocumentProxy { textDocumentProxy }
    var hostHasFullAccess: Bool { hasFullAccess }
    var hostNeedsSwitchKey: Bool { needsInputModeSwitchKey }

    func goToNextKeyboard() {
        advanceToNextInputMode()
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

        let constraint = view.heightAnchor.constraint(equalToConstant: contentHeight(for: .keys))
        constraint.priority = .required
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
        KeyboardMetrics(height: session.prefs.height, isLandscape: session.isLandscape)
    }

    /// 实际用的尺寸：系统给的高度不够时压缩键高，宁可矮一点也不切掉下面的键。
    private var metrics: KeyboardMetrics {
        let nominal = nominalMetrics
        let height = view.bounds.height - view.safeAreaInsets.bottom
        guard height >= 120 else { return nominal }
        let reserved: CGFloat
        switch session.page {
        case .chat:
            reserved = nominal.topBarHeight + 64
        case .field:
            reserved = nominal.topBarHeight + 84
        default:
            reserved = nominal.topBarHeight
        }
        return nominal.fitted(toSurfaceHeight: height - reserved)
    }

    /// 这一页应有的总高度（不含底部安全区）。
    private func contentHeight(for page: KeyboardSession.Page) -> CGFloat {
        let metrics = nominalMetrics
        let base = metrics.topBarHeight + metrics.surfaceHeight
        switch page {
        case .chat:
            return base + (metrics.isLandscape ? 86 : 162)
        case .field:
            return base + 84
        default:
            return base
        }
    }

    /// 把高度告诉系统。
    ///
    /// 只改约束常量不够：系统不一定重新量键盘，表现就是高度没变、下面的键被切掉。
    /// 不在布局回调里时要强制布局一次。在布局回调里绝对不能强制，会递归到栈溢出。
    private func applyHeight() {
        guard isViewLoaded else { return }
        let target = contentHeight(for: session.page) + view.safeAreaInsets.bottom
        if heightConstraint == nil {
            heightConstraint = view.heightAnchor.constraint(equalToConstant: target)
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
        let selector = NSSelectorFromString("requestInputViewHeightUpdate")
        if responds(to: selector) {
            perform(selector)
        }
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
        let height = max(view.bounds.height - insets.bottom, 0)
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
            let panel = max(height - bar - metrics.surfaceHeight, 0)
            panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: panel)
            topBar.frame = CGRect(x: insets.left, y: panel, width: width, height: bar)
            surface.frame = CGRect(x: insets.left, y: panel + bar, width: width, height: metrics.surfaceHeight)
        }

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
        let showsTopBar = page != .ai && page != .settings && page != .voice
        let showsSurface = page == .keys || page == .numbers || page == .chat || page == .field
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
