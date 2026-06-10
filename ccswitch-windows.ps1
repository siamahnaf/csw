#Requires -Version 5.1
# ccswitch-windows.ps1 — Multi-Account Switcher for Claude Code (Windows)

$ErrorActionPreference = "Stop"

$CSW_VERSION        = "2.5.0"
$CSW_REPO           = "siamahnaf/csw"
$CSW_DEFAULT_BRANCH = "main"

$BACKUP_DIR      = Join-Path $env:USERPROFILE ".claude-switch-backup"
$SEQUENCE_FILE   = Join-Path $BACKUP_DIR "sequence.json"
$LOG_FILE        = Join-Path $BACKUP_DIR "csw.log"
$CREDS_DIR       = Join-Path $BACKUP_DIR "credentials"
$CONFIGS_DIR     = Join-Path $BACKUP_DIR "configs"
$LIVE_CREDS_PATH = Join-Path $env:USERPROFILE ".claude\.credentials.json"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-CSWInfo    { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-CSWWarn    { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-CSWSuccess { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-CSWError   { param([string]$Msg) Write-Host "[ERR]  $Msg" -ForegroundColor Red }
function Write-CSWStep    { param([string]$Msg) Write-Host "==>  $Msg" -ForegroundColor Blue }
function Write-CSWTitle   { param([string]$Msg) Write-Host $Msg -ForegroundColor Magenta }
function Write-CSWDim     { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Platform guard
# ---------------------------------------------------------------------------
if ($env:OS -ne "Windows_NT") {
    Write-CSWError "This script is for Windows only. Use ccswitch.sh on macOS/Linux/WSL."
    exit 1
}

# ---------------------------------------------------------------------------
# DPAPI — credentials stored as Base64-encoded DPAPI blobs (current-user scope)
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Security

function Protect-CswData {
    param([string]$Data)
    if ([string]::IsNullOrEmpty($Data)) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                 $bytes, $null,
                 [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Convert]::ToBase64String($enc)
}

function Unprotect-CswData {
    param([string]$EncBase64)
    if ([string]::IsNullOrEmpty($EncBase64)) { return "" }
    try {
        $enc   = [System.Convert]::FromBase64String($EncBase64)
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                     $enc, $null,
                     [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch { return "" }
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------
function Test-ValidJson {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    try { $null = $Text | ConvertFrom-Json; return $true } catch { return $false }
}

function Write-JsonAtomic {
    param([string]$Path, [string]$Json)
    if (-not (Test-ValidJson $Json)) {
        Write-CSWError "Refusing to write invalid JSON to $Path"
        return $false
    }
    $tmp = "$Path.tmp"
    # [System.IO.File]::WriteAllText is used instead of Set-Content because
    # Set-Content's -NoNewline flag only exists in PS 6+; PS 5.1 (Windows built-in) lacks it.
    [System.IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding $false))
    try {
        Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        throw $_
    }
    try {
        $acl = Get-Acl $Path
        $acl.SetAccessRuleProtection($true, $false)
        $id  = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl.SetAccessRule(
            (New-Object System.Security.AccessControl.FileSystemAccessRule($id, "FullControl", "Allow")))
        Set-Acl -Path $Path -AclObject $acl
    } catch {}
    return $true
}

# Strip API-key fields from config JSON (prevents auth-conflict on restore)
function Get-SanitizedConfig {
    param([string]$Json)
    try {
        $obj = $Json | ConvertFrom-Json
        foreach ($f in @('apiKeyHelper','apiKey','anthropicApiKey','claudeApiKey',
                         'managedApiKey','externalApiKey','loginApiKey',
                         'enterpriseApiKey','organizationApiKey','apiKeySource','hasApiKey')) {
            $obj.PSObject.Properties.Remove($f)
        }
        return $obj | ConvertTo-Json -Depth 20 -Compress
    } catch { return $Json }
}

# Strip API-key fields from credentials JSON
function Get-SanitizedCredentials {
    param([string]$Json)
    try {
        $obj = $Json | ConvertFrom-Json
        foreach ($f in @('apiKey','anthropicApiKey','claudeApiKey','managedApiKey',
                         'externalApiKey','apiKeyHelper','loginApiKey')) {
            $obj.PSObject.Properties.Remove($f)
        }
        return $obj | ConvertTo-Json -Depth 20 -Compress
    } catch { return $Json }
}

# ---------------------------------------------------------------------------
# Claude config path  ($HOME\.claude\.claude.json  or  $HOME\.claude.json)
# ---------------------------------------------------------------------------
function Get-ClaudeConfigPath {
    $primary  = Join-Path $env:USERPROFILE ".claude\.claude.json"
    $fallback = Join-Path $env:USERPROFILE ".claude.json"
    if (Test-Path $primary) {
        try {
            if ($null -ne ($primary | Get-Item | Get-Content -Raw | ConvertFrom-Json).oauthAccount) {
                return $primary
            }
        } catch {}
    }
    return $fallback
}

# ---------------------------------------------------------------------------
# Claude CLI version (User-Agent header)
# ---------------------------------------------------------------------------
$script:_claudeVer = $null
function Get-ClaudeCLIVersion {
    if ($null -eq $script:_claudeVer) {
        try {
            $out = & claude --version 2>$null | Select-Object -First 1
            $script:_claudeVer = if ([string]::IsNullOrEmpty($out)) { "0.0.0" } else { ($out -split ' ')[0] }
        } catch { $script:_claudeVer = "0.0.0" }
    }
    return $script:_claudeVer
}

# ---------------------------------------------------------------------------
# Current account
# ---------------------------------------------------------------------------
function Get-CurrentAccount {
    $cfgPath = Get-ClaudeConfigPath
    if (-not (Test-Path $cfgPath)) { return "none" }
    try {
        $email = (Get-Content $cfgPath -Raw | ConvertFrom-Json).oauthAccount.emailAddress
        if ([string]::IsNullOrEmpty($email)) { return "none" }
        return $email
    } catch { return "none" }
}

# ---------------------------------------------------------------------------
# Live credentials I/O  (~\.claude\.credentials.json)
# ---------------------------------------------------------------------------
function Read-LiveCredentials {
    if (-not (Test-Path $LIVE_CREDS_PATH)) { return "" }
    try { return Get-Content $LIVE_CREDS_PATH -Raw } catch { return "" }
}

function Write-LiveCredentials {
    param([string]$Json)
    $dir = Split-Path $LIVE_CREDS_PATH
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-JsonAtomic $LIVE_CREDS_PATH $Json | Out-Null
}

# ---------------------------------------------------------------------------
# Per-account credential storage  (DPAPI-encrypted .enc files)
# ---------------------------------------------------------------------------
function Read-AccountCredentials {
    param([string]$Num, [string]$Email)
    $file = Join-Path $CREDS_DIR ".csw-cred-${Num}-${Email}.enc"
    if (-not (Test-Path $file)) { return "" }
    return Unprotect-CswData ((Get-Content $file -Raw).Trim())
}

function Write-AccountCredentials {
    param([string]$Num, [string]$Email, [string]$Json)
    if (-not (Test-ValidJson $Json)) { Write-CSWError "Refusing to store invalid JSON for Account-$Num"; return }
    if (-not (Test-Path $CREDS_DIR)) { New-Item -ItemType Directory -Path $CREDS_DIR -Force | Out-Null }
    Set-Content -Path (Join-Path $CREDS_DIR ".csw-cred-${Num}-${Email}.enc") `
        -Value (Protect-CswData $Json) -Encoding UTF8 -Force
}

function Remove-AccountCredentials {
    param([string]$Num, [string]$Email)
    $f = Join-Path $CREDS_DIR ".csw-cred-${Num}-${Email}.enc"
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---------------------------------------------------------------------------
# Per-account config storage
# ---------------------------------------------------------------------------
function Read-AccountConfig {
    param([string]$Num, [string]$Email)
    $f = Join-Path $CONFIGS_DIR ".csw-config-${Num}-${Email}.json"
    if (-not (Test-Path $f)) { return "" }
    try { return Get-Content $f -Raw } catch { return "" }
}

function Write-AccountConfig {
    param([string]$Num, [string]$Email, [string]$Json)
    if (-not (Test-Path $CONFIGS_DIR)) { New-Item -ItemType Directory -Path $CONFIGS_DIR -Force | Out-Null }
    Set-Content -Path (Join-Path $CONFIGS_DIR ".csw-config-${Num}-${Email}.json") `
        -Value $Json -Encoding UTF8 -Force
}

function Remove-AccountConfig {
    param([string]$Num, [string]$Email)
    $f = Join-Path $CONFIGS_DIR ".csw-config-${Num}-${Email}.json"
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ---------------------------------------------------------------------------
# Directory setup
# ---------------------------------------------------------------------------
function Initialize-Directories {
    foreach ($d in @($BACKUP_DIR, $CREDS_DIR, $CONFIGS_DIR)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# ---------------------------------------------------------------------------
# Sequence file
# ---------------------------------------------------------------------------
function Initialize-SequenceFile {
    if (Test-Path $SEQUENCE_FILE) { return }
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Set-Content -Path $SEQUENCE_FILE `
        -Value ('{"activeAccountNumber":null,"lastUpdated":"' + $now + '","sequence":[],"accounts":{}}') `
        -Encoding UTF8 -Force
}

function Get-SequenceData {
    if (-not (Test-Path $SEQUENCE_FILE)) { return $null }
    try { return Get-Content $SEQUENCE_FILE -Raw | ConvertFrom-Json } catch { return $null }
}

function Save-SequenceData {
    param($Data)
    $Data.lastUpdated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-JsonAtomic $SEQUENCE_FILE ($Data | ConvertTo-Json -Depth 20 -Compress) | Out-Null
}

function Get-NextAccountNumber {
    $seq = Get-SequenceData
    if ($null -eq $seq -or $null -eq $seq.accounts) { return 1 }
    $nums = @($seq.accounts.PSObject.Properties.Name | ForEach-Object { [int]$_ })
    if ($nums.Count -eq 0) { return 1 }
    return (($nums | Measure-Object -Maximum).Maximum + 1)
}

function Test-AccountExists {
    param([string]$Email)
    $seq = Get-SequenceData
    if ($null -eq $seq) { return $false }
    foreach ($p in $seq.accounts.PSObject.Properties) {
        if ($p.Value.email -eq $Email) { return $true }
    }
    return $false
}

function Resolve-AccountIdentifier {
    param([string]$Identifier)
    $seq = Get-SequenceData
    if ($null -eq $seq) { return $null }
    if ($Identifier -match '^\d+$') {
        $p = $seq.accounts.PSObject.Properties | Where-Object { $_.Name -eq $Identifier }
        if ($p) { return @{ Number = $Identifier; Email = $p.Value.email } }
    } else {
        foreach ($p in $seq.accounts.PSObject.Properties) {
            if ($p.Value.email -eq $Identifier) { return @{ Number = $p.Name; Email = $Identifier } }
        }
    }
    return $null
}

function Get-NextInSequence {
    $seq = Get-SequenceData
    if ($null -eq $seq) { return $null }
    $arr = @($seq.sequence | Where-Object { $null -ne $_ })
    if ($arr.Count -eq 0) { return $null }
    $active = $seq.activeAccountNumber
    $idx = -1
    for ($i = 0; $i -lt $arr.Count; $i++) { if ($arr[$i] -eq $active) { $idx = $i; break } }
    return "$($arr[(($idx + 1) % $arr.Count)])"
}

function Get-CurrentManagedAccountNum {
    param([string]$Email)
    if ($Email -eq "none") { return "" }
    $seq = Get-SequenceData
    if ($null -eq $seq) { return "" }
    foreach ($p in $seq.accounts.PSObject.Properties) {
        if ($p.Value.email -eq $Email) { return $p.Name }
    }
    return ""
}

# ---------------------------------------------------------------------------
# OAuth token refresh
# ---------------------------------------------------------------------------
function Invoke-OAuthRefresh {
    param([string]$Credentials, [string]$AccountNum, [string]$Email)

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    $refreshToken = ""
    try { $refreshToken = ($Credentials | ConvertFrom-Json).claudeAiOauth.refreshToken } catch {}
    if ([string]::IsNullOrEmpty($refreshToken)) {
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): No refreshToken — skipped."
        return @{ Status = 1; Credentials = $Credentials }
    }

    $headers = @{
        "Content-Type"   = "application/x-www-form-urlencoded"
        "User-Agent"     = "claude-cli/$(Get-ClaudeCLIVersion)"
        "anthropic-beta" = "oauth-2025-04-20"
    }
    $body = "grant_type=refresh_token" +
            "&refresh_token=$([Uri]::EscapeDataString($refreshToken))" +
            "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    $statusCode  = 0
    $respBody    = ""
    $respHeaders = $null

    try {
        $r = Invoke-WebRequest -Uri "https://platform.claude.com/v1/oauth/token" `
             -Method Post -Headers $headers -Body $body -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $statusCode  = [int]$r.StatusCode
        $respBody    = $r.Content
        $respHeaders = $r.Headers
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            try {
                $rdr     = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $respBody = $rdr.ReadToEnd(); $rdr.Dispose()
            } catch {}
            $respHeaders = $_.Exception.Response.Headers
        } else {
            Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Network error — $($_.Exception.Message)"
            return @{ Status = 2; Credentials = $Credentials }
        }
    } catch {
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Network error — $($_.Exception.Message)"
        return @{ Status = 2; Credentials = $Credentials }
    }

    if ($statusCode -ne 200) {
        $retryAfter = try { if ($respHeaders) { $respHeaders["retry-after"] } else { "" } } catch { "" }
        $rateReset  = try { if ($respHeaders) { $respHeaders["anthropic-ratelimit-requests-reset"] } else { "" } } catch { "" }
        $rateRemain = try { if ($respHeaders) { $respHeaders["anthropic-ratelimit-requests-remaining"] } else { "" } } catch { "" }
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Server error HTTP $statusCode"
        return @{ Status = 3; Credentials = $Credentials; HttpStatus = $statusCode
                  Body = $respBody; RetryAfter = $retryAfter; RateReset = $rateReset; RateRemain = $rateRemain }
    }

    try {
        $ro          = $respBody | ConvertFrom-Json
        $accessToken = $ro.access_token
        $expiresIn   = if ($ro.expires_in) { [long]$ro.expires_in } else { 28800 }
        $newRT       = $ro.refresh_token
    } catch {
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Invalid response body"
        return @{ Status = 4; Credentials = $Credentials }
    }

    if ([string]::IsNullOrEmpty($accessToken)) {
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Missing access_token in response"
        return @{ Status = 4; Credentials = $Credentials }
    }

    $expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ($expiresIn * 1000)
    if ([string]::IsNullOrEmpty($newRT)) { $newRT = $refreshToken }

    try {
        $obj = $Credentials | ConvertFrom-Json
        $obj.claudeAiOauth.accessToken  = $accessToken
        $obj.claudeAiOauth.expiresAt    = $expiresAt
        $obj.claudeAiOauth.refreshToken = $newRT
        $updated = $obj | ConvertTo-Json -Depth 20 -Compress
    } catch {
        Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Failed to patch credentials object"
        return @{ Status = 4; Credentials = $Credentials }
    }

    Add-Content -Path $LOG_FILE -Value "[$ts] [FG] Account-${AccountNum} (${Email}): Token refreshed successfully."
    return @{ Status = 0; Credentials = $updated }
}

# ---------------------------------------------------------------------------
# Process detection
# ---------------------------------------------------------------------------
function Test-ClaudeRunning {
    return ($null -ne (Get-Process -Name "claude" -ErrorAction SilentlyContinue))
}

function Wait-ClaudeClose {
    if (-not (Test-ClaudeRunning)) { return }
    Write-CSWWarn "Claude Code is running. Please close it first."
    Write-CSWInfo "Waiting for Claude Code to close..."
    while (Test-ClaudeRunning) { Start-Sleep -Seconds 1 }
    Write-CSWSuccess "Claude Code closed. Continuing..."
}

# ---------------------------------------------------------------------------
# Semver comparison  (returns 1 if A > B, -1 if A < B, 0 if equal)
# ---------------------------------------------------------------------------
function Compare-SemVer {
    param([string]$A, [string]$B)
    $A = $A -replace '^v',''; $B = $B -replace '^v',''
    $pa = @($A -split '\.') + @(0,0,0)
    $pb = @($B -split '\.') + @(0,0,0)
    for ($i = 0; $i -lt 3; $i++) {
        $a = [int]($pa[$i] -replace '[^\d]'); $b = [int]($pb[$i] -replace '[^\d]')
        if ($a -gt $b) { return 1 } ; if ($a -lt $b) { return -1 }
    }
    return 0
}

# ---------------------------------------------------------------------------
# Background refresh (Start-Job so it survives main script exit)
# ---------------------------------------------------------------------------
function Start-BackgroundRefresh {
    param([string]$ActiveNum)
    $bgScript = {
        param($SeqFile, $ActiveNum, $CredsDir, $LogFile)
        Add-Type -AssemblyName System.Security
        Start-Sleep -Seconds 5
        if (-not (Test-Path $SeqFile)) { return }
        $seq   = Get-Content $SeqFile -Raw | ConvertFrom-Json
        $first = $true
        foreach ($prop in $seq.accounts.PSObject.Properties) {
            if ($prop.Name -eq $ActiveNum) { continue }
            $num   = $prop.Name
            $email = $prop.Value.email
            if (-not $first) { Start-Sleep -Seconds 120 }
            $first = $false
            $encFile = Join-Path $CredsDir ".csw-cred-${num}-${email}.enc"
            if (-not (Test-Path $encFile)) { continue }
            $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            try {
                $b64   = (Get-Content $encFile -Raw).Trim()
                $encB  = [System.Convert]::FromBase64String($b64)
                $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                             $encB, $null,
                             [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                $obj   = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                $rt    = $obj.claudeAiOauth.refreshToken
                if ([string]::IsNullOrEmpty($rt)) {
                    Add-Content $LogFile "[$ts] [BG] Account-${num} (${email}): No refreshToken — skipped."
                    continue
                }
                $hdrs = @{
                    "Content-Type"   = "application/x-www-form-urlencoded"
                    "User-Agent"     = "claude-cli/0.0.0"
                    "anthropic-beta" = "oauth-2025-04-20"
                }
                $body = "grant_type=refresh_token&refresh_token=$([Uri]::EscapeDataString($rt))&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
                $r    = Invoke-WebRequest -Uri "https://platform.claude.com/v1/oauth/token" `
                        -Method Post -Headers $hdrs -Body $body -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                $ro   = $r.Content | ConvertFrom-Json
                $ei   = if ($ro.expires_in) { [long]$ro.expires_in } else { 28800 }
                $obj.claudeAiOauth.accessToken  = $ro.access_token
                if ($ro.refresh_token) { $obj.claudeAiOauth.refreshToken = $ro.refresh_token }
                $obj.claudeAiOauth.expiresAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ($ei * 1000)
                $newJson  = $obj | ConvertTo-Json -Depth 20 -Compress
                $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newJson)
                $newEnc   = [System.Security.Cryptography.ProtectedData]::Protect(
                                $newBytes, $null,
                                [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
                Set-Content -Path $encFile -Value ([System.Convert]::ToBase64String($newEnc)) -Encoding UTF8 -Force
                Add-Content $LogFile "[$ts] [BG] Account-${num} (${email}): Token refreshed successfully."
            } catch {
                $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "ERR" }
                Add-Content $LogFile "[$ts] [BG] Account-${num} (${email}): Failed — HTTP $sc $($_.Exception.Message)"
            }
        }
    }
    Start-Job -ScriptBlock $bgScript -ArgumentList @($SEQUENCE_FILE, $ActiveNum, $CREDS_DIR, $LOG_FILE) | Out-Null
}

# ---------------------------------------------------------------------------
# perform_switch — core logic
# ---------------------------------------------------------------------------
function Invoke-PerformSwitch {
    param([string]$TargetNum)

    Wait-ClaudeClose

    $seq = Get-SequenceData
    if ($null -eq $seq) { Write-CSWError "Sequence file not found."; exit 1 }

    $targetProp = $seq.accounts.PSObject.Properties | Where-Object { $_.Name -eq $TargetNum }
    if ($null -eq $targetProp) { Write-CSWError "Account-$TargetNum not found."; exit 1 }
    $targetEmail = $targetProp.Value.email

    $cfgPath      = Get-ClaudeConfigPath
    $currentEmail = Get-CurrentAccount
    $currentNum   = Get-CurrentManagedAccountNum $currentEmail
    if ([string]::IsNullOrEmpty($currentNum)) { $currentNum = "$($seq.activeAccountNumber)" }

    # Backup current account
    if (-not [string]::IsNullOrEmpty($currentNum) -and $currentNum -ne "null" -and $currentEmail -ne "none") {
        Write-CSWStep "Saving current account backup..."
        $liveCreds = Read-LiveCredentials
        if (-not [string]::IsNullOrEmpty($liveCreds)) {
            Write-AccountCredentials $currentNum $currentEmail (Get-SanitizedCredentials $liveCreds)
        } else {
            Write-CSWWarn "Could not read current credentials; skipping credentials backup."
        }
        if (Test-Path $cfgPath) {
            Write-AccountConfig $currentNum $currentEmail (Get-SanitizedConfig (Get-Content $cfgPath -Raw))
        }
        Write-CSWSuccess "Backed up: Account-$currentNum ($currentEmail)"
    }

    # Load target data
    $targetCreds  = Read-AccountCredentials $TargetNum $targetEmail
    $targetCfgRaw = Read-AccountConfig      $TargetNum $targetEmail
    if ([string]::IsNullOrEmpty($targetCreds) -or [string]::IsNullOrEmpty($targetCfgRaw)) {
        Write-CSWError "Missing backup data for Account-$TargetNum ($targetEmail)."
        exit 1
    }
    $targetCreds = Get-SanitizedCredentials $targetCreds

    # Clear log for this run
    Set-Content -Path $LOG_FILE -Value "" -Encoding UTF8 -Force

    # Foreground OAuth refresh
    Write-CSWStep "Refreshing OAuth token for Account-$TargetNum..."
    $result = Invoke-OAuthRefresh $targetCreds $TargetNum $targetEmail

    switch ($result.Status) {
        0 {
            $targetCreds = $result.Credentials
            Write-AccountCredentials $TargetNum $targetEmail $targetCreds
            Write-CSWSuccess "Token refreshed successfully — new access token applied."
        }
        1 { Write-CSWWarn "Token refresh skipped — no refreshToken in stored credentials." }
        2 { Write-CSWWarn "Token refresh failed — network error. Using stored credentials." }
        3 {
            Write-CSWWarn "Token refresh failed — HTTP $($result.HttpStatus)."
            if ($result.RetryAfter) { Write-CSWInfo "Retry after: $($result.RetryAfter) seconds." }
            if ($result.RateReset)  { Write-CSWInfo "Rate limit resets at: $($result.RateReset)" }
            Write-CSWInfo "Re-login with: claude login"
        }
        4 { Write-CSWWarn "Token refresh failed — invalid server response. Using stored credentials." }
    }

    # Apply credentials
    Write-CSWStep "Applying target credentials/config..."
    Write-LiveCredentials $targetCreds

    # Merge config: set oauthAccount from target, strip API key fields
    if (Test-Path $cfgPath) {
        try {
            $currentCfgObj = Get-Content $cfgPath -Raw | ConvertFrom-Json
            $targetCfgObj  = $targetCfgRaw | ConvertFrom-Json
            if ($null -eq $targetCfgObj.oauthAccount) {
                Write-CSWError "Invalid oauthAccount in backup config for Account-$TargetNum"; exit 1
            }
            $currentCfgObj | Add-Member -MemberType NoteProperty -Name "oauthAccount" `
                -Value $targetCfgObj.oauthAccount -Force
            foreach ($f in @('apiKeyHelper','apiKey','anthropicApiKey','claudeApiKey','managedApiKey',
                              'externalApiKey','loginApiKey','enterpriseApiKey','organizationApiKey',
                              'apiKeySource','hasApiKey')) {
                $currentCfgObj.PSObject.Properties.Remove($f)
            }
            Write-JsonAtomic $cfgPath ($currentCfgObj | ConvertTo-Json -Depth 20 -Compress) | Out-Null
        } catch {
            Write-CSWError "Failed to merge config: $_"; exit 1
        }
    }

    # Update sequence
    $seq.activeAccountNumber = [int]$TargetNum
    Save-SequenceData $seq
    Write-CSWSuccess "Switched to Account-$TargetNum ($targetEmail)"

    Start-BackgroundRefresh $TargetNum
    Invoke-List
    Write-Host ""
    Write-CSWWarn "Please restart Claude Code to use the new authentication."
    Write-Host ""
}

# ---------------------------------------------------------------------------
# cmd_add_account
# ---------------------------------------------------------------------------
function Invoke-AddAccount {
    Initialize-Directories
    Initialize-SequenceFile

    $email = Get-CurrentAccount
    if ($email -eq "none") {
        Write-CSWError "No active Claude account found. Please log in with 'claude login' first."
        exit 1
    }
    if (Test-AccountExists $email) { Write-CSWWarn "Account $email is already managed."; exit 0 }

    $cfgPath    = Get-ClaudeConfigPath
    $accountNum = Get-NextAccountNumber

    $liveCreds = Read-LiveCredentials
    if ([string]::IsNullOrEmpty($liveCreds)) {
        Write-CSWError "No credentials found. Please log in with 'claude login' first."
        exit 1
    }
    Write-AccountCredentials "$accountNum" $email (Get-SanitizedCredentials $liveCreds)

    if (Test-Path $cfgPath) {
        Write-AccountConfig "$accountNum" $email (Get-SanitizedConfig (Get-Content $cfgPath -Raw))
    }

    $accountUuid = ""
    try { $accountUuid = (Get-Content $cfgPath -Raw | ConvertFrom-Json).oauthAccount.accountUuid } catch {}

    $seq = Get-SequenceData
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $seq.accounts | Add-Member -MemberType NoteProperty -Name "$accountNum" -Value ([PSCustomObject]@{
        email = $email
        uuid  = if ([string]::IsNullOrEmpty($accountUuid)) { [guid]::NewGuid().ToString() } else { $accountUuid }
        added = $now
    }) -Force
    $seq | Add-Member -MemberType NoteProperty -Name "sequence" -Value (@($seq.sequence) + @($accountNum)) -Force
    $seq.activeAccountNumber = $accountNum
    Save-SequenceData $seq

    Write-CSWSuccess "Added Account $accountNum: $email"
}

# ---------------------------------------------------------------------------
# first_run_setup
# ---------------------------------------------------------------------------
function Invoke-FirstRunSetup {
    $email = Get-CurrentAccount
    if ($email -eq "none") { Write-CSWError "No active Claude account found. Please log in first."; return }
    $ans = Read-Host "No managed accounts found. Add current account ($email) to managed list? [Y/n]"
    if ($ans -eq "n" -or $ans -eq "N") { Write-CSWWarn "Setup cancelled. Run 'csw add-account' later."; return }
    Invoke-AddAccount
}

# ---------------------------------------------------------------------------
# cmd_list
# ---------------------------------------------------------------------------
function Invoke-List {
    if (-not (Test-Path $SEQUENCE_FILE)) {
        Write-CSWWarn "No accounts are managed yet."
        Invoke-FirstRunSetup
        exit 0
    }
    $seq = Get-SequenceData
    if ($null -eq $seq -or $seq.accounts.PSObject.Properties.Count -eq 0) {
        Write-CSWWarn "No accounts managed yet. Run: csw add-account"; return
    }
    $currentEmail = Get-CurrentAccount
    $activeNum    = if ($currentEmail -ne "none") { Get-CurrentManagedAccountNum $currentEmail } else { "" }

    Write-CSWTitle "Accounts:"
    foreach ($n in @($seq.sequence)) {
        $num   = "$n"
        $p     = $seq.accounts.PSObject.Properties | Where-Object { $_.Name -eq $num }
        if ($null -eq $p) { continue }
        $isAct = ($activeNum -eq $num)
        Write-Host ("  {0}: {1}{2}" -f $num, $p.Value.email, (if ($isAct) { " (active)" } else { "" })) `
            -ForegroundColor (if ($isAct) { "Green" } else { "White" })
    }
}

# ---------------------------------------------------------------------------
# cmd_switch  (rotate)
# ---------------------------------------------------------------------------
function Invoke-Switch {
    if (-not (Test-Path $SEQUENCE_FILE)) { Write-CSWError "No accounts are managed yet."; exit 1 }
    $currentEmail = Get-CurrentAccount
    if ($currentEmail -eq "none") { Write-CSWError "No active Claude account found."; exit 1 }

    if (-not (Test-AccountExists $currentEmail)) {
        Write-CSWWarn "Active account '$currentEmail' is not managed. Adding automatically..."
        Invoke-AddAccount
        Write-CSWInfo "Please run 'csw switch' again to switch to the next account."
        exit 0
    }

    $nextNum = Get-NextInSequence
    if ([string]::IsNullOrEmpty($nextNum)) {
        Write-CSWError "No accounts in sequence. Add more with: csw add-account"; exit 1
    }
    Invoke-PerformSwitch $nextNum
}

# ---------------------------------------------------------------------------
# cmd_switch_to
# ---------------------------------------------------------------------------
function Invoke-SwitchTo {
    param([string]$Identifier)
    if ([string]::IsNullOrEmpty($Identifier)) {
        Write-CSWError "Usage: csw switch-to <account_number|email>"; exit 1
    }
    if (-not (Test-Path $SEQUENCE_FILE)) { Write-CSWError "No accounts are managed yet."; exit 1 }
    $acct = Resolve-AccountIdentifier $Identifier
    if ($null -eq $acct) { Write-CSWError "No account found for '$Identifier'. Run: csw list"; exit 1 }
    Invoke-PerformSwitch $acct.Number
}

# ---------------------------------------------------------------------------
# cmd_remove_account
# ---------------------------------------------------------------------------
function Invoke-RemoveAccount {
    param([string]$Identifier)
    if ([string]::IsNullOrEmpty($Identifier)) {
        Write-CSWError "Usage: csw remove-account <account_number|email>"; exit 1
    }
    if (-not (Test-Path $SEQUENCE_FILE)) { Write-CSWError "No accounts are managed yet."; exit 1 }
    $acct = Resolve-AccountIdentifier $Identifier
    if ($null -eq $acct) { Write-CSWError "No account found for '$Identifier'."; exit 1 }

    $num = $acct.Number; $email = $acct.Email
    $seq = Get-SequenceData
    if ("$($seq.activeAccountNumber)" -eq $num) { Write-CSWWarn "Account-$num ($email) is currently active." }

    $ans = Read-Host "Are you sure you want to permanently remove Account-$num (${email})? [y/N]"
    if ($ans -ne "y" -and $ans -ne "Y") { Write-CSWWarn "Cancelled."; return }

    Remove-AccountCredentials $num $email
    Remove-AccountConfig      $num $email
    $seq.accounts.PSObject.Properties.Remove($num)
    $seq | Add-Member -MemberType NoteProperty -Name "sequence" `
        -Value @($seq.sequence | Where-Object { "$_" -ne $num }) -Force
    if ("$($seq.activeAccountNumber)" -eq $num) { $seq.activeAccountNumber = $null }
    Save-SequenceData $seq
    Write-CSWSuccess "Account-$num ($email) has been removed."
}

# ---------------------------------------------------------------------------
# cmd_log
# ---------------------------------------------------------------------------
function Invoke-Log {
    if (-not (Test-Path $LOG_FILE) -or [string]::IsNullOrWhiteSpace((Get-Content $LOG_FILE -Raw))) {
        Write-CSWInfo "No logs found. Logs are created when token refresh runs during switch."; return
    }
    Write-CSWTitle "Token Refresh Status (last switch):"
    Write-Host ""
    if (Test-Path $SEQUENCE_FILE) {
        $seq = Get-SequenceData
        if ($null -ne $seq) {
            foreach ($n in @($seq.sequence)) {
                $num = "$n"
                $p   = $seq.accounts.PSObject.Properties | Where-Object { $_.Name -eq $num }
                if ($null -eq $p) { continue }
                $e    = $p.Value.email
                $last = Get-Content $LOG_FILE | Where-Object { $_ -like "*Account-${num} (${e})*" } | Select-Object -Last 1
                $msg  = if ($last) { $last } else { "Account-${num} (${e}): Pending (background refresh may still be running)." }
                Write-Host "  $msg" -ForegroundColor DarkGray
            }
            Write-Host ""
        }
    }
    Write-CSWTitle "Log Entries:"
    Get-Content $LOG_FILE | ForEach-Object { Write-Host $_ }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# cmd_check_update
# ---------------------------------------------------------------------------
function Invoke-CheckUpdate {
    Write-CSWStep "Checking for updates..."
    try {
        $rel    = Invoke-RestMethod -Uri "https://api.github.com/repos/$CSW_REPO/releases/latest" -TimeoutSec 10 -ErrorAction Stop
        $latest = $rel.tag_name -replace '^v',''
        if ([string]::IsNullOrEmpty($latest)) {
            Write-CSWWarn "No GitHub releases found for $CSW_REPO."
            Write-CSWInfo "You can still update with: csw -update"; return
        }
        if ((Compare-SemVer $latest $CSW_VERSION) -gt 0) {
            Write-CSWWarn "Update available: $CSW_VERSION -> $latest"
            Write-CSWInfo "Run: csw -update"
        } else { Write-CSWSuccess "You are up to date: $CSW_VERSION" }
    } catch { Write-CSWError "Could not check for updates: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# cmd_update
# ---------------------------------------------------------------------------
function Install-FromTarball {
    param([string]$TarUrl, [string]$InstallDir)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "csw_upd_$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $tarFile = Join-Path $tmp "repo.tar.gz"
        Write-CSWStep "Downloading..."
        Invoke-WebRequest -Uri $TarUrl -OutFile $tarFile -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
        Write-CSWStep "Extracting..."
        $p = Start-Process "tar" -ArgumentList @("-xzf", $tarFile, "-C", $tmp) -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -ne 0) { throw "tar failed (exit $($p.ExitCode))" }
        $repoDir = Get-ChildItem $tmp -Directory | Where-Object { $_.Name -like "csw-*" } | Select-Object -First 1
        if ($null -eq $repoDir) { throw "Could not find extracted repo directory" }
        Copy-Item (Join-Path $repoDir.FullName "ccswitch-windows.ps1") (Join-Path $InstallDir "ccswitch-windows.ps1") -Force
        Write-CSWSuccess "Updated: $(Join-Path $InstallDir 'ccswitch-windows.ps1')"
        Write-CSWSuccess "Done."
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Update {
    $installDir = Split-Path -Parent $PSCommandPath
    Write-CSWStep "Checking for latest release..."
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$CSW_REPO/releases/latest" -TimeoutSec 10 -ErrorAction Stop
        $tag = $rel.tag_name
        if (-not [string]::IsNullOrEmpty($tag)) {
            $latest = $tag -replace '^v',''
            if ((Compare-SemVer $latest $CSW_VERSION) -gt 0) {
                Write-CSWStep "Updating to release $tag..."
            } else { Write-CSWStep "Reinstalling latest release $tag..." }
            Install-FromTarball "https://codeload.github.com/$CSW_REPO/tar.gz/$tag" $installDir
            return
        }
    } catch {}
    Write-CSWWarn "No GitHub releases found. Updating from branch '$CSW_DEFAULT_BRANCH'..."
    Install-FromTarball "https://codeload.github.com/$CSW_REPO/tar.gz/refs/heads/$CSW_DEFAULT_BRANCH" $installDir
}

# ---------------------------------------------------------------------------
# show_usage
# ---------------------------------------------------------------------------
function Show-Usage {
    Write-CSWTitle "csw — Multi-Account Switcher for Claude Code (Windows)"
    Write-Host "  Non-destructive: only switches authentication; themes/settings stay intact." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Usage: csw <command> [args]" -ForegroundColor White
    Write-Host ""
    Write-CSWTitle "Commands:"
    @(
        @("  add-account",              "Add the currently logged-in Claude Code account"),
        @("  list | ls",                "List all managed accounts"),
        @("  switch | next",            "Rotate to the next account in sequence"),
        @("  switch-to <n|email>",      "Switch to a specific account by number or email"),
        @("  remove-account <n|email>", "Remove a managed account (with confirmation)"),
        @("  log",                      "Show OAuth token refresh logs from last switch"),
        @("  -check-update",            "Check for a newer version on GitHub"),
        @("  -update",                  "Update csw to the latest version"),
        @("  -v | -version",            "Show current csw version"),
        @("  -help",                    "Show this help")
    ) | ForEach-Object { Write-Host ("{0,-32} {1}" -f $_[0], $_[1]) -ForegroundColor DarkGray }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
$cmd  = if ($args.Count -gt 0) { "$($args[0])" } else { "" }
$arg1 = if ($args.Count -gt 1) { "$($args[1])" } else { "" }

switch ($cmd) {
    { $_ -in @("add-account","--add-account") }                              { Invoke-AddAccount }
    { $_ -in @("list","ls","--list","--ls") }                                { Invoke-List }
    { $_ -in @("switch","next","--switch") }                                 { Invoke-Switch }
    { $_ -in @("switch-to","--switch-to","to") }                             { Invoke-SwitchTo $arg1 }
    { $_ -in @("remove-account","rm-account","--remove-account","--rm-account") } { Invoke-RemoveAccount $arg1 }
    { $_ -in @("log","--log") }                                              { Invoke-Log }
    { $_ -in @("-check-update","--check-update","check-update") }            { Invoke-CheckUpdate }
    { $_ -in @("-update","--update","update") }                              { Invoke-Update }
    { $_ -in @("-v","-version","--version","version") }                      { Write-CSWSuccess "csw version $CSW_VERSION (Windows)" }
    { $_ -in @("-help","--help","help","-h") }                               { Show-Usage }
    ""                                                                        { Show-Usage }
    default { Write-CSWError "Unknown command: $cmd"; Show-Usage; exit 1 }
}
