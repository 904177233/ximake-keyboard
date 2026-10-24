#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— Swift 静态检查（QA-1）。

对 `ios/**/*.swift` 做 8 类静态检查（Python 3 标准库，零依赖，可独立运行）：

    [SWIFT-LEX]     括号/花括号/方括号平衡、字符串未闭合（P0）
    [LAYER]         Shared/IMECore、Shared/Networking 出现 import UIKit/SwiftUI（P0）
    [EXT-UIAPP]     AIKeyboardExtension 出现 UIApplication（P0）
    [CRASH]         try! / as! / fatalError（P1，带 // SAFE: 注释降级 P2）
    [SYMBOL]        未定义符号粗查（P2，标注 [粗查]，白名单见 SYSTEM_TYPES）
    [DUP]           同名同类型顶层声明重复（P2）
    [FILE]          编码/CRLF/BOM/超长文件（P1/P2）
    [I18N]          Text("...")/label:/title: 纯英文 UI 文案（P2）

用法:
    python scripts/qa/static_check.py
    python scripts/qa/static_check.py --json
    python scripts/qa/static_check.py --all
    python scripts/qa/static_check.py --md docs/06-QA报告-static.md
    python scripts/qa/static_check.py --skeleton docs/06-QA报告.md

退出码: 0=无 P0/P1；1=有 P1；2=有 P0；3=脚本内部错误。
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

from qa_common import (
    DEFAULT_IOS, Report, add_common_args, find_files, finish, lex_swift,
    main_guard, read_text_file, rel,
)

# ---------------------------------------------------------------------------
# 系统 API / 语言关键字白名单（用于未定义符号粗查，尽量压低误报）
# 维护说明：新增误报时把类型名加到这里，并尽量保持字母序分组。
# ---------------------------------------------------------------------------

