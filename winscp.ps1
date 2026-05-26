# Get current date string using native PowerShell cmdlet format
$dateStamp = Get-Date -Format "yyyyMMdd"

# Define Variables
$sessionUrl = 'sftp://test:password@78.43.22.66/ -hostkey="ssh-rsa 2048 <rsa>" -privatekey="C:\Keys\MOH\ReuthPrivatMOH.ppk"'

# Local Directories
$localFrom = "C:\SafesMOH\FROM\"
$localTo = "C:\SafesMOH\TO\"
$backupDir = "C:\SafesMOH\Backup\"

# Remote Directories
$remoteFrom = "/FROM_REUTH/"
$remoteTo = "/TO_REUTH/"

# Script & Log Paths (Daily rotation applied)
$sftpDir = "C:\SFTP"
$syncScript = "C:\SFTP\SyncScript.txt"
$actionLog = "C:\SFTP\ScriptActions_$dateStamp.log"
$winScpLog = "C:\SFTP\WinScpLog_$dateStamp.log"
$failedResults = @()

# Ensure base directories exist
foreach ($dir in @($localFrom, $localTo, $backupDir, $sftpDir)) {
    if (-not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

# Add a starting entry to the local log file
Add-Content -Path $actionLog -Value "=== Sync Started: $(Get-Date) ===" -Encoding UTF8

# Locate WinSCP executable dynamically
$winScpSearch = Get-ChildItem -Path "C:\Program Files*" -Filter "WinSCP.com" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($winScpSearch) {
    $winScpPath = $winScpSearch.FullName
} else {
    $winScpPath = "C:\Program Files (x86)\WinSCP\WinSCP.com"
}

# 1. Create the Sync Script for WinSCP (Handling BOTH directions)
$syncCommands = @"
option batch abort
option confirm off
open $sessionUrl
# Send files TO the remote server (FROM local)
synchronize remote -resumesupport=on "$localFrom" "$remoteFrom"
# Receive files FROM the remote server (TO local)
synchronize local -resumesupport=on "$localTo" "$remoteTo"
exit
"@

$syncCommands | Set-Content -Path $syncScript -Encoding UTF8

# 2. Execute WinSCP
Add-Content -Path $actionLog -Value "$(Get-Date) - Starting WinSCP synchronization." -Encoding UTF8
& "$winScpPath" /script="$syncScript" /log="$winScpLog" /ini=nul

if ($LASTEXITCODE -ne 0) {
    $failedResults += [PSCustomObject]@{
        Action = "WinSCP Sync"
        Status = "Failed"
        Details = "Exit Code: $LASTEXITCODE. Check $winScpLog"
    }
    Add-Content -Path $actionLog -Value "$(Get-Date) - ERROR: WinSCP Sync failed with exit code $LASTEXITCODE" -Encoding UTF8
} else {
    Add-Content -Path $actionLog -Value "$(Get-Date) - WinSCP Sync completed successfully." -Encoding UTF8
}

# 3. Local File Management: Move files older than 1 day to Backup (Preserving Folders)
$oneDayAgo = (Get-Date) - (New-TimeSpan -Days 1)

# Define an array to map source folders to their respective backup roots
$foldersToBackup = @(
    @{ Source = $localFrom; BackupRoot = Join-Path $backupDir "FROM" },
    @{ Source = $localTo; BackupRoot = Join-Path $backupDir "TO" }
)

foreach ($folderMap in $foldersToBackup) {
    $sourceRoot = $folderMap.Source
    $backupRoot = $folderMap.BackupRoot
    
    # Get only files (leaving folders intact) older than 1 day
    $oldFiles = Get-ChildItem -Path $sourceRoot -File -Recurse | Where-Object { $_.LastWriteTime -lt $oneDayAgo }
    
    foreach ($file in $oldFiles) {
        # Determine the relative path to maintain folder structure using native regex replace
        $relativePath = $file.DirectoryName -replace [regex]::Escape($sourceRoot), ""
        $targetFolder = Join-Path $backupRoot $relativePath
        
        # Ensure the destination subfolder exists in the Backup directory
        if (-not (Test-Path -Path $targetFolder)) {
            New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null
            Add-Content -Path $actionLog -Value "$(Get-Date) - Created backup folder: $targetFolder" -Encoding UTF8
        }
        
        try {
            Move-Item -Path $file.FullName -Destination $targetFolder -Force -ErrorAction Stop
            Add-Content -Path $actionLog -Value "$(Get-Date) - Moved to backup: $($file.FullName)" -Encoding UTF8
        } catch {
            $failedResults += [PSCustomObject]@{
                Action = "Move to Backup"
                Status = "Failed"
                Details = "File: $($file.Name) - $($_.Exception.Message)"
            }
            Add-Content -Path $actionLog -Value "$(Get-Date) - ERROR moving file: $($file.FullName)" -Encoding UTF8
        }
    }
}

# 4. Cleanup: Delete files older than 14 days from Backup (Preserving Folders)
$fourteenDaysAgo = (Get-Date) - (New-TimeSpan -Days 14)

# Target files only, deep inside the backup directory
$expiredBackupFiles = Get-ChildItem -Path $backupDir -File -Recurse | Where-Object { $_.LastWriteTime -lt $fourteenDaysAgo }

foreach ($file in $expiredBackupFiles) {
    try {
        Remove-Item -Path $file.FullName -Force -ErrorAction Stop
        Add-Content -Path $actionLog -Value "$(Get-Date) - Deleted expired backup file: $($file.FullName)" -Encoding UTF8
    } catch {
        $failedResults += [PSCustomObject]@{
            Action = "Delete from Backup"
            Status = "Failed"
            Details = "File: $($file.Name) - $($_.Exception.Message)"
        }
        Add-Content -Path $actionLog -Value "$(Get-Date) - ERROR deleting backup file: $($file.FullName)" -Encoding UTF8
    }
}

# 5. Log Cleanup: Delete log files older than 60 days (2 months)
$sixtyDaysAgo = (Get-Date) - (New-TimeSpan -Days 60)
$expiredLogs = Get-ChildItem -Path $sftpDir -File -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $sixtyDaysAgo }

foreach ($logFile in $expiredLogs) {
    try {
        Remove-Item -Path $logFile.FullName -Force -ErrorAction Stop
    } catch {
        $failedResults += [PSCustomObject]@{
            Action = "Delete Old Log"
            Status = "Failed"
            Details = "Log: $($logFile.Name) - $($_.Exception.Message)"
        }
    }
}

Add-Content -Path $actionLog -Value "=== Sync Finished: $(Get-Date) ===`n" -Encoding UTF8

# 6. Display Summary Table
if ($failedResults.Count -gt 0) {
    Write-Host "Process completed with errors. Review the table below and the log file at $actionLog" -ForegroundColor Yellow
    $failedResults | Format-Table -AutoSize
} else {
    Write-Host "Sync and local cleanup completed successfully. Full details logged at $actionLog" -ForegroundColor Green
}
