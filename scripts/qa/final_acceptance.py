#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 iOS 输入法 · 最终验收（final_acceptance.py）

一条命令串起全部 6 个闸门，汇总成一张表，给出明确的 GO / NO-GO 结论。

闸门顺序（任一 P0 即 NO-GO）：
    1. gen_xcodeproj.py --check     工程与磁盘是否同步
    2. validate_project.py          工程结构 85+ 项校验（ios-skeleton 维护）
    3. qa/project_check.py          pbxproj 结构（target / UUID / 文件归属）
    4. qa/static_check.py           Swift 静态检查（括号 / 分层 / 符号 / 编码 / 文案）
    5. qa/consistency_check.py      设计令牌 ↔ Theme.swift 一致性
    6. qa/link_check.py --all       文档路径死链

用法（Windows PowerShell）：
    python scripts\\qa\\final_acceptance.py
    python scripts\\qa\\final_acceptance.py --md docs\\06-QA报告.md --inject
    python scripts\\qa\\final_acceptance.py --fix        # 允许重跑生成器（会改 pbxproj）

退出码：
    0  GO（六闸门全绿）
    1  CONDITIONAL（无 P0，但有 P1 —— 需 Lead 逐条签收）
    2  NO-GO（存在 P0）
    3  脚本内部错误
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

# Windows 控制台默认 GBK，中文会乱码 —— 强制 UTF-8
for _stream_name in ("stdout", "stderr"):
    try:
        getattr(sys, _stream_name).reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass

REPO_ROOT = Path(__file__).resolve().parents[2]
PY = sys.executable

#: 单闸门超时（秒）。静态检查扫几百个文件也就几秒，600 秒足够宽松。
GATE_TIMEOUT = 600

#: docs/06 里自动注入区的标记
INJECT_START = "<!-- QA:FINAL:START -->"
INJECT_END = "<!-- QA:FINAL:END -->"


# ---------------------------------------------------------------------------
# 数据结构
# ---------------------------------------------------------------------------

@dataclass
class GateResult:
    """一个闸门的执行结果。"""
    key: str                      # 短代号，用于表格
    title: str                    # 中文名
    command: str                  # 实际执行的命令（便于复现）
    exit_code: int = -1
    ok: bool = False              # 是否通过（按各脚本自己的语义）
    p0: int = 0
    p1: int = 0
    p2: int = 0
    warning: int = 0
    verdict: str = ""             # 脚本自己给的结论
    detail: str = ""              # 关键补充说明
    stats: dict = field(default_factory=dict)
    stdout: str = ""
    stderr: str = ""
    elapsed: float = 0.0
    crashed: bool = False         # 脚本本身跑挂了（区别于"检查发现问题"）
    derived: bool = False         # P0 是否与其它闸门同源（pbxproj 漂移链）
    symbol_undefined: int = 0     # `SYMBOL-UNDEFINED` 条数（P0+P2 合计，一票否决指标）


# ---------------------------------------------------------------------------
# 执行工具
# ---------------------------------------------------------------------------

def _run(cmd: list[str]) -> tuple[int, str, str]:
    """跑一条命令，返回 (退出码, stdout, stderr)。绝不因非零退出码抛异常。"""
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=GATE_TIMEOUT,
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired:
        return -9, "", f"超时（>{GATE_TIMEOUT}s）"
    except FileNotFoundError as exc:
        return -1, "", f"命令不存在: {exc}"
    except Exception as exc:  # noqa: BLE001
        return -1, "", f"{type(exc).__name__}: {exc}"


def _parse_json(stdout: str) -> dict | None:
    """从 stdout 里抠出 JSON（脚本可能先打印几行提示）。"""
    text = stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    start = text.find("{")
    end = text.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None
    return None


def _tail(text: str, n: int = 12) -> str:
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-n:])


_RE_VALIDATE = re.compile(
    r"通过检查项\s*(\d+)\s*个\s*\|\s*P0=(\d+)\s*P1=(\d+)\s*WARNING=(\d+)"
)


