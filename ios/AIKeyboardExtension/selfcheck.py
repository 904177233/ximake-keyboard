#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）键盘扩展 · 本地静态自查脚本。

用途
----
本工程只能在 macOS + Xcode 上真正编译，Windows 侧无法 `swift build`。本脚本用
纯文本规则做**代理检查**，把「能被机器发现的问题」全部前置暴露，减少来回改动。

检查项（与 `scripts/qa/static_check.py` 互补，侧重扩展目录自身的编译直觉）：

  1. 编码 / 换行 / BOM / 行数（每文件 ≤ 600 行）
  2. 括号配对（忽略字符串与注释中的括号）
  3. 危险语法：`try!` / `as!` / `fatalError` / `UIApplication`
  4. iOS 17+ 专用 API 黑名单（本项目 iOS 16.0 起）
  5. `.font(.system(size: N))` 的字号是否在设计令牌集合内
  6. 顶层类型重复声明（同一 target 内 `struct/class/enum/protocol` 同名）
  7. 引用但未定义的 `KM*` 类型（粗查，排除系统/Shared 白名单）
  8. 命中区抽查（`KeyCap` 是否用 `Theme.Sizing.minTapTarget` 抬升到 44pt）
  9. 硬编码色值 `#RRGGBB` / `0xRRGGBB`

用法
----
    python ios/AIKeyboardExtension/selfcheck.py            # 人类可读
    python ios/AIKeyboardExtension/selfcheck.py --json     # 机器可读
    python ios/AIKeyboardExtension/selfcheck.py --strict   # 有 WARN 也返回非 0

退出码：0 = 无 ERROR；1 = 存在 ERROR；--strict 下 WARN 也算失败。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent  # 仓库根（ios/AIKeyboardExtension -> 仓库根）

MAX_LINES_PER_FILE = 600
MIN_TAP_TARGET = 44

TOKENS_REL = "design/tokens.json"

# 兜底字号集合（design/tokens.json 缺失或解析失败时才使用）。
FALLBACK_FONT_SIZES = {
    10.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 20.0, 22.0, 24.0, 34.0,
}

# iOS 17+ 才有 / 语义易错的 API（本项目 iOS 16.0 起）。
FORBIDDEN_API = {
    ".scrollTargetBehavior": "iOS 17+",
    ".symbolEffect": "iOS 17+",
    ".containerRelativeFrame": "iOS 17+",
    ".onScrollGeometryChange": "iOS 17+",
    "ContentUnavailableView": "iOS 17+",
    ".rect(cornerRadius:": "iOS 17+",
    "UnevenRoundedRectangle": "iOS 17+",
    ".scrollPosition(": "iOS 17+",
}

# 系统框架类型白名单（用于「引用但未定义」粗查，避免误报）。
SYSTEM_TYPES = {
    "AnyCancellable", "AnyView", "Array", "AsyncThrowingStream", "Bundle", "Button",
    "ButtonStyle", "CancellationError", "Capsule", "CharacterSet", "Circle", "CodingKey",
    "Color", "Combine", "Configuration", "Content", "CoreGraphics", "Data", "Date",
    "Decoder", "Dictionary", "DispatchQueue", "EmptyView", "Encoder", "Environment",
    "Error", "Float", "Font", "ForEach", "GeometryReader", "GridItem", "Group", "HStack",
    "Hashable", "Identifiable", "Image", "Int", "JSONDecoder", "JSONEncoder", "LazyVGrid",
    "LazyVStack", "LinearGradient", "Locale", "LocalizedError", "Never", "Notification",
    "NSLayoutConstraint", "NSLock", "NSRegularExpression", "NSSelectorFromString",
    "NSString", "ObservableObject", "ObservedObject", "Optional", "Path", "Published",
    "Rectangle", "RoundedRectangle", "ScrollView", "ScrollViewReader", "Sendable",
    "Set", "Spacer", "State", "String", "Task", "Text", "TimeInterval", "Timer",
    "Toggle", "UIColor", "UIControl", "UIImage", "UIGraphicsImageRenderer",
    "UIHostingController", "UIInputViewController", "UIKeyboardAppearance",
    "UIPasteboard", "UIResponder", "UIScreen", "UITextDocumentProxy", "UITraitCollection",
    "UIView", "UIViewPropertyAnimator", "UIViewController", "UIAccessibility", "URL",
    "UUID", "VStack", "View", "ViewBuilder", "ZStack", "Bool", "CGFloat", "CGSize",
    "CGRect", "CGPoint", "CGColor", "NSObject", "Selector", "Character", "Substring",
    "Result", "Sequence", "Collection", "CaseIterable", "Equatable", "Comparable",
    "CustomStringConvertible", "LocalizedStringKey", "Angle", "Edge", "EdgeInsets",
    "Axis", "Alignment", "Animation", "Transaction", "UnitPoint", "Binding", "Scene",
    "App", "StateObject", "EnvironmentObject", "MainActor", "OSStatus", "URLSession",
    "URLRequest", "HTTPURLResponse", "JSONSerialization", "NSURLErrorDomain",
    "NSURLErrorCannotConnectToHost", "NSURLErrorCannotFindHost",
    "NSURLErrorDNSLookupFailed", "NSURLErrorNetworkConnectionLost",
    "NSURLErrorSecureConnectionFailed", "NSURLErrorTimedOut", "ObjCBool",
    "SecItemAdd", "SecItemCopyMatching", "SecItemDelete", "SecItemUpdate", "Security",
    "CFDictionary", "CFTypeRef", "Sheet", "PresentationDetent", "AccessibilityTraits",
    "LayoutDirection", "OpenURLAction", "DismissAction", "EditMode", "DynamicProperty",
    "ObjectIdentifier", "Range", "ClosedRange", "Stride", "KeyPath", "Mirror",
}

