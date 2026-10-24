#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— Xcode 工程结构校验（project_check.py）。

Python 3 标准库，零第三方依赖，可在 Windows 直接运行（无需 Xcode）。

校验内容（docs/02 §2 构建配置契约）：
  1. `project.pbxproj` 花括号 / 圆括号平衡
  2. 24 位十六进制 UUID 引用完整性（被引用的 UUID 必须有定义）
  3. 两个 target 存在：`AIKeyboard`（App）与 `AIKeyboardExtension`（扩展）
  4. productType 正确：com.apple.product-type.application / .app-extension
  5. `Embed App Extensions`（Copy Files / PlugIns）构建阶段存在且包含 .appex
  6. `ios/Shared/**/*.swift` 同时出现在两个 target 的 Sources 阶段
  7. `ios/AIKeyboard/**/*.swift` 只出现在 App 的 Sources
  8. `ios/AIKeyboardExtension/**/*.swift` 只出现在 Extension 的 Sources
  9. Info.plist / entitlements / xcconfig 文件存在
 10. 扩展 Info.plist 关键键：NSExtensionPointIdentifier / NSExtensionPrincipalClass /
     RequestsOpenAccess / IsASCIICapable / PrimaryLanguage
 11. 构建配置关键项：SWIFT_VERSION / IPHONEOS_DEPLOYMENT_TARGET / PRODUCT_BUNDLE_IDENTIFIER
     / CODE_SIGN_STYLE / TARGETED_DEVICE_FAMILY

pbxproj 尚未生成时：打印 WARNING 并 **退出码 0**（不算失败，仅提示工程未落盘）。

用法：
    python scripts/qa/project_check.py                # 彩色终端报告
    python scripts/qa/project_check.py --json         # JSON（给 Lead/CI 汇总）
    python scripts/qa/project_check.py --md out.md    # Markdown 报告
    python scripts/qa/project_check.py --root <repo>  # 指定仓库根

退出码：0 = 无 P0/P1；1 = 有 P1；2 = 有 P0；3 = 脚本内部错误。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from qa_common import Report, add_common_args, finish, main_guard, rel

# ---------------------------------------------------------------------------
# 常量：契约（docs/02 §2）
# ---------------------------------------------------------------------------

APP_TARGET = "AIKeyboard"
EXT_TARGET = "AIKeyboardExtension"
PRODUCT_TYPE_APP = "com.apple.product-type.application"
PRODUCT_TYPE_EXT = "com.apple.product-type.app-extension"

PBXPROJ_REL = "ios/AIKeyboard.xcodeproj/project.pbxproj"
WORKSPACE_REL = "ios/AIKeyboard.xcworkspace"

# 期望存在的工程外文件（相对仓库根）
REQUIRED_FILES = [
    ("ios/Config/App-Info.plist", "P0", "宿主 App 的 Info.plist"),
    ("ios/Config/Extension-Info.plist", "P1", "输入法扩展的 Info.plist"),
    ("ios/Config/AIKeyboard.entitlements", "P1", "宿主 App 的 entitlements"),
    ("ios/Config/AIKeyboardExtension.entitlements", "P1", "扩展的 entitlements"),
]

# 扩展 Info.plist 必须键（docs/02 §2）
EXT_PLIST_REQUIRED = {
    "NSExtensionPointIdentifier": "com.apple.keyboard-service",
    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).KeyboardViewController",
    "RequestsOpenAccess": None,   # 值为 true
    "IsASCIICapable": None,       # 值为 true
    "PrimaryLanguage": "zh-Hans",
}

# 构建配置必须项（出现即视为存在，值只做弱校验）
BUILD_SETTING_HINTS = [
    ("SWIFT_VERSION", "P1", "Swift 版本（契约 5.0）"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "P0", "最低 iOS 版本（契约 16.0）"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "P0", "Bundle ID（契约占位 com.example.moyu）"),
    ("CODE_SIGN_STYLE", "P1", "签名方式（契约 Automatic）"),
    ("TARGETED_DEVICE_FAMILY", "P2", "设备族（契约 1,2）"),
    ("INFOPLIST_FILE", "P1", "Info.plist 路径"),
    ("CODE_SIGN_ENTITLEMENTS", "P2", "entitlements 路径"),
]

