#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""link_check.py —— 文档路径/链接真实性校验（墨语 iOS 输入法 · QA）

用途
----
`docs/04-安装与续签指南.md`、`README.md`、`docs/00-待确认问题.md` 等文档里会大量
提到仓库中的真实文件（`design/tokens.json`、`ios/Config/Base.xcconfig`、脚本名…）。
一旦文档提到的文件不存在，用户照着做就会"走到半路发现没这个东西"，非常掉分。

本脚本扫描指定 Markdown/文本文件，抽出所有"看起来像仓库内路径"的片段，逐个检查：

  1. Markdown 链接 `[label](path)` —— 相对路径按**该 Markdown 文件所在目录**解析
  2. 行内代码里的仓库路径 `` `ios/Config/Base.xcconfig` `` —— 按**仓库根**解析
  3. 目录树代码块里的 `├── xxx/`（可选，默认关闭）

并按**严重度**分级：
  - P1 LINK-MISSING   ：明确写成「文件路径」且带扩展名（`.swift/.json/.md/.py/.yml/.plist/.xcconfig`…）但不存在
  - P2 LINK-MISSING-DIR：以 `/` 结尾的**目录**不存在
  - P2 LINK-MISSING-REL：Markdown 链接目标不存在（相对该 md 文件解析）
  - P2 LINK-UNVERIFIABLE：提到了但无法判断（含占位符 `<...>`、`你的名字`、外部 URL 等）

同时会输出「**反向检查**」：仓库里存在的关键构件是否被文档提到（覆盖度提示），
以及「**未来文件**」白名单（阶段二才会落盘的东西），避免阶段一刷一堆假警报。

用法
----
    python scripts/qa/link_check.py                     # 检查默认文档集合
    python scripts/qa/link_check.py docs/04-安装与续签指南.md
    python scripts/qa/link_check.py --all               # 检查 docs/ 下全部 md + README
    python scripts/qa/link_check.py --strict            # P2 也算失败（退出码 1）
    python scripts/qa/link_check.py --json              # 输出 JSON
    python scripts/qa/link_check.py --md out.md         # 输出 Markdown 报告

退出码：0 = 无问题（或仅有 --strict 关闭时的 P2）；1 = 有 P1；2 = 有 P0（本脚本不产生 P0）；3 = 内部错误

设计原则
--------
* **零误报优先**：识别不出是不是路径的一律跳过，不做模糊猜测。
* 允许**未来文件白名单**（`FUTURE_OK`）：阶段二才落盘的构件单独列在报告末尾，
  不打扰 P0/P1/P2 计数，但会明确打印"以下路径文档已引用、仓库暂未落盘"。
* 纯标准库，无第三方依赖；Windows 控制台 UTF-8 已由 qa_common 修复。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass, field

# 允许脚本被 `python scripts/qa/link_check.py` 直接运行时找到同目录的 qa_common
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import qa_common as qc  # noqa: E402

REPO_ROOT = qc.REPO_ROOT

# ---------------------------------------------------------------------------
# 配置区
# ---------------------------------------------------------------------------

#: 默认要检查的文档（相对仓库根）。文件不存在则跳过并警告。
DEFAULT_DOCS = [
    "README.md",
    "docs/00-待确认问题.md",
    "docs/04-安装与续签指南.md",
    "docs/05-常见问题.md",
]

#: 被视为「文件」的扩展名（出现这些才按文件强校验）
FILE_EXTS = {
    ".swift", ".json", ".md", ".py", ".yml", ".yaml", ".plist", ".xcconfig",
    ".entitlements", ".xcodeproj", ".xcworkspace", ".sh", ".txt", ".pbxproj",
    ".png", ".jpg", ".jpeg", ".svg", ".pdf", ".ipa", ".zip", ".js", ".ts",
    ".c", ".h", ".m", ".mm", ".html", ".css",
}