# Shared 层（只读）提供的类型：列在扩展里出现属于正常引用。
SHARED_TYPES = {
    "AIClientFactory", "AIError", "AIFeature", "AIProviderConfig", "ModelRef",
    "AnthropicClient", "BuiltInPrompts", "ChatDelta", "ChatMessage", "ChatRequest",
    "ChatResult", "TokenUsage", "ConfigSnapshot", "ConfigStore", "InMemoryConfigStore",
    "ConfigStoring", "GeminiClient", "GeneratedImage", "HTTPTransport", "ImageDownloader",
    "OpenAICompatibleImageClient", "ImageClientRouter", "ImageRequest", "KeychainError",
    "KeychainStore", "ImageGenerating", "LLMClient", "OpenAICompatibleClient",
    "PasteboardBridge", "PasteboardBridgeError", "ExportPayload", "PinyinSyllables",
    "PresetProviders", "PromptLibrary", "PromptTemplate", "ProviderKind",
    "SeedreamImageClient", "SharedStoreKey", "SharedStore", "SSEEvent", "SSEParser",
    "Theme", "WanxImageClient", "IMEKit", "IMECandidate", "DictionaryEntry",
    "PinyinDictionary", "PinyinEngine", "UserLearningStore", "PhraseLibrary", "PhraseItem",
    "ClipboardHistory", "PhraseSuggestionIndex", "ImageProgress", "AIErrorViewData",
    "ImageResultViewData",
}

RE_STRING_OR_COMMENT = re.compile(
    r'"""(?:.|\n)*?"""'      # 多行字符串
    r'|"(?:[^"\\\n]|\\.)*"'  # 单行字符串
    r'|//[^\n]*'             # 行注释
    r'|/\*(?:.|\n)*?\*/',    # 块注释
    re.MULTILINE,
)

RE_DECL_TYPE = re.compile(
    r'^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+|final\s+|open\s+)*'
    r'(struct|class|enum|protocol|typealias|actor)\s+([A-Za-z_][A-Za-z0-9_]*)',
    re.MULTILINE,
)

RE_TYPE_REF = re.compile(r'\b(KM[A-Za-z0-9_]+)\b')


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------

@dataclass
class Issue:
    """一条检查结果。"""
    level: str      # ERROR / WARN
    code: str       # 短代号
    file: str       # 相对仓库根的路径
    line: int       # 1 基行号
    message: str    # 中文说明
    hint: str = ""  # 修复建议

    def as_dict(self) -> dict:
        return {
            "level": self.level, "code": self.code, "file": self.file,
            "line": self.line, "message": self.message, "hint": self.hint,
        }