RE_UUID_DEF = re.compile(r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{", re.M)
RE_UUID_REF = re.compile(r"\b([0-9A-Fa-f]{24})\b")
RE_IS_PHASE = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{[^}]*?isa\s*=\s*(PBXSourcesBuildPhase|PBXCopyFilesBuildPhase|"
    r"PBXFrameworksBuildPhase|PBXResourcesBuildPhase)\s*;", re.M | re.S)
RE_NATIVE_TARGET = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{[^}]*?isa\s*=\s*PBXNativeTarget\s*;(.*?)\n\t\t\};", re.M | re.S)
RE_BUILD_FILE = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{[^}]*?isa\s*=\s*PBXBuildFile\s*;(.*?)\n\t\t\};", re.M | re.S)
RE_FILE_REF = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{[^}]*?isa\s*=\s*PBXFileReference\s*;(.*?)\n\t\t\};", re.M | re.S)
RE_GROUP = re.compile(
    r"^\s*([0-9A-Fa-f]{24})\s*=\s*\{[^}]*?isa\s*=\s*PBXGroup\s*;(.*?)\n\t\t\};", re.M | re.S)


# ---------------------------------------------------------------------------
# pbxproj 轻量解析
# ---------------------------------------------------------------------------

def strip_pbx_comments(text: str) -> str:
    """去掉 /* ... */ 注释（pbxproj 里注释不参与语义，且常含中文路径）。"""
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def check_brace_balance(report: Report, raw: str, stripped: str):
    """花括号 / 圆括号平衡（只统计去注释后的内容）。"""
    for opener, closer, code, label in (("{", "}", "PBX-BRACE", "花括号"),
                                        ("(", ")", "PBX-PAREN", "圆括号")):
        depth = 0
        bad_line = 0
        min_depth = 0
        for idx, ch in enumerate(stripped):
            if ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth < min_depth:
                    min_depth = depth
                    bad_line = stripped.count("\n", 0, idx) + 1
                    # 只记第一次下溢
                    break
        if min_depth < 0:
            report.add("P0", code, PBXPROJ_REL, bad_line,
                       f"pbxproj {label}下溢（多余的 `{closer}`），工程文件已损坏",
                       "用 `plutil -lint` 或 Xcode 打开验证；从备份恢复")
        elif depth != 0:
            report.add("P0", code, PBXPROJ_REL, stripped.count("\n") + 1,
                       f"pbxproj {label}不平衡：{label}未闭合，最终深度 {depth:+d}",
                       "工程文件被截断/手改错；删除并从备份或 `xcodegen` 重新生成")


def parse_uuid_table(stripped: str) -> dict[str, str]:
    """解析 `UUID = { ... };` 对象定义，返回 {uuid: 对象正文}。"""
    table: dict[str, str] = {}
    # 逐个顶层对象扫描：以 `\t\tUUID = {` 开头到匹配的 `};`
    for m in re.finditer(r"^\t\t([0-9A-Fa-f]{24})\s*=\s*\{", stripped, re.M):
        uuid = m.group(1)
        start = m.end()
        depth = 1
        i = start
        while i < len(stripped) and depth > 0:
            ch = stripped[i]
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            i += 1
        table[uuid] = stripped[start:i - 1]
    return table