SYSTEM_TYPES = frozenset("""
# ---- Swift 语言内置 ----
Self Any AnyObject Void Never Type Optional Result Error Bool String Substring Character
Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Decimal
Array Dictionary Set Range ClosedRange PartialRangeFrom PartialRangeThrough PartialRangeUpTo
Collection Sequence IteratorProtocol BidirectionalCollection RandomAccessCollection
MutableCollection RangeReplaceableCollection StringProtocol Numeric BinaryInteger
FloatingPoint Strideable OptionSet Hashable Equatable Comparable Identifiable CaseIterable
RawRepresentable Codable Encodable Decodable Sendable Actor MainActor
CustomStringConvertible CustomDebugStringConvertible LocalizedError
ExpressibleByStringLiteral ExpressibleByIntegerLiteral ExpressibleByArrayLiteral
ExpressibleByDictionaryLiteral KeyPath WritableKeyPath ReferenceWritableKeyPath PartialKeyPath
Mirror UnsafePointer UnsafeMutablePointer UnsafeRawPointer UnsafeMutableRawPointer
ManagedBuffer StaticString UnicodeScalar UTF8 UTF16

# ---- Foundation ----
URL URLRequest URLResponse HTTPURLResponse URLSession URLSessionConfiguration URLSessionTask
URLSessionTaskMetrics URLComponents URLQueryItem URLCredential URLCache
Data Date DateFormatter ISO8601DateFormatter DateComponents JSONEncoder JSONDecoder
JSONSerialization PropertyListEncoder PropertyListDecoder PropertyListSerialization
UserDefaults UUID Notification NotificationCenter NotificationCenterObservable
Bundle FileManager ProcessInfo Thread Timer TimerPublisher RunLoop
DispatchQueue DispatchGroup DispatchSemaphore DispatchTime DispatchQueueMain DispatchWorkItem
Operation OperationQueue BlockOperation
Locale Calendar TimeZone NumberFormatter Formatter DateFormatter Measurement Unit
IndexPath IndexSet IndexingIterator CharacterSet Scanner
NSObject NSError NSNumber NSString NSArray NSDictionary NSSet NSValue NSLock NSRecursiveLock
NSCondition NSRange NSAttributedString NSMutableAttributedString NSParagraphStyle
NSMutableParagraphStyle NSRegularExpression NSPredicate NSSortDescriptor
InputStream OutputStream Stream Pipe FileHandle Progress UndoManager
AttributedString AttributeContainer
AsyncStream AsyncThrowingStream AsyncSequence AsyncIteratorProtocol AsyncCompactMapSequence
AsyncImage AsyncImagePhase AsyncMapSequence AsyncFilterSequence AsyncDropFirstSequence
CheckedContinuation UnsafeContinuation Task TaskGroup ThrowingTaskGroup TaskPriority
CancellationError CancellationError2 Never
ValueTransformer NSUndoManager NSLocalizedString
CodingKey Encoder Decoder KeyedEncodingContainer KeyedDecodingContainer
UnkeyedEncodingContainer UnkeyedDecodingContainer SingleValueEncodingContainer
SingleValueDecodingContainer
CGPoint CGSize CGRect CGAffineTransform CGColor CGImage CGContext CGBitmapInfo CGDataProvider
CGImageAlphaInfo CGColorSpace CGGradient CGPath CGLineCap CGLineJoin CGBlendMode CGEvent
CFString CFData CFDictionary CFTypeRef CFIndex CFURL CFNumber
AuthorizationStatus
OperatingSystemVersion
TimeInterval DateInterval ByteCountFormatter RelativeDateTimeFormatter
ISO8601FormatStyle DateComponentsFormatter MeasurementFormatter
NSRange2 NumberFormatter2

# ---- 系统安全框架（Keychain）----
SecItemAdd SecItemCopyMatching SecItemDelete SecItemUpdate SecItemExport
SecRandomCopyBytes SecTrust SecCertificate SecKey SecPolicy OSStatus
SecAccessControl SecAccessControlCreateWithFlags

# ---- SwiftUI ----
App Scene WindowGroup Window ScenePhase View ViewBuilder ViewModifier ViewModel
Text Image Label LabelStyle Button ButtonStyle ButtonRole Toggle ToggleStyle
TextField TextEditor SecureField ScrollView ScrollViewReader ScrollViewProxy
LazyVStack LazyHStack LazyVGrid LazyHGrid Grid GridRow GridItem VStack HStack ZStack Spacer
Divider List Section Form Group GroupBox TabView TabSection
NavigationStack NavigationView NavigationLink NavigationSplitView NavigationPath
NavigationBarItem NavigationDestination ToolbarItem ToolbarItemGroup ToolbarContent
ForEach AnyLayout LayoutValueKey DynamicProperty2 ButtonStyleConfiguration
PlainButtonStyle BorderlessButtonStyle DefaultButtonStyle BorderedButtonStyle
BorderedProminentButtonStyle LinkButtonStyle PlainListStyle InsetListStyle
SidebarListStyle GroupedListStyle InsetGroupedListStyle PlainTextFieldStyle
DefaultTextFieldStyle RoundedBorderTextFieldStyle DefaultPickerStyle
SegmentedPickerStyle WheelPickerStyle MenuPickerStyle InlinePickerStyle
NavigationLinkButtonStyle Picker2
ToolbarPlacement Menu MenuStyle Picker PickerStyle Stepper Slider DatePicker ColorPicker
ProgressView ProgressViewStyle CircularProgressViewStyle LinearProgressViewStyle
ButtonMenuStyle SettingsLink BorderlessButtonMenuStyle PullDownMenuButtonStyle
LongPressGesture TapGesture DragGesture SpatialTapGesture MagnifyGesture RotateGesture
GestureState GestureMask SimultaneousGesture ExclusiveGesture SequenceGesture
AnyGesture EmptyGesture UpdatingGesture Gesture
Alert ConfirmationDialog ActionSheet ContextMenu Popover
FullScreenCover Sheet PresentationDetent PresentationMode OpenURLAction Link ShareLink
Color Font FontWeight FontDesign FontLeading FontWidth Material
LinearGradient RadialGradient AngularGradient Gradient ShapeStyle HierarchicalShapeStyle
AnyShapeStyle BackgroundStyle ForegroundStyle FillStyle StrokeStyle
RoundedRectangle Rectangle Circle Capsule Ellipse UnevenRoundedRectangle
Shape Path GeometryReader GeometryProxy GeometryEffect Anchor
EdgeInsets Edge Alignment HorizontalAlignment VerticalAlignment
Animation AnimationCurve AnimationTimingCurve Transaction Transition AnyTransition
AnyView EmptyView TupleView EquatableView
Environment EnvironmentValues EnvironmentObject ObservedObject StateObject State Binding
Published DynamicProperty PreferenceKey Layout CustomLayout
FocusState FocusedValue FocusedBinding FocusedValueKey KeyboardShortcut
SensoryFeedback TimelineView Canvas GraphicsContext SymbolEffect ContentTransition
Namespace MatchedGeometryProperties
UIViewRepresentable UIViewControllerRepresentable UIHostingController
ColorScheme ContentSizeCategory DynamicTypeSize
SafeAreaInsets SafeAreaRegions UserInterfaceSizeClass
SceneStorage AppStorage SecureStorage2
LocalizedStringKey TextFieldStyle LabelStyle2
ToggleStyle2 ProgressViewStyle2
GridItem2
Animation2
# iOS 16 之前常见的兼容名
UIApplicationDelegateAdaptor
ColorScheme2
# CoreHaptics / 触感
CHHapticEngine CHHapticPattern CHHapticEvent

# ---- UIKit ----
UIApplication UIViewController UIView UIWindow UIWindowScene UIScene UISceneDelegate
UISceneSession UISceneConfiguration UISceneConnectionOptions
UIColor UIImage UIImageView UILabel UIButton UITextField UITextView UIScrollView
UIStackView UITableView UITableViewCell UICollectionView UICollectionViewCell
UIControl UIGestureRecognizer UITapGestureRecognizer UILongPressGestureRecognizer
UIPanGestureRecognizer UISwipeGestureRecognizer UIPinchGestureRecognizer
UIInputViewController UIInputView UITextDocumentProxy UITextInput UITextPosition UITextRange
UITextInputMode UITextInputDelegate UITextSelectionDirection
UIKeyboardAppearance UIKeyboardType UIKeyboardLayoutGuide UIReturnKeyType
UIPasteboard UIPasteboardName
UIImpactFeedbackGenerator UISelectionFeedbackGenerator UINotificationFeedbackGenerator
UIFeedbackGenerator UIDevice UIScreen UINavigationController UITabBarController
UITabBar UINavigationBar UINavigationItem UIToolbar UIBarButtonItem UIResponder
UIEdgeInsets UIUserInterfaceStyle UITraitCollection UITraitEnvironment
UILayoutPriority UILayoutGuide NSLayoutConstraint NSLayoutAnchor NSLayoutDimension
UIFont UIFontDescriptor UIFontWeight
UIBezierPath UIBlurEffect UIVisualEffectView UIVisualEffect
UIAccessibility UIAccessibilityPostNotification UIAccessibilityTraits
UIAccessibilityElement UIAccessibilityCustomAction
UIContentSizeCategory UIContentSizeCategory2
UIApplicationShortcutItem UIApplicationShortcutIcon
UIOpenURLContext UIApplicationOpenURLOptionsKey
UIActivityViewController UIDocumentPickerViewController UIDocumentInteractionController
UIImagePickerController PHPickerViewController PHPickerConfiguration PHPickerResult
UISheetPresentationController UISheetPresentationControllerDetent
UIPresentationController UIPopoverPresentationController
UIDragInteraction UIDropInteraction UIDragItem NSItemProvider
UIContextMenuInteraction UIContextMenuConfiguration
UIRefreshControl UIActivityIndicatorView UIProgressView UISwitch UISlider UIPageControl
UISegmentedControl UIDatePicker UIPickerView
UIVisualEffect UIVibrancyEffect
UIViewPropertyAnimator UIViewAnimating
CATransaction CALayer CAShapeLayer CAGradientLayer CABasicAnimation CAAnimation
CAMediaTimingFunction CATransform3D
CAReplicatorLayer2
NSAttributedStringKey NSMutableAttributedStringKey
UIGraphicsImageRenderer UIGraphicsImageRendererFormat UIGraphicsBeginImageContext
UIGraphicsImageRendererContext
# ---- Photos 框架（相册写入；只在用户点「保存到相册」时用 .addOnly 权限，不读取相册）----
PHPhotoLibrary PHAssetChangeRequest PHAsset PHAssetCollection PHAuthorizationStatus
PHPhotoChangeRequest PHFetchResult PHImageManager Photos
Logger OSLog OSSignposter OSSignpostID MXMetricManager MXMetricPayload MXDiagnosticPayload MXAppLaunchMetric MXAppRunTimeMetric MXAppResponsivenessMetric MXCPUExceptionDiagnostic MXDiskWriteExceptionDiagnostic MXHangDiagnostic MXCrashDiagnostic MXCallStackTree MXMetaData MXAverage MXHistogram MXHistogramBucket CGColorSpaceCreateDeviceRGB CGColorSpaceRelease CGContextDrawImage CGImageCreate
# ---- PhotosUI（主题形象导入：PhotosPicker 是 out-of-process，不申请相册读取权限）----
PhotosUI PhotosPicker PhotosPickerItem PHPickerFilter PHPickerConfiguration
PHPickerViewController PHPickerResult NSItemProvider
# ---- Speech / AVFoundation（键盘内语音输入：iOS 26 起扩展可录音，见 docs/13）----
Speech AVFoundation SFSpeechRecognizer SFSpeechAudioBufferRecognitionRequest
SFSpeechRecognitionTask SFSpeechRecognitionResult SFSpeechRecognitionRequest
SFSpeechRecognitionTaskDelegate SFSpeechRecognizerAuthorizationStatus
AVAudioSession AVAudioEngine AVAudioApplication AVAudioPCMBuffer AVAudioFormat
AVAudioNode AVAudioNodeTapBlock AVAudioSessionRecordPermission AVAudioSessionCategory
AVAudioSessionCategoryOptions AVAudioSessionMode AVAudioTime AVAudioChannelCount
SpeechAnalyzer DictationTranscriber SpeechTranscriber SpeechDetector AnalyzerInput
AssetInventory Locale2
UIApplication2
UIScreen2
QRCoder2
""".split())

