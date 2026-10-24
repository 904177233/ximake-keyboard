#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Swift import 覆盖粗查（Lead 专用）。

Swift 的 import 是**按文件**生效的，同模块不共享。在 Windows 上无法编译时，
「用了 UIKit/SwiftUI/Combine 的符号但没 import 对应框架」是最常见的批量编译错误之一。

本脚本对每个 .swift 文件：
  1. 收集它 import 了哪些模块；
  2. 用符号特征判断它是否用到了 UIKit / SwiftUI / Combine / Foundation 的 API；
  3. 若用到但未直接或间接 import，则报缺。

已知间接覆盖：
  - `import SwiftUI` 会带入 Foundation（部分）与部分 UIKit 类型（UIImage 等需要显式 import UIKit）；
  - `import UIKit` 带入 Foundation；
  - `import Combine` 不会被 SwiftUI 带入（保守起见要求显式）。

用法：python scripts/lead/import_check.py [--verbose]
退出码：0=无缺失；1=有缺失。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "ios"

IMPORT_RE = re.compile(r"^\s*(?:@_exported\s+|@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def strip_source(text: str) -> str:
    out = []
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
    return "".join(out)


# 只放「一定属于某框架」的强特征符号，避免误报
UIKIT_TOKENS = [
    "UIView", "UIColor", "UIFont", "UIImage", "UIViewController", "UIInputViewController",
    "UIPasteboard", "UIScreen", "UIApplication", "UIHostingController", "UIViewPropertyAnimator",
    "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator", "UISelectionFeedbackGenerator",
    "NSLayoutConstraint", "UIKeyboardAppearance", "UITextDocumentProxy", "UIKeyInput",
    "UITraitCollection", "UIGraphicsImageRenderer", "UIEdgeInsets", "UIScrollView",
    "UILabel", "UITextField", "UITextView", "UIStackView", "UISwitch", "UISlider",
    "UIResponder", "UIControl", "UIGestureRecognizer", "UIAccessibility", "UIWindow",
    "UINavigationController", "UIStoryboard", "UIButton", "UITableView",
]

# SwiftUI 用**词边界正则**判定：`Text(` 必须前面不是标识符字符（否则会误中 insertText( / extractText(），
# 且中间不能有点号（否则会误中 UIKit 的 UIColor. 之类无关项）。
SWIFTUI_REGEXES = [
    r"(?<![\w.])Text\(",
    r"(?<![\w.])Image\(",
    r"(?<![\w.])VStack\b",
    r"(?<![\w.])HStack\b",
    r"(?<![\w.])ZStack\b",
    r"(?<![\w.])@ViewBuilder\b",
    r"(?<![\w.])@State\b",
    r"(?<![\w.])@StateObject\b",
    r"(?<![\w.])@ObservedObject\b",
    r"(?<![\w.])@EnvironmentObject\b",
    r"(?<![\w.])GeometryReader\b",
    r"(?<![\w.])NavigationStack\b",
    r"(?<![\w.])NavigationLink\b",
    r"(?<![\w.])RoundedRectangle\b",
    r"(?<![\w.])LinearGradient\b",
    r"(?<![\w.])withAnimation\b",
    r"(?<![\w.])ProgressView\b",
    r"(?<![\w.])TextField\(",
    r"(?<![\w.])SecureField\(",
    r"(?<![\w.])Toggle\(",
    r"(?<![\w.])TabView\b",
    r"(?<![\w.])ToolbarItem\b",
    r"(?<![\w.])ForEach\(",
    r"(?<![\w.])ScrollView\b",
    r"(?<![\w.])LazyVStack\b",
    r"(?<![\w.])some View\b",
]

COMBINE_TOKENS = [
    "AnyCancellable", "PassthroughSubject", "CurrentValueSubject", "ObservableObject",
    "Cancellable", "AnyPublisher", "Publishers.", ".sink(", ".eraseToAnyPublisher()",
    "AsyncPublisher", "@Published",
]

FOUNDATION_TOKENS = [
    "NSLock", "JSONDecoder", "JSONEncoder", "URLSession", "URLRequest", "CodingKey",
    "NotificationCenter", "FileManager", "DateFormatter", "UserDefaults", "IndexSet",
    "CharacterSet", "NSRegularExpression", "Date(",
]


def main() -> int:
    verbose = "--verbose" in sys.argv
    problems: list[tuple[str, str, str]] = []

    for p in sorted(IOS.rglob("*.swift")):
        rel = p.relative_to(ROOT).as_posix()
        raw = p.read_text(encoding="utf-8", errors="replace")
        code = strip_source(raw)
        imports = {m.group(1) for m in IMPORT_RE.finditer(raw)}

        has_foundation = "Foundation" in imports or "UIKit" in imports or "SwiftUI" in imports
        has_uikit = "UIKit" in imports or "SwiftUI" in imports  # SwiftUI 转出部分 UIKit 类型
        has_swiftui = "SwiftUI" in imports
        has_combine = "Combine" in imports

        def used(tokens: list[str]) -> list[str]:
            hits = []
            for t in tokens:
                if t in code:
                    hits.append(t)
            return hits

        u = used(UIKIT_TOKENS)
        s = [m for rx in SWIFTUI_REGEXES for m in [re.search(rx, code)] if m]
        s = [m.group(0) for m in s]
        c = used(COMBINE_TOKENS)
        f = used(FOUNDATION_TOKENS)

        if f and not has_foundation:
            problems.append((rel, "Foundation", ", ".join(f[:4])))
        if u and not has_uikit:
            problems.append((rel, "UIKit", ", ".join(u[:4])))
        if s and not has_swiftui:
            problems.append((rel, "SwiftUI", ", ".join(s[:4])))
        if c and not has_combine and not has_swiftui:
            problems.append((rel, "Combine", ", ".join(c[:4])))

    if verbose:
        for rel, mod, syms in problems:
            print(f"[缺 {mod}] {rel}   <- {syms}")
    print(f"import 缺失条目: {len(problems)}")
    by_mod: dict[str, int] = {}
    for _, mod, _ in problems:
        by_mod[mod] = by_mod.get(mod, 0) + 1
    for k, v in sorted(by_mod.items()):
        print(f"  {k}: {v}")
    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
