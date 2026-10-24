#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— QA 脚本公共库。

Python 3.8+ 标准库，零第三方依赖，可在 Windows 直接运行。

本模块提供：
1. 仓库路径与文件发现（find_files / iter_swift_files）
2. Swift 简易词法状态机 lex_swift()
   - 屏蔽 `//`、可嵌套 `/* */` 注释与所有字符串字面量（含 #"..."# 原始字符串、
     三引号多行字符串与 \\( ) 插值），避免在注释/字符串里误报
   - 返回 code 掩码（1=代码字符）与字符串片段（用于中文文案检查）
3. 问题模型 Issue（P0/P1/P2/INFO）、Report（彩色终端输出 + JSON + Markdown）
4. 文本读取（UTF-8/BOM/CRLF/编码检测）

退出码约定（三个 QA 脚本统一）：
    0 = 无 P0/P1（可能有 P2 提示）
    1 = 存在 P1
    2 = 存在 P0
"""

from __future__ import annotations

import bisect
import json
import os
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# Windows 控制台默认 GBK，中文报告会乱码：强制 UTF-8 输出（Python 3.7+）
for _stream_name in ("stdout", "stderr"):
    _stream = getattr(sys, _stream_name, None)
    try:
        if _stream is not None and hasattr(_stream, "reconfigure"):
            _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001 - 输出流不可重配置时忽略
        pass

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

QA_DIR = Path(__file__).resolve().parent          # <repo>/scripts/qa
REPO_ROOT = QA_DIR.parents[1]                     # <repo>
DEFAULT_IOS = REPO_ROOT / "ios"
DEFAULT_DESIGN = REPO_ROOT / "design"
DEFAULT_DOCS = REPO_ROOT / "docs"

# 扫描时跳过的目录（构建产物、依赖、缓存）
SKIP_DIR_NAMES = {
    ".git", ".svn", ".hg", "build", "Build", "DerivedData", ".build",
    "Pods", "Carthage", "node_modules", "__pycache__", "xcuserdata",
    ".swiftpm", ".idea", ".vscode", "index.php", "Archive",
}


def rel(path, base: Path | None = None) -> str:
    """把绝对/相对路径转成相对仓库根的、正斜杠分隔的展示路径。"""
    try:
        p = Path(path).resolve()
        b = (base or REPO_ROOT).resolve()
        return p.relative_to(b).as_posix()
    except Exception:
        return str(path).replace("\\", "/")


def find_files(root, suffixes=(".swift",)):
    """递归收集指定后缀的文件，跳过构建产物目录。返回 Path 列表（已排序）。"""
    root = Path(root)
    out = []
    if not root.exists():
        return out
    suffixes = tuple(s.lower() for s in suffixes)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIR_NAMES)
        for name in sorted(filenames):
            if name.lower().endswith(suffixes):
                out.append(Path(dirpath) / name)
    return out


def iter_swift_files(ios_root):
    return find_files(ios_root, (".swift",))


# ---------------------------------------------------------------------------
# 文本读取与编码检查
# ---------------------------------------------------------------------------

@dataclass
class TextFile:
    path: Path
    text: str
    encoding: str = "utf-8"
    has_bom: bool = False
    crlf_lines: int = 0
    lf_lines: int = 0
    read_error: str = ""


def read_text_file(path: Path) -> TextFile:
    """读取文本文件并检测编码 / BOM / CRLF。非 UTF-8 用容错解码但记录编码名。"""
    raw = Path(path).read_bytes()
    has_bom = raw.startswith(b"\xef\xbb\xbf")
    encoding = "utf-8"
    text = ""
    error = ""
    candidates = ["utf-8"]
    if has_bom:
        candidates = ["utf-8-sig"]
    for enc in candidates:
        try:
            text = raw.decode(enc)
            encoding = enc
            break
        except UnicodeDecodeError:
            continue
    if not text:
        for enc in ("gbk", "gb18030", "utf-16", "latin-1"):
            try:
                text = raw.decode(enc)
                encoding = enc
                break
            except Exception:
                continue
        if not text:
            text = raw.decode("latin-1", errors="replace")
            encoding = "latin-1"
            error = "无法按 UTF-8/GBK 解码"
    crlf = text.count("\r\n")
    lf = text.count("\n") - crlf
    return TextFile(Path(path), text, encoding, has_bom, crlf, lf, error)


# ---------------------------------------------------------------------------
# Swift 简易词法状态机
# ---------------------------------------------------------------------------

@dataclass
class StringSpan:
    """字符串字面量的内容区间 [start, end)（不含引号；多行字符串不含三引号）。"""
    start: int
    end: int
    multiline: bool = False


class SwiftLexResult:
    def __init__(self, src: str):
        self.src = src
        n = len(src)
        code = bytearray(n)
        strings: list[StringSpan] = []
        # 帧栈：code 帧（interp 标记是否在插值中，paren 记录括号深度）与 string 帧
        frames: list[dict] = [{"kind": "code", "interp": False, "paren": 0}]
        i = 0
        while i < n:
            frame = frames[-1]
            if frame["kind"] == "string":
                hashes = frame["hashes"]
                multiline = frame["multiline"]
                c = src[i]
                if c == "\\":
                    j = i + 1
                    h = 0
                    while h < hashes and j < n and src[j] == "#":
                        h += 1
                        j += 1
                    if h == hashes and j < n and src[j] == "(":
                        # 字符串插值：进入 code 帧，起始括号深度 1（外层 ( 不参与平衡计数）
                        frames.append({"kind": "code", "interp": True, "paren": 1})
                        i = j + 1
                        continue
                    i = min(n, j + 1)
                    continue
                if multiline:
                    if src.startswith('"""', i):
                        j = i + 3
                        h = 0
                        while h < hashes and j < n and src[j] == "#":
                            h += 1
                            j += 1
                        if h == hashes:
                            strings.append(StringSpan(frame["content_start"], i, True))
                            frames.pop()
                            i = j
                            continue
                    i += 1
                    continue
                else:
                    if c == '"':
                        j = i + 1
                        h = 0
                        while h < hashes and j < n and src[j] == "#":
                            h += 1
                            j += 1
                        if h == hashes:
                            strings.append(StringSpan(frame["content_start"], i, False))
                            frames.pop()
                            i = j
                            continue
                    if c == "\n":
                        # 未终止的单行字符串：容错恢复
                        strings.append(StringSpan(frame["content_start"], i, False))
                        frames.pop()
                        i += 1
                        continue
                    i += 1
                    continue

            # ---- code 帧 ----
            c = src[i]
            if c == "/" and i + 1 < n and src[i + 1] == "/":
                j = src.find("\n", i)
                i = n if j < 0 else j
                continue
            if c == "/" and i + 1 < n and src[i + 1] == "*":
                depth = 1
                j = i + 2
                while j < n and depth > 0:
                    if src.startswith("/*", j):
                        depth += 1
                        j += 2
                    elif src.startswith("*/", j):
                        depth -= 1
                        j += 2
                    else:
                        j += 1
                i = j
                continue
            if c == '"':
                multiline = src.startswith('"""', i)
                start = i + (3 if multiline else 1)
                frames.append({"kind": "string", "hashes": 0, "multiline": multiline,
                               "content_start": start})
                i = start
                continue
            if c == "#":
                k = i
                while k < n and src[k] == "#":
                    k += 1
                if k < n and src[k] == '"':
                    hashes = k - i
                    multiline = src.startswith('"""', k)
                    start = k + (3 if multiline else 1)
                    frames.append({"kind": "string", "hashes": hashes,
                                   "multiline": multiline, "content_start": start})
                    i = start
                    continue
                code[i] = 1
                i += 1
                continue
            # 插值帧的括号跟踪
            if frame.get("interp"):
                if c == "(":
                    frame["paren"] += 1
                elif c == ")":
                    frame["paren"] -= 1
                    if frame["paren"] == 0:
                        frames.pop()
                        i += 1
                        continue
            code[i] = 1
            i += 1

        # 文件结束仍未闭合的字符串
        while len(frames) > 1:
            fr = frames.pop()
            if fr["kind"] == "string":
                strings.append(StringSpan(fr["content_start"], n, fr["multiline"]))

        self.code = bytes(code)
        self.strings = strings
        # 供正则使用的"掩码源码"：注释/字符串内容替换为空格（保留换行，偏移不变）
        masked = []
        for idx in range(n):
            if code[idx]:
                masked.append(src[idx])
            else:
                masked.append("\n" if src[idx] == "\n" else " ")
        self.masked = "".join(masked)
        self._line_starts = [0]
        for idx, ch in enumerate(src):
            if ch == "\n":
                self._line_starts.append(idx + 1)

        # 字符串内容起点索引，便于"Text(\"...\")"取文案
        self.span_by_start = {}
        self.span_by_cover = {}
        for sp in strings:
            self.span_by_start.setdefault(sp.start, sp)
            self.span_by_cover.setdefault(sp.start - 4, sp)  # 容错：""" 或 #"

    def line_of(self, offset: int) -> int:
        """偏移 → 1 基行号。"""
        return bisect.bisect_right(self._line_starts, offset)

    def line_text(self, offset: int) -> str:
        ln = self.line_of(offset)
        start = self._line_starts[ln - 1]
        end = self._line_starts[ln] - 1 if ln < len(self._line_starts) else len(self.src)
        return self.src[start:end].rstrip("\r")

    def string_at(self, quote_offset: int) -> StringSpan | None:
        """给定引号起始偏移，返回对应字符串片段（支持 "..." / \"\"\"...\"\"\" / #\"...\"#）。"""
        src = self.src
        q = quote_offset
        hashes = 0
        while q > 0 and src[q] == "#":
            q -= 1
        while q + hashes < len(src) and src[q + hashes] == "#":
            hashes += 1
        if q < 0 or q >= len(src) or src[q] != '"':
            return None
        if src.startswith('"""', q):
            start = q + 3 + hashes
            for sp in self.strings:
                if sp.start == start and sp.multiline:
                    return sp
            return None
        start = q + 1
        return self.span_by_start.get(start)