#: 明显不是仓库内路径的片段（URL、绝对路径、占位符）—— 直接跳过
SKIP_PATTERNS = [
    re.compile(r"^(?:https?|ftp|mailto):", re.I),
    # 省略协议头的域名（`developer.apple.com/library/.../CustomKeyboard.html`、
    # `github.com/hkgood/OSGKeyboard`）：判断依据是「第一段含点、且点后直接接斜杠」，
    # 因此 `README.md` / `design/tokens.json` 这类真文件引用不会被误跳过。
    re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?=/)", re.I),
    re.compile(r"^[A-Za-z]:[\\/]"),          # C:\...  Windows 绝对路径
    re.compile(r"^\\\\"),                     # UNC 路径
    re.compile(r"^/"),                        # Unix 绝对路径
    re.compile(r"[<>]"),                       # <你的用户名> 之类占位符
    re.compile(r"[(（]"),                       # 括号说明
    re.compile(r"\s"),                         # 含空格（多半是句子）
    re.compile(r"^\.\.?$"),                    # . / ..
    re.compile(r"^\$"),                        # $PRODUCT_MODULE_NAME
    re.compile(r"^(?:Payload|ipa_check|build|DerivedData)[\\/]", re.I),
]

#: 文档里合法提到、但当前仓库确实还没有的路径 —— 不算错，单独提示。
#: 维护方式：某个文件落盘后，就把它从这张表里删掉。
FUTURE_OK = {
    "ios/AIKeyboard.xcodeproj",
    "ios/AIKeyboard.xcodeproj/project.pbxproj",
    "ios/AIKeyboard.xcodeproj/xcshareddata",
    ".github/workflows/build.yml",
    ".github/workflows",
    "ios/AIKeyboardExtension",
    "ios/Shared/IMECore",
    "ios/Shared/Storage",
    "design/03-设计与交互规范.md",
    "design/03-视觉设计规范.md",
    "docs/06-QA报告.md",
}

#: 这些片段是「相对于某个子目录」或「IPA / 工程包内部」的路径，不是仓库路径。
#: 文档里出现它们属于正常描述（如「解压后看 Payload/AIKeyboard.app/PlugIns/…」）。
RELATIVE_FRAGMENT_PREFIXES = (
    "xcshareddata/",
    "PlugIns/",
    "Payload/",
    "ipa_check/",
    "DerivedData/",
    "build/",
)

#: 允许「省略前缀」的源码根。文档表格里常写 `Support/ViewCompat.swift` 这种
#: 相对某个 target 目录的片段（省略 `ios/AIKeyboard/`）。检查时会把这些前缀
#: 依次拼上去试，能命中就说明只是缩写，不算死链（只记 INFO）。
FRAGMENT_ROOTS = (
    "",
    "ios/AIKeyboard/",
    "ios/AIKeyboardExtension/",
    "ios/Shared/",
    "ios/Config/",
    "ios/Resources/",
    "scripts/",
    "docs/",
    "design/",
    "tools/",
    ".github/",
)

#: 反向检查：这些关键构件应当在文档里被提到（缺了说明文档覆盖不全）
SHOULD_MENTION = [
    "design/tokens.json",
    "docs/04-安装与续签指南.md",
    "docs/05-常见问题.md",
    "ios/Config/Extension-Info.plist",
]

RE_MD_LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
RE_INLINE_CODE = re.compile(r"`([^`\n]{2,120})`")
RE_PATHLIKE = re.compile(
    r"^(?:[A-Za-z0-9_.\-\u4e00-\u9fff]+/[A-Za-z0-9_.\-\u4e00-\u9fff]+.*)$"
)
#: 目录树代码块：只认 `├──` / `└──` 连接的树行（README 里另有 ASCII 架构图用 `──▶`，
#: 不能用 `──` 泛匹配，否则会把架构图解析成一堆假路径）。
RE_TREE_LINE = re.compile(r"^(?P<prefix>[│├└─\s]*)[├└]──\s*(?P<name>.+?)\s*$")
RE_FENCE = re.compile(r"^\s*```")
#: 树节点名后面的中文注解（`← 说明` / `# 说明` / 两个以上空格后的说明 / 全角括号说明）
RE_TREE_ANNOT = re.compile(r"(?:\s+←.*$)|(?:\s+#.*$)|(?:\s{2,}\S.*$)|(?:\s*（.*?）\s*$)")

#: 仓库的一级目录/文件。只有首层命中这些名的代码块才当「仓库目录树」解析；
#: 否则（如 docs/04 里的 IPA 包结构图 `AIKeyboard.app/…`、架构图）一律跳过。
KNOWN_TOP_LEVEL = {
    "README.md", ".github", "docs", "design", "ios", "scripts", "tools",
}



# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------

@dataclass
class Ref:
    """文档里出现的一处路径引用。"""
    doc: str            # 相对仓库根的文档路径
    line: int
    raw: str            # 原文
    kind: str           # "md-link" / "inline-code"
    resolved: str       # 解析后的仓库相对路径（POSIX 风格）
    is_dir: bool = False
    skipped: str = ""   # 非空表示跳过原因


@dataclass
class LinkReport:
    """汇总结果。"""
    refs: list[Ref] = field(default_factory=list)
    missing_file: list[Ref] = field(default_factory=list)
    missing_dir: list[Ref] = field(default_factory=list)
    missing_rel_link: list[Ref] = field(default_factory=list)
    future: list[Ref] = field(default_factory=list)
    fragments: list[Ref] = field(default_factory=list)
    unverifiable: list[Ref] = field(default_factory=list)
    docs_checked: list[str] = field(default_factory=list)
    docs_missing: list[str] = field(default_factory=list)

    @property
    def p1_count(self) -> int:
        return len(self.missing_file) + len(self.missing_rel_link)

    @property
    def p2_count(self) -> int:
        return len(self.missing_dir)


# ---------------------------------------------------------------------------
# 路径抽取
# ---------------------------------------------------------------------------

def _norm(p: str) -> str:
    """把任意路径片段规范化为仓库相对 POSIX 路径。"""
    p = p.strip().strip("`").strip()
    p = p.replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    # 去掉锚点 / 查询串
    p = re.split(r"[#?]", p, maxsplit=1)[0]
    return p.strip("/") if p.endswith("/") else p


def _should_skip(raw: str) -> str:
    """返回跳过原因；空串表示不跳过。"""
    s = raw.strip()
    if not s or len(s) < 3:
        return "太短"
    for pat in SKIP_PATTERNS:
        if pat.search(s):
            return "形似 URL / 绝对路径 / 占位符"
    if "*" in s:
        return "通配符 / glob 模式，无法逐字校验"
    if s.replace("\\", "/").startswith(RELATIVE_FRAGMENT_PREFIXES):
        return "相对子目录 / IPA 包内片段，不是仓库路径"
    if not RE_PATHLIKE.match(s.replace("\\", "/")):
        return "不像仓库内相对路径"
    return ""


def _looks_like_path(s: str) -> bool:
    """是否像一个仓库内相对路径（含 / 且首段不是纯中文句子）。"""
    if "/" not in s and "." not in s:
        return False
    ext = os.path.splitext(s.rstrip("/"))[1].lower()
    if ext in FILE_EXTS:
        return True
    if s.endswith("/"):
        return True
    # 目录/工程名形态：ios/AIKeyboard.xcodeproj
    return bool(re.search(r"\.[A-Za-z0-9]{2,10}$", s))


def extract_refs(doc_rel: str, text: str) -> list[Ref]:
    """从一个文档的正文里抽出所有路径引用。"""
    out: list[Ref] = []
    doc_dir = os.path.dirname(doc_rel).replace("\\", "/")

    for i, line in enumerate(text.splitlines(), start=1):
        # a) Markdown 链接：按文档所在目录解析
        for m in RE_MD_LINK.finditer(line):
            target = m.group(1).strip()
            reason = _should_skip(target)
            if reason:
                continue
            if not _looks_like_path(target):
                continue
            base = target if target.startswith(("/", "\\")) else os.path.join(doc_dir, target)
            resolved = _norm(os.path.normpath(base).replace("\\", "/"))
            out.append(Ref(doc=doc_rel, line=i, raw=target, kind="md-link",
                           resolved=resolved, is_dir=target.endswith("/")))

        # b) 行内代码：按仓库根解析（文档里通常写全路径）
        for m in RE_INLINE_CODE.finditer(line):
            target = m.group(1).strip()
            reason = _should_skip(target)
            if reason:
                continue
            if not _looks_like_path(target):
                continue
            norm = _norm(target)
            if not norm:
                continue
            # 行内代码里的相对片段（如 `Config/App.xcconfig`）按仓库根也找不到，
            # 但只要首段在仓库根存在就算有效；否则仍按仓库根校验。
            out.append(Ref(doc=doc_rel, line=i, raw=target, kind="inline-code",
                           resolved=norm, is_dir=target.endswith("/")))

    # c) 目录树代码块：按缩进还原层级后整体校验
    out.extend(extract_tree_refs(doc_rel, text))
    return out


