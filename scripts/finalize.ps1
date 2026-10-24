#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    墨语（Moyu）iOS 输入法 · 一键收尾闸门（Windows / PowerShell 版）

.DESCRIPTION
    冻结代码、提交前、或 CI 之外本地自检时，用这一条命令跑完所有检查。
    任何一步返回非零退出码就立刻中止并打印失败原因，不会「带病往下走」。

    顺序是刻意的：
      1. gen_xcodeproj.py     —— 先按磁盘上的真实 .swift 重新生成 pbxproj
                                 （否则后面所有校验都在校验一份过期的工程文件）
      2. validate_project.py  —— 工程结构校验（我自己写的，85+ 项）
      3. qa/project_check.py  —— QA 的第二道独立校验（不可跳过）
      4. qa/static_check.py   —— Swift 源码静态检查（括号/强制解包/UIKit 越界…）
      5. qa/consistency_check.py —— 设计令牌一致性（颜色/字号有没有硬编码）

.PARAMETER Python
    Python 可执行文件路径。默认自动探测。

.PARAMETER Check
    只检查、不写盘：跳过第 1 步的写盘，改用 `gen_xcodeproj.py --check`。
    适合「我怀疑有人手改了 pbxproj」时用。

.PARAMETER SkipGen
    完全跳过 gen 步骤（只有在你确定 pbxproj 是最新的时候才用，不建议）。

.EXAMPLE
    # Windows PowerShell 5.1（系统自带 powershell.exe，本机已实测通过）
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1

.EXAMPLE
    # PowerShell 7+（装了 pwsh 的话）
    pwsh -File scripts/finalize.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/finalize.ps1 -Check

.NOTES
    兼容 Windows PowerShell 5.1 与 PowerShell 7+（本机只有 5.1，已实测）。
    本脚本在 Windows 上开发与验证；CI（macOS）用的是等价的 scripts/finalize.sh。
    两者跑的是同一组 Python 脚本，结果应当一致。
#>

[CmdletBinding()]
param(
    [string]$Python = "",
    [switch]$Check,
    [switch]$SkipGen
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 0) 定位仓库根 + Python
# ---------------------------------------------------------------------------

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location -LiteralPath $RepoRoot

if (-not $Python) {
    # 优先用 py 启动器 / PATH 上的 python，避免把某一台机器的绝对路径写死。
    $candidates = @(
        "py",
        "python",
        "python3"
    )
    foreach ($c in $candidates) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { $Python = $cmd.Source; break }
    }
}
if (-not $Python) {
    Write-Host "[错误] 找不到 Python。请用 -Python 指定解释器路径。" -ForegroundColor Red
    exit 2
}

# 强制 UTF-8 输出，避免中文日志在 GBK 控制台下乱码
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$Failures = @()
$Total = 0

function Invoke-Gate {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$Hint = ""
    )

    $script:Total++
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host (" [{0}/{1}] {2}" -f $script:Total, 5, $Title) -ForegroundColor Cyan
    Write-Host ("         {0} {1}" -f $ScriptPath, ($Arguments -join " ")) -ForegroundColor DarkGray
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    Write-Host ""

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Host ("[失败] 脚本不存在：{0}" -f $ScriptPath) -ForegroundColor Red
        if ($Hint) { Write-Host ("        提示：{0}" -f $Hint) -ForegroundColor Yellow }
        $script:Failures += "$Title（脚本缺失：$ScriptPath）"
        return $false
    }

    & $Python -X utf8 $ScriptPath @Arguments
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Write-Host ""
        Write-Host ("[失败] {0} 退出码 = {1}" -f $Title, $code) -ForegroundColor Red
        if ($Hint) { Write-Host ("        提示：{0}" -f $Hint) -ForegroundColor Yellow }
        $script:Failures += ("{0}（退出码 {1}）" -f $Title, $code)
        return $false
    }

    Write-Host ""
    Write-Host ("[通过] {0}" -f $Title) -ForegroundColor Green
    return $true
}