# 上述集合里带后缀 2 的是为了排版占位，实际不存在，剔除避免污染
SYSTEM_TYPES = frozenset(t for t in SYSTEM_TYPES if not t.endswith("2"))

# 这些是「看起来像类型」但其实是 Swift 关键字/语法糖，出现在 `X(`/`X.` 前不算未定义
SYNTAX_WORDS = frozenset({
    "Self", "Any", "AnyObject", "Void", "Never", "Type", "Protocol",
})

# 常量/函数式白名单（大写开头但其实是函数或常量）
SYSTEM_FUNCS = frozenset({
    "NSLocalizedString", "NSSelectorFromString", "NSStringFromClass",
    "SecItemAdd", "SecItemCopyMatching", "SecItemDelete", "SecItemUpdate",
    "SecRandomCopyBytes", "UIAccessibilityPostNotification",
    "CFRelease", "CFRetain", "CFEqual", "CGColorCreate", "CGRectMake",
})

# 中文 UI 文案检查里允许保留的英文词（品牌 / 模型 / 技术缩写 / 单位）
EN_TEXT_WHITELIST = frozenset(w.lower() for w in """
AI GPT API URL HTTP HTTPS iOS iPadOS iPhone iPad Mac macOS OK ID JSON PDF Wi-Fi WIFI
KB MB GB TB ms pt px SDK UI UX App Store Apple Siri iCloud Xcode TestFlight
DeepSeek OpenAI Anthropic Gemini Claude Kimi Moonshot GLM Qwen 通义 Doubao 豆包
SiliconFlow OpenRouter DALL DALL·E Dalle gpt-image OpenAI-Compat LLM OCR CPU RAM
PNG JPG JPEG HEIC GIF WebP 2FA iOS16 iOS17 5G 4G LTE
Pro Max Plus Mini SE Air
Base Key Token Tokens Endpoint Header Headers Body Stream Text
temperature top_p max_tokens prompt system user assistant
ABC QWERTY QWERTZ AZERTY 9宫格 26键
""".split())

# ---------------------------------------------------------------------------
# 正则
# ---------------------------------------------------------------------------