def check_uuids(report: Report, stripped: str, table: dict[str, str]) -> dict[str, str]:
    """24 位 UUID 引用完整性：被引用的 UUID 必须在某处有定义。"""
    defined = set(table)
    # 定义也会出现在 `UUID /* comment */ = {`，上面的 table 已覆盖；
    # 再补 SC/TargetAttributes 等键值不对的 UUID 定义
    defined |= set(RE_UUID_DEF.findall(stripped))
    referenced: dict[str, int] = {}
    for m in RE_UUID_REF.finditer(stripped):
        uuid = m.group(1)
        referenced.setdefault(uuid, stripped.count("\n", 0, m.start()) + 1)
    missing = {u: ln for u, ln in referenced.items() if u not in defined}
    # 常见的「伪 UUID」：全 0 / 全 F 之类不报
    missing = {u: ln for u, ln in missing.items() if set(u) not in ({"0"}, {"F"}, {"f"})}
    if missing:
        items = sorted(missing.items(), key=lambda kv: kv[1])[:20]
        for uuid, line in items:
            report.add("P0", "PBX-UUID-MISSING", PBXPROJ_REL, line,
                       f"引用了未定义的 UUID `{uuid}`（该对象不存在，Xcode 打开会报损坏）",
                       "检查是否漏了 PBXBuildFile/PBXFileReference 定义，或重新生成 pbxproj")
        if len(missing) > 20:
            report.add("P0", "PBX-UUID-MISSING", PBXPROJ_REL, 0,
                       f"另有 {len(missing) - 20} 个未定义 UUID 未列出", "重新生成 pbxproj")
    report.stats["uuid_defined"] = len(defined)
    report.stats["uuid_referenced"] = len(referenced)
    return missing


def check_targets(report: Report, stripped: str, table: dict[str, str]) -> dict[str, str]:
    """两个 target 存在、productType 正确。返回 {target名: uuid}。"""
    found: dict[str, str] = {}
    product_types: dict[str, str] = {}
    for uuid, body in table.items():
        if "isa = PBXNativeTarget" not in body:
            continue
        m = re.search(r"\bname\s*=\s*\"?([^;\"]+)\"?\s*;", body)
        name = m.group(1).strip() if m else ""
        if not name:
            continue
        found[name] = uuid
        # productType 的值可能带引号也可能不带（Xcode 自己生成的是不带引号：
        # `productType = com.apple.product-type.application;`），两种都要认。
        pt = re.search(r"\bproductType\s*=\s*\"?([^;\"]+)\"?\s*;", body)
        product_types[name] = pt.group(1).strip() if pt else ""
    for name, expect, sev in ((APP_TARGET, PRODUCT_TYPE_APP, "P0"),
                              (EXT_TARGET, PRODUCT_TYPE_EXT, "P0")):
        if name not in found:
            report.add(sev, "PBX-TARGET-MISSING", PBXPROJ_REL, 0,
                       f"缺少 target `{name}`（docs/02 §2 要求双 target）",
                       "在 project.yml / Xcode 中补 target，或重新生成工程")
            continue
        got = product_types.get(name, "")
        if got != expect:
            report.add("P0", "PBX-PRODUCT-TYPE", PBXPROJ_REL, 0,
                       f"target `{name}` 的 productType 为 `{got or '(空)'}`，应为 `{expect}`",
                       "App 用 application、扩展用 app-extension，错了两者都无法上真机")
    for name in found:
        if name not in (APP_TARGET, EXT_TARGET):
            report.warn(f"发现第三个 target `{name}`（契约只要求两个，请确认是否为测试/UIScene target）")
    report.stats["targets"] = ",".join(sorted(found)) or "(无)"
    return found


def check_embed_extension(report: Report, stripped: str, table: dict[str, str]):
    """Embed App Extensions（PBXCopyFilesBuildPhase + dstSubfolderSpec = 13 + .appex）存在。"""
    ok = False
    for uuid, body in table.items():
        if "isa = PBXCopyFilesBuildPhase" not in body:
            continue
        if "dstSubfolderSpec = 13" not in body:
            continue
        # 该 phase 的 files 列表里的 build file 是否指向 .appex
        file_ids = re.findall(r"([0-9A-Fa-f]{24})", body.split("files = (")[-1]) if "files = (" in body else []
        for fid in file_ids:
            bf = table.get(fid, "")
            if ".appex" in bf or "AppExtension" in bf or "Extension.appex" in bf:
                ok = True
                break
        if ok:
            break
        # 退一步：整个 pbxproj 里出现 .appex 文件引用 + 有 dstSubfolderSpec=13
        if ".appex" in stripped:
            ok = True
    if not ok:
        report.add("P0", "PBX-EMBED-EXT", PBXPROJ_REL, 0,
                   "缺少 Embed App Extensions 构建阶段（PBXCopyFilesBuildPhase + dstSubfolderSpec=13）",
                   "没有这个阶段，IPA 里不会带 PlugIns/AIKeyboardExtension.appex，键盘装不上")


