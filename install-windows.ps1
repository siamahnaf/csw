#Requires -Version 5.1
# install-windows.ps1 — CSW Windows Installer

$ErrorActionPreference = "Stop"

$REPO        = "siamahnaf/csw"
$BRANCH      = if ($env:BRANCH) { $env:BRANCH } else { "main" }
$TARBALL     = "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH"
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "csw"

function Write-Step    { param($Msg) Write-Host "==>  $Msg" -ForegroundColor Cyan }
function Write-Success { param($Msg) Write-Host "[OK]  $Msg" -ForegroundColor Green }
function Write-Err     { param($Msg) Write-Host "[ERR]  $Msg" -ForegroundColor Red }
function Write-Info    { param($Msg) Write-Host "[INFO] $Msg" -ForegroundColor Blue }
function Write-Warn    { param($Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-KV      { param($K,$V) Write-Host ("  {0,-12} {1}" -f "${K}:", $V) -ForegroundColor DarkGray }
function Write-HR      { Write-Host "────────────────────────────────────────" -ForegroundColor DarkGray }

if ($env:OS -ne "Windows_NT") {
    Write-Err "This installer is for Windows only. Use install.sh on macOS/Linux/WSL."
    exit 1
}

Write-Host ""
Write-HR
Write-Host "CSW Installer (Windows)" -ForegroundColor Magenta
Write-Host "  $REPO @ $BRANCH" -ForegroundColor DarkGray
Write-HR
Write-KV "Install Dir" $INSTALL_DIR
Write-HR
Write-Host ""

# PowerShell version check
Write-Step "Checking PowerShell version..."
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Err "PowerShell 5.1 or later is required. Current: $($PSVersionTable.PSVersion)"
    exit 1
}
Write-Success "PowerShell $($PSVersionTable.PSVersion)"

# Create install directory
Write-Step "Creating install directory..."
if (-not (Test-Path $INSTALL_DIR)) {
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
}
Write-Success "$INSTALL_DIR"

# Download & extract
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "csw_install_$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

try {
    Write-Step "Downloading csw..."
    Write-Info "Source: ${REPO}@${BRANCH}"
    $tarFile = Join-Path $tmp "repo.tar.gz"
    Invoke-WebRequest -Uri $TARBALL -OutFile $tarFile -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
    Write-Success "Downloaded tarball"

    Write-Step "Extracting..."
    $p = Start-Process "tar" -ArgumentList @("-xzf", $tarFile, "-C", $tmp) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "tar failed with exit code $($p.ExitCode)" }
    Write-Success "Extracted"

    $repoDir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like "csw-*" } | Select-Object -First 1
    if ($null -eq $repoDir) { throw "Could not find extracted repo directory in $tmp" }
    Write-Info "Repo dir: $($repoDir.FullName)"

    # Install main script
    Write-Step "Installing files..."
    $scriptSrc  = Join-Path $repoDir.FullName "ccswitch-windows.ps1"
    $scriptDest = Join-Path $INSTALL_DIR "ccswitch-windows.ps1"
    if (-not (Test-Path $scriptSrc)) { throw "ccswitch-windows.ps1 not found in tarball" }
    Copy-Item $scriptSrc $scriptDest -Force

    # Create csw.cmd wrapper (absolute path baked in, same pattern as Unix bin/csw)
    $wrapperDest = Join-Path $INSTALL_DIR "csw.cmd"
    $wrapperContent = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptDest`" %*"
    Set-Content -Path $wrapperDest -Value $wrapperContent -Encoding ASCII -Force

    Write-Success "Installed binaries"

    # Read version from installed script
    $installedVersion = "unknown"
    try {
        $line = Get-Content $scriptDest | Where-Object { $_ -match '\$CSW_VERSION\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"' } | Select-Object -First 1
        if ($line -match '"([0-9]+\.[0-9]+\.[0-9]+)"') { $installedVersion = $Matches[1] }
    } catch {}

} catch {
    Write-Err "Installation failed: $_"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

# Add to user PATH
Write-Step "Adding to user PATH..."
$currentPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$INSTALL_DIR*") {
    [System.Environment]::SetEnvironmentVariable("PATH", "$currentPath;$INSTALL_DIR", "User")
    Write-Success "Added $INSTALL_DIR to user PATH."
} else {
    Write-Success "Already in user PATH."
}

Write-Host ""
Write-HR
Write-Success "Installed:"
Write-KV "Binary"   "$INSTALL_DIR\csw.cmd"
Write-KV "Library"  "$INSTALL_DIR\ccswitch-windows.ps1"
Write-KV "Version"  $installedVersion
Write-HR
Write-Host ""
Write-Warn "Restart your terminal for PATH changes to take effect."
Write-Info "Then run 'csw -help' to get started."
Write-Host ""
