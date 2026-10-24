#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ios/Shared/selfcheck.py — 共享层静态自检（本机没有 Xcode/swift，只能用 Python 粗查）

检查项：
  1) 文件编码 / 换行 / 缩进（UTF-8、LF、4 空格）
  2) 括号配对（() [] {} 三种，跳过字符串与注释）
  3) 禁用写法（try! / as! / fatalError 在非调试位）
  4) 模块纯度（Models / Networking / Prompts 只允许 Foundation）
  5) 每个 .swift 文件必须带「模块职责 / 依赖 / 使用方」文件头注释
  6) Theme.swift 的颜色十六进制值必须与 design/tokens.json 逐键一致
  7) 跨文件符号引用：本目录内所有 `Xxx.yyy` / `Xxx(` 引用必须能找到声明（启发式）
  8) 协议方法签名一致性：LLMClient / ImageGenerating / ConfigStoring 的实现类
  9) `ios/Shared/` 跨目录顶层类型重名（含 IMECore，Swift 同模块编译期错误）

用法：
    python ios/Shared/selfcheck.py
退出码：0 = 全绿；1 = 有 FAIL。
"""

import json
import os
import re
import sys

# Windows 控制台默认 GBK，中文与符号会直接抛 UnicodeEncodeError，这里强制 UTF-8。
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001 - 老 Python 无 reconfigure 时忽略
    pass

ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(ROOT))  # 输入法/
TOKENS_PATH = os.path.join(PROJECT_ROOT, "design", "tokens.json")

LAYER_DIRS = ["Models", "Networking", "Storage", "Prompts", "Theme"]

# 纯 Foundation 的层（不得 import UIKit / SwiftUI）
PURE_FOUNDATION_DIRS = ["Models", "Networking", "Prompts"]

failures = []
warnings = []
checks = 0


def fail(msg):
    failures.append(msg)


def warn(msg):
    warnings.append(msg)


def ok(_msg=""):
    global checks
    checks += 1


# --------------------------------------------------------------------------
# 1) 文本层检查：编码 / 换行 / 行尾空白 / 制表符
# --------------------------------------------------------------------------

def check_text_hygiene(path, text, rel):
    raw = open(path, "rb").read()
    # UTF-8（含 BOM 则警告）
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail("%s: 不是合法 UTF-8（%s）" % (rel, exc))
        return
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("%s: 文件带 UTF-8 BOM" % rel)
    if b"\r\n" in raw:
        fail("%s: 存在 CRLF 换行（要求 LF）" % rel)
    if b"\t" in raw:
        fail("%s: 存在制表符（要求 4 空格缩进）" % rel)
    # 4 空格缩进：只看真实代码行（字符串/注释内容会被 strip_code 抹成空格而自动跳过）
    # 续行对齐（上一行以 ( [ , : = -> 结尾）是 Swift 官方风格，允许非 4 倍数缩进。
    code_lines = strip_code(text).split("\n")
    prev_code_tail = ""
    for i, line in enumerate(code_lines, 1):
        stripped = line.strip()
        if not stripped:
            continue
        lead = len(line) - len(line.lstrip(" "))
        is_continuation = prev_code_tail in ("(", "[", ",", ":", "=", "->", "?", "(")
        if lead % 4 != 0 and not is_continuation:
            warn("%s:%d: 缩进 %d 空格（不是 4 的倍数）" % (rel, i, lead))
            break
        prev_code_tail = stripped[-1]
    ok()


# --------------------------------------------------------------------------
# 2) 括号配对（跳过 // 注释、/* */ 块注释、字符串与三引号字符串）
# --------------------------------------------------------------------------

def strip_code(text):
    """把注释与字符串内容替换成空格，保留结构字符与换行位置。"""
    out = []
    i = 0
    n = len(text)
    state = "code"  # code | line_comment | block_comment | string | multiline
    depth = 0  # block comment nesting（Swift 支持嵌套块注释）
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if ch == "/" and nxt == "/":
                state = "line_comment"
                out.append("  ")
                i += 2
                continue
            if ch == "/" and nxt == "*":
                state = "block_comment"
                depth = 1
                out.append("  ")
                i += 2
                continue
            if text.startswith('"""', i):
                state = "multiline"
                out.append("   ")
                i += 3
                continue
            if ch == '"':
                state = "string"
                out.append(" ")
                i += 1
                continue
            out.append(ch)
            i += 1
            continue
        if state == "line_comment":
            if ch == "\n":
                state = "code"
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue
        if state == "block_comment":
            if text.startswith("/*", i):
                depth += 1
                out.append("  ")
                i += 2
                continue
            if text.startswith("*/", i):
                depth -= 1
                out.append("  ")
                i += 2
                if depth == 0:
                    state = "code"
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
        if state == "string":
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                state = "code"
                out.append(" ")
                i += 1
                continue
            if ch == "\n":
                # 单行字符串里出现换行属于语法错误；这里保持状态机继续，交给括号检查暴露
                out.append("\n")
                i += 1
                continue
            out.append(" ")
            i += 1
            continue
        if state == "multiline":
            if text.startswith('"""', i):
                state = "code"
                out.append("   ")
                i += 3
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue
    return "".join(out)


