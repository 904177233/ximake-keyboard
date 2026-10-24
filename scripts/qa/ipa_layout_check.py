#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— IPA 包内布局校验（打包后立刻跑）。

校验未签名 IPA 的 Payload 目录结构，重点保证**词库落在 `dict/` 而不是 `Resources/dict/`**：
folder reference 会把目录名原样复制到 bundle 根，一旦出现 `Resources/` 目录，
iOS 27 的 installd / IXPlaceholder 会拒绝安装（IXErrorDomain Code=13 Missing bundle ID，
真机实测空目录也会失败）。历史上就是 `ios/Shared/Resources/dict/` 这个布局踩了这个坑。

纯 Python 3 标准库（`zipfile` + `plistlib`），零第三方依赖，可直接在 Windows / macOS / CI 运行。

用法:
    python scripts/qa/ipa_layout_check.py dist/AIKeyboard-unsigned.ipa
    python scripts/qa/ipa_layout_check.py dist/AIKeyboard-unsigned.ipa --json
    python scripts/qa/ipa_layout_check.py dist/AIKeyboard-unsigned.ipa --md docs/ipa-layout.md

校验项:
    [L1] `Payload/<App>.app/Info.plist` 存在
    [L2] `Payload/<App>.app/dict/{base_dict.tsv,phrases.tsv,dict_meta.json}` 三个齐全
    [L3] `Payload/<App>.app/PlugIns/<Ext>.appex/dict/` 三个齐全（缺 appex 为 P1 警告）
    [L4] 全包**没有任何路径含 `Resources/`**（旧的 Shared/Resources 布局残留）
    [L5] `Info.plist` 里有非空 `CFBundleIdentifier`（app + appex 各查一次）

退出码（与 scripts/qa/ 其它脚本统一）:
    0 = 通过（无 P0/P1，可能带 P2 提示）
    1 = 失败（存在 P0/P1）
    2 = 脚本内部错误（文件不存在 / 不是 ZIP / 参数错误）