def build_phase_members(stripped: str, table: dict[str, str]) -> dict[str, set[str]]:
    """返回 {phase_uuid: {源文件相对路径...}}，通过 PBXBuildFile→PBXFileReference 链解析。"""
    # build file → fileRef uuid
    bf_to_ref: dict[str, str] = {}
    for uuid, body in table.items():
        if "isa = PBXBuildFile" not in body:
            continue
        m = re.search(r"\bfileRef\s*=\s*([0-9A-Fa-f]{24})", body)
        if m:
            bf_to_ref[uuid] = m.group(1)
    # fileRef → path/name
    ref_to_path: dict[str, str] = {}
    for uuid, body in table.items():
        if "isa = PBXFileReference" not in body:
            continue
        m = re.search(r"\bpath\s*=\s*\"?([^\";]+)\"?\s*;", body)
        if not m:
            m = re.search(r"\bname\s*=\s*\"?([^\";]+)\"?\s*;", body)
        if m:
            ref_to_path[uuid] = m.group(1).strip()

    result: dict[str, set[str]] = {}
    # 找每个 phase 的 files 列表
    for m in re.finditer(r"^\t\t([0-9A-Fa-f]{24})\s*=\s*\{", stripped, re.M):
        uuid = m.group(1)
        body = table.get(uuid, "")
        if "BuildPhase" not in body:
            continue
        fm = re.search(r"files\s*=\s*\((.*?)\);", body, re.S)
        if not fm:
            result[uuid] = set()
            continue
        paths: set[str] = set()
        for fid in re.findall(r"([0-9A-Fa-f]{24})", fm.group(1)):
            ref = bf_to_ref.get(fid)
            if ref and ref in ref_to_path:
                paths.add(ref_to_path[ref])
        result[uuid] = paths
    return result


def target_sources(stripped: str, table: dict[str, str], target_uuid: str) -> set[str]:
    """取某 target 的 Sources 阶段里的文件路径集合。"""
    body = table.get(target_uuid, "")
    phases = re.search(r"buildPhases\s*=\s*\((.*?)\);", body, re.S)
    if not phases:
        return set()
    members = build_phase_members(stripped, table)
    out: set[str] = set()
    for pid in re.findall(r"([0-9A-Fa-f]{24})", phases.group(1)):
        pbody = table.get(pid, "")
        if "PBXSourcesBuildPhase" in pbody:
            out |= members.get(pid, set())
    return out


def norm(path: str) -> str:
    return path.replace("\\", "/").lstrip("./")


def classify(path: str) -> str:
    p = norm(path)
    if "/Shared/" in f"/{p}" or p.startswith("Shared/"):
        return "shared"
    if "AIKeyboardExtension/" in p:
        return "ext"
    if p.startswith("AIKeyboard/") or "/AIKeyboard/" in p:
        return "app"
    return "other"


