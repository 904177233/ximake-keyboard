#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨 target 未定义类型粗查（Lead 专用，不参与 QA 四件套）。

背景：本项目在 Windows 上无法运行 swiftc / Xcode，而「引用了不存在的类型」是
并行开发里最容易漏掉的编译级错误（例如 KeyboardViewController 引用还未落盘的
KeyboardRootView）。本脚本按 target 的实际文件归属，收集所有「大写开头的标识符」，
减去本 target 内有定义的符号、再减去系统框架白名单，输出剩余可疑项。

用法：
    python scripts/lead/target_symbols.py            # 摘要
    python scripts/lead/target_symbols.py --verbose  # 逐条列出
    python scripts/lead/target_symbols.py --json

退出码：0=无可疑；1=有可疑（仅供人工判断，不阻断）。
"""

from __future__ import annotations

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"

# ---------------------------------------------------------------- 词法预处理

def strip_source(text: str) -> tuple[str, list[int]]:
    """注释/字符串替换为空格（保留换行），返回 (新文本, 每行起始偏移)。"""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            depth = 1
            out.append("  ")
            i += 2
            while i < n and depth > 0:
                if text[i] == "/" and i + 1 < n and text[i + 1] == "*":
                    depth += 1
                    out.append("  ")
                    i += 2
                elif text[i] == "*" and i + 1 < n and text[i + 1] == "/":
                    depth -= 1
                    out.append("  ")
                    i += 2
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            continue
        if ch == '"':
            # 三引号
            if text.startswith('"""', i):
                out.append("   ")
                i += 3
                while i < n and not text.startswith('"""', i):
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
                if i < n:
                    out.append("   ")
                    i += 3
                continue
            out.append(" ")
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out), []