"""

from __future__ import annotations

import argparse
import json
import plistlib
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

try:  # Windows 控制台默认 GBK，中文报告会乱码：强制 UTF-8 输出
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001 - 输出流不可重配置时忽略
    pass

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

EXPECTED_APP_NAME = "AIKeyboard"
EXPECTED_EXT_NAME = "AIKeyboardExtension"
DICT_FILES = ("base_dict.tsv", "phrases.tsv", "dict_meta.json")

SEVERITY_P0 = "P0"
SEVERITY_P1 = "P1"
SEVERITY_P2 = "P2"
SEVERITY_INFO = "INFO"


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------


@dataclass
class Issue:
    """一条校验问题。"""

    severity: str
    code: str
    message: str


@dataclass
class Report:
    """校验报告。"""

    ipa_path: str
    issues: list[Issue] = field(default_factory=list)
    entries: list[str] = field(default_factory=list)
    app_dir: str = ""
    ext_dir: str = ""

    def add(self, severity: str, code: str, message: str) -> None:
        """追加一条问题。"""
        self.issues.append(Issue(severity=severity, code=code, message=message))

    def count(self, severity: str) -> int:
        """统计某个严重级别的问题数。"""
        return sum(1 for item in self.issues if item.severity == severity)

    def has_blocking(self) -> bool:
        """是否存在阻断性问题（P0/P1）。"""
        return self.count(SEVERITY_P0) > 0 or self.count(SEVERITY_P1) > 0

    def exit_code(self) -> int:
        """按统一约定计算退出码。"""
        return 1 if self.has_blocking() else 0


# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------


def _normalize(name: str) -> str:
    """统一 ZIP 内的路径分隔符（部分打包工具会写反斜杠）。"""
    return name.replace("\\", "/")


def _is_dir(name: str) -> bool:
    """ZIP 条目是否为目录。"""
    return name.endswith("/")


def _find_app_dir(entries: list[str]) -> str:
    """在 Payload 下定位唯一的 `.app` 目录。

    - Parameter entries: 规范化后的全部条目。
    - Returns: `Payload/xxx.app/` 形式的前缀；找不到返回空串。
    """
    candidates = sorted(
        entry for entry in entries
        if entry.startswith("Payload/") and entry.endswith(".app/") and entry.count("/") == 2
    )
    if not candidates:
        return ""
    preferred = [item for item in candidates if Path(item.rstrip("/")).name == f"{EXPECTED_APP_NAME}.app"]
    return preferred[0] if preferred else candidates[0]


def _find_appex_dir(entries: list[str], app_dir: str) -> str:
    """在 app 的 PlugIns 下定位唯一的 `.appex` 目录。

    - Parameters:
      - entries: 规范化后的全部条目。
      - app_dir: `.app` 目录前缀。
    - Returns: `Payload/xxx.app/PlugIns/yyy.appex/` 形式的前缀；找不到返回空串。
    """
    prefix = f"{app_dir}PlugIns/"
    candidates = sorted(
        entry for entry in entries
        if entry.startswith(prefix) and entry.endswith(".appex/") and entry.count("/") == 4
    )
    if not candidates:
        return ""
    preferred = [item for item in candidates if Path(item.rstrip("/")).name == f"{EXPECTED_EXT_NAME}.appex"]
    return preferred[0] if preferred else candidates[0]


def _read_plist(archive: zipfile.ZipFile, name: str) -> dict | None:
    """读取 ZIP 内的 plist（支持 XML 与 binary 两种格式）。

    - Parameters:
      - archive: 已打开的 ZIP。
      - name: 条目名。
    - Returns: 解析后的字典；条目不存在或解析失败返回 `None`。
    """
    try:
        raw = archive.read(name)
    except KeyError:
        return None
    try:
        loaded = plistlib.loads(raw)
    except Exception:  # noqa: BLE001 - plist 损坏时按"无法解析"处理
        return None
    return loaded if isinstance(loaded, dict) else None


# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------


def check_ipa(ipa_path: Path) -> Report:
    """对一个 IPA 做完整布局校验。

    - Parameter ipa_path: IPA 文件路径。
    - Returns: 校验报告。
    - Raises: FileNotFoundError / zipfile.BadZipFile —— 由调用方转为退出码 2。
    """
    report = Report(ipa_path=str(ipa_path))

    with zipfile.ZipFile(ipa_path) as archive:
        entries = sorted(_normalize(name) for name in archive.namelist())
        report.entries = entries

        app_dir = _find_app_dir(entries)
        report.app_dir = app_dir
        if not app_dir:
            report.add(SEVERITY_P0, "L1", "Payload 下找不到唯一的 .app 目录（IPA 结构异常）")
            return report

        app_name = Path(app_dir.rstrip("/")).name
        if app_name != f"{EXPECTED_APP_NAME}.app":
            report.add(SEVERITY_P2, "L1",
                       f"App 名字是 {app_name}，与预期的 {EXPECTED_APP_NAME}.app 不同（若已改名可忽略）")

        # ---- L1: 主 App Info.plist ----
        app_info_name = f"{app_dir}Info.plist"
        if app_info_name not in entries:
            report.add(SEVERITY_P0, "L1", f"缺少 {app_info_name}")
        else:
            report.add(SEVERITY_INFO, "L1", f"存在 {app_info_name}")

        # ---- L2: 主 App 词库 ----
        app_dict_dir = f"{app_dir}dict/"
        missing_app = [name for name in DICT_FILES if f"{app_dict_dir}{name}" not in entries]
        if missing_app:
            report.add(SEVERITY_P0, "L2",
                       f"主 App 的 dict/ 缺少 {len(missing_app)} 个文件：{', '.join(missing_app)}"
                       f"（应在 {app_dict_dir}）")
        else:
            report.add(SEVERITY_INFO, "L2", f"主 App 词库三件齐全：{app_dict_dir}")

        # ---- L3: Extension 词库 ----
        ext_dir = _find_appex_dir(entries, app_dir)
        report.ext_dir = ext_dir
        if not ext_dir:
            report.add(SEVERITY_P1, "L3", f"{app_dir}PlugIns/ 下找不到 .appex（键盘扩展未嵌入）")
        else:
            ext_dict_dir = f"{ext_dir}dict/"
            missing_ext = [name for name in DICT_FILES if f"{ext_dict_dir}{name}" not in entries]
            if missing_ext:
                report.add(SEVERITY_P0, "L3",
                           f"键盘扩展的 dict/ 缺少 {len(missing_ext)} 个文件：{', '.join(missing_ext)}"
                           f"（appex 必须自带词库，{ext_dict_dir}）")
            else:
                report.add(SEVERITY_INFO, "L3", f"扩展词库三件齐全：{ext_dict_dir}")

        # ---- L4: 全包不允许出现 Resources/ 路径 ----
        offenders = [name for name in entries if "Resources/" in name]
        if offenders:
            preview = ", ".join(offenders[:5])
            more = "" if len(offenders) <= 5 else f" 等共 {len(offenders)} 条"
            report.add(SEVERITY_P0, "L4",
                       f"包内存在 {len(offenders)} 条含 `Resources/` 的路径：{preview}{more}"
                       "（iOS 27 installd 会拒绝安装，必须让词库走 dict/）")
        else:
            report.add(SEVERITY_INFO, "L4", "全包无任何 `Resources/` 路径")

        # ---- L5: CFBundleIdentifier ----
        app_plist = _read_plist(archive, app_info_name) if app_info_name in entries else None
        if app_info_name in entries:
            if app_plist is None:
                report.add(SEVERITY_P1, "L5", f"{app_info_name} 无法解析为 plist 字典")
            else:
                bundle_id = app_plist.get("CFBundleIdentifier")
                if not isinstance(bundle_id, str) or not bundle_id.strip():
                    report.add(SEVERITY_P0, "L5", f"{app_info_name} 缺少有效的 CFBundleIdentifier")
                else:
                    report.add(SEVERITY_INFO, "L5", f"App CFBundleIdentifier = {bundle_id}")

        if ext_dir:
            ext_info_name = f"{ext_dir}Info.plist"
            if ext_info_name not in entries:
                report.add(SEVERITY_P1, "L5", f"缺少 {ext_info_name}")
            else:
                ext_plist = _read_plist(archive, ext_info_name)
                if ext_plist is None:
                    report.add(SEVERITY_P1, "L5", f"{ext_info_name} 无法解析为 plist 字典")
                else:
                    ext_bundle_id = ext_plist.get("CFBundleIdentifier")
                    if not isinstance(ext_bundle_id, str) or not ext_bundle_id.strip():
                        report.add(SEVERITY_P0, "L5", f"{ext_info_name} 缺少有效的 CFBundleIdentifier")
                    else:
                        report.add(SEVERITY_INFO, "L5", f"Extension CFBundleIdentifier = {ext_bundle_id}")
                    extension = ext_plist.get("NSExtension")
                    if isinstance(extension, dict):
                        point = extension.get("NSExtensionPointIdentifier")
                        if point != "com.apple.keyboard-service":
                            report.add(SEVERITY_P1, "L5",
                                       f"appex 的 NSExtensionPointIdentifier 是 {point!r}，"
                                       "不是 com.apple.keyboard-service")
                        else:
                            report.add(SEVERITY_INFO, "L5", "appex 是键盘扩展（keyboard-service）")
                    else:
                        report.add(SEVERITY_P1, "L5", "appex 的 Info.plist 缺少 NSExtension 字典")

    return report


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------


def print_report(report: Report, verbose: bool) -> None:
    """打印人类可读报告。"""
    print("=" * 78)
    print(" 墨语 iOS 输入法 · IPA 包内布局校验（ipa_layout_check.py）")
    print("=" * 78)
    print(f" IPA 文件 : {report.ipa_path}")
    print(f" App 目录 : {report.app_dir or '（未找到）'}")
    print(f" 扩展目录 : {report.ext_dir or '（未找到）'}")
    print(f" 条目总数 : {len(report.entries)}")
    print("-" * 78)

    order = {SEVERITY_P0: 0, SEVERITY_P1: 1, SEVERITY_P2: 2, SEVERITY_INFO: 3}
    for issue in sorted(report.issues, key=lambda item: order.get(item.severity, 9)):
        if verbose or issue.severity in (SEVERITY_P0, SEVERITY_P1):
            print(f" [{issue.severity}] {issue.code} {issue.message}")

    print("-" * 78)
    print(f" P0={report.count(SEVERITY_P0)} P1={report.count(SEVERITY_P1)} "
          f"P2={report.count(SEVERITY_P2)} INFO={report.count(SEVERITY_INFO)}")
    print(f" 结论: {'通过（词库布局符合 iOS 27 要求）' if not report.has_blocking() else '失败'}")
    print("=" * 78)

    if report.has_blocking() and not verbose:
        print("\n提示：用 --verbose 查看全部条目级检查结果；"
              "旧 IPA（18:02 构建）会因 `Resources/dict/` 被 L4 判为 P0，需用新 pbxproj 重新打包。")


def print_markdown(report: Report, out_path: Path) -> None:
    """把报告写成 Markdown 文件（便于贴进 docs / CI 摘要）。"""
    lines = [
        "# IPA 包内布局校验报告",
        "",
        f"- IPA 文件：`{report.ipa_path}`",
        f"- App 目录：`{report.app_dir or '（未找到）'}`",
        f"- 扩展目录：`{report.ext_dir or '（未找到）'}`",
        f"- 条目总数：{len(report.entries)}",
        "",
        "| 级别 | 代码 | 说明 |",
        "| --- | --- | --- |",
    ]
    for issue in report.issues:
        lines.append(f"| {issue.severity} | {issue.code} | {issue.message.replace('|', '/')} |")
    lines.extend([
        "",
        f"**结果**：P0={report.count(SEVERITY_P0)} P1={report.count(SEVERITY_P1)} "
        f"P2={report.count(SEVERITY_P2)} → "
        f"{'通过' if not report.has_blocking() else '失败'}",
        "",
    ])
    out_path.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f" 已写出 Markdown 报告: {out_path}")


def print_json(report: Report) -> None:
    """打印 JSON 报告（CI 消费用）。"""
    payload = {
        "ipa": report.ipa_path,
        "app_dir": report.app_dir,
        "ext_dir": report.ext_dir,
        "entry_count": len(report.entries),
        "counts": {
            "P0": report.count(SEVERITY_P0),
            "P1": report.count(SEVERITY_P1),
            "P2": report.count(SEVERITY_P2),
            "INFO": report.count(SEVERITY_INFO),
        },
        "passed": not report.has_blocking(),
        "issues": [
            {"severity": item.severity, "code": item.code, "message": item.message}
            for item in report.issues
        ],
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    """构造命令行解析器。"""
    parser = argparse.ArgumentParser(
        description="校验墨语 IPA 的 Payload 布局（词库必须在 dict/，不得出现 Resources/）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  python scripts/qa/ipa_layout_check.py dist/AIKeyboard-unsigned.ipa\n"
            "  python scripts/qa/ipa_layout_check.py dist/AIKeyboard-unsigned.ipa --json\n"
        ),
    )
    parser.add_argument("ipa", help="IPA 文件路径")
    parser.add_argument("--json", action="store_true", help="输出 JSON 报告")
    parser.add_argument("--md", default=None, help="把 Markdown 报告写到指定路径")
    parser.add_argument("--verbose", "-v", action="store_true", help="显示 INFO 级条目检查结果")
    return parser


def main(argv: list[str] | None = None) -> int:
    """脚本入口。

    - Parameter argv: 命令行参数（默认取 `sys.argv[1:]`）。
    - Returns: 退出码 0/1/2。
    """
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:  # argparse 的参数错误
        return int(exc.code) if isinstance(exc.code, int) else 2

    ipa_path = Path(args.ipa)
    if not ipa_path.is_file():
        print(f"[脚本错误] IPA 文件不存在：{ipa_path}", file=sys.stderr)
        return 2
    if not zipfile.is_zipfile(ipa_path):
        print(f"[脚本错误] 不是有效的 ZIP/IPA 文件：{ipa_path}", file=sys.stderr)
        return 2

    try:
        report = check_ipa(ipa_path)
    except (zipfile.BadZipFile, OSError) as exc:
        print(f"[脚本错误] 读取 IPA 失败：{exc}", file=sys.stderr)
        return 2

    if args.json:
        print_json(report)
    else:
        print_report(report, verbose=args.verbose)

    if args.md:
        try:
            print_markdown(report, Path(args.md))
        except OSError as exc:
            print(f"[脚本错误] 写 Markdown 失败：{exc}", file=sys.stderr)
            return 2

    return report.exit_code()


if __name__ == "__main__":
    sys.exit(main())
