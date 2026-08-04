#Requires -Version 5.1
<#
.SYNOPSIS
    SFTP exchange with Reuth / MOH using file-only operations.

.DESCRIPTION
    Server permissions are limited to: upload files, download files.
    NO directory creation, NO deletion on the server.

    Therefore this script never calls mkdir or rm remotely. It only:
      UPLOAD   local  C:\SafesMOH\TO    ->  remote /FROM_REUTH/   (existing dirs only)
      DOWNLOAD remote /TO_REUTH/        ->  local  C:\SafesMOH\FROM

    Because files are never deleted from the server, a local ledger records what
    has already been downloaded, so archived files are not fetched again.
    Uploaded files are moved into a local Sent archive so they are not re-sent.
#>

# ============================================================================
# Configuration
# ============================================================================
$dateStamp = Get-Date -Format "yyyyMMdd"

# Local directories (no trailing backslash)
$localFrom = "C:\SafesMOH\FROM"     # inbox  - files downloaded from the server
$localTo   = "C:\SafesMOH\TO"       # outbox - files waiting to be uploaded
$backupDir = "C:\SafesMOH\Backup"

# Remote directories
$remoteUploadRoot   = "/FROM_REUTH/"   # we upload here
$remoteDownloadRoot = "/TO_REUTH/"     # we download from here

# Working paths
$sftpDir    = "C:\SFTP"
$actionLog  = Join-Path $sftpDir "ScriptActions_$dateStamp.log"
$ledgerFile = Join-Path $sftpDir "downloaded_ledger.txt"

# Connection details
$hostName   = "78.43.22.66"
$userName   = "test"
$password   = "password"
$sshHostKey = "ssh-rsa 2048 <rsa>"                   # <-- put the REAL fingerprint here
$privateKey = "C:\Keys\MOH\ReuthPrivatMOH.ppk"       # set to $null for password-only auth

# Retention (days)
$deleteBackupAfterDays = 14
$deleteLogsAfterDays   = 60

$failedResults = @()
$warnings      = @()