@dataclass
class Context:
    """检查上下文。"""
    files: list = field(default_factory=list)       # list[Path]
    issues: list = field(default_factory=list)      # list[Issue]
    type_defs: dict = field(default_factory=dict)   # name -> (kind, relpath, line)
    stats: dict = field(default_factory=dict)

    def add(self, level: str, code: str, path: Path, line: int, message: str, hint: str = "") -> None:
        self.issues.append(Issue(level, code, _rel(path), line, message, hint))


# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------

def _rel(path: Path) -> str:
    """转成相对仓库根的 POSIX 路径（输出稳定、跨平台）。"""
    try:
        return path.resolve().relative_to(ROOT.resolve()).as_posix()
    except ValueError:
        return path.as_posix()


def strip_strings_and_comments(text: str) -> str:
    """把字符串与注释替换成等长空白（保留行号与列位置），便于做括号配对。"""
    def _blank(match: re.Match) -> str:
        chunk = match.group(0)
        return "".join("\n" if ch == "\n" else " " for ch in chunk)
    return RE_STRING_OR_COMMENT.sub(_blank, text)


def collect_files() -> list:
    """收集扩展目录下全部 .swift 文件（稳定排序）。"""
    return sorted(HERE.rglob("*.swift"), key=lambda p: p.as_posix())


def load_allowed_font_sizes() -> set:
    """从 design/tokens.json 派生「允许字号」集合。

    与 `scripts/qa/consistency_check.py` 的口径保持一致：收集 typography 的 `size`，
    以及 spacing / radius / sizing 里的全部数值（例如 radius.control = 10、
    radius.chip = 14 也在允许范围内）。

    Returns:
        允许的字号集合；tokens.json 缺失或解析失败时返回内置兜底集合。
    """
    path = ROOT / TOKENS_REL
    if not path.is_file():
        return set(FALLBACK_FONT_SIZES)

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return set(FALLBACK_FONT_SIZES)

    sizes = set()

    typography = data.get("typography", {})
    if isinstance(typography, dict):
        for spec in typography.values():
            if isinstance(spec, dict) and "size" in spec:
                try:
                    sizes.add(float(spec["size"]))
                except (TypeError, ValueError):
                    pass

    def walk(node) -> None:
        if isinstance(node, dict):
            for value in node.values():
                walk(value)
        elif isinstance(node, (int, float)) and not isinstance(node, bool):
            sizes.add(float(node))

    for group in ("spacing", "radius", "sizing"):
        walk(data.get(group, {}))

    return sizes or set(FALLBACK_FONT_SIZES)


# ---------------------------------------------------------------------------
# 各检查项
# ---------------------------------------------------------------------------

def check_encoding_and_size(ctx: Context) -> None:
    """① 编码 / BOM / 换行 / 行数。"""
    ctx.stats["files"] = len(ctx.files)
    ctx.stats["lines"] = 0
    for path in ctx.files:
        raw = path.read_bytes()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            ctx.add("ERROR", "FILE-ENCODING", path, 0,
                    f"不是合法 UTF-8：{exc}", "另存为 UTF-8（无 BOM）")
            continue
        if raw.startswith(b"\xef\xbb\xbf"):
            ctx.add("WARN", "FILE-BOM", path, 1, "文件带 UTF-8 BOM", "去掉 BOM")
        if b"\r\n" in raw:
            ctx.add("WARN", "FILE-CRLF", path, 0, "存在 CRLF 换行", "统一改为 LF")
        lines = text.count("\n") + (0 if text.endswith("\n") else 1)
        ctx.stats["lines"] += lines
        if lines > MAX_LINES_PER_FILE:
            ctx.add("ERROR", "FILE-TOO-LONG", path, lines,
                    f"{lines} 行，超过 {MAX_LINES_PER_FILE} 行硬约束",
                    "拆分为多个 extension 文件")


def check_brackets(ctx: Context) -> None:
    """② 括号配对（忽略字符串 / 注释）。"""
    pairs = {"(": ")", "[": "]", "{": "}"}
    closers = {v: k for k, v in pairs.items()}
    for path in ctx.files:
        text = path.read_text(encoding="utf-8")
        masked = strip_strings_and_comments(text)
        stack = []
        for index, ch in enumerate(masked):
            if ch in pairs:
                stack.append((ch, index))
            elif ch in closers:
                if not stack:
                    line = masked.count("\n", 0, index) + 1
                    ctx.add("ERROR", "LEX-UNMATCHED", path, line, f"多余的右括号 `{ch}`")
                    continue
                opener, _ = stack.pop()
                if pairs[opener] != ch:
                    line = masked.count("\n", 0, index) + 1
                    ctx.add("ERROR", "LEX-MISMATCH", path, line,
                            f"括号不匹配：`{opener}` 未闭合却遇到 `{ch}`")
        for opener, index in stack:
            line = masked.count("\n", 0, index) + 1
            ctx.add("ERROR", "LEX-UNCLOSED", path, line, f"`{opener}` 未闭合")