PAIRS = {")": "(", "]": "[", "}": "{"}


def check_braces(text, rel):
    code = strip_code(text)
    stack = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "([{":
            stack.append((ch, line))
        elif ch in ")]}":
            if not stack:
                fail("%s:%d: 多余的右括号 %r" % (rel, line, ch))
                return
            opener, opener_line = stack.pop()
            if opener != PAIRS[ch]:
                fail("%s:%d: 括号不配对（%r 对应第 %d 行的 %r）" % (rel, line, ch, opener_line, opener))
                return
    if stack:
        opener, opener_line = stack[-1]
        fail("%s:%d: 未闭合的 %r（共 %d 个未闭合）" % (rel, opener_line, opener, len(stack)))
        return
    ok()


# --------------------------------------------------------------------------
# 3) 禁用写法
# --------------------------------------------------------------------------

BANNED = [
    (re.compile(r"\btry!\b"), "使用了 try!（禁止）"),
    (re.compile(r"\bas!\s"), "使用了 as!（禁止）"),
]


def check_banned(text, rel):
    code = strip_code(text)
    for pattern, message in BANNED:
        for match in pattern.finditer(code):
            line = code[: match.start()].count("\n") + 1
            fail("%s:%d: %s" % (rel, line, message))
            return
    ok()


# --------------------------------------------------------------------------
# 4) 模块纯度
# --------------------------------------------------------------------------

def check_purity(text, rel, layer):
    if layer not in PURE_FOUNDATION_DIRS:
        ok()
        return
    for i, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("import ") and stripped not in ("import Foundation",):
            fail("%s:%d: %s 层只允许 `import Foundation`，实际 `%s`" % (rel, i, layer, stripped))
            return
    ok()


# --------------------------------------------------------------------------
# 5) 文件头注释
# --------------------------------------------------------------------------

HEADER_KEYS = ("模块职责", "依赖", "使用方")


def check_header(text, rel):
    head = "\n".join(text.split("\n")[:24])
    missing = [key for key in HEADER_KEYS if key not in head]
    if missing:
        fail("%s: 文件头缺少 %s" % (rel, " / ".join(missing)))
        return
    ok()


# --------------------------------------------------------------------------
# 6) Theme 颜色与 tokens.json 对账
# --------------------------------------------------------------------------

THEME_MAP = {
    "keyboardBackground": "bg.keyboard",
    "keyBackground": "bg.key",
    "keyBackgroundPressed": "bg.key.pressed",
    "keyFunctionBackground": "bg.key.function",
    "keyFunctionBackgroundPressed": "bg.key.function.pressed",
    "surface": "bg.surface",
    "surfaceElevated": "bg.surfaceElevated",
    "surfaceGrouped": "bg.surfaceGrouped",
    "glassTint": "bg.glassTint",
    "textPrimary": "text.primary",
    "textSecondary": "text.secondary",
    "textTertiary": "text.tertiary",
    "textPlaceholder": "text.placeholder",
    "textOnAccent": "text.onAccent",
    "accent": "accent",
    "accentSoft": "accent.soft",
    "accentPressed": "accent.pressed",
    "separator": "separator",
    "separatorOpaque": "separator.opaque",
    "success": "success",
    "successSoft": "success.soft",
    "warning": "warning",
    "warningSoft": "warning.soft",
    "danger": "danger",
    "dangerSoft": "danger.soft",
    "candidateBar": "candidate.bar",
    "candidateSelected": "candidate.selected",
    "candidateSeparator": "candidate.separator",
    "chipBackground": "chip.bg",
    "chipBackgroundPressed": "chip.bg.pressed",
    "chipBorder": "chip.border",
    "chipText": "chip.text",
    "keyShadow": "shadow.key",
    "keyboardTopShadow": "keyboard.topShadow",
    "overlayScrim": "overlay.scrim",
    "aiGlow": "ai.glow",
}