def extract_tree_refs(doc_rel: str, text: str) -> list[Ref]:
    """从目录树代码块（`├── xxx/`）里抽出路径，按缩进还原层级后整体校验。

    README 的「目录结构」是一个 ```text 代码块，里面的条目不是反引号路径，
    前两条正则都抽不到；但恰恰是这里最容易写出"文档有、仓库没有"的假目录。

    只解析**根节点是仓库一级目录**的代码块（`README.md` / `docs` / `ios` …）；
    docs/04 里画的是「解压后的 IPA 包结构」（`Payload/`、`AIKeyboard.app/`），
    不是仓库目录树，必须排除，否则会刷一堆假死链。
    """
    lines = text.splitlines()
    blocks: list[list[tuple[int, str]]] = []   # [(行号, 原文行)]
    cur: list[tuple[int, str]] = []
    in_fence = False
    for i, line in enumerate(lines, start=1):
        if RE_FENCE.match(line):
            if in_fence and cur:
                blocks.append(cur)
            cur = []
            in_fence = not in_fence
            continue
        if in_fence:
            cur.append((i, line))
    if cur:
        blocks.append(cur)

    out: list[Ref] = []
    for block in blocks:
        rows: list[tuple[int, int, str, str]] = []
        for lineno, line in block:
            m = RE_TREE_LINE.match(line)
            if not m:
                continue
            raw_name = m.group("name").strip()
            name = RE_TREE_ANNOT.sub("", raw_name).strip()
            name = name.replace("\\", "/").strip("/")
            if not name:
                continue
            depth = len(m.group("prefix").expandtabs(4)) // 4
            rows.append((lineno, depth, name, raw_name))
        if not rows:
            continue
        # 根节点必须是仓库一级条目，否则这个块不是仓库目录树
        first_depth = min(r[1] for r in rows)
        roots = {r[2] for r in rows if r[1] == first_depth}
        if not (roots & KNOWN_TOP_LEVEL):
            continue

        stack: list[tuple[int, str]] = []
        for lineno, depth, name, raw_name in rows:
            stack = [s for s in stack if s[0] < depth]
            stack.append((depth, name))
            resolved = "/".join(s[1] for s in stack)
            out.append(Ref(doc=doc_rel, line=lineno, raw=raw_name,
                           kind="tree", resolved=resolved,
                           is_dir=raw_name.endswith(("/", "\\"))))
    return out


# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

def check_ref(ref: Ref, root: str) -> None:
    """判断一个引用是否真实存在，结果落到 report 时再分流。"""
    abs_path = os.path.join(root, ref.resolved.replace("/", os.sep))
    if os.path.exists(abs_path):
        return
    if ref.resolved in FUTURE_OK:
        ref.skipped = "future"
        return
    # 前缀落在 FUTURE_OK 里也算未来文件（如 ios/AIKeyboardExtension/Views/Xxx.swift）
    for fut in FUTURE_OK:
        if ref.resolved.startswith(fut.rstrip("/") + "/"):
            ref.skipped = "future"
            return
    # 缩写片段：文档表格里常写 `Support/ViewCompat.swift`（省略 `ios/AIKeyboard/`）。
    # 依次补各源码根试一遍，命中即认为只是缩写，不算死链。
    for prefix in FRAGMENT_ROOTS:
        if not prefix:
            continue
        cand = prefix + ref.resolved
        if os.path.exists(os.path.join(root, cand.replace("/", os.sep))):
            ref.skipped = "fragment"
            ref.resolved = cand          # 记录补全后的真实路径，便于阅读
            return