def lex_swift(src: str) -> SwiftLexResult:
    return SwiftLexResult(src)


# ---------------------------------------------------------------------------
# 问题模型与报告
# ---------------------------------------------------------------------------

SEV_ORDER = {"P0": 0, "P1": 1, "P2": 2, "INFO": 3}
SEV_TITLE = {"P0": "P0 · 阻断（必须修复，无法编译/审核风险）",
             "P1": "P1 · 严重（影响功能或质量，发布前修复）",
             "P2": "P2 · 建议（风格/可维护性/误报待确认）",
             "INFO": "INFO · 提示"}


def _supports_color() -> bool:
    if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
        return False
    if os.name == "nt":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)
            mode = ctypes.c_uint32()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)) == 0:
                return False
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
            return True
        except Exception:
            return False
    return True


_COLOR = _supports_color()
_ANSI = {
    "reset": "\033[0m", "bold": "\033[1m", "dim": "\033[2m",
    "red": "\033[31m", "yellow": "\033[33m", "cyan": "\033[36m",
    "green": "\033[32m", "magenta": "\033[35m", "grey": "\033[90m",
}
_SEV_COLOR = {"P0": "red", "P1": "yellow", "P2": "cyan", "INFO": "grey"}


def c(text: str, color: str = "", bold: bool = False) -> str:
    if not _COLOR:
        return text
    prefix = _ANSI.get(color, "")
    if bold:
        prefix = _ANSI["bold"] + prefix
    return f"{prefix}{text}{_ANSI['reset']}" if prefix else text