RE_IMPORT_UI = re.compile(r"^[ \t]*(?:@testable[ \t]+)?import[ \t]+(UIKit|SwiftUI)\b", re.M)
RE_UIAPPLICATION = re.compile(r"\bUIApplication\b")
RE_TRY_FORCE = re.compile(r"\btry!")
RE_AS_FORCE = re.compile(r"\bas!")
RE_FATAL = re.compile(r"\bfatalError\s*\(")
RE_TODO = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b")
RE_DECL_TYPE = re.compile(
    r"^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*"
    r"(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+|open[ \t]+|final[ \t]+|indirect[ \t]+)*"
    r"(struct|class|enum|protocol|actor)[ \t]+([A-Za-z_]\w*)", re.M)
RE_DECL_ANY_TYPE = re.compile(r"\b(?:struct|class|enum|protocol|actor)[ \t]+([A-Za-z_]\w*)")
RE_DECL_EXTENSION = re.compile(r"\bextension[ \t]+([A-Z][\w.]*)")
RE_DECL_FUNC = re.compile(r"\bfunc[ \t]+([A-Za-z_]\w*)")
RE_DECL_LETVAR = re.compile(r"^[ \t]*(?:public[ \t]+|internal[ \t]+|private[ \t]+|fileprivate[ \t]+|static[ \t]+)*(?:let|var)[ \t]+([A-Za-z_]\w*)", re.M)
RE_DECL_PROTO_SYM = re.compile(r"\bprotocol[ \t]+([A-Za-z_]\w*)")
RE_TYPE_USE = re.compile(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)")
RE_TEXT_CALL = re.compile(r"\bText\s*\(\s*\"((?:[^\"\\\n]|\\.)*)\"")
RE_LABEL_TEXT = re.compile(r"\b(?:label|title)\s*:\s*\"((?:[^\"\\\n]|\\.)*)\"")
CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
WORD_RE = re.compile(r"[A-Za-z]{2,}")

OPENERS = "([{"
CLOSERS = {")": "(", "]": "[", "}": "{"}


# ---------------------------------------------------------------------------
# 各检查器
# ---------------------------------------------------------------------------

def check_balanced(report: Report, relpath: str, src: str, lex):
    """括号平衡 + 字符串未闭合。"""
    stack: list[tuple[str, int]] = []
    mismatches = 0
    for idx, ch in enumerate(src):
        if not lex.code[idx]:
            continue
        if ch in OPENERS:
            stack.append((ch, idx))
        elif ch in CLOSERS:
            if not stack:
                report.add("P0", "SWIFT-LEX-EXTRA-CLOSER", relpath, lex.line_of(idx),
                           f"多余的右括号 `{ch}`（前面没有匹配的左括号）",
                           "删除多余字符；文件被截断时请检查合并冲突残留")
                mismatches += 1
                if mismatches >= 5:
                    return
                continue
            opener, opos = stack.pop()
            if opener != CLOSERS[ch]:
                report.add("P0", "SWIFT-LEX-MISMATCH", relpath, lex.line_of(idx),
                           f"括号不匹配：第 {lex.line_of(opos)} 行 `{opener}` 与第 {lex.line_of(idx)} 行 `{ch}`",
                           "检查该函数/结构体的结尾，常见于多写了一层 `}` 或少写 `)`")
                mismatches += 1
                if mismatches >= 5:
                    return
    if stack:
        unclosed = stack[:3]
        for opener, opos in unclosed:
            report.add("P0", "SWIFT-LEX-UNCLOSED", relpath, lex.line_of(opos),
                       f"`{opener}` 未闭合（文件结束时仍缺 {len(stack)} 个配对符号）",
                       "补上对应的 `)`/`]`/`}`；优先检查文件末尾")
    # 字符串未闭合
    for span in lex.strings:
        if span.multiline:
            if not src.startswith('"""', span.end):
                report.add("P0", "SWIFT-LEX-UNCLOSED-STRING", relpath, lex.line_of(span.start),
                           "多行字符串 \"\"\" 未闭合", "检查是否缺少结尾的三引号")
        else:
            if span.end >= len(src) or src[span.end] != '"':
                report.add("P0", "SWIFT-LEX-UNCLOSED-STRING", relpath, lex.line_of(span.start),
                           "字符串引号未闭合（行内未找到结束引号）",
                           "检查字符串里的引号转义；Swift 单行字符串不能直接换行")


def check_layer_imports(report: Report, relpath: str, src: str, lex):
    """Shared/IMECore 与 Shared/Networking 不得 import UIKit/SwiftUI。"""
    posix = relpath.replace("\\", "/")
    if not (posix.startswith("ios/Shared/IMECore/") or posix.startswith("ios/Shared/Networking/")):
        return
    for m in RE_IMPORT_UI.finditer(lex.masked):
        report.add("P0", "LAYER-UI-IMPORT", relpath, lex.line_of(m.start()),
                   f"分层违规：`import {m.group(1)}` 出现在非 UI 层（{posix.split('/')[2] if posix.count('/') > 2 else 'Shared'}）",
                   "引擎/网络层只允许 Foundation；UI 能力请通过闭包或协议由上层注入")