def check_sources_membership(report: Report, stripped: str, table: dict[str, str],
                             targets: dict[str, str]):
    """Shared 同进两 target；App 只在 App；Extension 只在 Extension。"""
    if APP_TARGET not in targets or EXT_TARGET not in targets:
        return
    app_src = {norm(p) for p in target_sources(stripped, table, targets[APP_TARGET])}
    ext_src = {norm(p) for p in target_sources(stripped, table, targets[EXT_TARGET])}
    report.stats["app_sources"] = len(app_src)
    report.stats["ext_sources"] = len(ext_src)

    shared_app = {p for p in app_src if classify(p) == "shared"}
    shared_ext = {p for p in ext_src if classify(p) == "shared"}

    # 7/8：目录归属
    for p in sorted(app_src):
        if classify(p) == "ext":
            report.add("P0", "PBX-SRC-WRONG-TARGET", PBXPROJ_REL, 0,
                       f"扩展源文件 `{p}` 被编进了 App target（会重复定义/编译失败）",
                       "从 App 的 Sources 移除，只留在 Extension")
    for p in sorted(ext_src):
        if classify(p) == "app":
            report.add("P0", "PBX-SRC-WRONG-TARGET", PBXPROJ_REL, 0,
                       f"宿主 App 源文件 `{p}` 被编进了 Extension target（扩展内存 60MB 且无 UIKit 宿主）",
                       "从 Extension 的 Sources 移除，只留在 App")

    # 6：Shared 同时进两 target（以磁盘实际存在的 Shared 文件为准，做双向比对）
    ios_root = report.root / "ios"
    on_disk_shared = set()
    shared_dir = ios_root / "Shared"
    if shared_dir.exists():
        for p in shared_dir.rglob("*.swift"):
            on_disk_shared.add(p.name)
    missing_in_app = sorted(n for n in on_disk_shared if n not in {Path(x).name for x in shared_app})
    missing_in_ext = sorted(n for n in on_disk_shared if n not in {Path(x).name for x in shared_ext})
    for name in missing_in_app:
        report.add("P0", "PBX-SHARED-NOT-IN-APP", PBXPROJ_REL, 0,
                   f"`ios/Shared/**/{name}` 未加入 App target 的 Sources（App 会缺符号无法编译）",
                   "在 App target 的 Sources 里勾选该文件")
    for name in missing_in_ext:
        report.add("P0", "PBX-SHARED-NOT-IN-EXT", PBXPROJ_REL, 0,
                   f"`ios/Shared/**/{name}` 未加入 Extension target 的 Sources（扩展会缺符号无法编译）",
                   "在 Extension target 的 Sources 里勾选该文件")

    # Extension 源文件数量下限
    if len(ext_src) == 0:
        report.add("P0", "PBX-EXT-EMPTY", PBXPROJ_REL, 0,
                   "Extension target 的 Sources 为空（键盘不可能被构建）", "把 ios/AIKeyboardExtension/** 加入")

    # 磁盘上有、但没登记进任何 target 的 Sources —— 这些文件不会参与编译
    check_untracked_sources(report, app_src, ext_src)


def check_untracked_sources(report: Report, app_src: set[str], ext_src: set[str]):
    """磁盘上存在但没进 Sources 的 .swift → P0/P1。

    典型场景：先跑了工程生成器，之后队友又新增了代码文件却没重跑生成器。
    后果是这些文件不参与编译 —— 现象是"明明写了却报 cannot find xxx in scope"。
    这里做双向核对：`ios/AIKeyboard/**` 必须出现在 App Sources，
    `ios/AIKeyboardExtension/**` 必须出现在 Extension Sources。
    """
    ios_root = report.root / "ios"
    tracked_names = {Path(p).name for p in app_src} | {Path(p).name for p in ext_src}

    areas = (
        ("ios/AIKeyboard", "app", app_src),
        ("ios/AIKeyboardExtension", "ext", ext_src),
    )
    for rel_dir, kind, srcs in areas:
        base = report.root / rel_dir
        if not base.is_dir():
            continue
        src_names = {Path(p).name for p in srcs}
        on_disk = sorted(p for p in base.rglob("*.swift") if p.is_file())
        untracked = [p for p in on_disk if p.name not in src_names]
        if not untracked:
            continue
        target = APP_TARGET if kind == "app" else EXT_TARGET
        listed = "、".join(rel(p) for p in untracked[:12])
        more = f" 等 {len(untracked)} 个" if len(untracked) > 12 else ""
        report.add("P0", "PBX-UNTRACKED-SOURCE", PBXPROJ_REL, 0,
                   f"磁盘上有 {len(untracked)} 个 Swift 文件未加入 `{target}` 的 Sources，"
                   f"不会参与编译：{listed}{more}",
                   "重跑 `scripts/gen_xcodeproj.py` 重新生成 pbxproj（该脚本会 rglob 全部 .swift），"
                   "或在 Xcode 里手动勾选这些文件")


