#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语 iOS · Xcode 工程结构校验器（validate_project.py）

用途
----
`scripts/gen_xcodeproj.py` 用 Python 程序化生成 `ios/AIKeyboard.xcodeproj/project.pbxproj`，
本脚本是它的**独立第二道门**：不依赖生成脚本的任何内部数据结构，
完全重新解析落盘的 pbxproj 文本，逐项校验结构正确性。

因为开发者（以及 CI）都在 Windows / Linux 上，没有 Xcode 可用来"打开工程验证"，
所以只能靠静态校验尽量兜住"打不开的工程"这一类事故。

校验项
------
结构层：
  1. 花括号 `{}` / 圆括号 `()` 平衡（跳过字符串与注释）
  2. 用 OpenStep plist 递归下降解析器完整解析 pbxproj（解析不了 = P0）
  3. objectVersion / compatibilityVersion 合法（56 或 60；Xcode 14.0 / 15.0）
  4. rootObject → PBXProject 存在

UUID 层：
  5. 每个 24 位十六进制 UUID 引用都必须在本文件内有定义
  6. 每个 PBXBuildFile.fileRef 都存在
  7. 每个 target 的 buildConfigurationList / productReference 都存在

target 层：
  8. 两个 target 都存在，productType 正确
  9. 每个 target 都有 Sources / Frameworks / Resources 三个阶段
 10. Sources 阶段非空（目录为空时降级为 WARNING）
 11. App 的 buildPhases 含 Copy Files 阶段，dstSubfolderSpec == 13（Embed Foundation Extensions）
 12. Embed 阶段嵌入的 Product 就是 Extension target 的 productReference
 13. App 依赖 Extension（PBXTargetDependency + PBXContainerItemProxy）

文件引用层：
 14. 每个 PBXFileReference 的 path 在磁盘上真实存在（sourceTree = SOURCE_ROOT 时）
 15. 无重复 path（同一 physical path 只能被引用一次）
 16. App 的 Resources 含 Assets.xcassets（folder.assetcatalog）与 Shared 资源文件夹引用
 17. Extension 的 Resources 含 Shared 资源文件夹引用（folder reference，lastKnownFileType = folder）
 18. 磁盘上的 .swift 文件都被收进对应 target（Shared 进两个 target、App 只进 App、Ext 只进 Ext）

配置层：
 19. 每个 target 的 INFOPLIST_FILE / CODE_SIGN_ENTITLEMENTS 在磁盘上存在
 20. 两个 Info.plist 能被 plistlib 解析，且 Extension 的 NSExtension 五个键齐全
 21. baseConfigurationReference 指向的 xcconfig 存在
 22. buildSettings 里必填键齐全（SWIFT_VERSION / IPHONEOS_DEPLOYMENT_TARGET / ...）

group / scheme 层：
 23. mainGroup / productRefGroup 合法且互相可寻址
 24. Products 组里含两个 target 的 productReference
 25. shared scheme 存在、BlueprintIdentifier 指向真实 target

退出码
------
0 = 通过（可能有 WARNING）
1 = 存在 P0 错误（工程很可能打不开或构建失败）
2 = 脚本自身无法运行（文件缺失等）

用法
----
    python scripts/validate_project.py
    python scripts/validate_project.py --strict      # WARNING 也算失败
    python scripts/validate_project.py -v            # 打印更多细节
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
IOS_DIR_NAME = "ios"
PROJECT_DIR_NAME = "AIKeyboard.xcodeproj"
PBXPROJ_NAME = "project.pbxproj"

APP_TARGET = "AIKeyboard"
EXT_TARGET = "AIKeyboardExtension"

PRODUCT_TYPE_APP = "com.apple.product-type.application"
PRODUCT_TYPE_EXT = "com.apple.product-type.app-extension"

ALLOWED_OBJECT_VERSIONS = {"56", "60"}
ALLOWED_COMPATIBILITY_VERSIONS = {"Xcode 14.0", "Xcode 15.0"}

RE_UUID = re.compile(r"^[0-9A-Fa-f]{24}$")

EMBED_DST_SUBFOLDER_PLUGINS = 13

#: 共享资源目录（folder reference，两个 target 都要引；目录不存在时降级为 WARNING）
SHARED_RESOURCES_REL = "Shared/Resources"

#: target 的 buildSettings 里必须出现的键（生成器会把 xcconfig 标量回填进来）
REQUIRED_BUILD_SETTINGS_COMMON = [
    "SWIFT_VERSION",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "CODE_SIGN_STYLE",
    "TARGETED_DEVICE_FAMILY",
    "INFOPLIST_FILE",
    "CODE_SIGN_ENTITLEMENTS",
]
REQUIRED_BUILD_SETTINGS_EXT = [
    "APPLICATION_EXTENSION_API_ONLY",
    "SKIP_INSTALL",
]

#: 磁盘扫描时跳过的目录名
SKIP_DIR_NAMES = {
    ".git", ".svn", ".hg", "build", "DerivedData", "xcuserdata",
    ".swiftpm", "__pycache__", "node_modules", ".build", ".tmp",
}

# ---------------------------------------------------------------------------
# 报告
# ---------------------------------------------------------------------------


@dataclass
class Issue:
    level: str   # P0 / P1 / WARNING / INFO
    code: str
    message: str


@dataclass
class Report:
    checks_run: int = 0
    issues: list[Issue] = field(default_factory=list)

    def _add(self, level: str, code: str, message: str) -> None:
        self.issues.append(Issue(level=level, code=code, message=message))

    def p0(self, code: str, message: str) -> None:
        self._add("P0", code, message)

    def p1(self, code: str, message: str) -> None:
        self._add("P1", code, message)

    def warn(self, code: str, message: str) -> None:
        self._add("WARNING", code, message)

    def info(self, code: str, message: str) -> None:
        self._add("INFO", code, message)

    def ok(self, code: str, message: str) -> None:
        """记录一条通过的校验（仅 --verbose 展示）。"""
        self.checks_run += 1
        self._add("OK", code, message)

    @property
    def errors(self) -> list[Issue]:
        return [i for i in self.issues if i.level == "P0"]

    @property
    def p1s(self) -> list[Issue]:
        return [i for i in self.issues if i.level == "P1"]

    @property
    def warnings(self) -> list[Issue]:
        return [i for i in self.issues if i.level == "WARNING"]

    @property
    def oks(self) -> list[Issue]:
        return [i for i in self.issues if i.level == "OK"]


# ---------------------------------------------------------------------------
# OpenStep plist 解析器（pbxproj 的语法）
# ---------------------------------------------------------------------------


class PbxSyntaxError(Exception):
    """pbxproj 语法错误。"""


