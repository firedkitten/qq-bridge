# 记忆目录同步：把服务器上的「人格档案」拉到本地，或者从本地推到服务器。
#
# 为什么要这个脚本：
#   人格内核、事实/日记、交接单、档案留存全都在服务器的 state/ 目录里。代码可以用 git
#   管，记忆不行——它一直在变，而且只存在那台机器上。换机器、重装、想留个副本时，
#   就是这个脚本一句话的事。
#
# 用法（在仓库根目录执行）：
#   powershell -ExecutionPolicy Bypass -File scripts\sync-memory.ps1                 # 拉一份快照到 .sync\<时间戳>\
#   powershell -ExecutionPolicy Bypass -File scripts\sync-memory.ps1 -Apply          # 拉下来并覆盖本地 state\
#   powershell -ExecutionPolicy Bypass -File scripts\sync-memory.ps1 -Direction push # 把本地 state 推回服务器
#
# 只搬这三样，不碰代码：
#   state/                              桥接侧（会话表、人格记忆缓存、日志等）
#   qqbridge-tool/memory-diary/state/   人格档案（facts/diary/archive/handoff）
#   qqbridge-tool/memory-diary/persona-core/  内核（含 .bak；真实内核不进 git，只能靠它搬）
#
# 实现上刻意不用 tar：Windows 自带的 tar.exe 解 Unix tar 包时，中文目录名会被当成
# 「Invalid empty pathname」丢掉（实测），所以这里一律用 scp -r 逐目录传。
param(
  [string]$Remote = 'root@123.57.37.192',
  [string]$KeyFile = '',
  [string]$RemoteRoot = '/opt/qq-bridge',
  [ValidateSet('pull', 'push')][string]$Direction = 'pull',
  [switch]$Apply,
  [switch]$Force,
  [int]$PruneDays = 14
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $KeyFile) { $KeyFile = Join-Path $repo '_yzxmm.pem' }
if (-not (Test-Path $KeyFile)) { throw "找不到私钥：$KeyFile（用 -KeyFile 指定）" }

$paths = @('state', 'qqbridge-tool/memory-diary/state', 'qqbridge-tool/memory-diary/persona-core')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $repo '.sync'
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-Scp([string[]]$ScpArgs) {
  & scp -r -i $KeyFile -o StrictHostKeyChecking=no @ScpArgs
  if ($LASTEXITCODE -ne 0) { throw "scp 失败（exit $LASTEXITCODE）" }
}
function Invoke-Ssh([string]$Cmd) {
  $out = & ssh -i $KeyFile -o StrictHostKeyChecking=no $Remote $Cmd
  if ($LASTEXITCODE -ne 0) { throw "ssh 失败：$Cmd" }
  return $out
}
function Count-Lines([string]$Root, [string]$Pattern) {
  $n = 0
  Get-ChildItem -Path $Root -Recurse -File -Filter $Pattern -ErrorAction SilentlyContinue | ForEach-Object {
    $n += (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
  }
  return $n
}

if ($Direction -eq 'pull') {
  $existing = @()
  foreach ($p in $paths) {
    $check = (Invoke-Ssh "test -e '$RemoteRoot/$p' && echo yes || echo no").Trim()
    if ($check -eq 'yes') { $existing += $p }
  }
  if (-not $existing.Count) { throw "服务器上这三样都不存在：$($paths -join ', ')" }

  $snap = Join-Path $work "memory-$stamp"
  foreach ($p in $existing) {
    $dest = Join-Path $snap (Split-Path $p -Parent)
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Write-Host "拉取 $p ..."
    Invoke-Scp @("${Remote}:$RemoteRoot/$p", $dest)
  }

  $facts = Count-Lines $snap 'facts.jsonl'
  $diary = Count-Lines $snap 'diary.jsonl'
  Write-Host "已拉取快照：$snap"
  Write-Host "  事实 $facts 条 · 日记 $diary 条"

  # 快照只增不减会吃掉磁盘，默认留最近 14 天
  if ($PruneDays -gt 0) {
    $cut = (Get-Date).AddDays(-$PruneDays)
    Get-ChildItem $work -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'memory-*' -and $_.LastWriteTime -lt $cut } |
      ForEach-Object { Write-Host "  清掉过期快照：$($_.Name)"; Remove-Item $_.FullName -Recurse -Force }
  }

  if ($Apply) {
    $backup = Join-Path $work "prev-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($p in $existing) {
      $src = Join-Path $snap $p
      $dst = Join-Path $repo $p
      if (-not (Test-Path $src)) { continue }
      if (Test-Path $dst) {
        $b = Join-Path $backup $p
        New-Item -ItemType Directory -Force -Path (Split-Path $b -Parent) | Out-Null
        Copy-Item $dst $b -Recurse -Force
        Remove-Item $dst -Recurse -Force
      }
      New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
      Copy-Item $src $dst -Recurse -Force
      Write-Host "  已覆盖本地：$p"
    }
    Write-Host "  覆盖前的旧数据备份在：$backup"
  } else {
    Write-Host "  未覆盖本地文件（加 -Apply 才会覆盖，覆盖前会自动备份）"
  }
}
else {
  if (-not $Force) {
    $ans = Read-Host "这会用本地 state 覆盖服务器 $RemoteRoot 上的同名目录，继续吗？(yes/N)"
    if ($ans -ne 'yes') { Write-Host '已取消'; return }
  }
  $present = @($paths | Where-Object { Test-Path (Join-Path $repo $_) })
  if (-not $present.Count) { throw '本地没有可推送的 state 目录' }
  foreach ($p in $present) {
    $parent = "$RemoteRoot/" + (Split-Path $p -Parent) -replace '\\', '/'
    Invoke-Ssh "mkdir -p '$parent'"
    Write-Host "推送 $p ..."
    Invoke-Scp @((Join-Path $repo $p), "${Remote}:$parent/")
  }
  Invoke-Ssh "chown -R qqbridge:qqbridge $RemoteRoot/state $RemoteRoot/qqbridge-tool/memory-diary/state $RemoteRoot/qqbridge-tool/memory-diary/persona-core 2>/dev/null; echo PUSH_OK"
  Write-Host '已推送到服务器。建议重启桥接：ssh 上去 systemctl restart qq-bridge'
}