def check_extension_uiapplication(report: Report, relpath: str, src: str, lex):
    """键盘扩展内禁止 UIApplication。"""
    posix = relpath.replace("\\", "/")
    if not posix.startswith("ios/AIKeyboardExtension/"):
        return
    hits = list(RE_UIAPPLICATION.finditer(lex.masked))
    for m in hits[:10]:
        report.add("P0", "EXT-UIAPPLICATION", relpath, lex.line_of(m.start()),
                   "键盘扩展内出现 `UIApplication`（扩展中不可用，且审核/上架有风险）",
                   "改用 UIInputViewController 能力（如 advanceToNextInputMode / openSettings 由宿主 App 完成）")
    if len(hits) > 10:
        report.add("P0", "EXT-UIAPPLICATION", relpath, 0,
                   f"另有 {len(hits) - 10} 处 UIApplication 未逐条列出", "同上")


def _safe_marked(lex, offset: int, src_lines: list[str]) -> bool:
    """该行或上一行有 `// SAFE:` 说明则视为可接受。"""
    ln = lex.line_of(offset)
    for cand in (ln, ln - 1):
        if 1 <= cand <= len(src_lines):
            if "SAFE:" in src_lines[cand - 1]:
                return True
    return False


def check_crash_primitives(report: Report, relpath: str, src: str, lex):
    """try! / as! / fatalError → P1（SAFE 注释 → P2）。"""
    lines = src.splitlines()
    rules = [
        (RE_TRY_FORCE, "CRASH-TRY-FORCE", "强制 try!（出错即崩）", "改 `try?` + guard，或 `do/catch` 给出中文提示"),
        (RE_AS_FORCE, "CRASH-AS-FORCE", "强制 as!（类型不符即崩）", "改 `as?` + guard let"),
        (RE_FATAL, "CRASH-FATAL-ERROR", "fatalError（发布路径崩溃）", "改 assertionFailure + 默认值降级"),
    ]
    for regex, code, msg, hint in rules:
        for m in regex.finditer(lex.masked):
            safe = _safe_marked(lex, m.start(), lines)
            sev = "P2" if safe else "P1"
            tail = "（已标注 // SAFE:，降级 P2）" if safe else ""
            report.add(sev, code, relpath, lex.line_of(m.start()), msg + tail, hint)


def collect_declarations(report_data: dict, relpath: str, src: str, lex):
    """收集本文件的声明，用于全局符号表与重复声明检测。

    重复声明只统计「顶层」声明（花括号深度 0）：`CodingKeys` 这类每个类型内部
    各自嵌套的 enum 是 Swift 合法写法，不能算重复。
    """
    # 预计算每个偏移的花括号深度（只用代码字符）
    depth = [0] * (len(src) + 1)
    d = 0
    for idx, ch in enumerate(src):
        depth[idx] = d
        if lex.code[idx]:
            if ch == "{":
                d += 1
            elif ch == "}":
                d = max(0, d - 1)
    depth[len(src)] = d

    types_here: list[tuple[str, str, int]] = []
    for m in RE_DECL_TYPE.finditer(lex.masked):
        kind, name = m.group(1), m.group(2)
        # 跳过多行声明前缀造成的偏移误差：用声明关键字的位置判定深度
        kw_pos = lex.masked.rfind(kind, m.start(), m.end())
        if kw_pos < 0:
            kw_pos = m.start()
        if depth[kw_pos] != 0:
            report_data["declared_types"].add(name)   # 嵌套类型仍登记进符号表
            continue
        types_here.append((kind, name, lex.line_of(m.start())))
    for name in set(RE_DECL_ANY_TYPE.findall(lex.masked)):
        report_data["declared_types"].add(name)
    for name in RE_DECL_EXTENSION.findall(lex.masked):
        report_data["declared_types"].add(name.split(".")[0])
    for name in RE_DECL_FUNC.findall(lex.masked):
        report_data["declared_funcs"].add(name)
    for name in RE_DECL_LETVAR.findall(lex.masked):
        report_data["declared_values"].add(name)
    for kind, name, line in types_here:
        key = (kind, name)
        report_data["type_decls"][key].append((relpath, line))
        report_data["all_type_names"].add(name)
    # 重复声明：同名同类型、且是第一处以外
    for kind, name, line in types_here:
        prev = [x for x in report_data["type_decls"][(kind, name)] if x != (relpath, line)]
        if prev:
            p_file, p_line = prev[0]
            report_data.setdefault("dup_hits", []).append((relpath, line, kind, name, p_file, p_line))


def _is_likely_project_ui_type(name: str) -> bool:
    """判断一个未定义符号是否「几乎不可能是系统 API」。

    背景：`SYMBOL-UNDEFINED` 默认是 P2（`[粗查]`），因为白名单永远不够全，
    把系统 API 误报成未定义是很常见的噪声。但有一类符号**系统 SDK 里根本不可能有**：
    本项目自己的 View / 组件命名（`KeyRowsView`、`NumberPadView`、`AIPanelView`、
    `AIResultCardView`、`ExtensionSettingsSheet`、`PhraseBarView` …）。

    这类符号如果「被使用但全项目无定义」，那就是**硬编译错误**
    （`cannot find 'XxxView' in scope`），必须按 P0 处理，不能被「P2 不阻塞」放过。

    判定规则（任一命中即认为大概率本项目自造类型）：
      1. 后缀是 UI 组件常见词：View / Bar / Card / Sheet / Panel / Rows / Row /
         Button / Style / Picker / Cell / Item（且总长 > 后缀长，避免 `View` 本身）；
      2. 前缀是本项目命名空间：KM / AI / Key / Candidate / Emoji / Phrase /
         Settings / Extension / Keyboard / Prompt / Provider / Playground；
      3. 名字里含中文（本项目中文注释里出现的类型不会是系统 API）。

    误报兜底：即使命中，只要写进 `SYSTEM_TYPES` 白名单就不会走到这里；
    实在需要豁免可在该行加 `// SAFE:` 注释（`check_symbols` 已支持）。
    """
    if not name or not name[0].isupper():
        return False
    if re.search(r"[\u4e00-\u9fff]", name):
        return True

    ui_suffixes = (
        "View", "Bar", "Card", "Sheet", "Panel", "Rows", "Row",
        "Button", "Style", "Picker", "Cell", "Tile", "Chip", "Badge",
    )
    for suf in ui_suffixes:
        if name.endswith(suf) and len(name) > len(suf):
            return True

    project_prefixes = (
        "KM", "AI", "Key", "Candidate", "Emoji", "Phrase", "Settings",
        "Extension", "Keyboard", "Prompt", "Provider", "Playground",
        "Moyu", "Theme", "Tone", "Stream", "Caret", "Haptic",
    )
    for pre in project_prefixes:
        if name.startswith(pre) and len(name) > len(pre) + 1:
            return True

    return False