def _sanitize(text: str) -> str:
    """把会污染 Markdown 的字符洗掉。

    关键原因：报告会被 `link_check.py` 再扫一遍。如果这里输出的「错误描述」
    里带反引号包裹的路径（反引号包住 `Foo/Xxx.swift`），下一轮 link_check 会把
    它当成一条新的路径引用 → 报假死链 → 注入 → 再报，形成自我引用的死循环。
    所以统一去掉反引号（路径仍可读，但不再被解析），并把 `|` 换成 `/`
    避免破坏 Markdown 表格的列。
    """
    if not text:
        return ""
    return text.replace("`", "").replace("|", "/")



# ---------------------------------------------------------------------------
# 六个闸门
# ---------------------------------------------------------------------------

def gate_gen(fix: bool = False) -> GateResult:
    """闸门 1：工程生成器与磁盘是否同步。"""
    g = GateResult(
        key="gen",
        title="工程生成器同步",
        command="python scripts/gen_xcodeproj.py --check",
    )
    t0 = time.time()

    if fix:
        # 显式授权才写 pbxproj（会覆盖 ios-skeleton 的生成物）
        code, out, err = _run([PY, "scripts/gen_xcodeproj.py"])
        if code != 0:
            g.exit_code = code
            g.crashed = True
            g.verdict = "生成器执行失败"
            g.detail = _tail(err or out)
            g.elapsed = time.time() - t0
            return g
        g.detail = "已重跑生成器（--fix）"

    code, out, err = _run([PY, "scripts/gen_xcodeproj.py", "--check"])
    g.exit_code = code
    g.stdout = out
    g.stderr = err
    g.elapsed = time.time() - t0

    if code == 0:
        g.ok = True
        g.verdict = "工程与磁盘一致"
        if not g.detail:
            g.detail = "pbxproj 与磁盘文件树同步"
    elif code == 1:
        g.ok = False
        g.p0 = 1
        g.verdict = "工程与磁盘不一致"
        drift = [ln.strip(" -") for ln in out.splitlines() if ln.strip().startswith("-")]
        g.detail = ("检测到漂移：" + "；".join(drift[:4])) if drift else "需要重跑 gen_xcodeproj.py"
    else:
        g.crashed = True
        g.verdict = "生成器无法运行"
        g.detail = _tail(err or out)
    return g


def gate_validate() -> GateResult:
    """闸门 2：validate_project.py（ios-skeleton 的 85+ 项结构校验）。"""
    g = GateResult(
        key="validate",
        title="工程结构校验",
        command="python scripts/validate_project.py",
    )
    t0 = time.time()
    code, out, err = _run([PY, "scripts/validate_project.py"])
    g.exit_code = code
    g.stdout = out
    g.stderr = err
    g.elapsed = time.time() - t0

    m = _RE_VALIDATE.search(out)
    if m:
        g.stats["checks_passed"] = int(m.group(1))
        g.p0 = int(m.group(2))
        g.p1 = int(m.group(3))
        g.warning = int(m.group(4))

    if code == 0 and g.p0 == 0:
        g.ok = True
        g.verdict = f"通过（{g.stats.get('checks_passed', '?')} 项）"
    elif code == 0:
        g.ok = True
        g.verdict = "通过"
    else:
        g.ok = False
        if g.p0 == 0:
            g.p0 = 1
        problems = [ln.strip() for ln in out.splitlines() if ln.strip().startswith("[P0]")]
        g.detail = problems[0][:220] if problems else _tail(err or out, 6)
    return g


def gate_qa(key: str, title: str, script: str, extra_args: list[str],
            p1_is_fail: bool = False) -> GateResult:
    """通用闸门：跑 qa/ 下带 --json 的脚本，读 counts。"""
    g = GateResult(key=key, title=title,
                   command="python scripts/qa/" + script + " " + " ".join(extra_args))
    t0 = time.time()
    code, out, err = _run([PY, f"scripts/qa/{script}"] + extra_args)
    g.exit_code = code
    g.stdout = out
    g.stderr = err
    g.elapsed = time.time() - t0

    payload = _parse_json(out)
    if payload is None:
        g.crashed = True
        g.verdict = "脚本无法解析输出"
        g.detail = _tail(err or out)
        return g

    counts = payload.get("counts") or {}
    g.p0 = int(counts.get("P0", 0))
    g.p1 = int(counts.get("P1", 0))
    g.p2 = int(counts.get("P2", 0))
    g.warning = len(payload.get("warnings") or [])
    g.verdict = str(payload.get("verdict") or "")
    g.stats = payload.get("stats") or {}
    g.ok = (g.p0 == 0) and not (p1_is_fail and g.p1 > 0)

    issues = payload.get("issues") or []
    # `SYMBOL-UNDEFINED` 单独计数：它是"一票否决"指标（见 docs/06 §9.2），
    # 无论当前判成 P0 还是 P2 `[粗查]`，冻结时都必须为 0。
    g.symbol_undefined = sum(
        1 for i in issues if i.get("code") == "SYMBOL-UNDEFINED")
    p0s = [i for i in issues if i.get("severity") == "P0"]
    if p0s:
        first = p0s[0]
        loc = f"{first.get('file', '?')}:{first.get('line', 0)}"
        g.detail = f"{first.get('code', '')} {loc} — {str(first.get('message', ''))[:160]}"
    return g