ADAPTIVE_RE = re.compile(
    r'public\s+static\s+let\s+(\w+)\s*=\s*adaptive\(\s*"([0-9A-Fa-f]{6,8})"\s*,\s*"([0-9A-Fa-f]{6,8})"\s*\)'
)


def norm_hex(value):
    return value.replace("#", "").upper()


def check_theme_tokens(theme_text):
    if not os.path.exists(TOKENS_PATH):
        warn("design/tokens.json 不存在，跳过 Theme 对账")
        ok()
        return
    with open(TOKENS_PATH, "r", encoding="utf-8") as handle:
        tokens = json.load(handle)
    light = {k: norm_hex(v) for k, v in tokens["color"]["light"].items()}
    dark = {k: norm_hex(v) for k, v in tokens["color"]["dark"].items()}

    found = {}
    for match in ADAPTIVE_RE.finditer(theme_text):
        found[match.group(1)] = (norm_hex(match.group(2)), norm_hex(match.group(3)))

    for swift_name, token_key in THEME_MAP.items():
        if swift_name not in found:
            fail("Theme.swift: 缺少颜色常量 `%s`（token `%s`）" % (swift_name, token_key))
            continue
        if token_key not in light:
            fail("tokens.json: color.light 缺少键 `%s`" % token_key)
            continue
        got_light, got_dark = found[swift_name]
        if got_light != light[token_key]:
            fail(
                "Theme.swift: %s 浅色 #%s ≠ tokens %s #%s"
                % (swift_name, got_light, token_key, light[token_key])
            )
        if got_dark != dark[token_key]:
            fail(
                "Theme.swift: %s 深色 #%s ≠ tokens %s #%s"
                % (swift_name, got_dark, token_key, dark[token_key])
            )
    unmapped = set(found) - set(THEME_MAP)
    if unmapped:
        warn("Theme.swift 有 %d 个颜色未在 selfcheck 映射表中登记：%s" % (len(unmapped), ", ".join(sorted(unmapped))))
    ok()


# --------------------------------------------------------------------------
# 7) 跨文件符号存在性
#    (a) 重复类型声明 —— Swift 编译期直接报错，必须先查
#    (b) 其它层对共享层类型成员的访问（Theme.accent / KeychainStore.shared.apiKey …）
# --------------------------------------------------------------------------

DECL_TYPE_RE = re.compile(
    r"(?:^|\n)([ \t]*)(?:public\s+|internal\s+|private\s+|fileprivate\s+)?(?:final\s+)?"
    r"(?:class|struct|enum|protocol|actor|typealias)\s+(\w+)"
)
DECL_MEMBER_RE = re.compile(
    r"\b(?:public\s+|internal\s+|private\s+|fileprivate\s+)?(?:(?:static|class)\s+)?"
    r"(?:let|var|func|case)\s+(\w+)"
)
EXT_RE = re.compile(r"\bextension\s+(\w+)")


def collect_declared(swift_files):
    """返回 (顶层类型声明 {name: [rel]}, 全部成员名集合)。

    只统计**顶格（indent == 0）**的类型声明：嵌套类型（如各 struct 内部的
    `private enum CodingKeys`）在不同作用域内同名是合法的，不能当成重复。
    `extension X` 不计入重复判定（对既有类型追加成员是正常写法）。
    """
    declared_types = {}
    declared_members = set()
    for rel, text in swift_files:
        code = strip_code(text)
        for match in DECL_TYPE_RE.finditer(code):
            indent, name = match.group(1), match.group(2)
            if indent:
                continue  # 嵌套类型，跳过
            declared_types.setdefault(name, []).append(rel)
        declared_members.update(DECL_MEMBER_RE.findall(code))
        declared_members.update(EXT_RE.findall(code))
    return declared_types, declared_members