@dataclass
class Issue:
    severity: str          # P0 / P1 / P2 / INFO
    code: str              # 规则编号，如 BRACKET-UNCLOSED
    file: str              # 相对路径
    line: int              # 1 基行号，0 表示文件级
    message: str
    hint: str = ""

    def sort_key(self):
        return (SEV_ORDER.get(self.severity, 9), self.file, self.line, self.code)


class Report:
    def __init__(self, title: str, root: Path | None = None):
        self.title = title
        self.root = root or REPO_ROOT
        self.issues: list[Issue] = []
        self.warnings: list[str] = []
        self.stats: dict[str, object] = {}
        self.started_at = datetime.now()

    # -- 记录 ---------------------------------------------------------------
    def add(self, severity: str, code: str, file, line: int, message: str, hint: str = ""):
        self.issues.append(Issue(severity, code,
                                 file if isinstance(file, str) else rel(file),
                                 int(line), message, hint))

    def warn(self, message: str):
        self.warnings.append(message)

    # -- 统计 ---------------------------------------------------------------
    def count(self, severity: str) -> int:
        return sum(1 for it in self.issues if it.severity == severity)

    def counts(self) -> dict[str, int]:
        return {s: self.count(s) for s in ("P0", "P1", "P2", "INFO")}

    def exit_code(self) -> int:
        if self.count("P0"):
            return 2
        if self.count("P1"):
            return 1
        return 0

    def verdict(self) -> str:
        p0, p1 = self.count("P0"), self.count("P1")
        if p0:
            return f"不通过（存在 {p0} 个 P0，必须修复）"
        if p1:
            return f"有条件通过（存在 {p1} 个 P1，发布前修复）"
        return "通过（无 P0/P1）"

    def sorted_issues(self, severity: str | None = None):
        items = self.issues if severity is None else [i for i in self.issues if i.severity == severity]
        return sorted(items, key=lambda i: i.sort_key())

    # -- 终端输出 -----------------------------------------------------------
    def print_console(self, show_p2: int = 40, show_info: bool = False):
        line = "=" * 78
        print(c(line, "grey"))
        print(c(f" {self.title}", bold=True))
        print(f" 仓库根目录: {self.root}")
        print(f" 执行时间  : {self.started_at.strftime('%Y-%m-%d %H:%M:%S')}")
        if self.stats:
            print(" 扫描统计  : " + " | ".join(f"{k}={v}" for k, v in self.stats.items()))
        print(c(line, "grey"))

        if self.warnings:
            for w in self.warnings:
                print(c(f"[WARNING] {w}", "yellow"))

        shown = {"P0": 10 ** 9, "P1": 10 ** 9, "P2": max(0, show_p2)}
        any_issue = False
        for sev in ("P0", "P1", "P2", "INFO"):
            items = self.sorted_issues(sev)
            if not items or (sev == "INFO" and not show_info):
                continue
            any_issue = True
            print()
            print(c(f"── {SEV_TITLE[sev]}：{len(items)} 条 " + "─" * 20, _SEV_COLOR[sev], bold=True))
            limit = shown.get(sev, 40)
            for it in items[:limit]:
                loc = f"{it.file}:{it.line}" if it.line else it.file
                print(f"[{it.severity}] {c(it.code, 'magenta')}  {c(loc, 'cyan')}")
                print(f"      {it.message}")
                if it.hint:
                    print(c(f"      → 建议: {it.hint}", "grey"))
            if len(items) > limit:
                print(c(f"      … 其余 {len(items) - limit} 条已省略（加 --all 显示全部）", "grey"))

        if not any_issue:
            print()
            print(c("未发现任何问题。", "green"))

        print()
        print(c(line, "grey"))
        counts = self.counts()
        summary = (f"文件 {self.stats.get('files', '-')} | 行数 {self.stats.get('lines', '-')} | "
                   f"P0={counts['P0']} P1={counts['P1']} P2={counts['P2']}")
        print(summary)
        print(c(f"结论: {self.verdict()}", "red" if counts["P0"] else ("yellow" if counts["P1"] else "green"),
                bold=True))
        print(c(line, "grey"))

    # -- JSON ---------------------------------------------------------------
    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "root": str(self.root),
            "generated_at": self.started_at.isoformat(timespec="seconds"),
            "stats": self.stats,
            "counts": self.counts(),
            "verdict": self.verdict(),
            "exit_code": self.exit_code(),
            "warnings": self.warnings,
            "issues": [vars(it) for it in self.sorted_issues()],
        }

    def print_json(self):
        print(json.dumps(self.to_dict(), ensure_ascii=False, indent=2))

    # -- Markdown -----------------------------------------------------------
    def to_markdown(self, heading_level: int = 2) -> str:
        h = "#" * heading_level
        counts = self.counts()
        out = [f"{h} {self.title}", "",
               f"- 生成时间：{self.started_at.strftime('%Y-%m-%d %H:%M:%S')}",
               f"- 仓库根：`{self.root}`",
               f"- 统计：{('、'.join(f'{k}={v}' for k, v in self.stats.items())) or '—'}",
               f"- 结论：**{self.verdict()}**（P0={counts['P0']}，P1={counts['P1']}，P2={counts['P2']}）",
               ""]
        for sev in ("P0", "P1", "P2"):
            items = self.sorted_issues(sev)
            out.append(f"{h}# {sev}（{len(items)} 条）")
            out.append("")
            if not items:
                out.append("无。")
                out.append("")
                continue
            out.append("| # | 位置 | 问题 | 建议 | 规则 |")
            out.append("|---|---|---|---|---|")
            for idx, it in enumerate(items, 1):
                loc = f"`{it.file}:{it.line}`" if it.line else f"`{it.file}`"
                msg = it.message.replace("|", "\\|").replace("\n", " ")
                hint = (it.hint or "—").replace("|", "\\|").replace("\n", " ")
                out.append(f"| {idx} | {loc} | {msg} | {hint} | `{it.code}` |")
            out.append("")
        if self.warnings:
            out.append(f"{h}# 警告")
            out.append("")
            for w in self.warnings:
                out.append(f"- {w}")
            out.append("")
        return "\n".join(out)