def check_dangerous_syntax(ctx: Context) -> None:
    """③ 危险语法与扩展硬禁令。"""
    patterns = [
        (re.compile(r'\btry!'), "CRASH-TRY", "禁止 `try!`（docs/02 §3）"),
        (re.compile(r'\bas!'), "CRASH-AS", "禁止 `as!`（docs/02 §3）"),
        (re.compile(r'\bfatalError\s*\('), "CRASH-FATAL", "禁止 `fatalError`（docs/02 §3）"),
        (re.compile(r'\bUIApplication\b'), "EXT-UIAPP", "键盘扩展内禁止出现 UIApplication"),
    ]
    for path in ctx.files:
        masked = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        for pattern, code, message in patterns:
            for match in pattern.finditer(masked):
                line = masked.count("\n", 0, match.start()) + 1
                ctx.add("ERROR", code, path, line, message,
                        "改用 `try?` / `as?` / 返回错误值；扩展内只能文字引导，不能跳转设置")


def check_ios17_api(ctx: Context) -> None:
    """④ iOS 17+ API 黑名单（只看真实代码，忽略注释与字符串）。"""
    for path in ctx.files:
        masked = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        for token, reason in FORBIDDEN_API.items():
            for match in re.finditer(re.escape(token), masked):
                line = masked.count("\n", 0, match.start()) + 1
                ctx.add("ERROR", "API-IOS17", path, line,
                        f"使用了 {reason} 才有的 API：`{token}`",
                        "iOS 16 部署目标，改用 16.0 可用 API（详见 design/组件库.md 禁用清单）")


def check_magic_font(ctx: Context, allowed_sizes: set) -> None:
    """⑤ `.font(.system(size: N))` 的字号是否在设计令牌集合内。"""
    pattern = re.compile(r'\.font\s*\(\s*\.system\s*\(\s*size\s*:\s*([0-9]+(?:\.[0-9]+)?)')
    for path in ctx.files:
        text = path.read_text(encoding="utf-8")
        for match in pattern.finditer(text):
            size = float(match.group(1))
            if allowed_sizes and size in allowed_sizes:
                continue
            line = text.count("\n", 0, match.start()) + 1
            ctx.add("WARN", "FONT-MAGIC", path, line,
                    f"字号 {match.group(1)} 不在设计令牌集合内",
                    "改用 Theme.fontXxx，或使用 tokens 里的字号")


def check_duplicate_types(ctx: Context) -> None:
    """⑥ 顶层类型重复声明。"""
    for path in ctx.files:
        text = path.read_text(encoding="utf-8")
        masked = strip_strings_and_comments(text)
        for match in RE_DECL_TYPE.finditer(masked):
            kind, name = match.group(1), match.group(2)
            if kind == "typealias":
                continue
            line = masked.count("\n", 0, match.start()) + 1
            if name in ctx.type_defs:
                prev_kind, prev_path, prev_line = ctx.type_defs[name]
                ctx.add("ERROR", "DUP-DECL", path, line,
                        f"`{kind} {name}` 与 {prev_path}:{prev_line} 的 `{prev_kind}` 重名",
                        "改名（扩展侧统一加 KM 前缀）")
            else:
                ctx.type_defs[name] = (kind, _rel(path), line)


def check_undefined_km_types(ctx: Context) -> None:
    """⑦ 引用但未定义的 `KM*` 类型（粗查）。"""
    known = set(ctx.type_defs.keys()) | SYSTEM_TYPES | SHARED_TYPES
    for path in ctx.files:
        masked = strip_strings_and_comments(path.read_text(encoding="utf-8"))
        for match in RE_TYPE_REF.finditer(masked):
            name = match.group(1)
            if name in known:
                continue
            line = masked.count("\n", 0, match.start()) + 1
            ctx.add("WARN", "SYMBOL-KM", path, line,
                    f"引用了未在本目录定义的 `{name}`",
                    "确认是否另有文件定义；若缺失则需补类型声明")