def check_duplicate_types(declared_types):
    for name, locations in declared_types.items():
        unique = sorted(set(locations))
        if len(unique) > 1:
            fail("顶层类型 `%s` 被重复声明于：%s" % (name, ", ".join(unique)))
    ok()


def collect_all_shared_types():
    """扫描 `ios/Shared/` 下**所有**子目录（含 IMECore 等他人层）的顶格类型声明。

    本层五目录的规则（纯 Foundation、契约符号…）只作用于自己的层，
    但「顶层类型重名」是全 `ios/Shared/` 共享一个 Swift 模块的编译期错误，
    因此必须跨目录一起查。
    """
    result = {}
    for dirname in sorted(os.listdir(ROOT)):
        subdir = os.path.join(ROOT, dirname)
        if not os.path.isdir(subdir):
            continue
        for entry in sorted(os.listdir(subdir)):
            if not entry.endswith(".swift"):
                continue
            path = os.path.join(subdir, entry)
            with open(path, "r", encoding="utf-8") as handle:
                code = strip_code(handle.read())
            for match in DECL_TYPE_RE.finditer(code):
                indent, type_name = match.group(1), match.group(2)
                if indent:
                    continue  # 嵌套类型不参与
                result.setdefault(type_name, []).append(os.path.join(dirname, entry))
    return result


def check_shared_wide_duplicates():
    """`ios/Shared/` 跨目录重复顶层类型（含 IMECore / 未来新增层）。

    例：ime-core 的 `PhraseLibrary` 与共享层的 `PromptLibrary` 必须不同名；
    若两个文件都声明了 `PhraseItem`，Swift 会报 "invalid redeclaration"。
    """
    wide = collect_all_shared_types()
    for type_name, locations in wide.items():
        unique = sorted(set(locations))
        if len(unique) > 1:
            fail("ios/Shared 跨目录重复类型 `%s`：%s" % (type_name, ", ".join(unique)))
    ok()
    return wide


def check_theme_members(theme_text):
    """Theme.<member> 的每一次访问都必须能在 Theme.swift 里找到对应声明。"""
    declared = set(re.findall(
        r"\bpublic\s+static\s+(?:let|var|func)\s+(\w+)", strip_code(theme_text)
    ))
    nested = set(re.findall(r"\bpublic\s+(?:enum|struct)\s+(\w+)", strip_code(theme_text)))
    usages = set(re.findall(r"\bTheme\.(\w+)", strip_code(theme_text)))
    for name in sorted(usages):
        if name not in declared and name not in nested:
            fail("Theme.swift: 内部引用了不存在的成员 `Theme.%s`" % name)
    ok()


def check_known_type_members(swift_files, declared_members):
    """其它层用到的共享层成员，必须能在共享层找到同名声明（启发式，只警告）。"""
    known_types = {
        "Theme", "AIClientFactory", "ImageClientRouter", "KeychainStore", "SharedStore",
        "SharedStoreKey", "ConfigStore", "PasteboardBridge", "PromptLibrary", "BuiltInPrompts",
        "PresetProviders", "ConfigSnapshot", "AE", "ChatMessage", "ImageRequest", "AIError",
    }
    for rel, text in swift_files:
        code = strip_code(text)
        for i, line in enumerate(code.split("\n"), 1):
            for match in re.finditer(r"\b(\w+)\.([A-Za-z_]\w*)", line):
                owner, member = match.group(1), match.group(2)
                if owner not in known_types:
                    continue
                if owner == "Theme":
                    continue  # 已在 check_theme_members 里精确检查
                if member in ("self", "Type", "init", "some", "none"):
                    continue  # `ConfigSnapshot.self` 这类元类型表达式不是成员访问
                if member in declared_members:
                    continue
                warn("%s:%d: `%s.%s` 未在共享层找到同名声明（需人工确认）" % (rel, i, owner, member))
    ok()



# --------------------------------------------------------------------------
# 8) 协议实现一致性
# --------------------------------------------------------------------------

PROTOCOL_METHODS = {
    "LLMClient": ["func stream(", "func complete("],
    "ImageGenerating": ["func generate("],
    "ConfigStoring": ["func load(", "func save("],
}