def check_symbols(report: Report, relpath: str, src: str, lex, data: dict):
    """未定义符号粗查：`TypeName(` / `TypeName.` 未在本项目声明且不在白名单。

    严重度规则（Lead 定的冻结判定标准）：
      - 命中 `_is_likely_project_ui_type()`（明显是本项目自造的 UI 类型）
        → **P0**，因为它不可能是系统 API，缺定义 = 硬编译错误；
      - 其它 → P2 `[粗查]`（白名单不可能覆盖全部 SDK，宁漏不误报）。
    """
    known = data["declared_types"] | SYSTEM_TYPES | SYNTAX_WORDS
    local_funcs = data["declared_funcs"] | SYSTEM_FUNCS
    # 本文件内的泛型参数（`struct Foo<Item: Identifiable>` 里的 Item）不是未定义符号
    generics = set(re.findall(r"<([A-Z][A-Za-z0-9_]*)\s*:", lex.masked))
    known = known | generics
    seen: dict[str, int] = {}
    for m in RE_TYPE_USE.finditer(lex.masked):
        name = m.group(1)
        end = m.end()
        # 只关心紧跟 `(` 或 `.` 的类型用法
        rest = lex.masked[end:end + 3]
        if not (rest.startswith("(") or rest.startswith(".")):
            continue
        nxt = lex.masked[end:end + 1]
        # 跳过 `Name (` 但其实是函数调用的极少见情况；`Name.` 且 name 是函数名则跳过
        if name in known or name in local_funcs:
            continue
        # `Foo.init(` 之类：name 是类型；这里 name 一定大写开头
        if name not in seen:
            seen[name] = m.start()
    # 也检查 `TypeName.init(` 里的 TypeName 已被上面覆盖
    for name, off in list(seen.items())[:30]:
        line_no = lex.line_of(off)
        line_text = lex.line_text(off)
        # 同行有 `// SAFE:` 视为人工确认过（与 try!/as! 的豁免约定保持一致）
        if "// SAFE:" in (line_text or ""):
            report.add("P2", "SYMBOL-UNDEFINED", relpath, line_no,
                       f"[粗查] 使用了疑似未定义的符号 `{name}`（同行有 `// SAFE:` 豁免）",
                       "人工确认：若为系统 API 请加入 static_check.py 的 SYSTEM_TYPES；若为笔误请修正")
            continue
        if _is_likely_project_ui_type(name):
            report.add(
                "P0", "SYMBOL-UNDEFINED",
                relpath, line_no,
                f"使用了**未定义的本项目类型** `{name}`"
                f"（本项目所有 .swift 里都找不到定义，且它不可能是系统 API）",
                f"高置信度硬编译错误（cannot find '{name}' in scope）。"
                f"请补齐该类型的定义，或修正拼写；若确认是系统 API，"
                f"请把 `{name}` 加入 static_check.py 的 SYSTEM_TYPES 白名单",
            )
        else:
            report.add("P2", "SYMBOL-UNDEFINED", relpath, line_no,
                       f"[粗查] 使用了疑似未定义的符号 `{name}`（本项目声明与系统白名单中均未找到）",
                       "人工确认：若为系统 API 请加入 static_check.py 的 SYSTEM_TYPES；若为笔误请修正")
    if len(seen) > 30:
        report.add("P2", "SYMBOL-UNDEFINED", relpath, 0,
                   f"[粗查] 另有 {len(seen) - 30} 个疑似未定义符号未逐条列出", "加 --all 或人工排查")
    data["symbol_hits"] += len(seen)


def check_file_properties(report: Report, tf, relpath: str, line_count: int):
    """编码 / BOM / CRLF / 超长文件。"""
    if tf.read_error:
        report.add("P1", "FILE-ENCODING", relpath, 0,
                   f"文件编码可疑：{tf.read_error}（实际按 {tf.encoding} 读取）", "转换为 UTF-8 无 BOM")
    elif tf.encoding not in ("utf-8", "utf-8-sig"):
        report.add("P1", "FILE-ENCODING", relpath, 0,
                   f"非 UTF-8 编码：{tf.encoding}", "用编辑器另存为 UTF-8（无 BOM）")
    if tf.has_bom:
        report.add("P2", "FILE-BOM", relpath, 1, "文件带 UTF-8 BOM", "去掉 BOM（Xcode 对 BOM 兼容性差）")
    if tf.crlf_lines > 0:
        report.add("P2", "FILE-CRLF", relpath, 1,
                   f"使用 CRLF 换行（{tf.crlf_lines} 行）", "统一为 LF（Xcode/CI diff 更干净）")
    if line_count > 600:
        report.add("P2", "FILE-TOO-LONG", relpath, 1,
                   f"文件 {line_count} 行，超过 600 行上限", "按职责拆分（docs/02 §3.7）")