def check_hit_targets(ctx: Context) -> None:
    """⑧ 命中区抽查（KeyCap 必须有 44pt 命中区）。"""
    keycap = HERE / "Views" / "KeyCap.swift"
    if keycap.is_file():
        text = keycap.read_text(encoding="utf-8")
        if "minHeight: Theme.Sizing.minTapTarget" not in text:
            ctx.add("WARN", "A11Y-HIT", keycap, 0,
                    "KeyCap 未用 `minHeight: Theme.Sizing.minTapTarget` 抬升命中区",
                    "键盘视觉 39pt、命中区必须 ≥44pt（design/键盘布局规范.md §2.7）")


def check_hardcoded_colors(ctx: Context) -> None:
    """⑨ 硬编码色值。"""
    pattern = re.compile(r'#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b|\b0x(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})\b')
    for path in ctx.files:
        if path.name == "Theme.swift":
            continue
        text = path.read_text(encoding="utf-8")
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            ctx.add("WARN", "COLOR-HARDCODED", path, line,
                    f"硬编码色值 `{match.group(0)}`", "改用 Theme.xxx（颜色全部来自设计令牌）")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run() -> Context:
    """执行全部检查项。"""
    ctx = Context(files=collect_files())
    allowed_sizes = load_allowed_font_sizes()
    check_encoding_and_size(ctx)
    check_brackets(ctx)
    check_dangerous_syntax(ctx)
    check_ios17_api(ctx)
    check_magic_font(ctx, allowed_sizes)
    check_duplicate_types(ctx)
    check_undefined_km_types(ctx)
    check_hit_targets(ctx)
    check_hardcoded_colors(ctx)
    ctx.stats["types"] = len(ctx.type_defs)
    ctx.stats["font_sizes"] = len(allowed_sizes)
    ctx.stats["errors"] = sum(1 for i in ctx.issues if i.level == "ERROR")
    ctx.stats["warnings"] = sum(1 for i in ctx.issues if i.level == "WARN")
    return ctx


def render_text(ctx: Context) -> str:
    """渲染人类可读报告。"""
    lines = []
    lines.append("=" * 78)
    lines.append(" 墨语（Moyu）· 键盘扩展本地自查（ios/AIKeyboardExtension/selfcheck.py）")
    lines.append(f" 目录：{HERE.as_posix()}")
    lines.append(
        f" 文件 {ctx.stats.get('files', 0)} 个 | 代码 {ctx.stats.get('lines', 0)} 行 | "
        f"顶层类型 {ctx.stats.get('types', 0)} 个 | 允许字号 {ctx.stats.get('font_sizes', 0)} 个"
    )
    lines.append("=" * 78)

    if not ctx.issues:
        lines.append("")
        lines.append("未发现问题：括号配对、危险语法、iOS 17 API、字号令牌、类型重名、硬编码色值全部通过。")
        lines.append("")
        return "\n".join(lines)

    for level in ("ERROR", "WARN"):
        subset = [i for i in ctx.issues if i.level == level]
        if not subset:
            continue
        lines.append("")
        lines.append(f"── {level}（{len(subset)} 条）" + "-" * 50)
        for issue in subset:
            location = f"{issue.file}:{issue.line}" if issue.line else issue.file
            lines.append(f"[{issue.code}] {location}")
            lines.append(f"    {issue.message}")
            if issue.hint:
                lines.append(f"    → {issue.hint}")

    lines.append("")
    lines.append(f"合计：ERROR={ctx.stats.get('errors', 0)} WARN={ctx.stats.get('warnings', 0)}")
    lines.append("")
    return "\n".join(lines)


def main(argv: list) -> int:
    """命令行入口。"""
    parser = argparse.ArgumentParser(description="墨语键盘扩展本地静态自查")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("--strict", action="store_true", help="WARN 也视为失败")
    args = parser.parse_args(argv[1:])

    ctx = run()
    if args.json:
        payload = {
            "root": HERE.as_posix(),
            "stats": ctx.stats,
            "issues": [i.as_dict() for i in ctx.issues],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_text(ctx))

    if ctx.stats.get("errors", 0) > 0:
        return 1
    if args.strict and ctx.stats.get("warnings", 0) > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
