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
# 只会搬运这三样，不碰代码：
#   state/                              桥接侧（会话表、人格记忆缓存、日志等）
#   qqbridge-tool/memory-diary/state/   人格档案（facts/diary/archive/handoff）
#   qqbridge-tool/memory-diary/persona-core/  内核（含 .bak；真实内核不进 git，只能靠它搬）
param(
  [string]$Remote = 'root@123.57.37.192',
  [string]$KeyFile = '',
  [string]$RemoteRoot = '/opt/qq-bridge',
  [ValidateSet('pull', 'push')][string]$Direction = 'pull',
  [switch]$Apply,
  [switch]$Force
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
  & scp -i $KeyFile -o StrictHostKeyChecking=no @ScpArgs
  if ($LASTEXITCODE -ne 0) { throw "scp 失败（exit $LASTEXITCODE）" }
}

if ($Direction -eq 'pull') {
  $tarName = "memory-$stamp.tgz"
  $remoteTar = "/tmp/$tarName"
  $existing = @()
  foreach ($p in $paths) {
    $check = & ssh -i $KeyFile -o StrictHostKeyChecking=no $Remote "test -e '$RemoteRoot/$p' && echo yes || echo no"
    if ($check.Trim() -eq 'yes') { $existing += $p }
  }
  if (-not $existing.Count) { throw "服务器上这三样都不存在：$($paths -join ', ')" }

  $list = ($existing | ForEach-Object { "'$RemoteRoot/$_'" }) -join ' '
  & ssh -i $KeyFile -o StrictHostKeyChecking=no $Remote "cd '$RemoteRoot' && tar czf '$remoteTar' $list && ls -l '$remoteTar'"
  if ($LASTEXITCODE -ne 0) { throw '服务器打包失败' }

  $localTar = Join-Path $work $tarName
  Invoke-Scp @("${Remote}:$remoteTar", $localTar)
  & ssh -i $KeyFile -o StrictHostKeyChecking=no $Remote "rm -f '$remoteTar'"

  $snap = Join-Path $work "memory-$stamp"
  New-Item -ItemType Directory -Force -Path $snap | Out-Null
  & tar xzf $localTar -C $snap
  if ($LASTEXITCODE -ne 0) { throw '解包失败' }

  $facts = 0; $diary = 0; $archive = 0
  Get-ChildItem -Path $snap -Recurse -File -Filter 'facts.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
    $facts += (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
  }
  Get-ChildItem -Path $snap -Recurse -File -Filter 'diary.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
    $diary += (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
  }
  Get-ChildItem -Path $snap -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Where-Object { $_.Directory.Name -eq 'archive' } | ForEach-Object {
      $archive += (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    }

  Write-Host "已拉取快照：$snap"
  Write-Host "  事实 $facts 条 · 日记 $diary 条 · 档案 $archive 条"

  if ($Apply) {
    $backup = Join-Path $work "prev-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    foreach ($p in $paths) {
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
  $tarName = "memory-push-$stamp.tgz"
  $localTar = Join-Path $work $tarName
  $present = $paths | Where-Object { Test-Path (Join-Path $repo $_) }
  if (-not $present) { throw '本地没有可推送的 state 目录' }
  & tar czf $localTar -C $repo @present
  if ($LASTEXITCODE -ne 0) { throw '本地打包失败' }
  Invoke-Scp @($localTar, "${Remote}:/tmp/$tarName")
  $remoteCmd = "cd '$RemoteRoot' && tar xzf '/tmp/$tarName' && rm -f '/tmp/$tarName' && chown -R qqbridge:qqbridge state qqbridge-tool/memory-diary/state qqbridge-tool/memory-diary/persona-core 2>/dev/null; echo PUSH_OK"
  & ssh -i $KeyFile -o StrictHostKeyChecking=no $Remote $remoteCmd
  if ($LASTEXITCODE -ne 0) { throw '服务器解包失败' }
  Write-Host '已推送到服务器。建议重启桥接：ssh 上去 systemctl restart qq-bridge'
}