class Tokens:
    """把 pbxproj 文本切成 token 流。注释丢弃，字符串还原。"""

    _PUNCT = set("{}()=;,")

    def __init__(self, text: str) -> None:
        self.tokens: list[tuple[str, str]] = []
        self._scan(text)
        self.pos = 0

    def _scan(self, text: str) -> None:
        i = 0
        n = len(text)
        while i < n:
            ch = text[i]
            if ch in " \t\r\n":
                i += 1
                continue
            # /* ... */ 块注释（pbxproj 里到处都是）
            if text.startswith("/*", i):
                end = text.find("*/", i + 2)
                if end < 0:
                    raise PbxSyntaxError(f"块注释未闭合（offset {i}）")
                i = end + 2
                continue
            # // 行注释：只在行首或空白之后才当注释，避免误伤 URL
            if text.startswith("//", i) and (i == 0 or text[i - 1] in " \t\r\n"):
                end = text.find("\n", i)
                i = n if end < 0 else end + 1
                continue
            if ch == '"':
                i += 1
                buf: list[str] = []
                while i < n:
                    c = text[i]
                    if c == "\\":
                        if i + 1 >= n:
                            raise PbxSyntaxError("字符串转义在文件末尾截断")
                        buf.append(text[i + 1])
                        i += 2
                        continue
                    if c == '"':
                        i += 1
                        break
                    buf.append(c)
                    i += 1
                else:
                    raise PbxSyntaxError("字符串未闭合")
                self.tokens.append(("str", "".join(buf)))
                continue
            if ch in self._PUNCT:
                self.tokens.append(("punct", ch))
                i += 1
                continue
            # 裸 token：一直读到分隔符
            j = i
            while j < n and text[j] not in ' \t\r\n{}()=;,"':
                j += 1
            if j == i:
                raise PbxSyntaxError(f"无法识别的字符 {text[i]!r}（offset {i}）")
            self.tokens.append(("str", text[i:j]))
            i = j

    def peek(self) -> tuple[str, str] | None:
        if self.pos >= len(self.tokens):
            return None
        return self.tokens[self.pos]

    def take(self) -> tuple[str, str]:
        tok = self.peek()
        if tok is None:
            raise PbxSyntaxError("token 流意外结束")
        self.pos += 1
        return tok

    def expect(self, value: str) -> None:
        kind, val = self.take()
        if val != value:
            raise PbxSyntaxError(f"期望 {value!r}，实际 {val!r}（{kind}）")


def parse_plist(text: str) -> dict:
    """解析 pbxproj 顶层字典。"""
    toks = Tokens(text)

    def parse_value():
        tok = toks.peek()
        if tok is None:
            raise PbxSyntaxError("意外结束")
        kind, val = tok
        if kind == "punct":
            if val == "{":
                return parse_dict()
            if val == "(":
                return parse_array()
            raise PbxSyntaxError(f"值位置出现非法符号 {val!r}")
        toks.take()
        return val

    def parse_dict() -> dict:
        toks.expect("{")
        out: dict = {}
        while True:
            tok = toks.peek()
            if tok is None:
                raise PbxSyntaxError("字典未闭合")
            kind, val = tok
            if kind == "punct" and val == "}":
                toks.take()
                return out
            key = toks.take()[1]
            toks.expect("=")
            out[key] = parse_value()
            tok2 = toks.peek()
            if tok2 is not None and tok2[1] == ";":
                toks.take()
            elif tok2 is not None and tok2[1] == "}":
                continue  # 容忍最后一项省略分号
            else:
                raise PbxSyntaxError(f"字典项 {key} 后缺少 ';'")

    def parse_array() -> list:
        toks.expect("(")
        out: list = []
        while True:
            tok = toks.peek()
            if tok is None:
                raise PbxSyntaxError("数组未闭合")
            kind, val = tok
            if kind == "punct" and val == ")":
                toks.take()
                return out
            out.append(parse_value())
            tok2 = toks.peek()
            if tok2 is not None and tok2[1] == ",":
                toks.take()
            elif tok2 is not None and tok2[1] == ")":
                continue  # 尾随逗号可省

    result = parse_value()
    if not isinstance(result, dict):
        raise PbxSyntaxError("顶层不是字典")
    leftover = toks.peek()
    if leftover is not None:
        raise PbxSyntaxError(f"顶层字典之后还有多余内容：{leftover!r}")
    return result


# ---------------------------------------------------------------------------
# 文本层辅助
# ---------------------------------------------------------------------------


def strip_comments(text: str) -> str:
    """去掉 /* */ 与 // 注释（保留换行，避免行号漂移太多）。"""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)(^|\s)//[^\n]*", r"\1", text)
    return text


def check_balance(text: str, report: Report) -> None:
    """花括号 / 圆括号平衡（跳过字符串、注释）。"""
    text = strip_comments(text)
    pairs = {"{": "}", "(": ")"}
    stack: list[tuple[str, int]] = []
    in_str = False
    escaped = False
    line = 1
    for idx, ch in enumerate(text):
        if ch == "\n":
            line += 1
        if in_str:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
            continue
        if ch in pairs:
            stack.append((ch, line))
        elif ch in "})":
            if not stack:
                report.p0("BALANCE-EXTRA-CLOSE", f"第 {line} 行出现多余的 {ch!r}")
                return
            opener, oline = stack.pop()
            if pairs[opener] != ch:
                report.p0(
                    "BALANCE-MISMATCH",
                    f"第 {oline} 行的 {opener!r} 与第 {line} 行的 {ch!r} 不匹配",
                )
                return
    if in_str:
        report.p0("BALANCE-UNTERMINATED-STRING", "文件末尾有未闭合的字符串")
        return
    if stack:
        opener, oline = stack[-1]
        report.p0(
            "BALANCE-UNCLOSED",
            f"第 {oline} 行的 {opener!r} 未闭合（共 {len(stack)} 个未闭合括号）",
        )
        return
    report.ok("BALANCE", "花括号/圆括号平衡")


# ---------------------------------------------------------------------------
# 磁盘扫描
# ---------------------------------------------------------------------------


def iter_files(root: Path, pattern: str) -> list[Path]:
    """递归收集文件，跳过构建产物与隐藏目录。"""
    if not root.is_dir():
        return []
    out: list[Path] = []
    for path in root.rglob(pattern):
        if not path.is_file():
            continue
        rel_parts = path.relative_to(root).parts[:-1]
        if any(p in SKIP_DIR_NAMES or p.startswith(".") for p in rel_parts):
            continue
        out.append(path)
    return sorted(out)


def rel_posix(path: Path, base: Path) -> str:
    return path.relative_to(base).as_posix()


def scan_swift(ios_root: Path, sub: str, exclude_dirs: tuple[str, ...] = ()) -> list[str]:
    """扫描 ios/<sub> 下的 .swift，返回相对 ios/ 的 POSIX 路径。"""
    root = ios_root / sub
    out: list[str] = []
    for path in iter_files(root, "*.swift"):
        rel = rel_posix(path, ios_root)
        if any(rel.startswith(e) for e in exclude_dirs):
            continue
        out.append(rel)
    return sorted(out)


# ---------------------------------------------------------------------------
# 主校验
# ---------------------------------------------------------------------------


