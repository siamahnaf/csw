#Requires -Version 5.1
# uninstall-windows.ps1 — CSW Windows Uninstaller

$ErrorActionPreference = "Stop"

$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "csw"

function Write-Step    { param($Msg) Write-Host "==>  $Msg" -ForegroundColor Cyan }
function Write-Success { param($Msg) Write-Host "[OK]  $Msg" -ForegroundColor Green }
function Write-Warn    { param($Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Info    { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Blue }
function Write-KV      { param($K,$V) Write-Host ("  {0,-12} {1}" -f "${K}:", $V) -ForegroundColor DarkGray }
function Write-HR      { Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray }

Write-Host ""
Write-HR
Write-Host "CSW Uninstaller (Windows)" -ForegroundColor Magenta
Write-HR
Write-KV "Install Dir" $INSTALL_DIR
Write-HR
Write-Host ""

$removedAny = $false

Write-Step "Uninstalling csw..."

if (Test-Path $INSTALL_DIR) {
    Remove-Item $INSTALL_DIR -Recurse -Force
    Write-Success "Removed: $INSTALL_DIR"
    $removedAny = $true
} else {
    Write-Warn "Not found: $INSTALL_DIR"
}

Write-Step "Removing from user PATH..."
$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -like "*$INSTALL_DIR*") {
    $newPath = ($currentPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $INSTALL_DIR.TrimEnd('\') }) -join ';'
    [System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Success "Removed from user PATH."
} else {
    Write-Info "Not found in user PATH, skipping."
}

Write-Host ""
Write-HR
if ($removedAny) {
    Write-Success "csw uninstalled."
} else {
    Write-Warn "Nothing to uninstall (csw not found under $INSTALL_DIR)."
}
Write-HR
Write-Host ""
Write-Warn "Note: this does NOT delete your account backups:"
Write-Host "  Remove-Item -Recurse `"$env:USERPROFILE\.claude-switch-backup`"" -ForegroundColor White
Write-Host ""