def read_plist_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def check_required_files(report: Report):
    for relpath, sev, desc in REQUIRED_FILES:
        p = report.root / relpath
        if not p.is_file():
            report.add(sev, "FILE-MISSING", relpath, 0, f"缺少{desc}", "按 docs/02 §2 补齐")


def check_extension_plist(report: Report):
    p = report.root / "ios/Config/Extension-Info.plist"
    if not p.is_file():
        return
    text = read_plist_text(p)
    if not text:
        report.add("P1", "PLIST-EMPTY", rel(Path("ios/Config/Extension-Info.plist")), 0,
                   "扩展 Info.plist 读不到内容", "确认文件编码为 UTF-8")
        return
    for key, expect in EXT_PLIST_REQUIRED.items():
        if f"<key>{key}</key>" not in text:
            report.add("P0", "PLIST-KEY-MISSING", "ios/Config/Extension-Info.plist", 0,
                       f"扩展 Info.plist 缺少 `{key}`（键盘不会出现在「设置›键盘」列表）",
                       f"补充 <key>{key}</key>，参考 docs/02 §2")
            continue
        if expect:
            window = text.split(f"<key>{key}</key>", 1)[1][:260]
            if expect not in window:
                sev = "P0" if key == "NSExtensionPointIdentifier" else "P1"
                report.add(sev, "PLIST-KEY-VALUE", "ios/Config/Extension-Info.plist", 0,
                           f"扩展 Info.plist 的 `{key}` 值不是 `{expect}`",
                           "值写错系统不会把扩展识别为键盘")
    for key in ("RequestsOpenAccess", "IsASCIICapable"):
        if f"<key>{key}</key>" in text:
            window = text.split(f"<key>{key}</key>", 1)[1][:120]
            if "<true/>" not in window and "<string>YES</string>" not in window.lower():
                report.add("P1", "PLIST-BOOL", "ios/Config/Extension-Info.plist", 0,
                           f"`{key}` 未设为 true（完全访问/ASCII 兼容会缺失）",
                           "设为 <true/>")
    if "NSExtensionPrincipalClass" in text:
        window = text.split("<key>NSExtensionPrincipalClass</key>", 1)[1][:200]
        if "KeyboardViewController" not in window:
            report.add("P0", "PLIST-PRINCIPAL", "ios/Config/Extension-Info.plist", 0,
                       "`NSExtensionPrincipalClass` 未指向 KeyboardViewController（键盘启动即闪退）",
                       "值应为 $(PRODUCT_MODULE_NAME).KeyboardViewController")


def check_build_settings(report: Report, stripped: str):
    for key, sev, desc in BUILD_SETTING_HINTS:
        if not re.search(rf"\b{key}\s*=", stripped):
            report.add(sev, "PBX-SETTING-MISSING", PBXPROJ_REL, 0,
                       f"构建配置缺少 `{key}`（{desc}）", "在 xcconfig / build settings 中补齐")
            continue
        if key == "IPHONEOS_DEPLOYMENT_TARGET":
            vals = set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9.]+)\s*;", stripped))
            if vals and not any(v.startswith("16.") for v in vals):
                report.add("P1", "PBX-IOS-TARGET", PBXPROJ_REL, 0,
                           f"IPHONEOS_DEPLOYMENT_TARGET 为 {sorted(vals)}，契约要求 16.0",
                           "改为 16.0 与 docs/02 §2 一致")
        if key == "SWIFT_VERSION":
            vals = set(re.findall(r"SWIFT_VERSION\s*=\s*([0-9.]+)\s*;", stripped))
            if vals and not any(v.startswith("5.") for v in vals):
                report.add("P1", "PBX-SWIFT-VERSION", PBXPROJ_REL, 0,
                           f"SWIFT_VERSION 为 {sorted(vals)}，契约要求 5.0", "改为 5.0")
        if key == "PRODUCT_BUNDLE_IDENTIFIER":
            ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER\s*=\s*\"?([^;\"]+)\"?\s*;", stripped))
            ids = {i.strip() for i in ids if "$(" not in i}
            if ids and not any(i.startswith("com.example.moyu") for i in ids):
                report.warn(f"Bundle ID 为 {sorted(ids)}（契约占位是 com.example.moyu；"
                            "若已改成自己的 ID 属正常，记得两 target 都改）")


