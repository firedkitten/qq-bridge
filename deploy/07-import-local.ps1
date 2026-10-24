<#
.SYNOPSIS
  把服务器上 06-export.sh 打出来的 tgz 导入本地仓库，并自动改好 config.json。

.DESCRIPTION
  做四件事：
    1. 解包到临时目录并校验（必须有 config.json）
    2. 覆盖 state/、roles/、dsh/agent-presets/（覆盖前先备份到仓库根的 _import-backup-<时间戳>）
    3. 用服务器版 config.json 打底，只改「必须换成本机」的几项：
       snowluma.launcherPath / snowluma.homeDir / snowluma.accessToken / agentPreset
       —— consoleToken 默认保留本机原来的，免得面板和隧道配置要跟着改
    4. 重建 preset patch（scripts/build-agent-preset-patches.mjs），并删掉服务器遗留的 bridge.lock

  不会做的事：QQ 登录态（/opt/snowluma/*）不在包里，本机 SnowLuma 需要重新扫码。

.PARAMETER Archive
  06-export.sh 生成的 .zip（推荐）或 .tgz 路径。
  .tgz 也能解，但 Windows 自带的 bsdtar 遇到 roles/小鲸鱼.md 这类中文名会报
  “Invalid empty pathname” 并静默丢文件（实测 bsdtar 3.8.9），所以默认走 .zip。

.PARAMETER TargetDir
  本地仓库根目录，默认是脚本所在目录的上一级（即 deploy\ 的父目录）。

.PARAMETER SnowLumaDir
  本机 SnowLuma 所在目录（含 launcher.bat）。不传时先读本机现有 config.json 里的
  launcherPath，再不行就报错让你显式指定。

.PARAMETER KeepServerConsoleToken
  保留服务器那份 consoleToken（默认保留本机的，面板/隧道不用改）。

.PARAMETER SkipSnowLumaPath
  config.json 里的 SnowLuma 路径保持原样（一般用于只搬数据、路径自己手改）。

.PARAMETER DryRun
  只打印计划，不写任何文件。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\07-import-local.ps1 -Archive ..\qqbot-backup-20261024-1430.zip

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\07-import-local.ps1 -Archive .\b.zip -SnowLumaDir "<SnowLuma 安装目录>"

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\07-import-local.ps1 -Archive .\b.zip -DryRun
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Archive,
  [string]$TargetDir = '',
  [string]$SnowLumaDir = '',
  [switch]$KeepServerConsoleToken,
  [switch]$SkipSnowLumaPath,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Step([string]$text) { Write-Host "== $text ==" -ForegroundColor Cyan }
function Note([string]$text) { Write-Host "   $text" }
function Warn([string]$text) { Write-Host "   ! $text" -ForegroundColor Yellow }
function Plan([string]$text) {
  if ($DryRun) { Note "[dry-run] $text" } else { Note $text }
}

# PowerShell 5.1 的 ConvertTo-Json 会把中文写成 \uXXXX；读回来时还原成人能看的中文。
function UnescapeJsonUnicode([string]$s) {
  return [regex]::Replace($s, '\\u([0-9a-fA-F]{4})', {
      param($m)
      [string][char][Convert]::ToInt32($m.Groups[1].Value, 16)
    })
}

function WriteJsonNoBom([string]$path, $obj) {
  $json = $obj | ConvertTo-Json -Depth 24
  $json = UnescapeJsonUnicode $json
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($path, ($json + "`n"), $enc)
}

# ── 0. 路径解析 ────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $Archive)) { throw "找不到归档：$Archive" }
$Archive = (Resolve-Path -LiteralPath $Archive).Path

if (-not $TargetDir) { $TargetDir = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $TargetDir)) { throw "找不到目标目录：$TargetDir" }
$TargetDir = (Resolve-Path -LiteralPath $TargetDir).Path
if (-not (Test-Path (Join-Path $TargetDir 'package.json'))) {
  Warn "$TargetDir 里没有 package.json，确认这是 qq-bridge 仓库根目录"
}

$localCfgPath = Join-Path $TargetDir 'config.json'
$oldCfg = $null
if (Test-Path -LiteralPath $localCfgPath) {
  try { $oldCfg = Get-Content -LiteralPath $localCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
    Warn "本机现有 config.json 解析失败，将不保留其中的 consoleToken：$($_.Exception.Message)"
  }
}

if (-not $SnowLumaDir -and -not $SkipSnowLumaPath) {
  if ($oldCfg -and $oldCfg.snowluma -and $oldCfg.snowluma.launcherPath) {
    $candidate = Split-Path -Parent $oldCfg.snowluma.launcherPath
    if (Test-Path -LiteralPath (Join-Path $candidate 'launcher.bat')) { $SnowLumaDir = $candidate }
  }
}
if (-not $SnowLumaDir -and -not $SkipSnowLumaPath) {
  throw "无法确定本机 SnowLuma 目录：请加 -SnowLumaDir ""<你解压的目录>\SnowLuma-v2.1.1-win-x64""（或用 -SkipSnowLumaPath 只搬数据）"
}

Step "归档：$Archive"
Note "仓库：$TargetDir"
if (-not $SkipSnowLumaPath) { Note "SnowLuma：$SnowLumaDir" }

# ── 1. 解包 ────────────────────────────────────────────────────────────────────
$tmp = Join-Path $env:TEMP ("qqbot-import-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
  Step '解包'
  if ($Archive -like '*.zip') {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $tmp)
  } else {
    Warn '这是 tar 包：Windows 自带 bsdtar 解中文文件名会报 Invalid empty pathname 并丢文件，'
    Warn '建议改用 06-export.sh 生成的 .zip。这里仍尝试解包，中文名文件可能缺失。'
    & tar -xzf "$Archive" -C "$tmp"
    if ($LASTEXITCODE -ne 0) { throw "解包失败（tar 退出码 $LASTEXITCODE）" }
  }
  if (-not (Test-Path (Join-Path $tmp 'config.json'))) { throw '归档里没有 config.json，不是 06-export.sh 的产物？' }

  $items = @(
    @{ src = 'state'; dst = 'state' },
    @{ src = 'roles'; dst = 'roles' },
    @{ src = 'dsh/agent-presets'; dst = 'dsh\agent-presets' }
  )

  # ── 2. 备份 + 覆盖 ───────────────────────────────────────────────────────────
  # 备份必须放在仓库根的独立目录：早先放在 state\ 里面，结果「备份 state」把 state
  # 拷进它自己的子目录，Copy-Item -Recurse 无限递归、CPU 打满卡死（已踩过）。
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupRoot = Join-Path $TargetDir ("_import-backup-$stamp")

  Step '备份现有文件'
  $needBackup = @()
  foreach ($it in $items) {
    $p = Join-Path $TargetDir $it.dst
    if (Test-Path -LiteralPath $p) { $needBackup += $it.dst }
  }
  if (Test-Path -LiteralPath $localCfgPath) { $needBackup += 'config.json' }

  if ($needBackup.Count -eq 0) {
    Note '没有需要备份的现有文件'
  } else {
    foreach ($rel in $needBackup) {
      Plan "备份 $rel → _import-backup-$stamp\"
      if (-not $DryRun) {
        $dst = Join-Path $backupRoot $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $TargetDir $rel) -Destination $dst -Recurse -Force
      }
    }
  }

  Step '写入数据'
  foreach ($it in $items) {
    $srcPath = Join-Path $tmp ($it.src -replace '/', '\')
    if (-not (Test-Path -LiteralPath $srcPath)) { Warn "归档里没有 $($it.src)，跳过"; continue }
    $dstPath = Join-Path $TargetDir $it.dst
    Plan "覆盖 $($it.dst)"
    if (-not $DryRun) {
      # 目录用「源\* → 目标」合并；直接 Copy-Item 目录到已存在的同名目录会多套一层。
      if ((Get-Item -LiteralPath $srcPath).PSIsContainer) {
        New-Item -ItemType Directory -Path $dstPath -Force | Out-Null
        Copy-Item -Path (Join-Path $srcPath '*') -Destination $dstPath -Recurse -Force
      } else {
        Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
      }
    }
  }

  # ── 3. config.json ───────────────────────────────────────────────────────────
  Step '改写 config.json'
  $cfg = Get-Content -LiteralPath (Join-Path $tmp 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json

  if (-not $SkipSnowLumaPath) {
    $launcher = Join-Path $SnowLumaDir 'launcher.bat'
    if (-not $cfg.PSObject.Properties['snowluma']) {
      $cfg | Add-Member -NotePropertyName snowluma -NotePropertyValue ([pscustomobject]@{})
    }
    $cfg.snowluma | Add-Member -NotePropertyName launcherPath -NotePropertyValue $launcher -Force
    $cfg.snowluma | Add-Member -NotePropertyName homeDir -NotePropertyValue $SnowLumaDir -Force
    Plan "snowluma.launcherPath = $launcher"
    Plan "snowluma.homeDir      = $SnowLumaDir"
  }
  $cfg.snowluma | Add-Member -NotePropertyName accessToken -NotePropertyValue '' -Force
  Plan 'snowluma.accessToken  = ""（本机重新发现）'

  $preset = 'qq-chat-v2'
  if (-not $cfg.PSObject.Properties['agentPreset']) {
    $cfg | Add-Member -NotePropertyName agentPreset -NotePropertyValue $preset
  } else {
    $cfg.agentPreset = $preset
  }
  Plan "agentPreset           = $preset"

  if (-not $KeepServerConsoleToken -and $oldCfg -and $oldCfg.consoleToken) {
    $cfg.consoleToken = $oldCfg.consoleToken
    Plan "consoleToken          = 保留本机原值（加 -KeepServerConsoleToken 则用服务器的）"
  } else {
    $cfg.consoleToken = $cfg.consoleToken
    Plan "consoleToken          = 使用归档里的值"
  }

  if (-not $DryRun) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $localCfgPath) -Force | Out-Null
    WriteJsonNoBom $localCfgPath $cfg
    Note '已写入（UTF-8 无 BOM）'
  }

  # ── 4. 清理 + 重建 patch ─────────────────────────────────────────────────────
  $lock = Join-Path $TargetDir 'state\bridge.lock'
  if (Test-Path -LiteralPath $lock) {
    Plan '删除服务器遗留的 state\bridge.lock（本机若已有实例，重启时桥接会自己重建）'
    if (-not $DryRun) { Remove-Item -LiteralPath $lock -Force }
  }

  Step '重建 preset patch'
  $builder = Join-Path $TargetDir 'scripts\build-agent-preset-patches.mjs'
  if (-not (Test-Path -LiteralPath $builder)) {
    Warn '找不到 scripts\build-agent-preset-patches.mjs，跳过'
  } elseif ($DryRun) {
    Plan 'node scripts\build-agent-preset-patches.mjs'
  } else {
    Push-Location $TargetDir
    try {
      & node 'scripts\build-agent-preset-patches.mjs'
      if ($LASTEXITCODE -ne 0) { Warn "重建失败（退出码 $LASTEXITCODE），可稍后手动执行" }
    } catch {
      Warn "重建失败：$($_.Exception.Message)"
    } finally {
      Pop-Location
    }
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Step '完成，接下来手动做两件事'
Note '1. 启动本机 SnowLuma（launcher.bat）并扫码登录 —— 登录态不能迁移，必须重新扫码'
Note '2. 确认本机 DSH 在 http://127.0.0.1:3080 跑着，然后在本目录 npm start'
Note "   控制台：http://127.0.0.1:3100"
if (-not $DryRun) { Note "   回滚：把 _import-backup-$stamp 里的内容拷回原处即可" }