def gate_link() -> GateResult:
    """闸门 6：link_check.py --all（输出结构与 qa_common 的 Report 不同，单独处理）。"""
    g = GateResult(
        key="link",
        title="文档死链校验",
        command="python scripts/qa/link_check.py --all --json",
    )
    t0 = time.time()
    code, out, err = _run([PY, "scripts/qa/link_check.py", "--all", "--json"])
    g.exit_code = code
    g.stdout, g.stderr = out, err
    g.elapsed = time.time() - t0

    payload = _parse_json(out)
    if payload is None:
        g.crashed = True
        g.verdict = "脚本无法解析输出"
        g.detail = _tail(err or out)
        return g

    g.p0 = 0
    g.p1 = int(payload.get("p1", 0))
    g.p2 = int(payload.get("p2", 0))
    g.stats = {
        "docs_checked": len(payload.get("docs_checked") or []),
        "total_refs": payload.get("total_refs", 0),
        "future": len(payload.get("future") or []),
    }
    g.ok = g.p1 == 0
    g.verdict = "通过（无死链）" if g.ok else "存在死链"
    if not g.ok:
        bad = (payload.get("missing_file") or []) + (payload.get("missing_rel_link") or [])
        if bad:
            b = bad[0]
            # 注意：这里**不能**用反引号包路径 —— 否则 Markdown 报告被 link_check 再扫一遍时
            # 会把这句「错误描述」当成新的路径引用，形成自我引用的假死链。
            g.detail = f"{b.get('doc')}:{b.get('line')} 引用的路径「{b.get('raw')}」不存在"
    return g


def run_all(fix: bool = False) -> list[GateResult]:
    """按约定顺序跑完全部 6 个闸门。"""
    gates: list[GateResult] = []
    gates.append(gate_gen(fix=fix))
    gates.append(gate_validate())
    gates.append(gate_qa("project", "工程结构（pbxproj）", "project_check.py", ["--json"]))
    gates.append(gate_qa("static", "Swift 静态检查", "static_check.py", ["--json"]))
    gates.append(gate_qa("consistency", "设计令牌一致性", "consistency_check.py", ["--json"]))
    gates.append(gate_link())

    # 去重：闸门 1（gen）报「工程与磁盘不一致」时，闸门 2/3 的 membership 类 P0
    # 大概率是**同一个根因**（pbxproj 是生成物快照，滞后于磁盘）。
    # 把它们标成 derived，判定时合并计为 1 个 P0，并提示「跑一次 gen 就能一起收敛」。
    drift = gates[0].p0 > 0 and gates[0].key == "gen"
    if drift:
        for g in gates[1:3]:
            if g.p0 > 0:
                g.derived = True
                g.detail = ("（派生）与闸门 1 同源：pbxproj 滞后于磁盘，"
                            "重跑 gen_xcodeproj.py 后应一并消失。原始信息：" + g.detail)

    return gates


# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------