def check_app_group(report: Report, stripped: str):
    """免费开发者账号无 App Group：pbxproj 若声明了 App Group entitlement 要提示。"""
    ents = report.root / "ios/Config/AIKeyboard.entitlements"
    if ents.is_file():
        text = read_plist_text(ents)
        if "com.apple.security.application-groups" in text:
            report.add("P1", "ENT-APPGROUP", "ios/Config/AIKeyboard.entitlements", 0,
                       "entitlements 声明了 App Group，但免费 Apple ID 无法签发该 capability（签名会失败）",
                       "免费签名路径下移除 App Group，改用「同步到键盘」剪贴板搬运配置（docs/04）")


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run(root: Path) -> Report:
    report = Report("墨语 iOS 输入法 · Xcode 工程结构校验（project_check.py）", root)
    pbx = root / PBXPROJ_REL

    if not pbx.is_file():
        report.warn(
            "未找到 ios/AIKeyboard.xcodeproj/project.pbxproj —— 工程文件尚未落盘"
            "（由 ios-skeleton 负责）。本脚本跳过全部工程结构检查，退出码按 0 处理。"
        )
        report.stats.update({"pbxproj": "缺失", "targets": "—", "app_sources": 0, "ext_sources": 0})
        # 工程文件缺失时做「预检」（只提示，不阻断）：Info.plist / entitlements 是否已就绪
        pre = Report("预检", root)
        check_required_files(pre)
        check_extension_plist(pre)
        for it in pre.sorted_issues():
            report.warn(f"[预检][{it.severity}] {it.file}:{it.line} {it.message}")
        return report

    raw = pbx.read_bytes().decode("utf-8", errors="replace")
    stripped = strip_pbx_comments(raw)
    line_count = raw.count("\n") + 1
    report.stats.update({"pbxproj": f"{line_count} 行"})

    check_brace_balance(report, raw, stripped)
    table = parse_uuid_table(stripped)
    check_uuids(report, stripped, table)
    targets = check_targets(report, stripped, table)
    check_embed_extension(report, stripped, table)
    check_sources_membership(report, stripped, table, targets)
    check_required_files(report)
    check_extension_plist(report)
    check_build_settings(report, stripped)
    check_app_group(report, stripped)

    if (root / WORKSPACE_REL).exists():
        report.stats["workspace"] = "存在"
    else:
        report.warn("未发现 ios/AIKeyboard.xcworkspace（CI 里 xcodebuild -workspace 需要，若改用 -project+scheme 可忽略）")

    # 是否包含 shared scheme（CI xcodebuild -scheme 需要）
    scheme_dir = root / "ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes"
    if scheme_dir.is_dir():
        schemes = sorted(p.stem for p in scheme_dir.glob("*.xcscheme"))
        report.stats["schemes"] = ",".join(schemes) or "(空)"
        if APP_TARGET not in schemes:
            report.add("P1", "PBX-SCHEME-MISSING", "ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes", 0,
                       f"缺少 shared scheme `{APP_TARGET}.xcscheme`（GitHub Actions 里 `xcodebuild -scheme` 会失败）",
                       "在 Xcode › Product › Scheme › Manage Schemes 勾选 Shared，或手写 xcscheme")
    else:
        report.add("P1", "PBX-SCHEME-MISSING", "ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes", 0,
                   "未发现 shared scheme 目录（CI 云编译必需）",
                   "补 `xcshareddata/xcschemes/AIKeyboard.xcscheme`（ios-skeleton 产出）")

    return report


@main_guard
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="墨语 iOS 输入法 · Xcode 工程结构校验")
    add_common_args(ap)
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    report = run(root)
    return finish(report, args)


if __name__ == "__main__":
    sys.exit(main())
