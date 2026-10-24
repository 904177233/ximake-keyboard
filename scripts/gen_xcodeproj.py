#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""墨语（Moyu）iOS 输入法 —— Xcode 工程生成器（gen_xcodeproj.py）。

为什么不用手写 pbxproj / 不用 XcodeGen
--------------------------------------
本机是 Windows，没有 Xcode、没有 xcodegen、没有 ruby。pbxproj 是 OpenStep 风格的
plist，手写极易出现「括号不平衡 / UUID 引用断裂 / build phase 漏文件」导致 Xcode
直接拒绝打开。因此本脚本用 **Python 标准库** 程序化生成，并保证：

1. **确定性 UUID**：每个对象 UUID = MD5(种子字符串) 的前 24 位十六进制大写。
   种子由「对象类型 + 相对路径 + target 名」组成，因此**重跑输出逐字节一致**（幂等）。
2. **文件动态发现**：不硬编码任何文件名。每次运行都重新扫描磁盘：
      ios/Shared/**/*.swift              → 两个 target 的 Sources
      ios/AIKeyboard/**/*.swift          → 仅 App 的 Sources
      ios/AIKeyboardExtension/**/*.swift → 仅 Extension 的 Sources
      ios/Shared/Resources/              → folder reference（蓝文件夹），两个 target 的 Resources
      ios/Resources/Assets.xcassets      → 仅 App 的 Resources
      ios/Resources/ 下其他文件/目录      → 仅 App 的 Resources
      ios/Config/                         → 仅用于 Xcode 导航（不参与构建）
   并行开发中某个目录还没落盘时，脚本打印 WARNING 并继续，**不会崩**；
   等其它模块落盘后重跑本脚本即可自动纳入。
