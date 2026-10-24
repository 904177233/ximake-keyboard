#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Type.member 粗粒度解析检查器（只读，不参与构建）。

用途：Windows 上无法编译 Swift，此脚本用「词法剥离 + 花括号配对」近似还原每个
具名类型（struct/enum/class/protocol/extension/actor）的成员集合，然后扫描全仓
`Type.member` 形式的引用，找出「类型存在但成员不存在」的可疑点。

局限（已知，属设计取舍）：
  * 不做真正的 Swift 类型检查，也不处理泛型约束、协议扩展、条件编译分支差异；
  * macOS/iOS 系统框架类型的成员一律靠白名单跳过；
  * 因此输出是「可疑清单」而不是「错误清单」，需人工复核后才可判定。

退出码：0 = 无可疑；1 = 有可疑项。
"""

import collections
import pathlib
import re
import sys

TYPE_DECL = re.compile(
    r"\b(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+|"
    r"@MainActor\s+|@frozen\s+|indirect\s+)*"
    r"(struct|enum|class|protocol|extension|typealias|actor)\s+([A-Za-z_]\w*)"
)

MEMBER_DECL = re.compile(
    r"\b(?:public\s+|internal\s+|private\s+|fileprivate\s+|static\s+|final\s+|"
    r"override\s+|class\s+|@MainActor\s+|nonisolated\s+|lazy\s+|weak\s+|"
    r"unowned\s+|mutating\s+|open\s+|dynamic\s+)*"
    r"(let|var|func|case|init|subscript|typealias)\s+([A-Za-z_]\w*)"
)

NESTED = re.compile(r"\b(?:struct|enum|class|protocol|actor)\s+([A-Za-z_]\w*)")

REF = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)")

# 协议合成 / 元类型 / 标准库隐含成员：不在源码正文里出现，但合法
SYNTHESIZED_MEMBERS = {
    "self", "init", "Type", "Protocol",
    "allCases", "none", "some", "any",
    "rawValue", "description", "debugDescription", "hashValue", "hash",
    "id", "objectWillChange", "body", "Error", "NSError",
    "localizedDescription", "failureReason", "recoverySuggestion",
    "errorDescription", "helpAnchor",
    "default", "empty", "zero", "first", "last", "count", "index",
    "key", "value", "values", "keys", "element", "elements",
    "StaticString", "numeric", "dictionary", "representation",
}

# 系统框架 / 标准库类型：不做成员校验
SYSTEM_TYPES = {
    "Foundation", "UIKit", "SwiftUI", "Combine", "CoreGraphics", "QuartzCore",
    "AVFoundation", "Security", "SafariServices", "Photos", "StoreKit",
    "UserNotifications", "Observation", "OSLog", "UniformTypeIdentifiers",
    "CoreImage", "ImageIO", "MobileCoreServices", "CoreText", "CoreFoundation",
    "Dispatch", "Swift", "Darwin", "ObjectiveC", "WebKit", "MapKit", "CloudKit",
    "Int", "Double", "Float", "String", "Bool", "Array", "Dictionary", "Set",
    "Optional", "Result", "Date", "Data", "URL", "UUID", "CGFloat", "CGSize",
    "CGPoint", "CGRect", "UIColor", "UIImage", "UIFont", "UIScreen", "UIView",
    "UIPasteboard", "UIApplication", "UIImpactFeedbackGenerator",
    "UISelectionFeedbackGenerator", "UINotificationFeedbackGenerator",
    "UIScreenEdgePanGestureRecognizer", "UIKeyboardAppearance",
    "UIUserInterfaceStyle", "UIHostingController", "UIInputViewController",
    "UITextDocumentProxy", "UIScrollView", "UIViewController", "UIColorWell",
    "Animation", "Transition", "Font", "Color", "Image", "Text", "Button",
    "VStack", "HStack", "ZStack", "Spacer", "ScrollView", "LazyVStack",
    "LazyHStack", "Group", "Section", "List", "Form", "NavigationStack",
    "NavigationLink", "NavigationView", "TabView", "Toggle", "Slider",
    "Stepper", "Picker", "TextField", "TextEditor", "SecureField", "Label",
    "Divider", "ProgressView", "Alert", "Sheet", "GeometryReader",
    "LinearGradient", "RadialGradient", "AngularGradient", "Material",
    "RoundedRectangle", "Rectangle", "Circle", "Capsule", "Ellipse",
    "Path", "Shape", "ViewBuilder", "EnvironmentValues", "EnvironmentObject",
    "ObservedObject", "StateObject", "State", "Binding", "Published",
    "ObservableObject", "Cancellable", "AnyCancellable", "AnyPublisher",
    "PassthroughSubject", "CurrentValueSubject", "AsyncThrowingStream",
    "AsyncStream", "Task", "MainActor", "URLSession", "URLRequest",
    "HTTPURLResponse", "JSONDecoder", "JSONEncoder", "NotificationCenter",
    "UserDefaults", "FileManager", "Bundle", "Keychain", "SecItem",
    "Locale", "TimeZone", "Calendar", "CharacterSet", "NSLock",
    "NSRegularExpression", "NSRange", "CodingKeys", "Decodable", "Encodable",
    "Codable", "Hashable", "Equatable", "Identifiable", "Comparable",
    "RawRepresentable", "CaseIterable", "Error", "LocalizedError",
    "CustomStringConvertible", "Sendable", "UIEdgeInsets", "NSAttributedString",
    "NSMutableAttributedString", "UIFontDescriptor", "CGAffineTransform",
    "CGColor", "CGContext", "UIBezierPath", "UIBlurEffect",
    "UIVisualEffectView", "UIAccessibility", "UIResponder", "UIControl",
    "UIWindow", "UIInterfaceOrientation", "UIDevice", "UIScreenMode",
    "UIViewAnimating", "UIViewPropertyAnimator", "UITraitCollection",
    "NSLayoutConstraint", "NSLayoutAnchor", "NSObject", "AnyObject",
    "UIActivityViewController", "UIAlertController", "UIAlertAction",
    "UIMenu", "UIAction", "UIImagePickerController", "PHPhotoLibrary",
    "PHAsset", "CNContactStore", "NSPredicate", "NSNotification",
    "ImageRenderer", "ShareLink", "Menu", "ControlGroup", "Grid", "GridRow",
    "ViewThatFits", "AnyLayout", "Layout", "TimelineView", "Canvas",
    "Angle", "UnitPoint", "Edge", "EdgeInsets", "Axis", "ScrollViewReader",
    "ScrollViewProxy", "GestureState", "DragGesture", "TapGesture",
    "LongPressGesture", "MagnificationGesture", "Sequence", "Collection",
    "StringProtocol", "Substring", "Range", "ClosedRange", "Never", "Void",
    "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32",
    "UInt64", "Float80", "NSNumber", "NSString", "NSArray", "NSDictionary",
    "NSData", "NSURL", "NSError", "NSException", "NSValue", "NSNull",
    "Thread", "OperationQueue", "RunLoop", "CFRunLoop", "Timer",
    "Notification", "Predicate", "Regex", "NSDecimalNumber",
    "Decimal", "NumberFormatter", "DateFormatter", "ISO8601DateFormatter",
    "ByteCountFormatter", "MeasurementFormatter", "AttributedString",
    "AttributedSubstring", "Padding", "SafeAreaRegions", "ContentMode",
    "Axis", "TextAlignment", "LineLimit", "TextTruncationMode",
    "ContentTransition", "SymbolEffect", "PhaseAnimator", "KeyframeAnimator",
    "Namespace", "MatchedGeometryProperties", "GeometryProxy",
    "GeometryEffect", "Alignment", "HorizontalAlignment",
    "VerticalAlignment", "DynamicTypeSize", "LegibilityWeight",
    "ColorScheme", "LayoutDirection", "ScenePhase", "OpenURLAction",
    "DismissAction", "PresentationMode", "ArrowEdge", "FormStyle",
    "ListStyle", "PickerStyle", "ToggleStyle", "ButtonStyle",
    "TextFieldStyle", "LabelStyle", "ProgressViewStyle", "Gauge",
    "Table", "ToolbarItem", "ToolbarItemGroup", "ToolbarPlacement",
    "SearchFieldPlacement", "SubmitLabel", "TextInputAutocapitalization",
    "AutocorrectionDisabled", "TextContentType", "KeyboardType",
    "ReturnKeyType", "UITextAutocapitalizationType", "UIReturnKeyType",
    "UIKeyboardType", "UILayoutPriority", "UIContentSizeCategory",
    "UITraitEnvironment", "UIAppearance", "UIUserInterfaceIdiom",
    "UIScene", "UIApplicationDelegate", "UIWindowScene",
    "UIGraphicsImageRenderer", "UIImageSymbolConfiguration",
    "UIImageConfiguration", "UICommand", "UIKeyCommand", "UIPressesEvent",
    "UIGestureRecognizer", "UIViewControllerTransitioning",
    "UIViewControllerAnimatedTransitioning", "UITextInputTraits",
    "UITextPosition", "UITextRange", "UIWebView", "WKWebView",
    "NSCache", "NSUbiquitousKeyValueStore", "NSPersistentContainer",
    "NSManagedObject", "NSManagedObjectContext", "NSFetchRequest",
    "NSEntityDescription", "NSAttributeDescription", "NSSortDescriptor",
}


def strip_lexical(source: str) -> str:
    """去掉注释与字符串字面量，保留换行以维持行号可读性。"""
    out = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        if ch == "/" and i + 1 < n and source[i + 1] == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif ch == "/" and i + 1 < n and source[i + 1] == "*":
            i += 2
            while i + 1 < n and not (source[i] == "*" and source[i + 1] == "/"):
                if source[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif ch == '"':
            # 多行字符串 """ ... """ 与普通字符串，都压缩成占位
            if source[i:i + 3] == '"""':
                i += 3
                while i + 2 < n and source[i:i + 3] != '"""':
                    if source[i] == "\n":
                        out.append("\n")
                    i += 1
                i += 3
            else:
                i += 1
                while i < n:
                    if source[i] == "\\":
                        i += 2
                        continue
                    if source[i] == '"':
                        i += 1
                        break
                    if source[i] == "\n":
                        out.append("\n")
                    i += 1
            out.append('""')
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def find_body(source: str, open_index: int) -> int:
    """返回与 source[open_index] 处 '{' 配对的 '}' 下标；失败返回 -1。"""
    depth = 0
    k = open_index
    while k < len(source):
        if source[k] == "{":
            depth += 1
        elif source[k] == "}":
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return -1


