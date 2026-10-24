param(
  [Parameter(Mandatory = $true)][string]$Target,
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [string]$Dest
)

# PowerShell fallback for make-shortcut.vbs (kept ASCII-only on purpose).
$ErrorActionPreference = 'Stop'

# "QQ Bot 管理面板" built from code points so this file needs no special encoding
$name = 'QQ Bot ' + [string][char]31649 + [char]29702 + [char]38754 + [char]26495

try {
  $shell = New-Object -ComObject WScript.Shell
} catch {
  Write-Host "[x] cannot create WScript.Shell: $($_.Exception.Message)"
  exit 3
}

if (-not $Dest) {
  try { $Dest = $shell.SpecialFolders.Item('Desktop') } catch { $Dest = $null }
  if (-not $Dest) { try { $Dest = [Environment]::GetFolderPath('Desktop') } catch { $Dest = $null } }
  if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE 'Desktop' }
}

if (-not (Test-Path -LiteralPath $Dest)) {
  Write-Host "[x] desktop folder not found: $Dest"
  exit 2
}

$lnk = Join-Path $Dest ($name + '.lnk')
try {
  $sc = $shell.CreateShortcut($lnk)
  $sc.TargetPath = $Target
  $sc.WorkingDirectory = $WorkDir
  $sc.WindowStyle = 1
  $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',13'
  $sc.Description = $name + ' - SSH tunnel + web panel'
  $sc.Save()
} catch {
  Write-Host "[x] failed to save shortcut: $($_.Exception.Message)"
  exit 1
}

if (Test-Path -LiteralPath $lnk) {
  Write-Host "[v] shortcut ready: $lnk"
  exit 0
}

Write-Host "[x] shortcut not found after save: $lnk"
exit 1