def run(docs: list[str], root: str = REPO_ROOT,
        strict: bool = False) -> LinkReport:
    rep = LinkReport()
    seen: set[tuple[str, str]] = set()

    for doc in docs:
        abs_doc = os.path.join(root, doc.replace("/", os.sep))
        if not os.path.isfile(abs_doc):
            rep.docs_missing.append(doc)
            continue
        rep.docs_checked.append(doc)
        tf = qc.read_text_file(abs_doc)
        if tf.read_error:
            continue
        for ref in extract_refs(doc, tf.text):
            key = (ref.doc, ref.resolved)
            if key in seen:
                continue
            seen.add(key)
            check_ref(ref, root)
            rep.refs.append(ref)
            if ref.skipped == "future":
                rep.future.append(ref)
                continue
            if ref.skipped == "fragment":
                rep.fragments.append(ref)
                continue
            abs_path = os.path.join(root, ref.resolved.replace("/", os.sep))
            if os.path.exists(abs_path):
                continue
            if ref.kind == "md-link":
                rep.missing_rel_link.append(ref)
            elif ref.is_dir:
                rep.missing_dir.append(ref)
            else:
                ext = os.path.splitext(ref.resolved)[1].lower()
                if ext in FILE_EXTS:
                    rep.missing_file.append(ref)
                else:
                    rep.unverifiable.append(ref)
    return rep


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def render_console(rep: LinkReport, strict: bool = False) -> str:
    lines: list[str] = []
    bar = "=" * 78
    total_refs = len(rep.refs)
    lines.append(bar)
    lines.append(" 墨语 iOS 输入法 · 文档路径真实性校验（link_check.py）")
    lines.append(f" 仓库根目录: {REPO_ROOT}")
    lines.append(f" 检查文档  : {len(rep.docs_checked)} 份 | 提取路径引用: {total_refs} 处 "
                 f"| 未来文件(白名单): {len(rep.future)}")
    if rep.docs_missing:
        lines.append(f" 未找到文档: {', '.join(rep.docs_missing)}")
    lines.append(bar)
    lines.append("")

    def section(title: str, items: list[Ref], sev: str) -> None:
        if not items:
            return
        lines.append(f"── {sev} · {title}（{len(items)} 条）")
        for r in items:
            lines.append(f"[{sev}] LINK-MISSING  {r.doc}:{r.line}")
            lines.append(f"      引用原文: {r.raw}（{r.kind}）")
            lines.append(f"      解析为  : {r.resolved}")
            lines.append("      → 建议: 修正文档路径，或把该文件补进仓库，"
                         "或（阶段二才落盘）加入 FUTURE_OK 白名单")
        lines.append("")

    section("文档提到的文件不存在", rep.missing_file, "P1")
    section("Markdown 相对链接目标不存在", rep.missing_rel_link, "P1")
    section("文档提到的目录不存在", rep.missing_dir, "P2")

    if rep.unverifiable:
        lines.append(f"── INFO · 无法判断是否路径（{len(rep.unverifiable)} 条，不计分）")
        for r in rep.unverifiable[:20]:
            lines.append(f"[INFO] {r.doc}:{r.line}  {r.raw}")
        if len(rep.unverifiable) > 20:
            lines.append(f"[INFO] … 其余 {len(rep.unverifiable) - 20} 条省略")
        lines.append("")

    if rep.fragments:
        lines.append(f"── INFO · 缩写片段（已自动补全到真实路径，不计分，{len(rep.fragments)} 条）")
        for r in rep.fragments[:20]:
            lines.append(f"[INFO] {r.doc}:{r.line}  {r.raw}  →  {r.resolved}")
        if len(rep.fragments) > 20:
            lines.append(f"[INFO] … 其余 {len(rep.fragments) - 20} 条省略")
        lines.append("")

    if rep.future:
        lines.append(f"── 未来文件（文档已引用 · 仓库暂未落盘 · 不计分，{len(rep.future)} 条）")
        uniq = sorted({r.resolved for r in rep.future})
        for p in uniq:
            lines.append(f" · {p}")
        lines.append("")

    # 反向检查：关键构件是否被文档提到
    mentioned = {r.resolved for r in rep.refs}
    not_mentioned = [p for p in SHOULD_MENTION if p not in mentioned]
    if not_mentioned:
        lines.append("── 覆盖度提示：以下关键构件未在任何被检查文档中被提及")
        for p in not_mentioned:
            lines.append(f" · {p}")
        lines.append("")

    p1 = rep.p1_count
    p2 = rep.p2_count
    lines.append(bar)
    lines.append(f"引用 {total_refs} 处 | P1={p1} P2={p2} | 未来文件 {len(rep.future)} 处")
    if p1 == 0 and (p2 == 0 or not strict):
        verdict = "通过（无死链）"
    elif p1 == 0:
        verdict = "有条件通过（仅目录类 P2，可用 --strict 收紧）"
    else:
        verdict = "不通过（存在指向不存在文件的引用）"
    lines.append(f"结论: {verdict}")
    lines.append(bar)
    return "\n".join(lines)


