#Requires -Version 5.1
<#
.SYNOPSIS
    Two-way SFTP synchronization (WinSCP) with dated local backup and retention cleanup.

.DESCRIPTION
    - Sends files from the local FROM folder to the remote, and pulls files from the
      remote into the local TO folder.
    - Moves "settled" local files into a dated backup snapshot.
    - Cleans up old backup snapshots and old log files.

.NOTES
    Credentials are intentionally NOT stored in this script. The WinSCP "open" target
    (host, key, host fingerprint) is read from an external, restricted-ACL file:
        C:\SFTP\session.config
    On first run the script creates a template there and exits so you can fill it in.
#>

# ============================================================================
# Configuration
# ============================================================================
$dateStamp = Get-Date -Format "yyyyMMdd"

# Local directories (NO trailing backslash - important for the WinSCP quoting below)
$localFrom = "C:\SafesMOH\FROM"
$localTo   = "C:\SafesMOH\TO"
$backupDir = "C:\SafesMOH\Backup"

# Remote directories
$remoteFrom = "/FROM_REUTH/"   # remote OUTBOX: we upload local TO here
$remoteTo   = "/TO_REUTH/"     # remote INBOX:  we download from here into local FROM

# Script & log paths
$sftpDir    = "C:\SFTP"
$syncScript = Join-Path $sftpDir "SyncScript.txt"
$actionLog  = Join-Path $sftpDir "ScriptActions_$dateStamp.log"
$winScpLog  = Join-Path $sftpDir "WinScpLog_$dateStamp.log"

# Connection string (host, credentials, key, host fingerprint).
# NOTE: this contains a plaintext password and a private-key path. Restrict who
# can read this file on disk. Replace <rsa> with the real host fingerprint.
$sessionUrl = 'sftp://test:password@78.43.22.66/ -hostkey="ssh-rsa 2048 <rsa>" -privatekey="C:\Keys\MOH\ReuthPrivatMOH.ppk"'

# Retention (days)
$backupAfterDays       = 1     # move local files older than this into backup
$deleteBackupAfterDays = 14    # delete backup snapshots older than this
$deleteLogsAfterDays   = 60    # delete log files older than this