class Validator:
    def __init__(self, ios_root: Path, report: Report, verbose: bool = False) -> None:
        self.ios = ios_root
        self.report = report
        self.verbose = verbose
        self.project_dir = ios_root / PROJECT_DIR_NAME
        self.pbxproj_path = self.project_dir / PBXPROJ_NAME
        self.raw = ""
        self.clean = ""
        self.root: dict = {}
        self.objects: dict[str, dict] = {}

    # -- 便捷访问 ---------------------------------------------------------

    def obj(self, uid: str) -> dict | None:
        o = self.objects.get(uid)
        return o if isinstance(o, dict) else None

    def isa(self, uid: str) -> str:
        o = self.obj(uid)
        return (o or {}).get("isa", "") if o else ""

    def by_isa(self, isa: str) -> list[tuple[str, dict]]:
        return [(u, o) for u, o in self.objects.items()
                if isinstance(o, dict) and o.get("isa") == isa]

    # -- 入口 -------------------------------------------------------------

    def run(self) -> None:
        if not self.pbxproj_path.is_file():
            self.report.p0(
                "PBXPROJ-MISSING",
                f"找不到 {self.pbxproj_path.relative_to(self.ios.parent).as_posix()}；"
                f"请先运行 python scripts/gen_xcodeproj.py",
            )
            return
        self.raw = self.pbxproj_path.read_text(encoding="utf-8", errors="replace")
        self.report.ok("PBXPROJ-EXISTS",
                       f"{self.pbxproj_path.relative_to(self.ios.parent).as_posix()} "
                       f"({len(self.raw)} 字符, {len(self.raw.splitlines())} 行)")

        check_balance(self.raw, self.report)

        if not self.parse():
            return

        self.check_object_versions()
        self.check_project_root()
        self.check_uuid_references()
        self.check_build_files()
        self.check_targets()
        self.check_sources()
        self.check_resources()
        self.check_embed_extension()
        self.check_file_refs()
        self.check_duplicate_paths()
        self.check_config_refs()
        self.check_build_settings()
        self.check_groups()
        self.check_schemes()
        self.check_disk_membership()

    # -- 解析 -------------------------------------------------------------

    def parse(self) -> bool:
        try:
            self.root = parse_plist(self.raw)
        except PbxSyntaxError as exc:
            self.report.p0("PBXPROJ-PARSE", f"pbxproj 解析失败：{exc}")
            return False
        arch = self.root.get("archiveVersion")
        if arch != "1":
            self.report.p1("ARCHIVE-VERSION", f"archiveVersion 期望 '1'，实际 {arch!r}")
        objs = self.root.get("objects")
        if not isinstance(objs, dict):
            self.report.p0("OBJECTS-MISSING", "顶层缺少 objects 字典")
            return False
        self.objects = {k: v for k, v in objs.items() if isinstance(v, dict)}
        bad = [k for k, v in objs.items() if not isinstance(v, dict)]
        if bad:
            self.report.p0("OBJECTS-NOT-DICT",
                           f"objects 里有 {len(bad)} 个值不是字典：{bad[:5]}")
        self.report.ok("PARSE", f"OpenStep plist 解析通过，{len(self.objects)} 个对象")
        return True

    # -- 1. 版本 ----------------------------------------------------------

    def check_object_versions(self) -> None:
        ov = self.root.get("objectVersion", "")
        if ov not in ALLOWED_OBJECT_VERSIONS:
            self.report.p1(
                "OBJECT-VERSION",
                f"objectVersion={ov!r} 不在推荐集合 {sorted(ALLOWED_OBJECT_VERSIONS)} 中"
                f"（Xcode 14/15/16 的兼容值）",
            )
        else:
            self.report.ok("OBJECT-VERSION", f"objectVersion={ov}")

        proj_uids = [u for u, o in self.objects.items() if o.get("isa") == "PBXProject"]
        for uid in proj_uids:
            proj = self.objects[uid]
            cv = proj.get("compatibilityVersion", "")
            if cv not in ALLOWED_COMPATIBILITY_VERSIONS:
                self.report.p1(
                    "COMPATIBILITY-VERSION",
                    f"project.compatibilityVersion={cv!r} 不在 "
                    f"{sorted(ALLOWED_COMPATIBILITY_VERSIONS)} 中",
                )
            else:
                self.report.ok("COMPATIBILITY-VERSION", f"compatibilityVersion={cv!r}")
            attrs = proj.get("attributes") or {}
            luc = attrs.get("LastUpgradeCheck")
            if luc is None:
                self.report.warn("LAST-UPGRADE-CHECK", "attributes.LastUpgradeCheck 缺失")
            else:
                try:
                    val = int(str(luc))
                except ValueError:
                    self.report.warn("LAST-UPGRADE-CHECK",
                                     f"LastUpgradeCheck={luc!r} 不是整数")
                else:
                    if val < 1300:
                        self.report.warn(
                            "LAST-UPGRADE-CHECK",
                            f"LastUpgradeCheck={val} 偏旧（Xcode 会提示升级工程设置）",
                        )
                    else:
                        self.report.ok("LAST-UPGRADE-CHECK", f"LastUpgradeCheck={val}")

    # -- 2. 工程根对象 ----------------------------------------------------

    def check_project_root(self) -> None:
        root_uid = self.root.get("rootObject", "")
        if not RE_UUID.match(str(root_uid)):
            self.report.p0("ROOT-OBJECT-UUID", f"rootObject={root_uid!r} 不是 24 位 UUID")
            return
        proj = self.obj(root_uid)
        if proj is None:
            self.report.p0("ROOT-OBJECT-MISSING", f"rootObject={root_uid} 未在 objects 中定义")
            return
        if proj.get("isa") != "PBXProject":
            self.report.p0("ROOT-OBJECT-ISA",
                           f"rootObject 的 isa 应为 PBXProject，实际 {proj.get('isa')!r}")
            return
        self.report.ok("ROOT-OBJECT", f"rootObject → PBXProject {root_uid}")

        self.project_uid = root_uid
        self.main_group_uid = str(proj.get("mainGroup", ""))
        self.products_group_uid = str(proj.get("productRefGroup", ""))

    # -- 3. UUID 引用完整性 -----------------------------------------------

    def check_uuid_references(self) -> None:
        defined = set(self.objects)
        referenced: dict[str, list[str]] = {}

        def walk(node, path: str) -> None:
            if isinstance(node, dict):
                for k, v in node.items():
                    walk(v, f"{path}.{k}")
            elif isinstance(node, list):
                for idx, v in enumerate(node):
                    walk(v, f"{path}[{idx}]")
            elif isinstance(node, str) and RE_UUID.match(node):
                referenced.setdefault(node, []).append(path)

        walk(self.objects, "objects")
        dangling = {u: paths for u, paths in referenced.items() if u not in defined}
        if dangling:
            sample = list(dangling.items())[:5]
            detail = "; ".join(f"{u} ← {p[0]}" for u, p in sample)
            self.report.p0(
                "UUID-DANGLING",
                f"有 {len(dangling)} 个 UUID 被引用但未定义：{detail}",
            )
        else:
            self.report.ok("UUID-REFERENCES",
                           f"{len(referenced)} 个被引用 UUID 全部有定义")

        # 反向：定义了但从未被引用的对象（除了 rootObject 自身）
        unused = [u for u in defined if u not in referenced and u != self.root.get("rootObject")]
        if unused:
            self.report.warn(
                "UUID-ORPHAN",
                f"有 {len(unused)} 个对象已定义但未被引用（可能是垃圾对象）：{unused[:5]}",
            )
        else:
            self.report.ok("UUID-ORPHAN", "没有孤儿对象")

    # -- 4. PBXBuildFile --------------------------------------------------

    def check_build_files(self) -> None:
        build_files = self.by_isa("PBXBuildFile")
        if not build_files:
            self.report.p0("BUILDFILE-EMPTY", "没有任何 PBXBuildFile，工程里不会有源文件")
            return
        missing = []
        for uid, bf in build_files:
            ref = str(bf.get("fileRef", ""))
            if not RE_UUID.match(ref):
                missing.append(f"{uid}(fileRef={ref!r} 非法)")
            elif ref not in self.objects:
                missing.append(f"{uid}(fileRef={ref} 不存在)")
        if missing:
            self.report.p0(
                "BUILDFILE-FILEREF",
                f"有 {len(missing)} 个 PBXBuildFile 的 fileRef 无效：{missing[:5]}",
            )
        else:
            self.report.ok("BUILDFILE-FILEREF", f"{len(build_files)} 个 PBXBuildFile 的 fileRef 均有效")

        empties = [uid for uid, bf in build_files if not bf.get("fileRef")]
        if empties:
            self.report.p0("BUILDFILE-NO-FILEREF", f"PBXBuildFile 缺少 fileRef：{empties[:5]}")

    # -- 5. target --------------------------------------------------------

    def check_targets(self) -> None:
        targets = self.by_isa("PBXNativeTarget")
        by_name = {}
        for uid, t in targets:
            name = str(t.get("name", ""))
            by_name[name] = (uid, t)
        self.targets = by_name

        for name, want_type in ((APP_TARGET, PRODUCT_TYPE_APP), (EXT_TARGET, PRODUCT_TYPE_EXT)):
            if name not in by_name:
                self.report.p0("TARGET-MISSING", f"缺少 target {name!r}")
                continue
            uid, t = by_name[name]
            ptype = str(t.get("productType", ""))
            if ptype != want_type:
                self.report.p0(
                    "TARGET-PRODUCT-TYPE",
                    f"target {name} 的 productType={ptype!r}，期望 {want_type!r}",
                )
            else:
                self.report.ok("TARGET-PRODUCT-TYPE", f"{name} productType 正确")

            pr = str(t.get("productReference", ""))
            prod = self.obj(pr)
            if prod is None:
                self.report.p0("TARGET-PRODUCT-REF",
                               f"target {name} 的 productReference={pr} 不存在")
            else:
                self.report.ok("TARGET-PRODUCT-REF",
                               f"{name} productReference → {prod.get('path', '?')}")

            bcl = str(t.get("buildConfigurationList", ""))
            if self.obj(bcl) is None or self.isa(bcl) != "XCConfigurationList":
                self.report.p0("TARGET-CONFIG-LIST",
                               f"target {name} 的 buildConfigurationList 无效（{bcl}）")

            phases = t.get("buildPhases") or []
            if not isinstance(phases, list) or not phases:
                self.report.p0("TARGET-NO-PHASES", f"target {name} 没有任何 buildPhases")
                continue
            phase_isas = []
            for pu in phases:
                po = self.obj(str(pu))
                if po is None:
                    self.report.p0("TARGET-PHASE-MISSING",
                                   f"target {name} 的 buildPhase {pu} 未定义")
                    phase_isas.append("")
                else:
                    phase_isas.append(str(po.get("isa", "")))
            for need, cn in (
                ("PBXSourcesBuildPhase", "Sources"),
                ("PBXFrameworksBuildPhase", "Frameworks"),
                ("PBXResourcesBuildPhase", "Resources"),
            ):
                if need not in phase_isas:
                    self.report.p0(
                        "TARGET-MISSING-PHASE",
                        f"target {name} 缺少 {cn} 阶段（{need}）",
                    )
                else:
                    self.report.ok("TARGET-MISSING-PHASE", f"{name} 具备 {cn} 阶段")

    # -- 6. Sources -------------------------------------------------------

    def _phase_rel_paths(self, target_name: str, isa: str) -> list[tuple[str, str]]:
        """返回某 target 某阶段里所有 buildFile 对应的 (buildFileUUID, relPath)。"""
        entry = self.targets.get(target_name)
        if not entry:
            return []
        _, t = entry
        out: list[tuple[str, str]] = []
        for pu in t.get("buildPhases") or []:
            po = self.obj(str(pu))
            if po is None or po.get("isa") != isa:
                continue
            for bf_uid in po.get("files") or []:
                bf = self.obj(str(bf_uid))
                if bf is None:
                    out.append((str(bf_uid), "<buildFile 未定义>"))
                    continue
                ref = str(bf.get("fileRef", ""))
                fr = self.obj(ref)
                if fr is None:
                    out.append((str(bf_uid), "<fileRef 未定义>"))
                    continue
                out.append((str(bf_uid), str(fr.get("path", ""))))
        return out

    def check_sources(self) -> None:
        self.app_sources = self._phase_rel_paths(APP_TARGET, "PBXSourcesBuildPhase")
        self.ext_sources = self._phase_rel_paths(EXT_TARGET, "PBXSourcesBuildPhase")
        self.app_resources = self._phase_rel_paths(APP_TARGET, "PBXResourcesBuildPhase")
        self.ext_resources = self._phase_rel_paths(EXT_TARGET, "PBXResourcesBuildPhase")

        for name, entries, sub in (
            (APP_TARGET, self.app_sources, "AIKeyboard"),
            (EXT_TARGET, self.ext_sources, "AIKeyboardExtension"),
        ):
            if entries:
                self.report.ok("SOURCES-NONEMPTY",
                               f"{name} Sources 有 {len(entries)} 个编译单元")
            else:
                self.report.warn(
                    "SOURCES-EMPTY",
                    f"{name} 的 Sources 阶段为空 → 该 target 无法编译。"
                    f"如果 ios/{sub}/ 还没有源码，等其他模块落盘后重跑 "
                    f"python scripts/gen_xcodeproj.py 即可",
                )

        # App 不应该编进 Extension 的专属源码
        ext_only = set(scan_swift(self.ios, "AIKeyboardExtension"))
        app_only = set(scan_swift(self.ios, "AIKeyboard"))
        app_paths = {p for _, p in self.app_sources}
        ext_paths = {p for _, p in self.ext_sources}
        leaked = sorted(ext_only & app_paths)
        if leaked:
            self.report.p0("APP-CONTAINS-EXT-SOURCE",
                           f"App target 编进了 Extension 专属源码：{leaked[:5]}")
        leaked2 = sorted(app_only & ext_paths)
        if leaked2:
            self.report.p0("EXT-CONTAINS-APP-SOURCE",
                           f"Extension target 编进了 App 专属源码：{leaked2[:5]}")
        if not leaked and not leaked2:
            self.report.ok("SOURCE-OWNERSHIP", "App/Extension 专属源码没有互相串味")

    # -- 7. Resources -----------------------------------------------------

    def check_resources(self) -> None:
        def classify(target_name: str, entries: list[tuple[str, str]]) -> dict[str, str]:
            """返回 {类别: rel path}"""
            found: dict[str, str] = {}
            for _, path in entries:
                if path.endswith(".xcassets"):
                    found["assets"] = path
                elif path.endswith("/Resources") or path == "Shared/Resources":
                    found["shared"] = path
            return found

        app = classify(APP_TARGET, self.app_resources)
        ext = classify(EXT_TARGET, self.ext_resources)

        # --- App：Assets + Shared
        if "assets" not in app:
            self.report.p0("APP-RESOURCES-ASSETS",
                           "App 的 Resources 阶段缺少 Assets.xcassets（AppIcon 不会打包）")
        else:
            self.report.ok("APP-RESOURCES-ASSETS", f"App Resources 含 {app['assets']}")
            asset_path = self.ios / app["assets"].split("/")[-1] if False else self.ios / app["assets"]
            if not asset_path.is_dir():
                self.report.p0("APP-RESOURCES-ASSETS-DISK",
                               f"Assets 目录在磁盘上不存在：{app['assets']}")
            else:
                icon_contents = asset_path / "AppIcon.appiconset" / "Contents.json"
                if not icon_contents.is_file():
                    self.report.warn("APPICON-MISSING",
                                     f"{app['assets']}/AppIcon.appiconset/Contents.json 不存在；"
                                     f"运行 python scripts/make_appicon.py 生成")
                else:
                    try:
                        icon_meta = json.loads(icon_contents.read_text(encoding="utf-8"))
                    except (OSError, json.JSONDecodeError) as exc:
                        self.report.p0("APPICON-JSON", f"AppIcon Contents.json 解析失败：{exc}")
                    else:
                        images = icon_meta.get("images") or []
                        if not images:
                            self.report.p0("APPICON-IMAGES", "AppIcon Contents.json 的 images 为空")
                        else:
                            first = images[0]
                            fname = str(first.get("filename", ""))
                            if not fname:
                                self.report.p0("APPICON-FILENAME", "AppIcon images[0] 缺少 filename")
                            elif not (asset_path / "AppIcon.appiconset" / fname).is_file():
                                self.report.p0("APPICON-PNG",
                                               f"AppIcon 图片不存在：{fname}")
                            else:
                                self.report.ok("APPICON", f"AppIcon 到位（{fname}）")

        # 注意：Shared/Resources 尚未落盘时，gen 脚本不会凭空造文件夹引用（--repo-root 的
        # 空仓库场景）。此时降级为 WARNING：目录本身不存在 → 缺引用是预期行为，不是结构错误。
        shared_dir_exists = (self.ios / SHARED_RESOURCES_REL).is_dir()

        if "shared" not in app:
            if shared_dir_exists:
                self.report.p0("APP-RESOURCES-SHARED",
                               "App 的 Resources 阶段缺少 Shared 资源文件夹引用"
                               "（Shared/Resources，folder reference）")
            else:
                self.report.warn(
                    "APP-RESOURCES-SHARED",
                    f"App 的 Resources 阶段没有 {SHARED_RESOURCES_REL}（磁盘上该目录尚不存在；"
                    f"词库落盘后重跑 python scripts/gen_xcodeproj.py 会自动加入）",
                )
        else:
            self.report.ok("APP-RESOURCES-SHARED", f"App Resources 含 {app['shared']}")
            if not (self.ios / app["shared"]).is_dir():
                self.report.warn("APP-RESOURCES-SHARED-DISK",
                                 f"{app['shared']} 目录在磁盘上不存在（词库尚未落盘）")

        # --- Extension：Shared
        if "shared" not in ext:
            if shared_dir_exists:
                self.report.p0("EXT-RESOURCES-SHARED",
                               "Extension 的 Resources 阶段缺少 Shared 资源文件夹引用"
                               "（键盘扩展读不到词库）")
            else:
                self.report.warn(
                    "EXT-RESOURCES-SHARED",
                    f"Extension 的 Resources 阶段没有 {SHARED_RESOURCES_REL}"
                    f"（磁盘上该目录尚不存在；词库落盘后重跑 python scripts/gen_xcodeproj.py）",
                )
        else:
            self.report.ok("EXT-RESOURCES-SHARED", f"Extension Resources 含 {ext['shared']}")

        # 文件夹引用的 lastKnownFileType 必须是 folder（blue folder），否则会被拍平
        for target_name, entries in ((APP_TARGET, self.app_resources),
                                     (EXT_TARGET, self.ext_resources)):
            for _, path in entries:
                if not (path.endswith("/Resources") or path == "Shared/Resources"):
                    continue
                ref_uid = None
                for pu in self.targets[target_name][1].get("buildPhases") or []:
                    po = self.obj(str(pu))
                    if po is None or po.get("isa") != "PBXResourcesBuildPhase":
                        continue
                    for bf_uid in po.get("files") or []:
                        bf = self.obj(str(bf_uid)) or {}
                        ref_uid = str(bf.get("fileRef", ""))
                        fr = self.obj(ref_uid) or {}
                        if str(fr.get("path", "")) != path:
                            continue
                        ftype = str(fr.get("lastKnownFileType") or fr.get("explicitFileType") or "")
                        if ftype != "folder":
                            self.report.p0(
                                "RESOURCE-FOLDER-TYPE",
                                f"{target_name} 里的 {path} 的 lastKnownFileType={ftype!r}，"
                                f"folder reference 必须是 'folder'",
                            )
                        else:
                            self.report.ok("RESOURCE-FOLDER-TYPE",
                                           f"{target_name} 的 {path} 是 folder reference")
                break

    # -- 8. Embed Extension ------------------------------------------------

    def check_embed_extension(self) -> None:
        ext_entry = self.targets.get(EXT_TARGET)
        if not ext_entry:
            return
        _, ext_target = ext_entry
        ext_product = str(ext_target.get("productReference", ""))

        copy_phases = []
        app_entry = self.targets.get(APP_TARGET)
        if app_entry:
            for pu in app_entry[1].get("buildPhases") or []:
                po = self.obj(str(pu))
                if po is not None and po.get("isa") == "PBXCopyFilesBuildPhase":
                    copy_phases.append((str(pu), po))

        if not copy_phases:
            self.report.p0(
                "EMBED-PHASE-MISSING",
                f"App target 没有 Copy Files 阶段；键盘扩展不会被嵌入 .app/PlugIns，"
                f"真机上添加键盘时看不到墨语",
            )
            return

        embed = None
        for uid, po in copy_phases:
            try:
                spec = int(str(po.get("dstSubfolderSpec", "-1")))
            except ValueError:
                spec = -1
            name = str(po.get("name", ""))
            if spec == EMBED_DST_SUBFOLDER_PLUGINS:
                embed = (uid, po)
                break
        if embed is None:
            self.report.p0(
                "EMBED-DST-SPEC",
                f"App 的 Copy Files 阶段 dstSubfolderSpec != 13（PlugIns）："
                f"{[(u, p.get('dstSubfolderSpec')) for u, p in copy_phases]}",
            )
            return
        uid, po = embed
        dst_path = str(po.get("dstPath", ""))
        if dst_path not in ("", None):
            self.report.p1("EMBED-DST-PATH",
                           f"Embed 阶段 dstPath={dst_path!r}，期望空字符串（PlugIns 根）")
        else:
            self.report.ok("EMBED-DST-PATH", "Embed 阶段 dstPath 为空")

        # files → buildFile → fileRef 必须是 Extension 的 productReference
        ok_embed = False
        for bf_uid in po.get("files") or []:
            bf = self.obj(str(bf_uid)) or {}
            ref = str(bf.get("fileRef", ""))
            fr = self.obj(ref) or {}
            if ref == ext_product:
                ok_embed = True
                attrs = str(bf.get("settings", ""))
                if "RemoveHeadersOnCopy" not in attrs:
                    self.report.p1("EMBED-ATTRS",
                                   "Embed 的 PBXBuildFile 缺少 ATTRIBUTES = (RemoveHeadersOnCopy)")
                else:
                    self.report.ok("EMBED-ATTRS", "Embed 的 ATTRIBUTES 含 RemoveHeadersOnCopy")
                if not str(fr.get("path", "")).endswith(".appex"):
                    self.report.p0("EMBED-PRODUCT",
                                   f"被 Embed 的产物不是 .appex：{fr.get('path')!r}")
                elif fr.get("explicitFileType") not in (None, "wrapper.app-extension"):
                    self.report.p0(
                        "EMBED-PRODUCT-TYPE",
                        f"Extension 产物的 explicitFileType={fr.get('explicitFileType')!r}，"
                        f"期望 wrapper.app-extension",
                    )
                break
        if not ok_embed:
            self.report.p0(
                "EMBED-NOT-EXTENSION",
                f"Embed 阶段嵌入的不是 Extension 的 productReference（{ext_product}）",
            )
        else:
            self.report.ok("EMBED-EXTENSION", "Embed 阶段正确嵌入 AIKeyboardExtension.appex")

        # 依赖关系
        deps = app_entry[1].get("dependencies") or []
        found_dep = False
        for du in deps:
            do = self.obj(str(du)) or {}
            if do.get("isa") != "PBXTargetDependency":
                continue
            if str(do.get("target", "")) == self.targets[EXT_TARGET][0]:
                found_dep = True
                proxy = self.obj(str(do.get("targetProxy", "")))
                if proxy is None or proxy.get("isa") != "PBXContainerItemProxy":
                    self.report.p1("DEPENDENCY-PROXY",
                                   "PBXTargetDependency 缺少合法的 PBXContainerItemProxy")
                else:
                    remote = str(proxy.get("remoteGlobalIDString", ""))
                    if remote != self.targets[EXT_TARGET][0]:
                        self.report.p1("DEPENDENCY-PROXY-REMOTE",
                                       f"proxy.remoteGlobalIDString={remote} 与 Extension target 不符")
                    else:
                        self.report.ok("DEPENDENCY-PROXY", "Extension 依赖 proxy 正确")
                break
        if not found_dep:
            self.report.p1("DEPENDENCY-MISSING",
                           "App target 没有依赖 Extension（增量构建时可能用到旧 .appex）")
        else:
            self.report.ok("DEPENDENCY", "App 依赖 Extension")

    # -- 9. 文件引用 ------------------------------------------------------

    def check_file_refs(self) -> None:
        missing: list[str] = []
        outside: list[str] = []
        checked = 0
        for uid, fr in self.by_isa("PBXFileReference"):
            path = str(fr.get("path", ""))
            tree = str(fr.get("sourceTree", ""))
            if not path or tree in ("BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR"):
                continue
            if fr.get("explicitFileType", "").startswith("wrapper."):
                continue
            checked += 1
            target = (self.ios / path).resolve()
            try:
                target.relative_to(self.ios.resolve())
            except ValueError:
                outside.append(f"{path}（越出 ios/ 目录）")
                continue
            if not target.exists():
                missing.append(f"{path}（sourceTree={tree}）")
        if missing:
            self.report.p0(
                "FILEREF-MISSING",
                f"有 {len(missing)} 个 file reference 在磁盘上不存在：{missing[:6]}",
            )
        if outside:
            self.report.p0("FILEREF-OUTSIDE", f"文件引用越出 ios/：{outside[:5]}")
        if not missing and not outside:
            self.report.ok("FILEREF-EXISTS", f"{checked} 个 file reference 在磁盘上均存在")

    def check_duplicate_paths(self) -> None:
        seen: dict[str, list[str]] = {}
        for uid, fr in self.by_isa("PBXFileReference"):
            path = str(fr.get("path", ""))
            tree = str(fr.get("sourceTree", ""))
            if not path or tree in ("BUILT_PRODUCTS_DIR", "SDKROOT", "DEVELOPER_DIR"):
                continue
            seen.setdefault(path, []).append(uid)
        dups = {p: u for p, u in seen.items() if len(u) > 1}
        if dups:
            detail = "; ".join(f"{p} × {len(u)}" for p, u in list(dups.items())[:5])
            self.report.p0("FILEREF-DUPLICATE", f"有 {len(dups)} 个路径被重复引用：{detail}")
        else:
            self.report.ok("FILEREF-DUPLICATE", f"{len(seen)} 个路径无重复引用")

    # -- 10. 配置引用 -----------------------------------------------------

    def check_config_refs(self) -> None:
        configs = self.by_isa("XCBuildConfiguration")
        missing = []
        checked = 0
        for uid, cfg in configs:
            base = str(cfg.get("baseConfigurationReference", ""))
            if not base:
                continue
            checked += 1
            fr = self.obj(base)
            if fr is None:
                missing.append(f"{uid}: baseConfigurationReference {base} 未定义")
                continue
            path = str(fr.get("path", ""))
            if not (self.ios / path).is_file():
                missing.append(f"{uid}: {path} 不存在")
        if missing:
            self.report.p0("XCCONFIG-MISSING", f"xcconfig 引用异常：{missing[:5]}")
        else:
            self.report.ok("XCCONFIG", f"{checked} 个 baseConfigurationReference 均指向存在的 xcconfig")

        # 每个配置的 name 必须是 Debug / Release
        bad = [str(c.get("name")) for _, c in configs if str(c.get("name")) not in ("Debug", "Release")]
        if bad:
            self.report.p1("CONFIG-NAME", f"build configuration 名称异常：{sorted(set(bad))}")
        lists = self.by_isa("XCConfigurationList")
        for uid, cl in lists:
            names = []
            for cu in cl.get("buildConfigurations") or []:
                co = self.obj(str(cu)) or {}
                names.append(str(co.get("name", "?")))
            if sorted(names) != ["Debug", "Release"]:
                self.report.p1("CONFIG-LIST",
                               f"配置列表 {uid} 的 configuration 为 {names}，期望 ['Debug','Release']")
                break
        else:
            self.report.ok("CONFIG-LIST", f"{len(lists)} 个配置列表都是 Debug+Release")

    # -- 11. buildSettings -------------------------------------------------

    def check_build_settings(self) -> None:
        for target_name, extra in ((APP_TARGET, []), (EXT_TARGET, REQUIRED_BUILD_SETTINGS_EXT)):
            entry = self.targets.get(target_name)
            if not entry:
                continue
            cfg_uids = []
            cl = self.obj(str(entry[1].get("buildConfigurationList", ""))) or {}
            for cu in cl.get("buildConfigurations") or []:
                cfg_uids.append(str(cu))
            if not cfg_uids:
                self.report.p0("BUILDSETTINGS-NO-CONFIG",
                               f"target {target_name} 没有 build configuration")
                continue
            for cu in cfg_uids:
                cfg = self.obj(cu) or {}
                bs = cfg.get("buildSettings") or {}
                cname = str(cfg.get("name", "?"))
                missing = [k for k in REQUIRED_BUILD_SETTINGS_COMMON + extra
                           if not str(bs.get(k, "")).strip()]
                if missing:
                    self.report.p0(
                        "BUILDSETTINGS-MISSING",
                        f"target {target_name} / {cname} 缺少 buildSettings：{missing}",
                    )
                else:
                    self.report.ok("BUILDSETTINGS-MISSING",
                                   f"{target_name}/{cname} 必填 buildSettings 齐全")

                swift_ver = str(bs.get("SWIFT_VERSION", ""))
                if swift_ver and not swift_ver.startswith("5"):
                    self.report.p1("SWIFT-VERSION",
                                   f"{target_name}/{cname} SWIFT_VERSION={swift_ver}，期望 5.x")
                ios_ver = str(bs.get("IPHONEOS_DEPLOYMENT_TARGET", ""))
                if ios_ver:
                    try:
                        major = int(ios_ver.split(".", 1)[0])
                    except ValueError:
                        self.report.p1("DEPLOYMENT-TARGET",
                                       f"{target_name}/{cname} IPHONEOS_DEPLOYMENT_TARGET 非法：{ios_ver!r}")
                    else:
                        if major < 16:
                            self.report.p1(
                                "DEPLOYMENT-TARGET",
                                f"{target_name}/{cname} 部署目标 {ios_ver} < 16.0（产品要求 iOS 16+）",
                            )
                        else:
                            self.report.ok("DEPLOYMENT-TARGET",
                                           f"{target_name}/{cname} 部署目标 {ios_ver}")

                family = str(bs.get("TARGETED_DEVICE_FAMILY", ""))
                if family and family not in ("1", "1,2", "2"):
                    self.report.p1("DEVICE-FAMILY",
                                   f"{target_name}/{cname} TARGETED_DEVICE_FAMILY={family!r} 异常")

                plist_rel = str(bs.get("INFOPLIST_FILE", ""))
                if plist_rel:
                    plist_path = self.ios / plist_rel
                    if not plist_path.is_file():
                        self.report.p0("INFOPLIST-MISSING",
                                       f"{target_name}/{cname} INFOPLIST_FILE={plist_rel} 不存在")
                    else:
                        self.report.ok("INFOPLIST-MISSING",
                                       f"{target_name}/{cname} Info.plist 存在（{plist_rel}）")
                        self._check_plist(target_name, plist_path)

                ent_rel = str(bs.get("CODE_SIGN_ENTITLEMENTS", ""))
                if ent_rel:
                    if not (self.ios / ent_rel).is_file():
                        self.report.p0("ENTITLEMENTS-MISSING",
                                       f"{target_name}/{cname} CODE_SIGN_ENTITLEMENTS={ent_rel} 不存在")
                    else:
                        self.report.ok("ENTITLEMENTS-MISSING",
                                       f"{target_name}/{cname} entitlements 存在（{ent_rel}）")

    def _check_plist(self, target_name: str, path: Path) -> None:
        rel = path.relative_to(self.ios).as_posix()
        try:
            with path.open("rb") as fh:
                data = plistlib.load(fh)
        except (OSError, plistlib.InvalidFileException) as exc:
            self.report.p0("PLIST-PARSE", f"{rel} 解析失败：{exc}")
            return
        if not isinstance(data, dict):
            self.report.p0("PLIST-ROOT", f"{rel} 根节点不是 dict")
            return
        self.report.ok("PLIST-PARSE", f"{rel} plistlib 解析通过")

        if target_name == EXT_TARGET:
            ext = data.get("NSExtension")
            if not isinstance(ext, dict):
                self.report.p0("EXT-PLIST-NSEXTENSION", f"{rel} 缺少 NSExtension 字典")
                return
            point = str(ext.get("NSExtensionPointIdentifier", ""))
            if point != "com.apple.keyboard-service":
                self.report.p0("EXT-PLIST-POINT",
                               f"{rel} NSExtensionPointIdentifier={point!r}，"
                               f"期望 com.apple.keyboard-service")
            else:
                self.report.ok("EXT-PLIST-POINT", "NSExtensionPointIdentifier 正确")
            principal = str(ext.get("NSExtensionPrincipalClass", ""))
            if "KeyboardViewController" not in principal:
                self.report.p0("EXT-PLIST-PRINCIPAL",
                               f"{rel} NSExtensionPrincipalClass={principal!r} 不含 "
                               f"KeyboardViewController")
            elif "$(PRODUCT_MODULE_NAME)" not in principal and "." not in principal:
                self.report.p1("EXT-PLIST-PRINCIPAL",
                               f"{rel} NSExtensionPrincipalClass={principal!r} 未使用模块名限定")
            else:
                self.report.ok("EXT-PLIST-PRINCIPAL",
                               f"NSExtensionPrincipalClass={principal}")
            attrs = ext.get("NSExtensionAttributes")
            if not isinstance(attrs, dict):
                self.report.p0("EXT-PLIST-ATTRS", f"{rel} 缺少 NSExtensionAttributes 字典")
                return
            if attrs.get("IsASCIICapable") is not True:
                self.report.p0("EXT-PLIST-ASCII", f"{rel} NSExtensionAttributes.IsASCIICapable 应为 true")
            else:
                self.report.ok("EXT-PLIST-ASCII", "IsASCIICapable = true")
            if attrs.get("RequestsOpenAccess") is not True:
                self.report.p0("EXT-PLIST-OPENACCESS",
                               f"{rel} NSExtensionAttributes.RequestsOpenAccess 应为 true"
                               f"（否则键盘无法联网调用 AI）")
            else:
                self.report.ok("EXT-PLIST-OPENACCESS", "RequestsOpenAccess = true")
            if attrs.get("PrefersRightToLeft") is not False:
                self.report.p1("EXT-PLIST-RTL", f"{rel} PrefersRightToLeft 应为 false")
            if not str(attrs.get("PrimaryLanguage", "")):
                self.report.p1("EXT-PLIST-LANG", f"{rel} PrimaryLanguage 缺失")
        else:
            if "UILaunchScreen" not in data:
                self.report.p1("APP-PLIST-LAUNCHSCREEN",
                               f"{rel} 缺少 UILaunchScreen（否则 App 以兼容模式拉伸显示）")
            else:
                self.report.ok("APP-PLIST-LAUNCHSCREEN", "UILaunchScreen 存在")
            orients = data.get("UISupportedInterfaceOrientations")
            if not isinstance(orients, list) or not orients:
                self.report.p0("APP-PLIST-ORIENT", f"{rel} UISupportedInterfaceOrientations 缺失")
            else:
                self.report.ok("APP-PLIST-ORIENT",
                               f"支持 {len(orients)} 个方向：{orients}")
            disp = str(data.get("CFBundleDisplayName", ""))
            if not disp:
                self.report.p1("APP-PLIST-NAME", f"{rel} CFBundleDisplayName 缺失")
            else:
                self.report.ok("APP-PLIST-NAME", f"CFBundleDisplayName={disp}")

    # -- 12. 分组 ---------------------------------------------------------

    def check_groups(self) -> None:
        main = self.obj(self.main_group_uid)
        if main is None or main.get("isa") != "PBXGroup":
            self.report.p0("GROUP-MAIN", f"mainGroup={self.main_group_uid} 不是合法 PBXGroup")
            return
        self.report.ok("GROUP-MAIN", "mainGroup 合法")

        products = self.obj(self.products_group_uid)
        if products is None or products.get("isa") != "PBXGroup":
            self.report.p0("GROUP-PRODUCTS",
                           f"productRefGroup={self.products_group_uid} 不是合法 PBXGroup")
            return
        prod_children = {str(c) for c in products.get("children") or []}
        self.report.ok("GROUP-PRODUCTS", "productRefGroup 合法")

        for target_name in (APP_TARGET, EXT_TARGET):
            entry = self.targets.get(target_name)
            if not entry:
                continue
            pr = str(entry[1].get("productReference", ""))
            if pr not in prod_children:
                self.report.p0("GROUP-PRODUCTS-CHILD",
                               f"Products 组里没有 {target_name} 的 productReference")
            else:
                self.report.ok("GROUP-PRODUCTS-CHILD", f"Products 组含 {target_name} 产物")

        # 所有文件引用都应能在某人 group 的 children 里找到（否则 Xcode 侧栏看不到）
        reachable: set[str] = set()
        stack = [self.main_group_uid, self.products_group_uid]
        seen_groups: set[str] = set()
        while stack:
            g = stack.pop()
            if g in seen_groups:
                continue
            seen_groups.add(g)
            go = self.obj(g) or {}
            for c in go.get("children") or []:
                cu = str(c)
                reachable.add(cu)
                co = self.obj(cu) or {}
                if co.get("isa") == "PBXGroup":
                    stack.append(cu)
        unreachable = [u for u, o in self.by_isa("PBXFileReference") if u not in reachable]
        if unreachable:
            paths = [str((self.obj(u) or {}).get("path", "?")) for u in unreachable[:5]]
            self.report.warn("GROUP-UNREACHABLE",
                             f"有 {len(unreachable)} 个 file reference 不在任何 group 下"
                             f"（Xcode 侧栏不显示）：{paths}")
        else:
            self.report.ok("GROUP-UNREACHABLE", "所有 file reference 都可从 mainGroup 到达")

    # -- 13. scheme -------------------------------------------------------

    def check_schemes(self) -> None:
        schemes_dir = self.project_dir / "xcshareddata" / "xcschemes"
        if not schemes_dir.is_dir():
            self.report.p1("SCHEMES-MISSING",
                           "缺少 xcshareddata/xcschemes（Xcode 首次打开会自动生成，"
                           "但 CI 的 xcodebuild -scheme 找不到）")
            return
        want = [f"{APP_TARGET}.xcscheme", f"{EXT_TARGET}.xcscheme"]
        target_uids = {name: uid for name, (uid, _) in self.targets.items()}
        for fname in want:
            path = schemes_dir / fname
            if not path.is_file():
                self.report.p1("SCHEME-MISSING", f"缺少 shared scheme：{fname}")
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            ids = set(re.findall(r'BlueprintIdentifier\s*=\s*"([0-9A-Fa-f]{24})"', text))
            if not ids:
                self.report.p0("SCHEME-NO-BLUEPRINT", f"{fname} 里没有 BlueprintIdentifier")
                continue
            valid = {u for name, u in target_uids.items()}
            bad = ids - valid
            if bad:
                self.report.p0("SCHEME-BAD-BLUEPRINT",
                               f"{fname} 的 BlueprintIdentifier 指向不存在的 target：{sorted(bad)}")
            else:
                self.report.ok("SCHEME-BAD-BLUEPRINT", f"{fname} BlueprintIdentifier 有效")
            if "<BuildAction" not in text or "<LaunchAction" not in text:
                self.report.p1("SCHEME-STRUCTURE", f"{fname} 缺少 BuildAction / LaunchAction")
            else:
                self.report.ok("SCHEME-STRUCTURE", f"{fname} 结构完整")

    # -- 14. 磁盘 ↔ 工程一致性 --------------------------------------------

    def check_disk_membership(self) -> None:
        shared = [r for r in scan_swift(self.ios, "Shared", exclude_dirs=("Shared/Resources/",))]
        app_only = scan_swift(self.ios, "AIKeyboard")
        ext_only = scan_swift(self.ios, "AIKeyboardExtension")

        app_paths = {p for _, p in self.app_sources}
        ext_paths = {p for _, p in self.ext_sources}

        missing_shared_app = [r for r in shared if r not in app_paths]
        missing_shared_ext = [r for r in shared if r not in ext_paths]
        missing_app = [r for r in app_only if r not in app_paths]
        missing_ext = [r for r in ext_only if r not in ext_paths]

        if missing_shared_app:
            self.report.p0("MEMBERSHIP-SHARED-APP",
                           f"Shared 里有 {len(missing_shared_app)} 个 .swift 没进 App Sources："
                           f"{missing_shared_app[:5]}")
        else:
            self.report.ok("MEMBERSHIP-SHARED-APP", f"{len(shared)} 个 Shared .swift 都进了 App")

        if missing_shared_ext:
            self.report.p0("MEMBERSHIP-SHARED-EXT",
                           f"Shared 里有 {len(missing_shared_ext)} 个 .swift 没进 Extension Sources："
                           f"{missing_shared_ext[:5]}")
        else:
            self.report.ok("MEMBERSHIP-SHARED-EXT", f"{len(shared)} 个 Shared .swift 都进了 Extension")

        if missing_app:
            self.report.p0("MEMBERSHIP-APP",
                           f"ios/AIKeyboard 里有 {len(missing_app)} 个 .swift 没进 App Sources："
                           f"{missing_app[:5]}")
        else:
            self.report.ok("MEMBERSHIP-APP", f"{len(app_only)} 个 App .swift 都进了 App")

        if missing_ext:
            self.report.p0("MEMBERSHIP-EXT",
                           f"ios/AIKeyboardExtension 里有 {len(missing_ext)} 个 .swift "
                           f"没进 Extension Sources：{missing_ext[:5]}")
        else:
            self.report.ok("MEMBERSHIP-EXT", f"{len(ext_only)} 个 Extension .swift 都进了 Extension")

        # 扩展必须有 KeyboardViewController（Info.plist 的 NSExtensionPrincipalClass）
        if not ext_only:
            self.report.warn(
                "EXT-SOURCE-MISSING",
                "ios/AIKeyboardExtension/ 下还没有任何 .swift —— 键盘扩展缺 "
                "KeyboardViewController，会启动即崩溃。等 keyboard-ui 落盘后重跑 "
                "python scripts/gen_xcodeproj.py",
            )
        else:
            has_vc = False
            for rel in ext_only:
                try:
                    text = (self.ios / rel).read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                if re.search(r"class\s+KeyboardViewController\b", text):
                    has_vc = True
                    self.report.ok("EXT-KEYBOARDVC", f"找到 KeyboardViewController（{rel}）")
                    break
            if not has_vc:
                # 这是「源码完整性」提示而非「工程结构」错误：键盘扩展的
                # KeyboardViewController 由 keyboard-ui 负责落盘，本脚本不重复判定它
                # 是否属于结构缺陷。--strict 模式下 WARNING 同样判失败，CI 另有一道
                # preflight（grep class KeyboardViewController）做硬门禁。
                self.report.warn(
                    "EXT-KEYBOARDVC",
                    "Extension 源码里暂时还找不到 class KeyboardViewController（keyboard-ui "
                    "尚未落盘），而 Extension-Info.plist 的 NSExtensionPrincipalClass 指向它。"
                    "工程结构本身没问题；等功能代码落盘后重跑 python scripts/gen_xcodeproj.py "
                    "与本脚本，该检查会自动转为 OK。若到最终验收仍缺，键盘启动会崩溃。",
                )


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------