3. **配置单一真相源**：关键构建设置写在 ios/Config/*.xcconfig 里，本脚本会解析这些
   xcconfig 并把其中的关键键回填进 pbxproj 的 target buildSettings（这样即使有人只用
   文本编辑器看 pbxproj 也能看出 bundle id / 部署目标；同时 xcconfig 仍是可读的真相源）。
4. 同时生成 shared scheme（CI 里 `xcodebuild -scheme AIKeyboard` 必需）。

用法
----
    # 生成（幂等，可反复运行）
    python scripts/gen_xcodeproj.py

    # 只检查是否会发生变化（不写盘）；有差异退出码 1 —— CI / 自检用
    python scripts/gen_xcodeproj.py --check

    # 详细输出
    python scripts/gen_xcodeproj.py -v

生成物
------
    ios/AIKeyboard.xcodeproj/project.pbxproj
    ios/AIKeyboard.xcodeproj/project.xcworkspace/contents.xcworkspacedata
    ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes/AIKeyboard.xcscheme
    ios/AIKeyboard.xcodeproj/xcshareddata/xcschemes/AIKeyboardExtension.xcscheme

退出码：0 成功（允许 WARNING）；1 有差异（--check）或生成失败。
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量：与 docs/02 §2 构建配置契约一一对应
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
IOS_ROOT = REPO_ROOT / "ios"
PROJECT_DIR_NAME = "AIKeyboard.xcodeproj"

APP_TARGET = "AIKeyboard"
EXT_TARGET = "AIKeyboardExtension"

APP_BUNDLE_ID = "com.example.moyu"
EXT_BUNDLE_ID = "com.example.moyu.keyboard"

# objectVersion 56 = Xcode 14；compatibilityVersion "Xcode 14.0" 可被 14/15/16 打开
OBJECT_VERSION = 56
COMPATIBILITY_VERSION = "Xcode 14.0"
LAST_UPGRADE_CHECK = 1500      # Xcode 15 写入的值；14/16 都能接受
LAST_SWIFT_UPDATE_CHECK = 1500
CREATED_ON_TOOLS_VERSION = "15.0"

PRODUCT_TYPE_APP = "com.apple.product-type.application"
PRODUCT_TYPE_EXT = "com.apple.product-type.app-extension"

# 扫描时跳过的目录名（构建产物 / 版本库 / 用户态目录）
SKIP_DIR_NAMES = {
    ".git", ".hg", ".svn", ".build", "build", "DerivedData",
    "xcuserdata", ".swiftpm", "__pycache__", "node_modules",
}

# 已知扩展名 → pbxproj file type
FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".xcconfig": "text.xcconfig",
    ".md": "net.daringfireball.markdown",
    ".markdown": "net.daringfireball.markdown",
    ".json": "text.json",
    ".tsv": "text",
    ".csv": "text",
    ".txt": "text",
    ".strings": "text.plist.strings",
    ".png": "image.png",
    ".jpg": "image.jpeg",
    ".jpeg": "image.jpeg",
    ".pdf": "image.pdf",
    ".svg": "text",
    ".xcassets": "folder.assetcatalog",
    ".xcodeproj": "wrapper.pb-project",
    ".yml": "text.yaml",
    ".yaml": "text.yaml",
}

GENERATED_HEADER = "// !$*UTF8*$!\n"

# 从 xcconfig 回填进 pbxproj target buildSettings 的标量键
# （顺序即输出顺序，保证幂等）
INJECT_SCALAR_KEYS = [
    "PRODUCT_NAME",
    "PRODUCT_MODULE_NAME",
    "PRODUCT_BUNDLE_IDENTIFIER",
    "INFOPLIST_FILE",
    "GENERATE_INFOPLIST_FILE",
    "CODE_SIGN_ENTITLEMENTS",
    "CODE_SIGN_STYLE",
    "DEVELOPMENT_TEAM",
    "SWIFT_VERSION",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "TARGETED_DEVICE_FAMILY",
    "MARKETING_VERSION",
    "CURRENT_PROJECT_VERSION",
    "APPLICATION_EXTENSION_API_ONLY",
    "SKIP_INSTALL",
    "ASSETCATALOG_COMPILER_APPICON_NAME",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME",
    "ENABLE_BITCODE",
    "ENABLE_PREVIEWS",
    "SWIFT_STRICT_CONCURRENCY",
    "SWIFT_EMIT_LOC_STRINGS",
    "ENABLE_USER_SCRIPT_SANDBOXING",
]

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

_SAFE_UNQUOTED = re.compile(r"^[A-Za-z0-9_.$/:\-+]+$")


def quote(value: str) -> str:
    """按 pbxproj（OpenStep plist）规则给字符串加引号。"""
    if value == "":
        return '""'
    if _SAFE_UNQUOTED.match(value):
        return value
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


class UUIDFactory:
    """确定性 UUID 工厂：同一组 seed 永远得到同一个 24 位大写十六进制 UUID。"""

    def __init__(self) -> None:
        self._owner: dict[str, str] = {}

    def make(self, *parts: str) -> str:
        seed = "\x1f".join(parts)
        attempt = 0
        while True:
            raw = seed if attempt == 0 else f"{seed}\x1f{attempt}"
            uid = hashlib.md5(raw.encode("utf-8")).hexdigest()[:24].upper()
            owner = self._owner.get(uid)
            if owner is None:
                self._owner[uid] = seed
                return uid
            if owner == seed:                      # 同一对象重复取，幂等
                return uid
            attempt += 1                           # 极端哈希碰撞，换一个种子

    @property
    def count(self) -> int:
        return len(self._owner)


def read_xcconfig(path: Path) -> dict[str, str]:
    """极简 xcconfig 解析：只取无条件 `KEY = VALUE`（忽略注释与 [条件] 行）。"""
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return result
    for raw_line in text.splitlines():
        line = raw_line
        idx = line.find("//")
        if idx >= 0:
            line = line[:idx]
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            continue                               # 形如 FOO[sdk=...] 的条件键，忽略
        result[key] = value
    return result


# ---------------------------------------------------------------------------
# 文件发现
# ---------------------------------------------------------------------------

def _is_skipped(rel_parts: tuple[str, ...]) -> bool:
    return any(part in SKIP_DIR_NAMES or part.startswith(".") for part in rel_parts)


def discover_swift(ios_root: Path, sub_dir: str,
                   exclude_prefixes: tuple[str, ...] = ()) -> list[str]:
    """递归收集 <ios_root>/<sub_dir>/**/*.swift，返回相对 ios/ 的 POSIX 路径（已排序）。"""
    base = ios_root / sub_dir
    if not base.is_dir():
        return []
    found: list[str] = []
    for path in base.rglob("*.swift"):
        rel_parts = path.relative_to(ios_root).parts
        if _is_skipped(rel_parts):
            continue
        rel = path.relative_to(ios_root).as_posix()
        if any(rel == p or rel.startswith(p.rstrip("/") + "/") for p in exclude_prefixes):
            continue
        if not path.is_file():
            continue
        found.append(rel)
    return sorted(found)


def file_type_for(rel: str) -> str:
    suffix = Path(rel).suffix.lower()
    return FILE_TYPES.get(suffix, "text")


def discover_dir_entries(ios_root: Path, sub_dir: str) -> list[Path]:
    """列出某个目录的直接子项（文件或目录），排序后返回。"""
    base = ios_root / sub_dir
    if not base.is_dir():
        return []
    entries = [p for p in base.iterdir() if not p.name.startswith(".")]
    return sorted(entries, key=lambda p: p.name)


def discover_config_files(ios_root: Path) -> list[str]:
    base = ios_root / "Config"
    if not base.is_dir():
        return []
    out: list[str] = []
    for path in sorted(base.rglob("*")):
        if not path.is_file():
            continue
        if any(part.startswith(".") for part in path.relative_to(ios_root).parts):
            continue
        out.append(path.relative_to(ios_root).as_posix())
    return out


# ---------------------------------------------------------------------------
# 数据模型
# ---------------------------------------------------------------------------

@dataclass
class FileRefSpec:
    rel: str
    filetype: str
    comment: str
    source_tree: str = "SOURCE_ROOT"
    explicit_type: str | None = None
    include_in_index: int = 1


@dataclass
class BuildPhaseSpec:
    kind: str                     # PBXSourcesBuildPhase / PBXFrameworksBuildPhase / ...
    comment: str
    uuid: str = ""
    file_refs: list[FileRefSpec] = field(default_factory=list)
    extra_lines: list[str] = field(default_factory=list)


@dataclass
class TargetSpec:
    name: str
    product_type: str
    product_name: str            # 例如 AIKeyboard.app
    product_filetype: str        # wrapper.application / wrapper.app-extension
    xcconfig_rel: str
    uuid: str = ""
    product_uuid: str = ""
    phases: list[BuildPhaseSpec] = field(default_factory=list)
    build_settings: dict[str, str] = field(default_factory=dict)
    dependencies: list[str] = field(default_factory=list)
    sources: list[FileRefSpec] = field(default_factory=list)
    extra_build_resource_refs: list[tuple[str, str, str]] = field(default_factory=list)


# ---------------------------------------------------------------------------
# pbxproj 文本生成
# ---------------------------------------------------------------------------

class PbxWriter:
    """按 Xcode 的 section 顺序累积文本行。"""

    SECTION_ORDER = [
        "PBXBuildFile",
        "PBXContainerItemProxy",
        "PBXCopyFilesBuildPhase",
        "PBXFileReference",
        "PBXFrameworksBuildPhase",
        "PBXGroup",
        "PBXNativeTarget",
        "PBXProject",
        "PBXResourcesBuildPhase",
        "PBXSourcesBuildPhase",
        "PBXTargetDependency",
        "XCBuildConfiguration",
        "XCConfigurationList",
    ]

    def __init__(self) -> None:
        self.sections: dict[str, list[str]] = {name: [] for name in self.SECTION_ORDER}

    def add(self, section: str, text: str) -> None:
        if section not in self.sections:
            raise KeyError(f"未知 section: {section}")
        self.sections[section].append(text.rstrip("\n"))

    # ---- 具体对象 ----

    def build_file(self, uid: str, comment: str, file_ref_uid: str, file_ref_comment: str,
                   settings: str | None = None) -> None:
        extra = f" settings = {settings};" if settings else ""
        self.sections["PBXBuildFile"].append(
            f"\t\t{uid} /* {comment} */ = {{isa = PBXBuildFile; "
            f"fileRef = {file_ref_uid} /* {file_ref_comment} */;{extra} }};"
        )

    def file_reference(self, uid: str, spec: FileRefSpec) -> None:
        if spec.explicit_type:
            type_line = f"explicitFileType = {quote(spec.explicit_type)}; "
        else:
            type_line = f"lastKnownFileType = {quote(spec.filetype)}; "
        include = f"includeInIndex = {spec.include_in_index}; " if spec.include_in_index == 0 else ""
        self.sections["PBXFileReference"].append(
            f"\t\t{uid} /* {spec.comment} */ = {{isa = PBXFileReference; "
            f"{type_line}{include}path = {quote(spec.rel)}; sourceTree = {quote(spec.source_tree)}; }};"
        )

    def group(self, uid: str, comment: str, children: list[tuple[str, str]],
              name: str | None, path: str | None) -> None:
        lines = [f"\t\t{uid} /* {comment} */ = {{", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
        for child_uid, child_comment in children:
            lines.append(f"\t\t\t\t{child_uid} /* {child_comment} */,")
        lines.append("\t\t\t);")
        if name is not None:
            lines.append(f"\t\t\tname = {quote(name)};")
        if path is not None:
            lines.append(f"\t\t\tpath = {quote(path)};")
        lines.append('\t\t\tsourceTree = "<group>";')
        lines.append("\t\t};")
        self.sections["PBXGroup"].append("\n".join(lines))

    def phase(self, uid: str, isa: str, comment: str, build_files: list[tuple[str, str]],
              extra: list[str] | None = None) -> None:
        lines = [
            f"\t\t{uid} /* {comment} */ = {{",
            f"\t\t\tisa = {isa};",
            "\t\t\tbuildActionMask = 2147483647;",
        ]
        for line in (extra or []):
            # extra 里的行已经带好了 tab
            lines.append(line)
        lines.append("\t\t\tfiles = (")
        for bf_uid, bf_comment in build_files:
            lines.append(f"\t\t\t\t{bf_uid} /* {bf_comment} */,")
        lines.append("\t\t\t);")
        lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        lines.append("\t\t};")
        self.sections[isa].append("\n".join(lines))

    def container_item_proxy(self, uid: str, project_uid: str, project_comment: str,
                             remote_uid: str, remote_info: str) -> None:
        lines = [
            f"\t\t{uid} /* PBXContainerItemProxy */ = {{",
            "\t\t\tisa = PBXContainerItemProxy;",
            f"\t\t\tcontainerPortal = {project_uid} /* {project_comment} */;",
            "\t\t\tproxyType = 1;",
            f"\t\t\tremoteGlobalIDString = {remote_uid};",
            f"\t\t\tremoteInfo = {quote(remote_info)};",
            "\t\t};",
        ]
        self.sections["PBXContainerItemProxy"].append("\n".join(lines))

    def target_dependency(self, uid: str, target_uid: str, target_comment: str,
                          proxy_uid: str) -> None:
        lines = [
            f"\t\t{uid} /* PBXTargetDependency */ = {{",
            "\t\t\tisa = PBXTargetDependency;",
            f"\t\t\ttarget = {target_uid} /* {target_comment} */;",
            f"\t\t\ttargetProxy = {proxy_uid} /* PBXContainerItemProxy */;",
            "\t\t};",
        ]
        self.sections["PBXTargetDependency"].append("\n".join(lines))

    def native_target(self, uid: str, name: str, product_uid: str, product_comment: str,
                      product_type: str, phase_uids: list[tuple[str, str]],
                      dependency_uids: list[tuple[str, str]]) -> None:
        lines = [
            f"\t\t{uid} /* {name} */ = {{",
            "\t\t\tisa = PBXNativeTarget;",
            "\t\t\tbuildConfigurationList = "
            f"{self._config_list_uids[name]} /* Build configuration list for PBXNativeTarget \"{name}\" */;",
            "\t\t\tbuildPhases = (",
        ]
        for phase_uid, phase_comment in phase_uids:
            lines.append(f"\t\t\t\t{phase_uid} /* {phase_comment} */,")
        lines.append("\t\t\t);")
        lines.append("\t\t\tbuildRules = (")
        lines.append("\t\t\t);")
        lines.append("\t\t\tdependencies = (")
        for dep_uid, dep_comment in dependency_uids:
            lines.append(f"\t\t\t\t{dep_uid} /* {dep_comment} */,")
        lines.append("\t\t\t);")
        lines.append(f"\t\t\tname = {quote(name)};")
        lines.append(f"\t\t\tproductName = {quote(name)};")
        lines.append(f"\t\t\tproductReference = {product_uid} /* {product_comment} */;")
        lines.append(f"\t\t\tproductType = {quote(product_type)};")
        lines.append("\t\t};")
        self.sections["PBXNativeTarget"].append("\n".join(lines))

    _config_list_uids: dict[str, str] = {}

    def build_configuration(self, uid: str, name: str, base_config_uid: str | None,
                            base_config_comment: str, settings: dict[str, str]) -> None:
        lines = [f"\t\t{uid} /* {name} */ = {{", "\t\t\tisa = XCBuildConfiguration;"]
        if base_config_uid:
            lines.append(f"\t\t\tbaseConfigurationReference = {base_config_uid} /* {base_config_comment} */;")
        lines.append("\t\t\tbuildSettings = {")
        for key, value in settings.items():
            lines.append(f"\t\t\t\t{key} = {quote(value)};")
        lines.append("\t\t\t};")
        lines.append(f"\t\t\tname = {name};")
        lines.append("\t\t};")
        self.sections["XCBuildConfiguration"].append("\n".join(lines))

    def configuration_list(self, uid: str, comment: str,
                           configs: list[tuple[str, str]]) -> None:
        lines = [
            f"\t\t{uid} /* {comment} */ = {{",
            "\t\t\tisa = XCConfigurationList;",
            "\t\t\tbuildConfigurations = (",
        ]
        for cfg_uid, cfg_name in configs:
            lines.append(f"\t\t\t\t{cfg_uid} /* {cfg_name} */,")
        lines.append("\t\t\t);")
        lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
        lines.append("\t\t\tdefaultConfigurationName = Release;")
        lines.append("\t\t};")
        self.sections["XCConfigurationList"].append("\n".join(lines))

    def project(self, uid: str, main_group_uid: str, product_group_uid: str,
                project_config_list_uid: str, target_uids: list[tuple[str, str]],
                target_attributes: list[tuple[str, str]]) -> None:
        lines = [
            f"\t\t{uid} /* Project object */ = {{",
            "\t\t\tisa = PBXProject;",
            "\t\t\tattributes = {",
            "\t\t\t\tBuildIndependentTargetsInParallel = 1;",
            f"\t\t\t\tLastSwiftUpdateCheck = {LAST_SWIFT_UPDATE_CHECK};",
            f"\t\t\t\tLastUpgradeCheck = {LAST_UPGRADE_CHECK};",
            "\t\t\t\tTargetAttributes = {",
        ]
        for target_uid, target_name in target_attributes:
            lines.append(f"\t\t\t\t\t{target_uid} /* {target_name} */ = {{")
            lines.append(f"\t\t\t\t\t\tCreatedOnToolsVersion = {CREATED_ON_TOOLS_VERSION};")
            # Xcode 新建工程模板里每个 target 都带这一行；
            # 与 xcconfig 里的 CODE_SIGN_STYLE = Automatic 呼应，避免首次打开时签名面板反复弹窗。
            lines.append("\t\t\t\t\t\tProvisioningStyle = Automatic;")
            lines.append("\t\t\t\t\t};")
        lines.append("\t\t\t\t};")
        lines.append("\t\t\t};")
        lines.append(
            f"\t\t\tbuildConfigurationList = {project_config_list_uid} "
            f'/* Build configuration list for PBXProject "AIKeyboard" */;'
        )
        lines.append(f"\t\t\tcompatibilityVersion = {quote(COMPATIBILITY_VERSION)};")
        lines.append("\t\t\tdevelopmentRegion = en;")
        lines.append("\t\t\thasScannedForEncodings = 0;")
        lines.append("\t\t\tknownRegions = (")
        lines.append("\t\t\t\ten,")
        lines.append("\t\t\t\tBase,")
        lines.append("\t\t\t\t\"zh-Hans\",")
        lines.append("\t\t\t);")
        lines.append(f"\t\t\tmainGroup = {main_group_uid} /* Main group */;")
        lines.append(f"\t\t\tproductRefGroup = {product_group_uid} /* Products */;")
        lines.append("\t\t\tprojectDirPath = \"\";")
        lines.append("\t\t\tprojectRoot = \"\";")
        lines.append("\t\t\ttargets = (")
        for target_uid, target_name in target_uids:
            lines.append(f"\t\t\t\t{target_uid} /* {target_name} */,")
        lines.append("\t\t\t);")
        lines.append("\t\t};")
        self.sections["PBXProject"].append("\n".join(lines))

    def render(self, root_object_uid: str) -> str:
        parts: list[str] = [GENERATED_HEADER, "{\n", "\tarchiveVersion = 1;\n", "\tclasses = {\n\t};\n",
                            f"\tobjectVersion = {OBJECT_VERSION};\n", "\tobjects = {\n"]
        for section in self.SECTION_ORDER:
            items = self.sections[section]
            if not items:
                continue
            parts.append(f"\n/* Begin {section} section */\n")
            for item in items:
                parts.append(item + "\n")
            parts.append(f"/* End {section} section */\n")
        parts.append(f"\t}};\n\trootObject = {root_object_uid} /* Project object */;\n}}\n")
        return "".join(parts)


# ---------------------------------------------------------------------------
# 工程模型构建
# ---------------------------------------------------------------------------

class ProjectModel:
    def __init__(self, ios_root: Path, verbose: bool = False) -> None:
        self.ios_root = ios_root
        self.verbose = verbose
        self.uuids = UUIDFactory()
        self.warnings: list[str] = []
        self.stats: dict[str, int] = {}

        # ---- 文件发现 ----
        # 注意：Shared/Resources 是 folder reference，里面的 .swift（若有）不再单独编译，
        # 避免「既是资源又是源码」的重复。
        self.shared_swift = discover_swift(
            ios_root, "Shared", exclude_prefixes=("Shared/Resources",))
        self.app_swift = discover_swift(ios_root, APP_TARGET)
        self.ext_swift = discover_swift(ios_root, EXT_TARGET)
        self.config_files = discover_config_files(ios_root)

        self.app_resources: list[FileRefSpec] = []
        self.shared_resource_folder: FileRefSpec | None = None

        assets_rel = "Resources/Assets.xcassets"
        if (ios_root / assets_rel).is_dir():
            self.app_resources.append(FileRefSpec(
                rel=assets_rel, filetype="folder.assetcatalog", comment="Assets.xcassets"))
        else:
            self.warnings.append(
                f"未找到 {assets_rel}（AppIcon / AccentColor 缺失，App 仍可编译但无图标；"
                "先运行 python scripts/make_appicon.py 再重跑本脚本）")

        for entry in discover_dir_entries(ios_root, "Resources"):
            rel = entry.relative_to(ios_root).as_posix()
            if rel == assets_rel:
                continue
            if entry.is_dir():
                self.app_resources.append(FileRefSpec(rel=rel, filetype="folder", comment=entry.name))
            else:
                self.app_resources.append(FileRefSpec(rel=rel, filetype=file_type_for(rel), comment=entry.name))

        shared_res_rel = "Shared/Resources"
        if (ios_root / shared_res_rel).is_dir():
            self.shared_resource_folder = FileRefSpec(
                rel=shared_res_rel, filetype="folder", comment="Resources")
        else:
            self.warnings.append(
                f"未找到 {shared_res_rel}/（词库等共享资源尚未落盘；重跑本脚本会自动作为 "
                "folder reference 加入两个 target 的 Resources）")

        if not self.app_swift:
            self.warnings.append(
                f"{APP_TARGET}/ 下没有 .swift（宿主 App 的 Sources 为空，App 无法构建；"
                "等 host-app-ui 落盘后重跑本脚本）")
        if not self.ext_swift:
            self.warnings.append(
                f"{EXT_TARGET}/ 下没有 .swift（键盘扩展的 Sources 为空，扩展无法构建；"
                "等 keyboard-ui 落盘后重跑本脚本）")
        if not self.shared_swift:
            self.warnings.append("Shared/ 下没有 .swift（共享层尚未落盘）")

        self.stats["shared_swift"] = len(self.shared_swift)
        self.stats["app_swift"] = len(self.app_swift)
        self.stats["ext_swift"] = len(self.ext_swift)
        self.stats["app_resources"] = len(self.app_resources) + (1 if self.shared_resource_folder else 0)
        self.stats["config_files"] = len(self.config_files)

        # ---- 读取 xcconfig（真相源） ----
        self.base_cfg = read_xcconfig(ios_root / "Config" / "Base.xcconfig")
        self.app_cfg = read_xcconfig(ios_root / "Config" / "App.xcconfig")
        self.ext_cfg = read_xcconfig(ios_root / "Config" / "Extension.xcconfig")
        if not self.base_cfg:
            self.warnings.append("ios/Config/Base.xcconfig 缺失或无法解析（构建设置将用内置默认值）")

    # -- 便捷方法 --

    def uid(self, *parts: str) -> str:
        return self.uuids.make(*parts)

    def file_ref(self, rel: str, comment: str | None = None,
                 filetype: str | None = None) -> tuple[str, str]:
        comment = comment or Path(rel).name
        uid = self.uid("fileRef", rel)
        return uid, comment

    def build_settings_for(self, cfg: dict[str, str], target: str) -> dict[str, str]:
        settings: dict[str, str] = {}
        for key in INJECT_SCALAR_KEYS:
            if key not in cfg:
                continue
            value = cfg[key]
            if value == "":
                continue
            settings[key] = value
        # 兜底：xcconfig 缺失时也要保证关键项存在（契约硬要求）
        defaults = {
            "SWIFT_VERSION": "5.0",
            "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "CODE_SIGN_STYLE": "Automatic",
            "PRODUCT_BUNDLE_IDENTIFIER": APP_BUNDLE_ID if target == APP_TARGET else EXT_BUNDLE_ID,
            "INFOPLIST_FILE": ("Config/App-Info.plist" if target == APP_TARGET
                               else "Config/Extension-Info.plist"),
            "CODE_SIGN_ENTITLEMENTS": ("Config/AIKeyboard.entitlements" if target == APP_TARGET
                                       else "Config/AIKeyboardExtension.entitlements"),
            "GENERATE_INFOPLIST_FILE": "NO",
        }
        for key, value in defaults.items():
            settings.setdefault(key, value)
        return settings


def _ld_runpath_lines(target: str) -> str:
    """LD_RUNPATH_SEARCH_PATHS 需要写成数组。"""
    items = ['"$(inherited)"', '"@executable_path/Frameworks"']
    if target == EXT_TARGET:
        items.append('"@executable_path/../../Frameworks"')
    body = "\n".join(f"\t\t\t\t{item}," for item in items)
    return f"\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n{body}\n\t\t\t);"


def build_model(ios_root: Path, verbose: bool = False) -> ProjectModel:
    m = ProjectModel(ios_root, verbose)
    w = PbxWriter()

    project_uid = m.uid("project", "AIKeyboard")
    main_group_uid = m.uid("group", "<main>")
    products_group_uid = m.uid("group", "<products>")
    project_cfg_list_uid = m.uid("configList", "project")

    # ---------------- 所有 file reference ----------------
    ref_uid: dict[str, str] = {}       # rel -> fileRef uuid
    ref_spec: dict[str, FileRefSpec] = {}

    all_known_rels: set[str] = set()
    all_known_rels.update(m.shared_swift)
    all_known_rels.update(m.app_swift)
    all_known_rels.update(m.ext_swift)
    all_known_rels.update(m.config_files)
    for spec in m.app_resources:
        all_known_rels.add(spec.rel)
    if m.shared_resource_folder:
        all_known_rels.add(m.shared_resource_folder.rel)

    for rel in sorted(all_known_rels):
        if m.shared_resource_folder is not None and rel == m.shared_resource_folder.rel:
            spec = m.shared_resource_folder
        elif rel.startswith("Resources/"):
            spec = next(s for s in m.app_resources if s.rel == rel)
        else:
            spec = FileRefSpec(rel=rel, filetype=file_type_for(rel), comment=Path(rel).name)
        ref_spec[rel] = spec
        ref_uid[rel] = m.uid("fileRef", rel)
        w.file_reference(ref_uid[rel], spec)

    # 产品 file reference
    app_product_uid = m.uid("product", APP_TARGET)
    ext_product_uid = m.uid("product", EXT_TARGET)
    w.file_reference(app_product_uid, FileRefSpec(
        rel=f"{APP_TARGET}.app", filetype="", comment=f"{APP_TARGET}.app",
        source_tree="BUILT_PRODUCTS_DIR", explicit_type="wrapper.application", include_in_index=0))
    w.file_reference(ext_product_uid, FileRefSpec(
        rel=f"{EXT_TARGET}.appex", filetype="", comment=f"{EXT_TARGET}.appex",
        source_tree="BUILT_PRODUCTS_DIR", explicit_type="wrapper.app-extension", include_in_index=0))

    # ---------------- 分组树（Xcode 里好看，纯虚拟组） ----------------
    tree: dict[str, list[str]] = {}
    for rel in sorted(all_known_rels):
        parent = str(Path(rel).parent).replace("\\", "/")
        if parent == ".":
            parent = ""
        tree.setdefault(parent, []).append(rel)

    # 需要递归建组：收集所有出现的目录
    all_dirs: set[str] = set()
    for rel in all_known_rels:
        parts = Path(rel).parts[:-1]
        for i in range(1, len(parts) + 1):
            all_dirs.add("/".join(parts[:i]))

    group_children: dict[str, list[tuple[str, str]]] = {}

    def group_uid(rel_dir: str) -> str:
        return m.uid("group", rel_dir or "<main>")

    for rel in sorted(all_known_rels):
        parent = str(Path(rel).parent).replace("\\", "/")
        parent = "" if parent == "." else parent
        key = parent or "<main>"
        group_children.setdefault(key, []).append((ref_uid[rel], ref_spec[rel].comment))

    # 子目录挂在父目录下
    for d in sorted(all_dirs):
        parent = str(Path(d).parent).replace("\\", "/")
        parent = "" if parent == "." else parent
        key = parent or "<main>"
        group_children.setdefault(key, []).append((group_uid(d), Path(d).name))

    for rel_dir in sorted(all_dirs | {""}):
        key = rel_dir or "<main>"
        children = group_children.get(key, [])
        if rel_dir == "":
            continue  # mainGroup 最后手工组装
        w.group(group_uid(rel_dir), Path(rel_dir).name, children,
                name=Path(rel_dir).name, path=None)

    # ---------------- Sources / Resources 成员 ----------------
    def bf_uid(target: str, rel: str) -> str:
        return m.uid("buildFile", target, rel)

    def add_sources(target: str, rels: list[str], comment_suffix: str) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        for rel in rels:
            comment = f"{ref_spec[rel].comment} in {comment_suffix}"
            w.build_file(bf_uid(target, rel), comment, ref_uid[rel], ref_spec[rel].comment)
            out.append((bf_uid(target, rel), comment))
        return out

    def add_resources(target: str, rels: list[str]) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        for rel in rels:
            comment = f"{ref_spec[rel].comment} in Resources"
            w.build_file(bf_uid(target, rel), comment, ref_uid[rel], ref_spec[rel].comment)
            out.append((bf_uid(target, rel), comment))
        return out

    app_source_rels = sorted(set(m.shared_swift) | set(m.app_swift))
    ext_source_rels = sorted(set(m.shared_swift) | set(m.ext_swift))
    app_res_rels = [s.rel for s in m.app_resources]
    if m.shared_resource_folder:
        app_res_rels.append(m.shared_resource_folder.rel)
        ext_res_rels = [m.shared_resource_folder.rel]
    else:
        ext_res_rels = []

    app_sources_bf = add_sources(APP_TARGET, app_source_rels, "Sources")
    ext_sources_bf = add_sources(EXT_TARGET, ext_source_rels, "Sources")
    app_res_bf = add_resources(APP_TARGET, app_res_rels)
    ext_res_bf = add_resources(EXT_TARGET, ext_res_rels)

    # ---------------- phases ----------------
    app_sources_phase = m.uid("phase", APP_TARGET, "Sources")
    app_frameworks_phase = m.uid("phase", APP_TARGET, "Frameworks")
    app_resources_phase = m.uid("phase", APP_TARGET, "Resources")
    app_embed_phase = m.uid("phase", APP_TARGET, "Embed Foundation Extensions")

    ext_sources_phase = m.uid("phase", EXT_TARGET, "Sources")
    ext_frameworks_phase = m.uid("phase", EXT_TARGET, "Frameworks")
    ext_resources_phase = m.uid("phase", EXT_TARGET, "Resources")

    w.phase(app_sources_phase, "PBXSourcesBuildPhase", "Sources", app_sources_bf)
    w.phase(app_frameworks_phase, "PBXFrameworksBuildPhase", "Frameworks", [])
    w.phase(app_resources_phase, "PBXResourcesBuildPhase", "Resources", app_res_bf)
    w.phase(ext_sources_phase, "PBXSourcesBuildPhase", "Sources", ext_sources_bf)
    w.phase(ext_frameworks_phase, "PBXFrameworksBuildPhase", "Frameworks", [])
    w.phase(ext_resources_phase, "PBXResourcesBuildPhase", "Resources", ext_res_bf)

    # Embed Foundation Extensions（Copy Files，dstSubfolderSpec=13 → PlugIns）
    embed_bf_uid = m.uid("buildFile", APP_TARGET, "embed", f"{EXT_TARGET}.appex")
    embed_bf_comment = f"{EXT_TARGET}.appex in Embed Foundation Extensions"
    w.build_file(embed_bf_uid, embed_bf_comment, ext_product_uid, f"{EXT_TARGET}.appex",
                 settings="{ATTRIBUTES = (RemoveHeadersOnCopy, ); }")
    w.phase(app_embed_phase, "PBXCopyFilesBuildPhase", "Embed Foundation Extensions",
            [(embed_bf_uid, embed_bf_comment)],
            extra=[
                '\t\t\tdstPath = "";',
                "\t\t\tdstSubfolderSpec = 13;",
                '\t\t\tname = "Embed Foundation Extensions";',
            ])

    # ---------------- targets ----------------
    app_uuid = m.uid("target", APP_TARGET)
    ext_uuid = m.uid("target", EXT_TARGET)

    # ---------------- 依赖 ----------------
    # 注意：PBXContainerItemProxy.remoteGlobalIDString 与 PBXTargetDependency.target
    # 都必须指向 **target 的 UUID**（不是 product 的 fileRef UUID）。
    proxy_uid = m.uid("proxy", APP_TARGET, EXT_TARGET)
    dependency_uid = m.uid("dependency", APP_TARGET, EXT_TARGET)
    w.container_item_proxy(proxy_uid, project_uid, "Project object", ext_uuid, EXT_TARGET)
    w.target_dependency(dependency_uid, ext_uuid, EXT_TARGET, proxy_uid)

    app_settings = m.build_settings_for(m.app_cfg, APP_TARGET)
    ext_settings = m.build_settings_for(m.ext_cfg, EXT_TARGET)
    app_settings.setdefault("PRODUCT_NAME", APP_TARGET)
    ext_settings.setdefault("PRODUCT_NAME", EXT_TARGET)

    app_cfg_debug = m.uid("config", APP_TARGET, "Debug")
    app_cfg_release = m.uid("config", APP_TARGET, "Release")
    ext_cfg_debug = m.uid("config", EXT_TARGET, "Debug")
    ext_cfg_release = m.uid("config", EXT_TARGET, "Release")
    proj_cfg_debug = m.uid("config", "project", "Debug")
    proj_cfg_release = m.uid("config", "project", "Release")

    app_cfg_list = m.uid("configList", APP_TARGET)
    ext_cfg_list = m.uid("configList", EXT_TARGET)
    PbxWriter._config_list_uids = {APP_TARGET: app_cfg_list, EXT_TARGET: ext_cfg_list}

    base_rel = "Config/Base.xcconfig"
    app_rel = "Config/App.xcconfig"
    ext_rel = "Config/Extension.xcconfig"
    base_uid = ref_uid.get(base_rel)
    app_cfg_uid = ref_uid.get(app_rel)
    ext_cfg_uid = ref_uid.get(ext_rel)

    # 项目级：几乎全部设置在 xcconfig，这里只留空壳 + 指向 Base.xcconfig
    w.build_configuration(proj_cfg_debug, "Debug", base_uid, "Base.xcconfig", {})
    w.build_configuration(proj_cfg_release, "Release", base_uid, "Base.xcconfig", {})
    w.build_configuration(app_cfg_debug, "Debug", app_cfg_uid, "App.xcconfig", app_settings)
    w.build_configuration(app_cfg_release, "Release", app_cfg_uid, "App.xcconfig", app_settings)
    w.build_configuration(ext_cfg_debug, "Debug", ext_cfg_uid, "Extension.xcconfig", ext_settings)
    w.build_configuration(ext_cfg_release, "Release", ext_cfg_uid, "Extension.xcconfig", ext_settings)

    w.configuration_list(project_cfg_list_uid,
                         'Build configuration list for PBXProject "AIKeyboard"',
                         [(proj_cfg_debug, "Debug"), (proj_cfg_release, "Release")])
    w.configuration_list(app_cfg_list,
                         f'Build configuration list for PBXNativeTarget "{APP_TARGET}"',
                         [(app_cfg_debug, "Debug"), (app_cfg_release, "Release")])
    w.configuration_list(ext_cfg_list,
                         f'Build configuration list for PBXNativeTarget "{EXT_TARGET}"',
                         [(ext_cfg_debug, "Debug"), (ext_cfg_release, "Release")])

    w.native_target(
        app_uuid, APP_TARGET, app_product_uid, f"{APP_TARGET}.app", PRODUCT_TYPE_APP,
        [(app_sources_phase, "Sources"), (app_frameworks_phase, "Frameworks"),
         (app_resources_phase, "Resources"), (app_embed_phase, "Embed Foundation Extensions")],
        [(dependency_uid, "PBXTargetDependency")],
    )
    w.native_target(
        ext_uuid, EXT_TARGET, ext_product_uid, f"{EXT_TARGET}.appex", PRODUCT_TYPE_EXT,
        [(ext_sources_phase, "Sources"), (ext_frameworks_phase, "Frameworks"),
         (ext_resources_phase, "Resources")],
        [],
    )

    # ---------------- 分组 ----------------
    w.group(products_group_uid, "Products",
            [(app_product_uid, f"{APP_TARGET}.app"), (ext_product_uid, f"{EXT_TARGET}.appex")],
            name="Products", path=None)
    main_children = group_children.get("<main>", []) + [(products_group_uid, "Products")]
    w.group(main_group_uid, "Main group", main_children, name=None, path=None)

    # ---------------- project ----------------
    w.project(project_uid, main_group_uid, products_group_uid, project_cfg_list_uid,
              [(app_uuid, APP_TARGET), (ext_uuid, EXT_TARGET)],
              [(app_uuid, APP_TARGET), (ext_uuid, EXT_TARGET)])

    text = w.render(project_uid)
    return m, text, {
        "app_source_rels": app_source_rels,
        "ext_source_rels": ext_source_rels,
        "app_res_rels": app_res_rels,
        "ext_res_rels": ext_res_rels,
        "uuids": {
            "project": project_uid, "app_target": app_uuid, "ext_target": ext_uuid,
            "app_product": app_product_uid, "ext_product": ext_product_uid,
            "app_sources_phase": app_sources_phase, "app_resources_phase": app_resources_phase,
            "app_embed_phase": app_embed_phase, "ext_sources_phase": ext_sources_phase,
            "ext_resources_phase": ext_resources_phase,
            "main_group": main_group_uid, "products_group": products_group_uid,
        },
    }


# ---------------------------------------------------------------------------
# Scheme 生成
# ---------------------------------------------------------------------------

SCHEME_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "{last_upgrade}"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{blueprint}"
               BuildableName = "{buildable_name}"
               BlueprintName = "{blueprint_name}"
               ReferencedContainer = "container:{container}">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
{launch_body}
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
{runnable_body}
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

BUILDABLE_REF = """            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{blueprint}"
               BuildableName = "{buildable_name}"
               BlueprintName = "{blueprint_name}"
               ReferencedContainer = "container:{container}">
            </BuildableReference>"""


def _launch_body(blueprint: str, buildable_name: str, blueprint_name: str, container: str) -> str:
    ref = """         <BuildableProductRunnable
            runnableDebuggingMode = "0">
{ref}
         </BuildableProductRunnable>"""
    return ref.format(ref=BUILDABLE_REF.format(
        blueprint=blueprint, buildable_name=buildable_name,
        blueprint_name=blueprint_name, container=container))


def build_app_scheme(container: str, app_uuid: str) -> str:
    return SCHEME_TEMPLATE.format(
        last_upgrade=LAST_UPGRADE_CHECK,
        blueprint=app_uuid, buildable_name=f"{APP_TARGET}.app",
        blueprint_name=APP_TARGET, container=container,
        launch_body=_launch_body(app_uuid, f"{APP_TARGET}.app", APP_TARGET, container),
        runnable_body=_launch_body(app_uuid, f"{APP_TARGET}.app", APP_TARGET, container),
    )


def build_extension_scheme(container: str, ext_uuid: str, app_uuid: str) -> str:
    """扩展不能独立 Run，LaunchAction 用 MacroExpansion 指向宿主 App（Xcode 生成模板如此）。"""
    launch_body = """      <MacroExpansion>
{ref}
      </MacroExpansion>""".format(ref=BUILDABLE_REF.format(
        blueprint=app_uuid, buildable_name=f"{APP_TARGET}.app",
        blueprint_name=APP_TARGET, container=container))
    return SCHEME_TEMPLATE.format(
        last_upgrade=LAST_UPGRADE_CHECK,
        blueprint=ext_uuid, buildable_name=f"{EXT_TARGET}.appex",
        blueprint_name=EXT_TARGET, container=container,
        launch_body=launch_body,
        runnable_body="      <MacroExpansion>\n" + BUILDABLE_REF.format(
            blueprint=app_uuid, buildable_name=f"{APP_TARGET}.app",
            blueprint_name=APP_TARGET, container=container) + "\n      </MacroExpansion>",
    )


def workspace_contents() -> str:
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<Workspace\n'
            '   version = "1.0">\n'
            '   <FileRef\n'
            '      location = "self:">\n'
            '   </FileRef>\n'
            '</Workspace>\n')


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def generate(ios_root: Path, verbose: bool = False) -> tuple[dict[Path, str], ProjectModel, dict]:
    """返回 {输出文件路径: 内容}，便于 --check 与写盘共用。"""
    model, pbx_text, meta = build_model(ios_root, verbose=verbose)
    project_dir = ios_root / PROJECT_DIR_NAME
    container = PROJECT_DIR_NAME
    outputs: dict[Path, str] = {
        project_dir / "project.pbxproj": pbx_text,
        project_dir / "project.xcworkspace" / "contents.xcworkspacedata": workspace_contents(),
        project_dir / "xcshareddata" / "xcschemes" / f"{APP_TARGET}.xcscheme":
            build_app_scheme(container, meta["uuids"]["app_target"]),
        project_dir / "xcshareddata" / "xcschemes" / f"{EXT_TARGET}.xcscheme":
            build_extension_scheme(container, meta["uuids"]["ext_target"],
                                   meta["uuids"]["app_target"]),
    }
    return outputs, model, meta


def print_summary(model: ProjectModel, meta: dict, ios_root: Path) -> None:
    print("=" * 78)
    print("墨语 iOS 工程生成结果")
    print("=" * 78)
    print(f"  项目目录 : {ios_root / PROJECT_DIR_NAME}")
    print(f"  objectVersion = {OBJECT_VERSION}   compatibilityVersion = {COMPATIBILITY_VERSION}")
    print(f"  UUID 对象数 : {model.uuids.count}")
    print()
    print(f"  target {APP_TARGET}")
    print(f"    product     : {APP_TARGET}.app  ({PRODUCT_TYPE_APP})")
    print(f"    Sources     : {len(meta['app_source_rels'])} 个 .swift"
          f"（Shared {model.stats['shared_swift']} + App {model.stats['app_swift']}）")
    print(f"    Resources   : {len(meta['app_res_rels'])} 项"
          f"（Assets.xcassets{' + Shared/Resources' if model.shared_resource_folder else ''}"
          f"{' + 其他' if len(meta['app_res_rels']) > (1 + (1 if model.shared_resource_folder else 0)) else ''}）")
    print(f"    Frameworks  : (空，系统框架自动链接)")
    print(f"    Copy Files  : Embed Foundation Extensions → PlugIns"
          f"（{EXT_TARGET}.appex）")
    print()
    print(f"  target {EXT_TARGET}")
    print(f"    product     : {EXT_TARGET}.appex  ({PRODUCT_TYPE_EXT})")
    print(f"    Sources     : {len(meta['ext_source_rels'])} 个 .swift"
          f"（Shared {model.stats['shared_swift']} + Extension {model.stats['ext_swift']}）")
    print(f"    Resources   : {len(meta['ext_res_rels'])} 项"
          f"（{'Shared/Resources' if model.shared_resource_folder else '(无)'}）")
    print()
    if model.warnings:
        print(f"[WARNING] {len(model.warnings)} 条（不影响工程结构，但可能影响可编译性）：")
        for msg in model.warnings:
            print(f"  - {msg}")
        print()
    else:
        print("[OK] 没有 WARNING")
        print()


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="生成墨语 iOS 的 AIKeyboard.xcodeproj（importable by Xcode 14+）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--repo-root", default=str(REPO_ROOT), help="仓库根目录（默认脚本上一级）")
    ap.add_argument("--check", action="store_true",
                    help="只检查是否会发生变化（不写盘）；有差异退出码 1")
    ap.add_argument("-v", "--verbose", action="store_true", help="打印每个文件")
    args = ap.parse_args(argv)

    ios_root = Path(args.repo_root).resolve() / "ios"
    if not ios_root.is_dir():
        print(f"[错误] 找不到目录：{ios_root}", file=sys.stderr)
        return 1

    try:
        outputs, model, meta = generate(ios_root, verbose=args.verbose)
    except Exception as exc:  # noqa: BLE001
        print(f"[错误] 生成失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        return 1

    if args.check:
        changed: list[str] = []
        for path, content in outputs.items():
            if not path.is_file():
                changed.append(f"缺失：{path.relative_to(ios_root.parent).as_posix()}")
                continue
            current = path.read_text(encoding="utf-8", errors="replace")
            if current != content:
                changed.append(f"内容不同：{path.relative_to(ios_root.parent).as_posix()}")
        if changed:
            print("[check] 工程与磁盘不一致（需要重跑 gen_xcodeproj.py）：")
            for item in changed:
                print(f"  - {item}")
            return 1
        print(f"[check] OK：{len(outputs)} 个生成物与磁盘一致（幂等）")
        return 0

    written = 0
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode("utf-8")
        old = path.read_bytes() if path.is_file() else None
        if old == data:
            if args.verbose:
                print(f"  [未变化] {path.relative_to(ios_root.parent).as_posix()}")
            continue
        path.write_bytes(data)
        written += 1
        if args.verbose:
            print(f"  [已写入] {path.relative_to(ios_root.parent).as_posix()} "
                  f"({len(data)} bytes)")

    print_summary(model, meta, ios_root)
    print(f"[完成] 生成物 {len(outputs)} 个，实际写入 {written} 个"
          f"（其余未变化，说明幂等）。")
    print("        下一步：python scripts/validate_project.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