# ============================================================================
# Helpers
# ============================================================================
function Write-Log {
    param([string]$Message)
    Add-Content -Path $actionLog -Value ("{0} - {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}
function Add-Failure {
    param([string]$Action, [string]$Details)
    $script:failedResults += [PSCustomObject]@{ Action = $Action; Status = "Failed"; Details = $Details }
}

# ============================================================================
# Prepare
# ============================================================================
foreach ($dir in @($localFrom, $localTo, $backupDir, $sftpDir)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
}
Add-Content -Path $actionLog -Value "=== Sync Started: $(Get-Date) ===" -Encoding UTF8

# Load the WinSCP .NET assembly
$dllCandidates = @(
    "C:\Program Files (x86)\WinSCP\WinSCPnet.dll",
    "C:\Program Files\WinSCP\WinSCPnet.dll",
    (Join-Path $sftpDir "WinSCPnet.dll")
)
$dllPath = $dllCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $dllPath) {
    $found = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCPnet.dll" -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $dllPath = $found.FullName }
}
if (-not $dllPath) {
    Write-Host "ERROR: WinSCPnet.dll not found." -ForegroundColor Red
    Write-Host "       Install the WinSCP .NET assembly, or copy WinSCPnet.dll into $sftpDir" -ForegroundColor Red
    Write-Log "ERROR: WinSCPnet.dll not found. Aborting."
    exit 1
}
Add-Type -Path $dllPath
Write-Log "Loaded WinSCP assembly: $dllPath"

# Load ledger of already-downloaded remote files
$ledger = New-Object System.Collections.Generic.HashSet[string]
if (Test-Path -LiteralPath $ledgerFile) {
    Get-Content -LiteralPath $ledgerFile | Where-Object { $_ } | ForEach-Object { [void]$ledger.Add($_.Trim()) }
}
Write-Log "Ledger loaded: $($ledger.Count) entry(ies) previously downloaded."

# ============================================================================
# Session setup
# ============================================================================
$sessionOptions = New-Object WinSCP.SessionOptions -Property @{
    Protocol              = [WinSCP.Protocol]::Sftp
    HostName              = $hostName
    UserName              = $userName
    Password              = $password
    SshHostKeyFingerprint = $sshHostKey
}
if ($privateKey -and (Test-Path -LiteralPath $privateKey)) {
    $sessionOptions.SshPrivateKeyPath = $privateKey
}

# Transfer settings: never try to set remote timestamps.
# Setting mtime requires file ownership, which we do not have.
$transferOptions = New-Object WinSCP.TransferOptions
$transferOptions.TransferMode      = [WinSCP.TransferMode]::Binary
$transferOptions.PreserveTimestamp = $false

$session = New-Object WinSCP.Session
$uploadedFiles = @()

try {
    $session.Open($sessionOptions)
    Write-Log "Connected to $hostName."

    # ------------------------------------------------------------------------
    # 1. UPLOAD: local TO -> remote /FROM_REUTH/  (existing directories only)
    # ------------------------------------------------------------------------
    $pending = @(Get-ChildItem -Path $localTo -File -Recurse -ErrorAction SilentlyContinue)
    Write-Log "Upload queue: $($pending.Count) file(s) in $localTo"

    # Probe each remote directory only once
    $remoteDirCache = @{}

    foreach ($file in $pending) {
        # Build the remote target path, preserving any local subfolder structure
        $relativeDir = $file.DirectoryName.Substring($localTo.Length).TrimStart('\')
        $remoteDir = if ($relativeDir) {
            $remoteUploadRoot.TrimEnd('/') + '/' + ($relativeDir -replace '\\','/') + '/'
        } else {
            $remoteUploadRoot
        }

        # We cannot create directories, so verify the target exists first
        if (-not $remoteDirCache.ContainsKey($remoteDir)) {
            try   { $remoteDirCache[$remoteDir] = $session.FileExists($remoteDir.TrimEnd('/')) }
            catch { $remoteDirCache[$remoteDir] = $false }
        }
        if (-not $remoteDirCache[$remoteDir]) {
            $msg = "Remote folder missing and cannot be created: $remoteDir"
            Write-Log "SKIP: $msg (file: $($file.Name))"
            $warnings += $msg
            continue
        }

        $remotePath = $remoteDir + $file.Name
        try {
            $result = $session.PutFiles($file.FullName, $session.EscapeFileMask($remotePath), $false, $transferOptions)
            if ($result.IsSuccess) {
                Write-Log "UPLOADED: $($file.FullName) -> $remotePath"
                $uploadedFiles += $file
            } else {
                foreach ($f in $result.Failures) {
                    Write-Log "UPLOAD FAILED: $($file.Name) - $($f.Message)"
                    Add-Failure "Upload" "$($file.Name) - $($f.Message)"
                }
            }
        } catch {
            Write-Log "UPLOAD ERROR: $($file.Name) - $($_.Exception.Message)"
            Add-Failure "Upload" "$($file.Name) - $($_.Exception.Message)"
        }
    }

    # ------------------------------------------------------------------------
    # 2. DOWNLOAD: remote /TO_REUTH/ -> local FROM, new files only
    #    The server never deletes, so the ledger decides what counts as new.
    # ------------------------------------------------------------------------
    Write-Log "Enumerating remote $remoteDownloadRoot ..."
    $remoteFiles = $session.EnumerateRemoteFiles(
        $remoteDownloadRoot, $null, [WinSCP.EnumerationOptions]::AllDirectories)

    $newCount = 0
    foreach ($rf in $remoteFiles) {
        if ($rf.IsDirectory) { continue }

        # Key includes size + mtime so a replaced file is fetched again
        $key = "{0}|{1}|{2}" -f $rf.FullName, $rf.Length, $rf.LastWriteTime.ToString("yyyyMMddHHmmss")
        if ($ledger.Contains($key)) { continue }

        # Mirror the remote subfolder structure locally (local mkdir is fine)
        $relative       = $rf.FullName.Substring($remoteDownloadRoot.TrimEnd('/').Length).TrimStart('/')
        $localTarget    = Join-Path $localFrom ($relative -replace '/','\')
        $localTargetDir = Split-Path -Parent $localTarget
        if (-not (Test-Path -LiteralPath $localTargetDir)) {
            New-Item -Path $localTargetDir -ItemType Directory -Force | Out-Null
        }

        try {
            $result = $session.GetFiles($session.EscapeFileMask($rf.FullName), $localTarget, $false, $transferOptions)
            if ($result.IsSuccess) {
                Write-Log "DOWNLOADED: $($rf.FullName) -> $localTarget"
                Add-Content -Path $ledgerFile -Value $key -Encoding UTF8
                [void]$ledger.Add($key)
                $newCount++
            } else {
                foreach ($f in $result.Failures) {
                    Write-Log "DOWNLOAD FAILED: $($rf.FullName) - $($f.Message)"
                    Add-Failure "Download" "$($rf.Name) - $($f.Message)"
                }
            }
        } catch {
            Write-Log "DOWNLOAD ERROR: $($rf.FullName) - $($_.Exception.Message)"
            Add-Failure "Download" "$($rf.Name) - $($_.Exception.Message)"
        }
    }
    Write-Log "Download complete: $newCount new file(s)."

} catch {
    Write-Log "SESSION ERROR: $($_.Exception.Message)"
    Add-Failure "Session" $_.Exception.Message
} finally {
    $session.Dispose()
}

# ============================================================================
# 3. Archive successfully uploaded files so they are not re-sent
# ============================================================================
$sentRoot = Join-Path (Join-Path $backupDir "Sent") $dateStamp
foreach ($file in $uploadedFiles) {
    $relativeDir = $file.DirectoryName.Substring($localTo.Length).TrimStart('\')
    $target = if ($relativeDir) { Join-Path $sentRoot $relativeDir } else { $sentRoot }
    if (-not (Test-Path -LiteralPath $target)) { New-Item -Path $target -ItemType Directory -Force | Out-Null }
    try {
        Move-Item -LiteralPath $file.FullName -Destination $target -Force -ErrorAction Stop
        Write-Log "Archived sent file: $($file.Name)"
    } catch {
        Add-Failure "Archive Sent" "$($file.Name) - $($_.Exception.Message)"
    }
}

# ============================================================================
# 4. Retention: delete old local archive snapshots and old logs
# ============================================================================
$cutoffBackup = (Get-Date).AddDays(-$deleteBackupAfterDays)
$sentParent = Join-Path $backupDir "Sent"
if (Test-Path -LiteralPath $sentParent) {
    Get-ChildItem -Path $sentParent -Directory | ForEach-Object {
        $d  = New-Object DateTime
        $ok = [DateTime]::TryParseExact($_.Name, 'yyyyMMdd',
              [System.Globalization.CultureInfo]::InvariantCulture,
              [System.Globalization.DateTimeStyles]::None, [ref]$d)
        if ($ok -and $d -lt $cutoffBackup) {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Log "Deleted expired archive: $($_.FullName)"
            } catch {
                Add-Failure "Delete Archive" "$($_.Name) - $($_.Exception.Message)"
            }
        }
    }
}

$cutoffLogs = (Get-Date).AddDays(-$deleteLogsAfterDays)
Get-ChildItem -Path $sftpDir -File -Filter "*.log" |
    Where-Object { $_.LastWriteTime -lt $cutoffLogs } |
    ForEach-Object {
        try   { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
        catch { Add-Failure "Delete Old Log" "$($_.Name) - $($_.Exception.Message)" }
    }

Add-Content -Path $actionLog -Value "=== Sync Finished: $(Get-Date) ===`n" -Encoding UTF8

# ============================================================================
# 5. Summary
# ============================================================================
if ($warnings.Count -gt 0) {
    Write-Host "Warnings (non-fatal):" -ForegroundColor Yellow
    $warnings | Select-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($failedResults.Count -gt 0) {
    Write-Host "Completed with errors. See $actionLog" -ForegroundColor Red
    $failedResults | Format-Table -AutoSize
} else {
    Write-Host "Completed. Uploaded $($uploadedFiles.Count) file(s). Details in $actionLog" -ForegroundColor Green
}