def first_level(body: str) -> str:
    """只保留类型体的第一层内容（嵌套类型体整体折叠掉）。"""
    buf = []
    depth = 0
    for ch in body:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        if depth == 0:
            buf.append(ch)
    return "".join(buf)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    ios = root / "ios"
    files = sorted(ios.rglob("*.swift"))
    if not files:
        print("[ERROR] 未找到 ios/**/*.swift")
        return 1

    members = collections.defaultdict(set)
    declaring_files = collections.defaultdict(set)
    body_cache = {}

    def depths(src: str):
        """返回每个下标的花括号深度（用于区分顶层声明与嵌套声明）。"""
        out = [0] * (len(src) + 1)
        depth = 0
        for idx, ch in enumerate(src):
            if ch == "}":
                depth -= 1
            out[idx] = depth
            if ch == "{":
                depth += 1
        return out

    for path in files:
        raw = path.read_text(encoding="utf-8")
        src = strip_lexical(raw)
        body_cache[path] = src
        dep = depths(src)
        for m in TYPE_DECL.finditer(src):
            kind, name = m.group(1), m.group(2)
            # 只有顶层声明才会参与「跨 target 同名」判定；嵌套类型天然不冲突。
            # extension / typealias 是对既有类型的扩展与别名，不是新类型，不参与同名判定。
            if dep[m.start()] == 0 and kind not in ("extension", "typealias"):
                declaring_files[name].add(path)
            members[name]  # 确保键存在
            open_index = src.find("{", m.end())
            if open_index < 0:
                continue
            close_index = find_body(src, open_index)
            if close_index < 0:
                continue
            flat = first_level(src[open_index + 1:close_index])
            for mm in MEMBER_DECL.finditer(flat):
                members[name].add(mm.group(2))
            for mm in NESTED.finditer(flat):
                members[name].add(mm.group(1))

    known = {t for t in members if t and t[0].isupper()}

    # 跨 target 同名顶层类型（Swift invalid redeclaration 的硬错误来源）
    cross_target = []
    for name, paths in sorted(declaring_files.items()):
        targets = set()
        for p in paths:
            rel = p.as_posix()
            if "/AIKeyboardExtension/" in rel:
                targets.add("Extension")
            elif "/AIKeyboard/" in rel:
                targets.add("App")
            elif "/Shared/" in rel:
                targets.add("Shared")
        if len(targets) > 1:
            cross_target.append((name, sorted(targets), len(paths)))

    suspicious = collections.Counter()
    samples = collections.defaultdict(list)

    for path in files:
        src = body_cache[path]
        for m in REF.finditer(src):
            type_name, member = m.group(1), m.group(2)
            if type_name not in known or type_name in SYSTEM_TYPES:
                continue
            if member in members[type_name] or member in SYNTHESIZED_MEMBERS:
                continue
            suspicious[(type_name, member)] += 1
            if len(samples[(type_name, member)]) < 3:
                line = src[: m.start()].count("\n") + 1
                samples[(type_name, member)].append(f"{path.relative_to(root).as_posix()}:{line}")

    print("=" * 78)
    print("Type.member 粗粒度解析检查（只读）")
    print("=" * 78)
    print(f"Swift 文件 : {len(files)}")
    print(f"具名类型   : {len(known)}")
    print(f"跨 target 同名顶层类型 : {len(cross_target)}")
    for name, targets, count in cross_target:
        print(f"  [P0] {name} 出现在 {targets}，共 {count} 个文件")
    print(f"可疑 Type.member : {len(suspicious)}")
    for (type_name, member), count in suspicious.most_common(40):
        print(f"  {type_name}.{member}  x{count}")
        for sample in samples[(type_name, member)]:
            print(f"      {sample}")
    print("-" * 78)

    if cross_target:
        print("结论: 有 P0（跨 target 同名顶层类型，Swift 会报 invalid redeclaration）")
        return 1
    if suspicious:
        print("结论: 有可疑项，需人工复核（可能是协议扩展 / 泛型 / 系统类型同名）")
        return 1
    print("结论: 通过（无可疑项）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
