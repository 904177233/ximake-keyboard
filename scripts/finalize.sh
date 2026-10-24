#!/usr/bin/env bash
# 墨语（Moyu）iOS 输入法 · 一键收尾闸门（macOS / Linux / CI 版）
#
# 与 scripts/finalize.ps1 功能等价，跑的是同一组 Python 脚本。
# Windows 开发机用 finalize.ps1；macOS 本机或 CI 用这个。
#
# 用法：
#   bash scripts/finalize.sh              # 生成 + 全部校验
#   bash scripts/finalize.sh --check      # 只检查不写盘（gen 用 --check）
#   bash scripts/finalize.sh --skip-gen   # 跳过 gen（不建议）
#   PYTHON=python3 bash scripts/finalize.sh
#
# 任何一步非零退出即中止，不会「带病往下走」。
#
# 兼容性：只用 bash 3.2 就有的语法（macOS 自带的 /bin/bash 就是 3.2），
# 不依赖 bash 4 的关联数组 / local -n 等特性。

set -euo pipefail

# ---------------------------------------------------------------------------
# 0) 定位仓库根 + Python
# ---------------------------------------------------------------------------

SCRIPT_DIR_RAW="$(dirname -- "$0")"
SCRIPT_DIR="$(cd -- "${SCRIPT_DIR_RAW}" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

MODE_CHECK=0
SKIP_GEN=0
for arg in "$@"; do
  case "${arg}" in
    --check)    MODE_CHECK=1 ;;
    --skip-gen) SKIP_GEN=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "[错误] 未知参数：${arg}" >&2
      exit 2
      ;;
  esac
done

if [ -z "${PYTHON:-}" ]; then
  for candidate in python3 python3.13 python3.12 python3.11 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      PYTHON="${candidate}"
      break
    fi
  done
fi
if [ -z "${PYTHON:-}" ]; then
  echo "[错误] 找不到 Python 3。请用 PYTHON=/path/to/python3 bash scripts/finalize.sh 指定。" >&2
  exit 2
fi

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

FAILURES=""
TOTAL=0
# 闸门总数（含被 --skip-gen 跳过的那一步，编号保持连续）
GATE_TOTAL=6

hr() {
  # 78 个等号，避免依赖 seq 的具体行为
  echo "=============================================================================="
}

abort() {
  echo
  echo "收尾失败：${TOTAL} 个闸门中有未通过的。" >&2
  echo "  ✗ ${FAILURES}" >&2
  exit 1
}

# run_gate <标题> <脚本路径> [额外参数...]
run_gate() {
  local title="$1"
  local script_path="$2"
  shift 2

  TOTAL=$((TOTAL + 1))
  echo
  hr
  printf ' [%d/%d] %s\n' "${TOTAL}" "${GATE_TOTAL}" "${title}"
  printf '         %s %s\n' "${script_path}" "$*"
  hr
  echo

  if [ ! -f "${script_path}" ]; then
    echo "[失败] 脚本不存在：${script_path}" >&2
    FAILURES="${FAILURES}${title}（脚本缺失：${script_path}）；"
    return 1
  fi

  local code=0
  if [ "$#" -gt 0 ]; then
    "${PYTHON}" -X utf8 "${script_path}" "$@" || code=$?
  else
    "${PYTHON}" -X utf8 "${script_path}" || code=$?
  fi

  if [ "${code}" -ne 0 ]; then
    echo
    echo "[失败] ${title} 退出码 = ${code}" >&2
    FAILURES="${FAILURES}${title}（退出码 ${code}）；"
    return 1
  fi

  echo
  echo "[通过] ${title}"
  return 0
}

# ---------------------------------------------------------------------------
# 1..5 闸门：gen → validate → qa/project_check → qa/static_check → qa/consistency_check
# ---------------------------------------------------------------------------

echo
echo "墨语（Moyu）iOS 输入法 · 收尾闸门"
echo "仓库根：${REPO_ROOT}"
echo "Python：${PYTHON}"
if [ "${SKIP_GEN}" -eq 1 ]; then
  echo "模式：跳过 gen（--skip-gen）"
elif [ "${MODE_CHECK}" -eq 1 ]; then
  echo "模式：只检查不写盘（--check）"
else
  echo "模式：生成 + 校验（默认）"
fi

if [ "${SKIP_GEN}" -eq 1 ]; then
  TOTAL=$((TOTAL + 1))
  echo
  echo "[${TOTAL}/${GATE_TOTAL}] 1. 生成 Xcode 工程（gen_xcodeproj.py）—— 已按 --skip-gen 跳过"
elif [ "${MODE_CHECK}" -eq 1 ]; then
  run_gate "1. 生成 Xcode 工程（gen_xcodeproj.py）" "scripts/gen_xcodeproj.py" "--check" || abort
else
  run_gate "1. 生成 Xcode 工程（gen_xcodeproj.py）" "scripts/gen_xcodeproj.py" || abort
fi

run_gate "2. 工程结构校验（validate_project.py）" "scripts/validate_project.py" || abort
run_gate "3. QA 独立校验（qa/project_check.py）" "scripts/qa/project_check.py" || abort
run_gate "4. Swift 静态检查（qa/static_check.py）" "scripts/qa/static_check.py" || abort
run_gate "5. 设计令牌一致性（qa/consistency_check.py）" "scripts/qa/consistency_check.py" || abort
# 第 6 道是 CI run #1 失败后补的：结构校验全过，但 xcodebuild 报
# `Old-style plist parser: missing semicolon`，根因是带 `+` 的文件名
# （KeyboardViewModel+AI.swift）在 pbxproj 里必须加引号。
run_gate "6. pbxproj 词法校验（lead/pbxproj_plist_check.py）" "scripts/lead/pbxproj_plist_check.py" || abort

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

echo
hr
echo " 全部 ${TOTAL} 个闸门通过 —— 工程可以冻结 / 提交 / 交给 CI。"
hr
echo
echo "提醒：本仓库在 Windows 上生成，无法用 Xcode 验证能否打开/编译。"
echo "      真正的『能不能编译』只能由 .github/workflows/build.yml 在 macOS 上确认。"
echo
exit 0