# ---------------------------------------------------------------------------
# 命令行小工具
# ---------------------------------------------------------------------------

def add_common_args(parser, default_root: Path = REPO_ROOT):
    parser.add_argument("--root", default=str(default_root),
                        help=f"仓库根目录（默认 {default_root}）")
    parser.add_argument("--json", action="store_true", help="以 JSON 输出（便于 Lead 汇总）")
    parser.add_argument("--md", metavar="PATH", default=None,
                        help="把本脚本报告写成 Markdown 文件（用于拼装 docs/06-QA报告.md）")
    parser.add_argument("--all", action="store_true", help="终端显示全部条目（默认 P2 只显示前 40 条）")
    parser.add_argument("--no-color", action="store_true", help="禁用彩色输出")
    return parser


def finish(report: Report, args) -> int:
    """统一收尾：输出（终端/JSON/Markdown）并返回退出码。"""
    global _COLOR
    if getattr(args, "no_color", False):
        _COLOR = False
    if getattr(args, "json", False):
        report.print_json()
    else:
        report.print_console(show_p2=10 ** 9 if getattr(args, "all", False) else 40)
    md_path = getattr(args, "md", None)
    if md_path:
        p = Path(md_path)
        if not p.is_absolute():
            p = Path.cwd() / p
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(report.to_markdown(), encoding="utf-8")
        print(f"\n[Markdown 报告已写入] {p}")
    return report.exit_code()


def main_guard(fn):
    """包裹脚本 main()，把未捕获异常降级成可读错误（退出码 3）。"""
    def wrapper(argv=None):
        try:
            code = fn(argv)
        except SystemExit:
            raise
        except Exception as exc:  # noqa: BLE001
            import traceback
            print(f"[脚本内部错误] {type(exc).__name__}: {exc}", file=sys.stderr)
            traceback.print_exc()
            return 3
        return 0 if code is None else code
    return wrapper