# ---------------------------------------------------------------------------
# 1) 生成 / 校验 / 静态检查 / 一致性检查
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "墨语（Moyu）iOS 输入法 · 收尾闸门" -ForegroundColor White
Write-Host ("仓库根：{0}" -f $RepoRoot) -ForegroundColor DarkGray
Write-Host ("Python：{0}" -f $Python) -ForegroundColor DarkGray
if ($SkipGen) {
    Write-Host "模式：跳过 gen（-SkipGen）" -ForegroundColor Yellow
} elseif ($Check) {
    Write-Host "模式：只检查不写盘（-Check）" -ForegroundColor Yellow
} else {
    Write-Host "模式：生成 + 校验（默认）" -ForegroundColor DarkGray
}

if (-not $SkipGen) {
    $genArgs = @()
    if ($Check) { $genArgs += "--check" }
    $ok = Invoke-Gate -Title "1. 生成 Xcode 工程（gen_xcodeproj.py）" `
                      -ScriptPath "scripts/gen_xcodeproj.py" `
                      -Arguments $genArgs `
                      -Hint "若是 -Check 模式报「内容不同」，去掉 -Check 重跑一次即可（源码落盘后 pbxproj 需要刷新）。"
    if (-not $ok) {
        Write-Host ""
        Write-Host ("收尾失败：{0}/{1} 个闸门未通过。" -f $Failures.Count, $Total) -ForegroundColor Red
        $Failures | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
        exit 1
    }
} else {
    $Total++
    Write-Host ""
    Write-Host ("[{0}/5] 1. 生成 Xcode 工程（gen_xcodeproj.py）—— 已按 -SkipGen 跳过" -f $Total) -ForegroundColor DarkYellow
}

$ok = Invoke-Gate -Title "2. 工程结构校验（validate_project.py）" `
                  -ScriptPath "scripts/validate_project.py" `
                  -Hint "P0 必须全部修掉；若只剩 EXT-KEYBOARDVC 之类的 WARNING 说明功能代码还没落盘。"
if (-not $ok) {
    Write-Host ""
    Write-Host ("收尾失败：{0}/{1} 个闸门未通过。" -f $Failures.Count, $Total) -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
    exit 1
}

$ok = Invoke-Gate -Title "3. QA 独立校验（qa/project_check.py）" `
                  -ScriptPath "scripts/qa/project_check.py" `
                  -Hint "这是与 validate_project.py 独立的第二道门，P0 必须归零。"
if (-not $ok) {
    Write-Host ""
    Write-Host ("收尾失败：{0}/{1} 个闸门未通过。" -f $Failures.Count, $Total) -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
    exit 1
}

$ok = Invoke-Gate -Title "4. Swift 静态检查（qa/static_check.py）" `
                  -ScriptPath "scripts/qa/static_check.py" `
                  -Hint "P0/P1 必须归零；P2 是风格建议，可记录不阻塞。"
if (-not $ok) {
    Write-Host ""
    Write-Host ("收尾失败：{0}/{1} 个闸门未通过。" -f $Failures.Count, $Total) -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
    exit 1
}

$ok = Invoke-Gate -Title "5. 设计令牌一致性（qa/consistency_check.py）" `
                  -ScriptPath "scripts/qa/consistency_check.py" `
                  -Hint "P0/P1 必须归零；硬编码颜色/字号会在这里暴露。"
if (-not $ok) {
    Write-Host ""
    Write-Host ("收尾失败：{0}/{1} 个闸门未通过。" -f $Failures.Count, $Total) -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host ("  ✗ {0}" -f $_) -ForegroundColor Red }
    exit 1
}

# ---------------------------------------------------------------------------
# 2) 汇总
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor Green
Write-Host (" 全部 {0} 个闸门通过 —— 工程可以冻结 / 提交 / 交给 CI。" -f $Total) -ForegroundColor Green
Write-Host ("=" * 78) -ForegroundColor Green
Write-Host ""
Write-Host "提醒：本仓库在 Windows 上生成，无法用 Xcode 验证能否打开/编译。" -ForegroundColor Yellow
Write-Host "      真正的『能不能编译』只能由 .github/workflows/build.yml 在 macOS 上确认。" -ForegroundColor Yellow
Write-Host ""
exit 0
