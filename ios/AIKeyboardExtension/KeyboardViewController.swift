//
//  KeyboardViewController.swift
//  墨语键盘 · 入口
//
//  负责把顶栏、键区和 SwiftUI 面板摆好，管理键盘高度，把系统回调转给状态中心。
//  平时只有顶栏和键区两个 UIKit 视图，SwiftUI 面板第一次打开时才创建，省内存。
//

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

        let constraint = view.heightAnchor.constraint(equalToConstant: 261)
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
        feedback.prepare(enabled: session.prefs.haptics, sound: session.prefs.keySound, surface: surface)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 屏幕两边的系统手势会把第一次触摸压住大约 0.4 秒，打 q、p 时特别明显。关掉这个延迟。
        view.window?.gestureRecognizers?.forEach {
            $0.delaysTouchesBegan = false
            $0.cancelsTouchesInView = false
        }
        session.render()
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
        updateHeight()
        view.setNeedsLayout()
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

    private var metrics: KeyboardMetrics {
        KeyboardMetrics(height: session.prefs.height, isLandscape: session.isLandscape)
    }

    /// 面板区高度；0 表示这一页没有面板。
    private func panelHeight(for page: KeyboardSession.Page) -> CGFloat {
        let metrics = self.metrics
        switch page {
        case .keys, .numbers:
            return 0
        case .symbols, .candidates:
            return metrics.surfaceHeight
        case .ai, .settings, .voice:
            return metrics.topBarHeight + metrics.surfaceHeight
        case .chat:
            return metrics.isLandscape ? 86 : 162
        case .field:
            return 84
        }
    }

    private func contentHeight(for page: KeyboardSession.Page) -> CGFloat {
        let metrics = self.metrics
        switch page {
        case .keys, .numbers:
            return metrics.topBarHeight + metrics.surfaceHeight
        case .symbols, .candidates:
            return metrics.topBarHeight + metrics.surfaceHeight
        case .ai, .settings, .voice:
            return metrics.topBarHeight + metrics.surfaceHeight
        case .chat, .field:
            return panelHeight(for: page) + metrics.topBarHeight + metrics.surfaceHeight
        }
    }

    private func updateHeight() {
        let target = contentHeight(for: session.page) + view.safeAreaInsets.bottom
        if let constraint = heightConstraint, abs(constraint.constant - target) > 0.5 {
            constraint.constant = target
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutContent()
        // 只在宽度真的变了时重排键位。这里不能无条件刷新，否则会陷入布局循环。
        if lastLayoutWidth != view.bounds.width {
            lastLayoutWidth = view.bounds.width
            appliedVisualState = nil
            render()
        }
    }

    private func layoutContent() {
        let metrics = self.metrics
        let insets = view.safeAreaInsets
        let width = view.bounds.width - insets.left - insets.right
        let page = session.page
        let panel = panelHeight(for: page)
        var y: CGFloat = 0

        switch page {
        case .keys, .numbers:
            topBar.frame = CGRect(x: insets.left, y: 0, width: width, height: metrics.topBarHeight)
            surface.frame = CGRect(x: insets.left, y: metrics.topBarHeight, width: width, height: metrics.surfaceHeight)
        case .symbols, .candidates:
            topBar.frame = CGRect(x: insets.left, y: 0, width: width, height: metrics.topBarHeight)
            panelHost?.view.frame = CGRect(x: insets.left, y: metrics.topBarHeight, width: width, height: panel)
        case .ai, .settings, .voice:
            panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: panel)
        case .chat, .field:
            panelHost?.view.frame = CGRect(x: insets.left, y: 0, width: width, height: panel)
            y = panel
            topBar.frame = CGRect(x: insets.left, y: y, width: width, height: metrics.topBarHeight)
            y += metrics.topBarHeight
            surface.frame = CGRect(x: insets.left, y: y, width: width, height: metrics.surfaceHeight)
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
        let needsPanel = panelHeight(for: page) > 0
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
            if visual != appliedVisualState || width != appliedWidth || session.prefs != appliedPrefs
                || session.isDark != appliedDark || session.isLandscape != appliedLandscape {
                let metrics = self.metrics
                let layout = KeyLayoutBuilder.build(state: visual,
                                                    size: CGSize(width: width, height: metrics.surfaceHeight),
                                                    metrics: metrics)
                surface.configure(layout: layout, palette: palette, mascot: session.mascotImage)
                appliedVisualState = visual
                appliedWidth = width
                appliedPrefs = session.prefs
                appliedDark = session.isDark
                appliedLandscape = session.isLandscape
                feedback.prepare(enabled: session.prefs.haptics, sound: session.prefs.keySound, surface: surface)
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

        updateHeight()
        view.setNeedsLayout()
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
        feedback.keyDown(surface: surface)
    }
}

/// 按键触感和按键音。没开完全访问时系统会忽略，不会出错。
@MainActor
final class KeyFeedback {
    private let generator = UIImpactFeedbackGenerator(style: .light)
    private var hapticsEnabled = true
    private var soundEnabled = false

    func prepare(enabled: Bool, sound: Bool, surface: UIView) {
        hapticsEnabled = enabled
        soundEnabled = sound
        if enabled {
            generator.prepare()
        }
    }

    func keyDown(surface: UIView) {
        if hapticsEnabled {
            generator.impactOccurred(intensity: 0.55)
            generator.prepare()
        }
        if soundEnabled {
            UIDevice.current.playInputClick()
        }
    }

    func tapLight() {
        if hapticsEnabled {
            generator.impactOccurred(intensity: 0.4)
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