def check_protocols(swift_files):
    joined = "\n".join(text for _rel, text in swift_files)
    for proto, methods in PROTOCOL_METHODS.items():
        if ("protocol %s" % proto) not in joined:
            fail("缺少协议声明 `%s`" % proto)
            continue
        for method in methods:
            if method not in joined:
                fail("协议 %s 缺少方法 `%s`" % (proto, method))
    # 每个实现类必须能看到同名方法（粗查）
    impl_pairs = [
        ("OpenAICompatibleClient", ["func stream(", "func complete("]),
        ("AnthropicClient", ["func stream(", "func complete("]),
        ("GeminiClient", ["func stream(", "func complete("]),
        ("OpenAICompatibleImageClient", ["func generate("]),
        ("SeedreamImageClient", ["func generate("]),
        ("WanxImageClient", ["func generate("]),
        ("ConfigStore", ["func load(", "func save("]),
        ("InMemoryConfigStore", ["func load(", "func save("]),
    ]
    for class_name, methods in impl_pairs:
        if class_name not in joined:
            fail("缺少实现类 `%s`" % class_name)
            continue
        for method in methods:
            if method not in joined:
                fail("%s 缺少协议方法 `%s`" % (class_name, method))
    ok()


# --------------------------------------------------------------------------
# 9) 关键契约符号清单（docs/02 §4.1–4.5 + Lead 补丁）
# --------------------------------------------------------------------------

REQUIRED_SYMBOLS = {
    "Models": [
        "ProviderKind", "AIProviderConfig", "AIFeature", "ChatMessage", "ChatRequest",
        "ChatDelta", "ChatResult", "TokenUsage", "ImageRequest", "GeneratedImage",
        "ConfigSnapshot", "PresetProviders",
    ],
    "Networking": [
        "LLMClient", "ImageGenerating", "AIClientFactory", "SSEParser", "SSEEvent",
        "OpenAICompatibleClient", "AnthropicClient", "GeminiClient", "AIError",
        "OpenAICompatibleImageClient", "SeedreamImageClient", "WanxImageClient", "ImageClientRouter",
    ],
    "Storage": [
        "KeychainStore", "SharedStore", "ConfigStore", "ConfigStoring", "PasteboardBridge",
        "ExportPayload",
    ],
    "Prompts": ["PromptTemplate", "PromptLibrary", "BuiltInPrompts"],
    "Theme": ["Theme", "AppTheme", "ThemeStore"],
}

REQUIRED_MEMBERS = {
    "AIClientFactory": ["makeLLM", "makeImage"],
    "SSEParser": ["feed"],
    "SharedStore": ["shared", "isAppGroupAvailable", "defaults", "string", "set", "data", "setData"],
    "KeychainStore": ["shared", "setAPIKey", "apiKey", "deleteAPIKey", "isAvailable"],
    "PasteboardBridge": ["pasteboardName", "export", "importSnapshot", "magic"],
    "ConfigSnapshot": ["currentVersion", "imageProviderID", "defaultProvider", "presetOnly",
                       "enableAISuggestion", "enableTypoCorrection"],
    "PromptLibrary": ["builtIn", "templates", "render", "loadCustom", "saveCustom", "template",
                       "imagePromptEnhanceRequest"],
    "PromptTemplate": ["systemPrompt", "userTemplate", "isBuiltIn", "temperature"],
    "Theme": ["keyboardBackground", "candidateBar", "fontCandidate", "fontKey", "fontBody",
              "fontCaption", "fontTitle", "Spacing", "Radius", "Motion", "Sizing"],
    "PresetProviders": ["isImageOnly", "chatPresets", "imagePresets", "recommended",
                        "defaultImagePreset"],
    # design/05 §2.1 / §2.2 契约
    "AppTheme": ["preset", "allPresets", "default", "customID", "accent", "tint", "tint2",
                 "deep", "sub", "canvas"],
    "ThemeStore": ["shared", "currentThemeID", "currentTheme", "customMascotData",
                   "customMascotName", "clearCustomMascot", "showsMascot"],
    "SharedStoreKey": ["themeCurrent", "themeCustomMascot", "themeCustomMascotName",
                       "themeShowsMascot"],
}