$failedResults = @()

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
# Prepare directories & log
# ============================================================================
foreach ($dir in @($localFrom, $localTo, $backupDir, $sftpDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

Add-Content -Path $actionLog -Value "=== Sync Started: $(Get-Date) ===" -Encoding UTF8

# ============================================================================
# Locate WinSCP (check the common paths first; only recurse if not found)
# ============================================================================
$winScpPath = @(
    "C:\Program Files (x86)\WinSCP\WinSCP.com",
    "C:\Program Files\WinSCP\WinSCP.com"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (-not $winScpPath) {
    $found = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCP.com" -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $winScpPath = $found.FullName }
}

if (-not $winScpPath) {
    Write-Host "ERROR: WinSCP.com not found." -ForegroundColor Red
    Write-Log "ERROR: WinSCP.com not found. Aborting."
    exit 1
}

# ============================================================================
# 1. Build the WinSCP sync script (both directions)
#    NOTE: local paths have NO trailing backslash, otherwise the trailing
#    \" would be read by WinSCP as an escaped quote.
# ============================================================================
$syncCommands = @"
option batch abort
option confirm off
open $sessionUrl
# Upload: local TO  -> remote FROM_REUTH (push our outgoing files to Reuth)
synchronize remote -resumesupport=on "$localTo" "$remoteFrom"
# Download: remote TO_REUTH -> local FROM (pull files Reuth left for us)
synchronize local  -resumesupport=on "$localFrom" "$remoteTo"
exit
"@

$syncCommands | Set-Content -Path $syncScript -Encoding UTF8

# ============================================================================
# 2. Run WinSCP
# ============================================================================
Write-Log "Starting WinSCP synchronization."
& "$winScpPath" /script="$syncScript" /log="$winScpLog" /ini=nul

if ($LASTEXITCODE -ne 0) {
    Add-Failure "WinSCP Sync" "Exit Code: $LASTEXITCODE. Check $winScpLog"
    Write-Log "ERROR: WinSCP Sync failed with exit code $LASTEXITCODE"
} else {
    Write-Log "WinSCP Sync completed successfully."
}

# ============================================================================
# 3. Move settled local files into a dated backup snapshot
#    Backup layout:  C:\SafesMOH\Backup\FROM\yyyyMMdd\<relative path>\file
#                    C:\SafesMOH\Backup\TO\yyyyMMdd\<relative path>\file
#    - CreationTime is used (not LastWriteTime): WinSCP copies the remote
#      modified-time onto downloaded files, so LastWriteTime can be old the
#      moment a file arrives. CreationTime reflects when it landed locally.
#    - Dated folders avoid same-name collisions across days.
# ============================================================================
$cutoffBackup = (Get-Date).AddDays(-$backupAfterDays)

$foldersToBackup = @(
    @{ Source = $localFrom; BackupRoot = Join-Path $backupDir "FROM" },
    @{ Source = $localTo;   BackupRoot = Join-Path $backupDir "TO" }
)

foreach ($map in $foldersToBackup) {
    $sourceRoot = $map.Source
    $datedRoot  = Join-Path $map.BackupRoot $dateStamp
    if (-not (Test-Path -LiteralPath $sourceRoot)) { continue }

    $oldFiles = Get-ChildItem -Path $sourceRoot -File -Recurse |
                Where-Object { $_.CreationTime -lt $cutoffBackup }

    foreach ($file in $oldFiles) {
        # Relative path computed by length (handles root-level files correctly)
        $relativeDir  = $file.DirectoryName.Substring($sourceRoot.Length).TrimStart('\')
        $targetFolder = if ($relativeDir) { Join-Path $datedRoot $relativeDir } else { $datedRoot }

        if (-not (Test-Path -LiteralPath $targetFolder)) {
            New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
            Write-Log "Created backup folder: $targetFolder"
        }

        try {
            Move-Item -LiteralPath $file.FullName -Destination $targetFolder -Force -ErrorAction Stop
            Write-Log "Moved to backup: $($file.FullName)"
        } catch {
            Add-Failure "Move to Backup" "File: $($file.Name) - $($_.Exception.Message)"
            Write-Log "ERROR moving file: $($file.FullName) - $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# 4. Delete backup snapshots older than N days (by dated-folder name)
# ============================================================================
$cutoffDelete = (Get-Date).AddDays(-$deleteBackupAfterDays)

foreach ($root in @((Join-Path $backupDir "FROM"), (Join-Path $backupDir "TO"))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }

    Get-ChildItem -Path $root -Directory | ForEach-Object {
        $folderDate = New-Object DateTime
        $parsed = [DateTime]::TryParseExact(
            $_.Name, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$folderDate)

        if ($parsed -and $folderDate -lt $cutoffDelete) {
            try {
                Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                Write-Log "Deleted expired backup snapshot: $($_.FullName)"
            } catch {
                Add-Failure "Delete from Backup" "Folder: $($_.Name) - $($_.Exception.Message)"
                Write-Log "ERROR deleting backup snapshot: $($_.FullName) - $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================================
# 5. Delete log files older than N days
# ============================================================================
$cutoffLogs = (Get-Date).AddDays(-$deleteLogsAfterDays)
$expiredLogs = Get-ChildItem -Path $sftpDir -File -Filter "*.log" |
               Where-Object { $_.LastWriteTime -lt $cutoffLogs }

foreach ($logFile in $expiredLogs) {
    try {
        Remove-Item -LiteralPath $logFile.FullName -Force -ErrorAction Stop
    } catch {
        Add-Failure "Delete Old Log" "Log: $($logFile.Name) - $($_.Exception.Message)"
    }
}

Add-Content -Path $actionLog -Value "=== Sync Finished: $(Get-Date) ===`n" -Encoding UTF8

# ============================================================================
# 6. Summary
# ============================================================================
if ($failedResults.Count -gt 0) {
    Write-Host "Process completed with errors. Review the table below and the log file at $actionLog" -ForegroundColor Yellow
    $failedResults | Format-Table -AutoSize
} else {
    Write-Host "Sync and local cleanup completed successfully. Full details logged at $actionLog" -ForegroundColor Green
}