DECL_RE = re.compile(
    r"(?:\b|^)(?:public\s+|internal\s+|private\s+|fileprivate\s+|open\s+|package\s+)?"
    r"(?:final\s+|nonisolated\s+|@\w+\s+)*"
    r"(?:struct|class|enum|protocol|actor|typealias|extension)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)
# `case Word` / `case .foo` 里的枚举 case 也可能是大写开头，单独收集以免误报
CASE_RE = re.compile(r"^\s*case\s+([A-Z][A-Za-z0-9_]*)", re.MULTILINE)
IDENT_RE = re.compile(r"(?<![A-Za-z0-9_.$])([A-Z][A-Za-z0-9_]{1,})\b")

# 系统/框架符号白名单（本工程实际 import 的 Foundation / UIKit / SwiftUI / Combine 等）
SYSTEM = set(
    """
    A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
    Any AnyObject AnyView Array ArraySlice AsyncStream AsyncThrowingStream AsyncSequence
    AttributedString Autoreleasepool
    B C Bool Bundle Button Binding
    CGFloat CGColor CGAffineTransform CGImage CGPoint CGRect CGSize CGContext CGVector
    Calendar CaretRectangle CaseIterable Character ChatRequest ChatDelta ChatResult ClosedRange
    Codable Collection Color Data Date DateFormatter DateComponents DateInterval Decodable
    DefaultStringInterpolation Dictionary DispatchQueue DocumentStorage Double DropFirst
    EdgeInsets EdgeInsets Encodable Environment EnvironmentValues Equatable Error
    FileManager Float Font ForEach Formatter Foundation
    GeometryProxy GeometryReader GestureState Gesture
    HStack Hashable Haptic
    Identifiable Image ImageRenderer IndexPath IndexSet Int Int16 Int32 Int64
    JSONDecoder JSONEncoder Just
    KeyPath KeyboardShortcut Circle
    LazyVStack LazyHStack LazyVGrid LazyHGrid LinearGradient List LocalizedStringKey
    MainActor Margin
    NSError NSObject NSPredicate NSTextAlignment NSUUID Notification NotificationCenter
    CGFloat OffsetKeyframe
    ObservableObject Optional OutputStream
    Padding Patha Path Picker PlainButtonStyle ProgressView Published
    RoundedRectangle Range RangeReplaceableCollection Result Rectangle RegularRectangle
    RoundedRect RunLoop
    SAFE ScrollView ScrollViewProxy Sendable Set Shadow Shape Size Spacer State StateObject
    String StringProtocol StrokeStyle Substring Subject Subscribers ShapeStyle
    Task Text TextField TextEditor TapGesture TimeInterval Timer Toggle ToggleStyle
    TransparentType TupleView Transaction TypeAlias
    UIAccessibility UIActivityIndicatorView UIApplication UIColor UIControl UIDevice
    UIFeedbackGenerator UIFont UIGestureRecognizer UIImage UIImageView UIKit UIInputViewController
    UILabel UILayoutPriority UINavigationController UIPasteboard UIPress UIResponder
    UIScreen UIScrollView UISelectionFeedbackGenerator UISlider UIStackView
    UIStoryboard UISwitch UITableView UITextField UITextView UITraitCollection UIView
    UIViewAnimating UIViewPropertyAnimator UIViewController UIWindow
    UIImpactFeedbackGenerator UIScreenEdgePanGestureRecognizer UIHostingController
    URL URLComponents URLRequest URLResponse URLSession URLSessionConfiguration
    Uuid UUID Unmanaged UnsafePointer UserDefaults
    VerticalAlignment View ViewBuilder VisualEffect VStack VerticalEdge
    WeakWrapper
    XAxis YAxis ZStack
    NSParagraphStyle NSAttributedString NSTextAttachment NSMutableAttributedString
    NSAttributedStringKey NSRange
    CGAffineTransform Scale
    CollectionDifference KeyValuePairs
    CGImageAlphaInfo CGColorSpace
    ButtonStyle DragGesture MagnificationGesture LongPressGesture
    AnyTransition Animation AnimationTimelineSchedule
    App AppDelegate Scene WindowGroup MainStruct
    NSUserActivity UNUserNotificationCenter
    AsyncImage Phase
    PreviewProvider
    MainBundle
    Group Label Capsule Divider Section Menu ShareLink ControlGroup Grid GridRow
    Alert EmptyView FocusState EnvironmentObject ObservedObject CodingKey Decoder Encoder
    Content Configuration CircularProgressViewStyle PlainTextFieldStyle SegmentedPickerStyle
    ViewModifier ContentMode ColorScheme Never Void Self
    CancellationError CharacterSet Locale TimeZone JSONSerialization
    NSLock NSRegularExpression NSSelectorFromString NSString NSLayoutConstraint
    NSUInteger ObjCBool OSStatus CFDictionary CFTypeRef CoreGraphics Security
    NSURLErrorDomain NSURLErrorCannotConnectToHost NSURLErrorCannotFindHost
    NSURLErrorDNSLookupFailed NSURLErrorNetworkConnectionLost NSURLErrorSecureConnectionFailed
    SecItemAdd SecItemCopyMatching SecItemDelete SecItemUpdate
    UIGraphicsImageRenderer UIGraphicsImageRendererFormat UIKeyInput UITextInput UIKeyboardAppearance
    UINotificationFeedbackGenerator UITextDocumentProxy UInt8 UInt32 UInt64
    AnyCancellable Combine SwiftUI NavigationLink NavigationStack ScrollViewReader
    TabView TimelineView ToolbarItem Slider Stepper SecureField
    GridItem HTTPURLResponse LocalizedError Namespace
    CheckedContinuation CheckedThrowingContinuation
    PHPhotoLibrary PHAssetChangeRequest PHAsset PHAssetCollection PHAuthorizationStatus
    PHPhotoChangeRequest PHFetchResult PHImageManager Photos
    PhotosUI PhotosPicker PhotosPickerItem PHPickerFilter PHPickerConfiguration
    PHPickerViewController PHPickerResult NSItemProvider
    MetricKit MXMetricManager MXMetricManagerSubscriber MXMetricPayload MXDiagnosticPayload
    MXMetric MXDiagnostic MXCallStackTree MXMetaData MXAppLaunchMetric MXAppRunTimeMetric
    MXAppResponsivenessMetric MXCPUExceptionDiagnostic MXDiskWriteExceptionDiagnostic
    MXHangDiagnostic MXCrashDiagnostic MXAverage MXHistogram MXHistogramBucket
    OSLog Logger OSSignposter OSSignpostID
    Darwin MemoryLayout Thread Comparable CustomStringConvertible Ellipse FillStyle
    KERN_SUCCESS MACH_TASK_BASIC_INFO TASK_VM_INFO URLCache
    task_info task_vm_info MACH_TASK_BASIC_INFO_COUNT
    AVFoundation Speech AVAudioSession AVAudioEngine AVAudioApplication SFSpeechRecognizer
    SFSpeechAudioBufferRecognitionRequest SFSpeechRecognitionTask SFSpeechRecognitionResult
    AVAudioPCMBuffer AVAudioFormat AVAudioNodeTapBlock
    """.split()
)

# 常见的大写开头「非类型」标识符：枚举 case、常量名、方法名参数
NON_TYPE = set(
    """
    I II III IV V VI VII VIII IX X
    UTF8 UTF16 UTF32 ASCII GBK GB18030
    iOS macOS watchOS tvOS visionOS
    MARK TODO FIXME NOTE SAFE TOKEN
    DEBUG RELEASE
    OK FAIL PASS WARN ERROR
    URLSessionTaskDelegate
    """.split()
)


def target_files(prefixes: tuple[str, ...]) -> list[Path]:
    out: list[Path] = []
    for p in IOS.rglob("*.swift"):
        rel = p.relative_to(IOS).as_posix()
        if any(rel.startswith(pre) for pre in prefixes):
            out.append(p)
    return sorted(out)


def analyse(name: str, prefixes: tuple[str, ...]) -> dict:
    files = target_files(prefixes)
    defined: set[str] = set()
    defined_in: dict[str, str] = {}
    text_by_file: dict[Path, str] = {}

    for p in files:
        raw = p.read_text(encoding="utf-8", errors="replace")
        stripped, _ = strip_source(raw)
        text_by_file[p] = stripped
        for m in DECL_RE.finditer(stripped):
            sym = m.group(1)
            defined.add(sym)
            defined_in.setdefault(sym, p.relative_to(IOS).as_posix())
        for m in CASE_RE.finditer(stripped):
            defined.add(m.group(1))

    suspicious: dict[str, list[str]] = defaultdict(list)
    for p, stripped in text_by_file.items():
        rel = p.relative_to(IOS).as_posix()
        for lineno, line in enumerate(stripped.splitlines(), 1):
            for m in IDENT_RE.finditer(line):
                sym = m.group(1)
                if not sym.isalpha() and not sym[0].isalpha():
                    continue
                if len(sym) < 3:
                    continue
                if sym in defined or sym in SYSTEM or sym in NON_TYPE:
                    continue
                suspicious[sym].append(f"{rel}:{lineno}")

    return {
        "target": name,
        "files": len(files),
        "defined_count": len(defined),
        "suspicious": {k: v for k, v in sorted(suspicious.items())},
    }


def main() -> int:
    verbose = "--verbose" in sys.argv
    as_json = "--json" in sys.argv

    results = [
        analyse("AIKeyboard (App)", ("Shared/", "AIKeyboard/")),
        analyse("AIKeyboardExtension", ("Shared/", "AIKeyboardExtension/")),
    ]

    if as_json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0

    total_bad = 0
    for r in results:
        sus = r["suspicious"]
        total_bad += len(sus)
        head = f"=== {r['target']} ===  files={r['files']}  defined={r['defined_count']}  可疑={len(sus)}"
        print(head)
        if not sus:
            continue
        if verbose:
            for sym, locs in sus.items():
                print(f"  [{sym}]  {len(locs)} 处")
                for loc in locs[:12]:
                    print(f"      {loc}")
                if len(locs) > 12:
                    print(f"      … 另 {len(locs) - 12} 处")
        else:
            for sym, locs in list(sus.items())[:40]:
                print(f"  {sym:28s} {len(locs)} 处  首次 {locs[0]}")
            if len(sus) > 40:
                print(f"  … 另 {len(sus) - 40} 个")
        print("")

    print(f"合计可疑符号 {total_bad} 个（含系统框架白名单未覆盖的误报，需人工判断）")
    return 0 if total_bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