def render_markdown(rep: LinkReport) -> str:
    out: list[str] = ["# 文档路径校验报告（link_check.py）", ""]
    out.append("| 指标 | 数值 |")
    out.append("|---|---|")
    out.append(f"| 检查文档 | {len(rep.docs_checked)} 份 |")
    out.append(f"| 路径引用总数 | {len(rep.refs)} 处 |")
    out.append(f"| P1（文件不存在） | {rep.p1_count} |")
    out.append(f"| P2（目录不存在） | {rep.p2_count} |")
    out.append(f"| 未来文件（白名单） | {len(rep.future)} |")
    out.append("")

    def tbl(title: str, items: list[Ref]) -> None:
        if not items:
            return
        out.append(f"## {title}（{len(items)} 条）")
        out.append("")
        out.append("| 位置 | 引用原文 | 解析路径 |")
        out.append("|---|---|---|")
        for r in items:
            out.append(f"| `{r.doc}:{r.line}` | `{r.raw}` | `{r.resolved}` |")
        out.append("")

    tbl("P1 · 文档提到的文件不存在", rep.missing_file)
    tbl("P1 · Markdown 链接目标不存在", rep.missing_rel_link)
    tbl("P2 · 目录不存在", rep.missing_dir)

    if rep.future:
        out.append("## 未来文件（文档已引用 · 仓库暂未落盘 · 不计分）")
        out.append("")
        for p in sorted({r.resolved for r in rep.future}):
            out.append(f"- `{p}`")
        out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="link_check.py",
        description="校验文档里提到的仓库路径是否真实存在（墨语 iOS 输入法 · QA）",
    )
    p.add_argument("docs", nargs="*", help="要检查的文档（相对仓库根）；省略则用默认集合")
    p.add_argument("--root", default=None, help="仓库根目录（默认自动探测）")
    p.add_argument("--all", action="store_true", help="检查 docs/ 下全部 md + README.md")
    p.add_argument("--strict", action="store_true", help="P2 也算失败（退出码 1）")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    p.add_argument("--md", metavar="PATH", default=None, help="把 Markdown 报告写到文件")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = os.path.abspath(args.root) if args.root else REPO_ROOT

    if args.docs:
        docs = args.docs
    elif args.all:
        docs = ["README.md"]
        docs_dir = os.path.join(root, "docs")
        if os.path.isdir(docs_dir):
            docs += sorted(
                f"docs/{n}" for n in os.listdir(docs_dir)
                if n.lower().endswith(".md")
            )
    else:
        docs = list(DEFAULT_DOCS)

    rep = run(docs, root=root, strict=args.strict)

    if args.md:
        md_path = args.md if os.path.isabs(args.md) else os.path.join(root, args.md)
        with open(md_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(render_markdown(rep))
        print(f"[link_check] Markdown 报告已写入: {md_path}")

    if args.json:
        import json
        payload = {
            "docs_checked": rep.docs_checked,
            "docs_missing": rep.docs_missing,
            "total_refs": len(rep.refs),
            "p1": rep.p1_count,
            "p2": rep.p2_count,
            "missing_file": [
                {"doc": r.doc, "line": r.line, "raw": r.raw, "resolved": r.resolved}
                for r in rep.missing_file
            ],
            "missing_rel_link": [
                {"doc": r.doc, "line": r.line, "raw": r.raw, "resolved": r.resolved}
                for r in rep.missing_rel_link
            ],
            "missing_dir": [
                {"doc": r.doc, "line": r.line, "raw": r.raw, "resolved": r.resolved}
                for r in rep.missing_dir
            ],
            "future": sorted({r.resolved for r in rep.future}),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_console(rep, strict=args.strict))

    if rep.p1_count > 0:
        return 1
    if args.strict and rep.p2_count > 0:
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:  # noqa: BLE001
        print(f"[link_check] 内部错误: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