def decide(gates: list[GateResult]) -> tuple[str, str, str]:
    """返回 (结论代号, 中文结论, 一句话理由)。"""
    crashed = [g for g in gates if g.crashed]
    if crashed:
        names = "、".join(g.title for g in crashed)
        return ("NO-GO", "NO-GO（脚本无法运行）", f"{names} 跑不起来，无法判定")

    # 根因 P0（非派生）优先计数；派生 P0 只在没有根因时才算
    root_p0 = sum(g.p0 for g in gates if not g.derived)
    derived_p0 = sum(g.p0 for g in gates if g.derived)
    total_p1 = sum(g.p1 for g in gates)
    total_p2 = sum(g.p2 for g in gates)
    # 一票否决：未定义符号（含被判成 P2 `[粗查]` 的）一条都不许留。
    # 理由见 docs/06 §9.2：`[粗查]` 降级 P2 这条规则曾把 8 个真缺失的视图
    # （KeyboardRootView 引用的 KeyRowsView 等）标成"不阻塞"，实际那是必挂的编译错误。
    sym = sum(g.symbol_undefined for g in gates)

    if root_p0 > 0:
        bad = "、".join(g.title for g in gates if g.p0 > 0 and not g.derived)
        extra = f"（另有 {derived_p0} 个派生 P0 同源）" if derived_p0 else ""
        return ("NO-GO", "NO-GO（存在 P0）", f"{root_p0} 个 P0 分布在：{bad}{extra}")
    if sym > 0:
        return ("NO-GO", "NO-GO（存在未定义符号 · 一票否决）",
                f"SYMBOL-UNDEFINED 还剩 {sym} 条（含 P2 粗查项），冻结判定要求为 0；"
                "补定义或加入 SYSTEM_TYPES 白名单")
    if derived_p0 > 0:
        return ("NO-GO", "NO-GO（存在 P0）",
                f"{derived_p0} 个派生 P0：pbxproj 未同步，跑一次 gen_xcodeproj.py 即可收敛")
    if total_p1 > 0:
        bad = "、".join(g.title for g in gates if g.p1 > 0)
        return ("CONDITIONAL", "CONDITIONAL GO（无 P0，有 P1）",
                f"{total_p1} 个 P1 分布在：{bad}，需 Lead 逐条签收")
    if total_p2 > 0:
        return ("GO", "GO（无 P0/P1）", f"仅 {total_p2} 个 P2 建议项，不阻塞发布")
    return ("GO", "GO（六闸门全绿）", "P0/P1/P2 全部为 0")


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

def _fmt_secs(s: float) -> str:
    return f"{s:.1f}s" if s < 60 else f"{int(s // 60)}m{int(s % 60)}s"