def check_required(swift_files):
    by_layer = {}
    for rel, text in swift_files:
        layer = rel.split(os.sep)[0] if os.sep in rel else "Theme"
        by_layer.setdefault(layer, []).append(text)
    joined_by_layer = {layer: "\n".join(texts) for layer, texts in by_layer.items()}
    all_joined = "\n".join(joined_by_layer.values())

    for layer, names in REQUIRED_SYMBOLS.items():
        haystack = joined_by_layer.get(layer, "")
        for name in names:
            if not re.search(r"\b%s\b" % re.escape(name), haystack):
                fail("契约缺失：%s 层没有符号 `%s`" % (layer, name))
    for owner, members in REQUIRED_MEMBERS.items():
        for member in members:
            if not re.search(r"\b%s\b" % re.escape(member), all_joined):
                fail("契约缺失：`%s.%s` 未找到" % (owner, member))
    ok()


# --------------------------------------------------------------------------
# 10) 提示词与配置的交叉约束
# --------------------------------------------------------------------------

def check_prompts(swift_files):
    joined = "\n".join(text for _rel, text in swift_files)
    builtin_ids = set(re.findall(r'id:\s*"(builtin\.[a-z0-9.]+)"', joined))
    # docs/02 要求至少 12 条
    if len(builtin_ids) < 12:
        fail("内置 Prompt 模板只有 %d 条（要求 ≥ 12）：%s" % (len(builtin_ids), sorted(builtin_ids)))
    # 回复建议格式约束
    if "{{reply_count}}" not in joined:
        fail("Prompt 模板缺少 `{{reply_count}}` 占位符（回复建议条数）")
    if "1. 2. 3." not in joined and "1. 2. 3." not in joined.replace("\u3000", " "):
        warn("未找到「1. 2. 3.」格式说明，请确认回复建议输出格式已写进 systemPrompt")
    # 翻译模板目标语言占位符
    if "{{target_language}}" not in joined:
        fail("Prompt 模板缺少 `{{target_language}}` 占位符（翻译目标语言）")
    ok()


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    swift_files = []
    scanned = 0
    for layer in LAYER_DIRS:
        layer_dir = os.path.join(ROOT, layer)
        if not os.path.isdir(layer_dir):
            warn("缺少目录 ios/Shared/%s" % layer)
            continue
        for name in sorted(os.listdir(layer_dir)):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(layer_dir, name)
            rel = os.path.join(layer, name)
            with open(path, "r", encoding="utf-8") as handle:
                text = handle.read()
            swift_files.append((rel, text))
            scanned += 1

            check_text_hygiene(path, text, rel)
            check_braces(text, rel)
            check_banned(text, rel)
            check_purity(text, rel, layer)
            check_header(text, rel)

    if not swift_files:
        fail("没找到任何 .swift 文件")
    else:
        # 注意：不能用 `r.endswith("Theme.swift")` —— 同目录新增了 `AppTheme.swift`，
        # 它同样以 "Theme.swift" 结尾且排序更靠前，会顶掉真正的 Theme.swift。
        # 这里改成严格的 basename 比较。
        theme_entry = next(
            (t for r, t in swift_files if os.path.basename(r) == "Theme.swift"), None
        )
        if theme_entry is None:
            fail("缺少 ios/Shared/Theme/Theme.swift")
        else:
            check_theme_tokens(theme_entry)
            check_theme_members(theme_entry)
        declared_types, declared_members = collect_declared(swift_files)
        check_duplicate_types(declared_types)
        check_shared_wide_duplicates()
        check_known_type_members(swift_files, declared_members)
        check_protocols(swift_files)
        check_required(swift_files)
        check_prompts(swift_files)

    print("=" * 72)
    print("墨语 · Shared 层静态自检")
    print("=" * 72)
    print("扫描文件：%d 个 .swift" % scanned)
    print("通过检查：%d 项" % checks)
    print()

    if warnings:
        print("提示（%d）：" % len(warnings))
        for item in warnings[:40]:
            print("  ~ %s" % item)
        if len(warnings) > 40:
            print("  ... 还有 %d 条" % (len(warnings) - 40))
        print()

    if failures:
        print("FAIL（%d）：" % len(failures))
        for item in failures:
            print("  x %s" % item)
        print()
        print("结果：未通过")
        return 1

    print("结果：全部通过 ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