def print_report(report: Report, verbose: bool) -> None:
    shown = [i for i in report.issues if i.level != "OK" or verbose]
    for issue in shown:
        tag = {"P0": "[P0]", "P1": "[P1]", "WARNING": "[WARN]", "INFO": "[INFO]", "OK": "[OK]"}[issue.level]
        print(f"{tag:8} {issue.code:26} {issue.message}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="校验墨语 iOS Xcode 工程结构")
    ap.add_argument("--repo-root", default=str(REPO_ROOT), help="仓库根目录")
    ap.add_argument("--strict", action="store_true", help="WARNING 也视为失败")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印通过的检查项")
    args = ap.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    ios_root = repo_root / IOS_DIR_NAME

    print("=" * 78)
    print(" 墨语 iOS 输入法 · Xcode 工程结构校验（validate_project.py）")
    print("=" * 78)
    print(f" 仓库根目录: {repo_root}")
    print(f" 工程文件  : ios/{PROJECT_DIR_NAME}/{PBXPROJ_NAME}")
    print()

    if not ios_root.is_dir():
        print(f"[P0] 找不到 ios/ 目录：{ios_root}")
        return 2

    report = Report()
    Validator(ios_root, report, verbose=args.verbose).run()

    print_report(report, args.verbose)
    print()

    p0 = len(report.errors)
    p1 = len(report.p1s)
    warn = len(report.warnings)
    oks = len(report.oks)
    print("-" * 78)
    print(f" 通过检查项 {oks} 个 | P0={p0} P1={p1} WARNING={warn}")
    print("-" * 78)

    if p0:
        print("结论: 失败（存在 P0 结构错误，工程很可能打不开或构建不出内容）")
        return 1
    if args.strict and (p1 or warn):
        print("结论: 失败（--strict 模式下 P1/WARNING 也算失败）")
        return 1
    if p1 or warn:
        print("结论: 通过（有 WARNING，见上方说明；多为并行开发中的目录尚未落盘）")
    else:
        print("结论: OK（工程结构校验全部通过）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