def render_console(gates: list[GateResult], code: str, verdict: str, reason: str) -> str:
    bar = "=" * 80
    thin = "-" * 80
    lines: list[str] = []
    lines.append(bar)
    lines.append(" 墨语 iOS 输入法 · 最终验收（final_acceptance.py）")
    lines.append(f" 仓库根目录: {REPO_ROOT}")
    lines.append(f" 执行时间  : {time.strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append(bar)
    lines.append("")

    head = f"{'#':<2} {'闸门':<18} {'P0':>3} {'P1':>3} {'P2':>3} {'退出':>4}  {'耗时':>7}  结论"
    lines.append(head)
    lines.append(thin)
    for i, g in enumerate(gates, start=1):
        mark = "OK  " if g.ok else "FAIL"
        p0_cell = f"{g.p0}*" if g.derived else f"{g.p0}"
        lines.append(
            f"{i:<2} {g.title:<18} {p0_cell:>3} {g.p1:>3} {g.p2:>3} {g.exit_code:>4}  "
            f"{_fmt_secs(g.elapsed):>7}  {mark} {g.verdict}"
        )
    lines.append(thin)

    total_p0 = sum(g.p0 for g in gates)
    total_p1 = sum(g.p1 for g in gates)
    total_p2 = sum(g.p2 for g in gates)
    total_sym = sum(g.symbol_undefined for g in gates)
    derived_note = ""
    if any(g.derived for g in gates):
        derived_note = "（带 * 为派生 P0，与闸门 1 同源，跑一次 gen 即可一并收敛）"
    lines.append(
        f"合计: P0={total_p0}  P1={total_p1}  P2={total_p2}  "
        f"SYMBOL-UNDEFINED={total_sym}（一票否决指标，须为 0）{derived_note}")

    problems = [g for g in gates if not g.ok or g.detail]
    if problems:
        lines.append("")
        lines.append("── 明细（未通过的闸门 / 有补充说明的闸门）")
        for g in problems:
            lines.append(f"· [{g.key}] {g.title}")
            lines.append(f"  命令: {g.command}")
            if g.detail:
                lines.append(f"  说明: {g.detail}")
            for k, v in list(g.stats.items())[:6]:
                lines.append(f"  {k}: {v}")
            lines.append("")

    lines.append(bar)
    lines.append(f"结论: {verdict}")
    lines.append(f"理由: {reason}")
    lines.append(bar)
    return "\n".join(lines)


def render_markdown(gates: list[GateResult], code: str, verdict: str, reason: str) -> str:
    """生成可注入 docs/06 的 Markdown 片段（不含前后标记）。"""
    total_p0 = sum(g.p0 for g in gates)
    total_p1 = sum(g.p1 for g in gates)
    total_p2 = sum(g.p2 for g in gates)
    worst = max(gates, key=lambda g: (g.p0, g.p1, g.p2)) if gates else None

    out: list[str] = []
    out.append(f"> 本区由 `scripts/qa/final_acceptance.py` 自动生成 · "
               f"{time.strftime('%Y-%m-%d %H:%M:%S')} · **请勿手改**")
    out.append("")
    if any(g.derived for g in gates) or (gates and gates[0].p0 > 0):
        out.append("> ⚠️ **并行开发仍在进行**：闸门 1 报「工程与磁盘不一致」，说明还有 agent 正在落盘，"
                   "本区数据**只是自测快照**，冻结后必须重跑 `final_acceptance.py` 整段替换。")
        out.append("")
    out.append("| # | 闸门 | 脚本 | P0 | P1 | P2 | 退出码 | 耗时 | 结果 |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for i, g in enumerate(gates, start=1):
        mark = "✅ 通过" if g.ok else ("🟡 派生" if g.derived else "❌ 失败")
        p0_cell = f"{g.p0}\\*" if g.derived else str(g.p0)
        out.append(
            f"| {i} | {g.title} | `{g.command}` | {p0_cell} | {g.p1} | {g.p2} | "
            f"{g.exit_code} | {_fmt_secs(g.elapsed)} | {mark} |"
        )
    out.append(f"| | **合计** | | **{total_p0}** | **{total_p1}** | **{total_p2}** | | | |")
    if any(g.derived for g in gates):
        out.append("")
        out.append("> `*` 派生 P0：与闸门 1「工程生成器同步」同源（pbxproj 是生成物快照，"
                   "滞后于磁盘），重跑一次 `python scripts/gen_xcodeproj.py` 会一并收敛。")
    out.append("")

    # 关键指标：不论是否全绿都要输出 —— 全绿时的"规模数字"同样是验收证据的一部分
    # （冻结后回看需要知道这份报告是哪一版代码、多少文件的快照）。
    if worst is not None:
        out.append("**关键指标**（来自各脚本的 `stats`）：")
        out.append("")
        out.append("| 指标 | 值 |")
        out.append("|---|---|")
        st = gates[3].stats  # static_check
        if st:
            out.append(f"| Swift 文件数 | {st.get('files', '?')} |")
            out.append(f"| Swift 总行数 | {st.get('lines', '?')} |")
            out.append(f"| Shared / App / Extension 文件数 | "
                       f"{st.get('Shared', '?')} / {st.get('App', '?')} / {st.get('Extension', '?')} |")
            out.append(f"| SYMBOL-UNDEFINED 条数 | {st.get('symbols_checked', '?')} |")
        st = gates[2].stats  # project_check
        if st:
            out.append(f"| pbxproj 行数 | {st.get('pbxproj', '?')} |")
            out.append(f"| UUID 定义 / 引用 | {st.get('uuid_defined', '?')} / {st.get('uuid_referenced', '?')} |")
            out.append(f"| App / Extension Sources | {st.get('app_sources', '?')} / {st.get('ext_sources', '?')} |")
        st = gates[4].stats  # consistency_check
        if st:
            out.append(f"| 设计令牌叶子 / Theme 行数 | "
                       f"{st.get('token_leaves', '?')} / {st.get('theme', '?')} |")
            out.append(f"| 核对色值 / 数值 | {st.get('colors_checked', '?')} / {st.get('numbers_checked', '?')} |")
            out.append(f"| 硬编码 hex / 魔法字号 | {st.get('hardcoded_hex', '?')} / {st.get('magic_font', '?')} |")
        st = gates[5].stats  # link_check
        if st:
            out.append(f"| 文档 / 路径引用 / 未来文件 | {st.get('docs_checked', '?')} / "
                       f"{st.get('total_refs', '?')} / {st.get('future', '?')} |")
        st = gates[1].stats  # validate_project
        if st:
            out.append(f"| validate_project 通过项 | {st.get('checks_passed', '?')} |")
        out.append("")

    out.append(f"### 结论：**{verdict}**")
    out.append("")
    out.append(f"- **判定理由**：{_sanitize(reason)}")
    out.append(f"- **P0 / P1 / P2**：{total_p0} / {total_p1} / {total_p2}")
    total_sym = sum(g.symbol_undefined for g in gates)
    sym_mark = "✅ 0 条" if total_sym == 0 else f"❌ {total_sym} 条（一票否决）"
    out.append(f"- **SYMBOL-UNDEFINED**：{sym_mark}")
    out.append("")

    if total_p0 > 0 or total_p1 > 0:
        out.append("**未通过项明细**：")
        out.append("")
        out.append("| 闸门 | P0 | P1 | 说明 |")
        out.append("|---|---|---|---|")
        for g in gates:
            if g.p0 or g.p1:
                out.append(f"| {g.title} | {g.p0} | {g.p1} | "
                           f"{_sanitize(g.detail or g.verdict)} |")
        out.append("")
    return "\n".join(out)


def inject_into(path: Path, fragment: str) -> bool:
    """把片段注入 docs/06 的 QA:FINAL 标记之间。"""
    if not path.is_file():
        return False
    text = path.read_text(encoding="utf-8")
    if INJECT_START not in text or INJECT_END not in text:
        return False
    head, rest = text.split(INJECT_START, 1)
    _, tail = rest.split(INJECT_END, 1)
    new = head + INJECT_START + "\n" + fragment.rstrip() + "\n" + INJECT_END + tail
    path.write_text(new, encoding="utf-8", newline="\n")
    return True


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="final_acceptance.py",
        description="墨语 iOS 输入法 · 最终验收：串起 6 个闸门并给出 GO/NO-GO",
    )
    ap.add_argument("--fix", action="store_true",
                    help="允许重跑 gen_xcodeproj.py（会重写 project.pbxproj，慎用）")
    ap.add_argument("--md", metavar="PATH", default=None,
                    help="把 Markdown 表格写到文件")
    ap.add_argument("--inject", action="store_true",
                    help="配合 --md：把结果注入 docs/06 的 QA:FINAL 标记区（而不是覆盖整份文件）")
    ap.add_argument("--json", action="store_true", help="输出 JSON（供 CI 消费）")
    args = ap.parse_args(argv)

    gates = run_all(fix=args.fix)
    code, verdict, reason = decide(gates)

    if args.json:
        payload = {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "verdict": code,
            "verdict_text": verdict,
            "reason": reason,
            "total": {
                "P0": sum(g.p0 for g in gates),
                "P1": sum(g.p1 for g in gates),
                "P2": sum(g.p2 for g in gates),
                "SYMBOL_UNDEFINED": sum(g.symbol_undefined for g in gates),
            },
            "gates": [
                {
                    "key": g.key,
                    "title": g.title,
                    "command": g.command,
                    "exit_code": g.exit_code,
                    "ok": g.ok,
                    "P0": g.p0, "P1": g.p1, "P2": g.p2,
                    "symbol_undefined": g.symbol_undefined,
                    "verdict": g.verdict,
                    "detail": g.detail,
                    "stats": g.stats,
                    "elapsed": round(g.elapsed, 2),
                    "crashed": g.crashed,
                }
                for g in gates
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(render_console(gates, code, verdict, reason))

    if args.md:
        md_path = Path(args.md)
        if not md_path.is_absolute():
            md_path = REPO_ROOT / md_path
        fragment = render_markdown(gates, code, verdict, reason)
        if args.inject:
            if inject_into(md_path, fragment):
                print(f"[final_acceptance] 已注入 {md_path} 的 QA:FINAL 标记区")
            else:
                print(f"[final_acceptance] 注入失败：{md_path} 不存在或缺少 "
                      f"{INJECT_START} / {INJECT_END} 标记", file=sys.stderr)
        else:
            md_path.write_text(fragment + "\n", encoding="utf-8", newline="\n")
            print(f"[final_acceptance] Markdown 已写入 {md_path}")

    if code == "GO":
        return 0
    if code == "CONDITIONAL":
        return 1
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:  # noqa: BLE001
        print(f"[final_acceptance] 内部错误: {type(exc).__name__}: {exc}", file=sys.stderr)
        raise