def _is_model_ref_context(lex, pos: int) -> bool:
    """判断命中位置是否在 `ModelRef(title: "...")` / `Preset(name: "...")` 等
    技术标识符上下文里 —— 这类字符串是模型 ID / 品牌名，不是 UI 文案。

    也覆盖 `DispatchQueue(label:)` / `Logger(subsystem:category:)` 这类
    「反域名标识符」：`com.moyu.app.metrickit` 是日志/队列标识，不是给用户看的文案。
    """
    window = lex.masked[max(0, pos - 80):pos]
    if RE_MODEL_CONTEXT.search(window):
        return True
    if RE_TECH_IDENTIFIER.search(window):
        return True
    return False


RE_TECH_IDENTIFIER = re.compile(
    r"(?:DispatchQueue|Logger|os_log)\s*\("
)


RE_MODEL_CONTEXT = re.compile(r"(?:ModelRef|modelID|model|baseURL|consoleURL|systemImage)\s*\([^()]*$"
                              r"|(?:modelID|systemImage)\s*:\s*$")


def check_english_ui_text(report: Report, relpath: str, src: str, lex):
    """Text(\"...\") / label: / title: 里出现纯英文（白名单除外）→ P2。

    注意排除两类"看起来像英文文案、实际不是"的情况，避免刷假警报：
      1. 纯插值文案：`Text("\\(index)")`、`Text("\\(badge)")` —— 渲染时是数字/变量，
         源码里出现的 `index`/`badge` 只是 Swift 变量名，不是给用户看的英文词。
      2. 插值表达式内部的函数名：`Text("\\(Int(x * 100))%")` 里的 `Int`/`min`。
    判定方式：把 `\\( ... )` 整体抹掉后再看还剩哪些英文词。
    """
    for regex in (RE_TEXT_CALL, RE_LABEL_TEXT):
        for m in regex.finditer(src):
            if m.start() >= len(lex.code) or not lex.code[m.start()]:
                continue  # 命中的是注释内容
            content = m.group(1).strip()
            if not content or CJK_RE.search(content):
                continue
            if _is_model_ref_context(lex, m.start()):
                continue  # 模型 ID / 品牌名 / URL，本就是英文
            if "{{" in content:
                continue  # Prompt 模板占位符（如 {{text}} {{tone}}），是给模板引擎用的，不是 UI 文案
            # 抹掉 Swift 字符串插值 `\( ... )`（可任意层嵌套），剩下的才是字面文案
            literal = strip_interpolations(content)
            words = [w for w in WORD_RE.findall(literal) if w.lower() not in EN_TEXT_WHITELIST]
            if not words:
                continue
            report.add("P2", "I18N-EN-TEXT", relpath, lex.line_of(m.start()),
                       f"疑似英文 UI 文案：\"{content[:40]}\"（英文词：{', '.join(words[:5])}）",
                       "用户可见文案应为中文；模型名/URL/品牌名可保留并加入白名单")


def strip_interpolations(s: str) -> str:
    """把 Swift 字符串里的 `\\( ... )` 插值整段删掉（支持任意层嵌套括号）。

    `"共 \\(Int((max(min(fraction, 0.9), 0)) * 100))%"` → `"共 %"`，
    这样 `Int`/`min`/`fraction` 就不会被当成英文 UI 文案。
    """
    out: list[str] = []
    i = 0
    n = len(s)
    while i < n:
        if s[i] == "\\" and i + 1 < n and s[i + 1] == "(":
            depth = 0
            j = i + 1
            while j < n:
                if s[j] == "(":
                    depth += 1
                elif s[j] == ")":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            i = j
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run(root: Path) -> Report:
    ios_root = root / "ios"
    report = Report("墨语 iOS 输入法 · Swift 静态检查（static_check.py）", root)
    files = find_files(ios_root, (".swift",))
    if not files:
        report.warn(f"未发现任何 .swift 文件（目录：{rel(ios_root, root)}）。"
                    "工程骨架尚未落盘时这是正常的，退出码按 0 处理。")
        report.stats.update({"files": 0, "lines": 0})
        return report

    data = {
        "declared_types": set(), "declared_funcs": set(), "declared_values": set(),
        "type_decls": defaultdict(list), "all_type_names": set(),
        "dup_hits": [], "symbol_hits": 0,
    }
    parsed = []  # (relpath, TextFile, lex, line_count)
    total_lines = 0
    todo_total = 0
    area_files = defaultdict(int)
    area_lines = defaultdict(int)

    for path in files:
        relpath = rel(path, root)
        tf = read_text_file(path)
        src = tf.text
        lex = lex_swift(src)
        line_count = src.count("\n") + (0 if src.endswith("\n") else 1)
        total_lines += line_count
        parsed.append((relpath, tf, lex, line_count))

        if relpath.startswith("ios/Shared/"):
            area_files["Shared"] += 1
            area_lines["Shared"] += line_count
        elif relpath.startswith("ios/AIKeyboardExtension/"):
            area_files["Extension"] += 1
            area_lines["Extension"] += line_count
        elif relpath.startswith("ios/AIKeyboard/"):
            area_files["App"] += 1
            area_lines["App"] += line_count
        else:
            area_files["Other"] += 1
            area_lines["Other"] += line_count

        check_file_properties(report, tf, relpath, line_count)
        check_balanced(report, relpath, src, lex)
        check_layer_imports(report, relpath, src, lex)
        check_extension_uiapplication(report, relpath, src, lex)
        check_crash_primitives(report, relpath, src, lex)
        check_english_ui_text(report, relpath, src, lex)
        collect_declarations(data, relpath, src, lex)
        todo_total += len(RE_TODO.findall(lex.masked))

    # 依赖全局符号表的两类检查
    for relpath, tf, lex, line_count in parsed:
        check_symbols(report, relpath, tf.text, lex, data)

    for relpath, line, kind, name, p_file, p_line in data["dup_hits"]:
        # 顶层同名同类型 = Swift 硬编译错误（invalid redeclaration）。
        # 注意：即便其中一个是 private / fileprivate 也一样报错 —— 访问控制不参与
        # 重声明判定，所以这里必须给 P0，否则「编译不过」而 QA 只报了个 P2。
        report.add("P0", "DUP-DECL", relpath, line,
                   f"重复声明：{kind} `{name}` 与 {p_file}:{p_line} 同名同类型（Swift 会报 invalid redeclaration）",
                   "同名同类型顶层声明必定编译失败；合并、改名，或把其中一处嵌到别的类型内部（嵌套声明不算重复）")

    report.stats.update({
        "files": len(files),
        "lines": total_lines,
        "Shared": area_files["Shared"],
        "App": area_files["App"],
        "Extension": area_files["Extension"],
        "todo": todo_total,
        "symbols_checked": data["symbol_hits"],
    })
    if todo_total:
        report.warn(f"代码中仍有 {todo_total} 处 TODO/FIXME/XXX/HACK 标记（详见各文件注释）")
    return report


