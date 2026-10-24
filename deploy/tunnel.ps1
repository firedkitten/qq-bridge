# tunnel.ps1 —— 在 Windows 本机建立到 ECS 的 SSH 隧道（只做端口转发，不执行远程命令）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File deploy\tunnel.ps1 -Server <服务器IP>
#   $env:QQB_SERVER = '<服务器IP>'; powershell -ExecutionPolicy Bypass -File deploy\tunnel.ps1
#   powershell -ExecutionPolicy Bypass -File deploy\tunnel.ps1 -Server <IP> -Key "$env:USERPROFILE\.ssh\id_ed25519"
#
# 隧道建立后（保持这个窗口开着）：
#   http://127.0.0.1:3100  qq-bridge 控制台
#   http://127.0.0.1:5099  SnowLuma WebUI
#   http://127.0.0.1:6081/vnc.html?autoconnect=1   noVNC（扫码用）
#   http://127.0.0.1:3380  DSH（若服务器上也跑 DSH）
#   注意：本机 3080 已被你自己的 DSH 占用，所以服务器的 3080 映射到本机 3380
param(
  # 服务器公网 IP / 主机名：优先用参数，其次环境变量 QQB_SERVER
  [string]$Server = $env:QQB_SERVER,
  [string]$User   = $(if ($env:QQB_USER) { $env:QQB_USER } else { 'root' }),
  # SSH 私钥：优先用参数，其次环境变量 QQB_KEY，最后回退到仓库根的 id_ed25519
  [string]$Key    = $env:QQB_KEY,
  [int]$Port      = 22
)

if (-not $Server) {
  Write-Host ""
  Write-Host " [!] 没指定服务器地址。" -ForegroundColor Yellow
  Write-Host "     用法: powershell -ExecutionPolicy Bypass -File deploy\tunnel.ps1 -Server <服务器IP>" -ForegroundColor DarkGray
  Write-Host "     或先: `$env:QQB_SERVER = '<服务器IP>'" -ForegroundColor DarkGray
  exit 1
}

# 没显式给 -Key 时，自动用仓库根目录的私钥
if (-not $Key) {
  $candidate = Join-Path (Split-Path $PSScriptRoot -Parent) 'id_ed25519'
  if (Test-Path $candidate) { $Key = $candidate }
}

$forwards = @(
  '3100:127.0.0.1:3100',
  '5099:127.0.0.1:5099',
  '6081:127.0.0.1:6081',
  '3380:127.0.0.1:3080'
)

$sshArgs = @('-N', '-p', "$Port",
  '-o', 'ServerAliveInterval=30',
  '-o', 'ServerAliveCountMax=3',
  '-o', 'ExitOnForwardFailure=yes')

foreach ($f in $forwards) { $sshArgs += @('-L', $f) }
if ($Key -and (Test-Path $Key)) { $sshArgs += @('-i', $Key) }
$sshArgs += "$User@$Server"

Write-Host ""
Write-Host " SSH 隧道: $User@$Server" -ForegroundColor Cyan
Write-Host "   3100 qq-bridge 控制台 | 5099 SnowLuma | 6081 noVNC | 3380 服务器上的 DSH" -ForegroundColor DarkGray
Write-Host " Ctrl+C 断开" -ForegroundColor DarkGray
Write-Host ""

& ssh @sshArgs