def write_skeleton(path: Path, report: Report, root: Path):
    """生成 docs/06-QA报告.md 骨架（静态检查部分自动填充，其余待人工/其他脚本补充）。"""
    static_md = report.to_markdown(heading_level=3)
    skeleton = f"""# 06 · QA 报告（墨语 v1.0）

> 本文件由 QA 脚本 `scripts/qa/` 生成骨架 + qa-docs 人工分析补全。
> 生成时间：{report.started_at.strftime('%Y-%m-%d %H:%M:%S')}
> 检查对象：`ios/**/*.swift`（静态检查）、`ios/AIKeyboard.xcodeproj/project.pbxproj`（工程校验）、
> `design/tokens.json` × `ios/Shared/Theme/Theme.swift`（契约一致性）。

## 1. 执行摘要

| 指标 | 数值 | 说明 |
|---|---|---|
| Swift 文件数 | {report.stats.get('files', '—')} | 扫描 `ios/**/*.swift` |
| 代码总行数 | {report.stats.get('lines', '—')} | 含空行与注释 |
| P0 阻断 | **{report.count('P0')}** | 必须修复，否则无法编译/审核风险 |
| P1 严重 | **{report.count('P1')}** | 发布前修复 |
| P2 建议 | {report.count('P2')} | 可延后，含 `[粗查]` 误报待确认 |
| TODO/FIXME | {report.stats.get('todo', 0)} | 未完成标记 |

> 结论：**{report.verdict()}**

## 2. P0 明细（阻断项，必须修复）

| # | 位置 | 问题 | 建议修复方 |
|---|---|---|---|
| — | — | 待 `static_check.py` / `project_check.py` 运行结果与人工复核后填写 | — |

<!-- QA:AUTO:STATIC:START -->
{static_md}
<!-- QA:AUTO:STATIC:END -->

## 3. 工程结构校验（project_check.py）

> 运行 `python scripts/qa/project_check.py` 后把输出粘贴到本节。

## 4. 设计契约一致性（consistency_check.py）

> 运行 `python scripts/qa/consistency_check.py` 后把输出粘贴到本节。

## 5. 给 Lead 的集成检查清单（发布前必须做的 10 件事）

1. 所有 P0 清零（编译前检查）。
2. `project_check.py` 通过：双 target、Shared 同进两 target、App/Extension 源文件归属正确。
3. `consistency_check.py` 通过：tokens 顶层键齐全、Theme.swift 逐键实现。
4. 无完全访问权限、无网络、未配 Key、服务端报错四种降级路径均有人工验证记录。
5. 中文文案抽查（键盘、设置、错误提示页）。
6. Info.plist 扩展配置：`com.apple.keyboard-service`、RequestsOpenAccess、IsASCIICapable。
7. IPA 打包保留 `PlugIns/AIKeyboardExtension.appex`（Sideloadly 重签必须）。
8. GitHub Actions workflow 跑通并产出 unsigned IPA artifact。
9. 安装指南 docs/04 按实际 workflow 内容核对一次。
10. 真机 7 天续签流程演练一次并记录耗时。
"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(skeleton, encoding="utf-8")


@main_guard
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="墨语 iOS 输入法 · Swift 静态检查")
    add_common_args(ap)
    ap.add_argument("--skeleton", metavar="PATH", default=None,
                    help="生成 docs/06-QA报告.md 骨架")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    report = run(root)

    if args.skeleton:
        p = Path(args.skeleton)
        if not p.is_absolute():
            p = Path.cwd() / p
        write_skeleton(p, report, root)
        print(f"[骨架已生成] {p}")

    return finish(report, args)


if __name__ == "__main__":
    sys.exit(main())
