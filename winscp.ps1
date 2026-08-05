#Requires -Version 5.1
<#
.SYNOPSIS
    SFTP exchange with Reuth / MOH via WinSCP.com (URL-based session).

.DESCRIPTION
    Server permissions are limited: upload and download files only.
    NO directory creation, NO deletion, NO rename on the server.

    Directions:
      UPLOAD    local  C:\SafesMOH\toMOH    ->  remote /FROM_REUTH/   (existing dirs only)
      DOWNLOAD  remote /TO_REUTH/           ->  local  C:\SafesMOH\FROMMOH

    Why explicit "put" instead of "synchronize remote":
      synchronize wants to create remote directories, which is denied here.
      "put" only writes files into directories that already exist.

    Why -resumesupport=off:
      WinSCP would upload to "<name>.filepart" and then RENAME it to the final
      name. This server denies rename, so the transfer failed at the last step.

    Why -nopreservetime:
      Setting the remote modification time requires file ownership, which we
      do not have. Attempting it causes the file to be reported as failed.

    Download is a two-phase operation: first "get" retrieves the files, then a
    second pass issues one "rm" per successfully downloaded FILE. Directories
    are never deleted, because rmdir is denied on this server.
#>

# ============================================================================
# Configuration
# ============================================================================
$dateStamp = Get-Date -Format "yyyyMMdd"

# Local directories (no trailing backslash)
$localFrom = "C:\SafesMOH\FROMMOH"   # inbox  - receives from remote /TO_REUTH/
$localTo   = "C:\SafesMOH\toMOH"     # outbox - sends to remote /FROM_REUTH/
$backupDir = "C:\SafesMOH\Backup"

# Remote directories
$remoteUploadRoot   = "/FROM_REUTH/"
$remoteDownloadRoot = "/TO_REUTH/"

# Working paths
$sftpDir    = "C:\SFTP"
$syncScript = Join-Path $sftpDir "SyncScript.txt"
$actionLog  = Join-Path $sftpDir "ScriptActions_$dateStamp.log"
$winScpLog  = Join-Path $sftpDir "WinScpLog_$dateStamp.log"
$winScpXml  = Join-Path $sftpDir "WinScpLog_$dateStamp.xml"

# ---- Connection (the form that is known to work) ---------------------------
# Add :PORT after the host if you use a non-standard port, e.g. @78.43.22.66:2222/
$sessionUrl = 'sftp://REUTH_SFTP:password@78.43.22.66/ -hostkey="ssh-rsa 2048 <rsa>" -privatekey="C:\Keys\MOH\ReuthPrivatMOH.ppk"'

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

# Locate WinSCP.com
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
Write-Log "Using WinSCP: $winScpPath"

# ============================================================================
# 1. Build the command list
# ============================================================================
$pending = @(Get-ChildItem -Path $localTo -File -Recurse -ErrorAction SilentlyContinue)
Write-Log "Upload queue: $($pending.Count) file(s) in $localTo"

$commands = New-Object System.Collections.Generic.List[string]
$commands.Add("option batch continue")   # a denied item is skipped, not fatal
$commands.Add("option confirm off")
$commands.Add("open $sessionUrl")

# ---- Uploads: one explicit put per file, into existing remote folders -------
foreach ($file in $pending) {
    $relativeDir = $file.DirectoryName.Substring($localTo.Length).TrimStart('\')
    $remoteDir = if ($relativeDir) {
        $remoteUploadRoot.TrimEnd('/') + '/' + ($relativeDir -replace '\\','/') + '/'
    } else {
        $remoteUploadRoot
    }
    $commands.Add("put -nopreservetime -resumesupport=off ""$($file.FullName)"" ""$remoteDir""")
    Write-Log "queued upload: $($file.FullName) -> $remoteDir"
}

# ---- Download: retrieve only. Deletion is done afterwards, per FILE, so we
#      never attempt to remove a remote directory (rmdir is denied here).
$commands.Add("option batch continue")
$commands.Add("lcd ""$localFrom""")
$commands.Add("cd ""$($remoteDownloadRoot.TrimEnd('/'))""")
$commands.Add("get -nopreservetime -resumesupport=off *")
$commands.Add("exit")

$commands -join "`r`n" | Set-Content -Path $syncScript -Encoding UTF8

# ============================================================================
# 2. Run WinSCP
# ============================================================================
Write-Log "Starting WinSCP session."
& "$winScpPath" /script="$syncScript" /log="$winScpLog" /xmllog="$winScpXml" /ini=nul
$exitCode = $LASTEXITCODE

switch ($exitCode) {
    0 { Write-Log "WinSCP finished successfully." }
    1 {
        $msg = "WinSCP finished with skipped items (exit code 1). See $winScpXml"
        Write-Log "WARNING: $msg"
        $warnings += $msg
    }
    default {
        Add-Failure "WinSCP" "Exit code: $exitCode. See $winScpLog"
        Write-Log "ERROR: WinSCP failed with exit code $exitCode"
    }
}

# ============================================================================
# 3. Parse the XML log: which uploads actually succeeded?
# ============================================================================
$uploadedPaths = New-Object System.Collections.Generic.HashSet[string]
$downloadedRemotePaths = New-Object System.Collections.Generic.List[string]

if (Test-Path -LiteralPath $winScpXml) {
    try {
        [xml]$xml = Get-Content -LiteralPath $winScpXml -Raw
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace("w", "http://winscp.net/schema/session/1.0")

        foreach ($u in $xml.SelectNodes("//w:upload", $ns)) {
            $src = $u.filename.value
            if ($u.result.success -eq "true") {
                Write-Log "UPLOADED: $src"
                [void]$uploadedPaths.Add($src)
            } else {
                $reason = $u.result.message
                Write-Log "UPLOAD FAILED: $src - $reason"
                Add-Failure "Upload" "$([System.IO.Path]::GetFileName($src)) - $reason"
            }
        }

        $dl = @($xml.SelectNodes("//w:download", $ns))
        Write-Log "Downloads attempted: $($dl.Count)"
        foreach ($d in $dl) {
            if ($d.result.success -eq "true") {
                Write-Log "DOWNLOADED: $($d.filename.value)"
                [void]$downloadedRemotePaths.Add($d.filename.value)
            } else {
                Write-Log "DOWNLOAD FAILED: $($d.filename.value) - $($d.result.message)"
                Add-Failure "Download" "$($d.filename.value) - $($d.result.message)"
            }
        }

        if ($pending.Count -gt 0 -and $uploadedPaths.Count -eq 0) {
            $msg = "$($pending.Count) file(s) were queued but NONE uploaded. See $winScpXml"
            Write-Host $msg -ForegroundColor Red
            Write-Log "WARNING: $msg"
            $warnings += $msg
        }
    } catch {
        Write-Log "Could not parse XML log: $($_.Exception.Message)"
    }
}

# ============================================================================
# 3b. Delete the downloaded FILES on the server (files only, never directories)
# ============================================================================
if ($downloadedRemotePaths.Count -gt 0) {
    Write-Log "Removing $($downloadedRemotePaths.Count) downloaded file(s) from the server."

    $delScript = Join-Path $sftpDir "DeleteScript.txt"
    $delXml    = Join-Path $sftpDir "WinScpDelete_$dateStamp.xml"

    $delCommands = New-Object System.Collections.Generic.List[string]
    $delCommands.Add("option batch continue")
    $delCommands.Add("option confirm off")
    $delCommands.Add("open $sessionUrl")
    foreach ($rp in $downloadedRemotePaths) {
        # One explicit rm per file. Directories are never referenced.
        $delCommands.Add("rm ""$rp""")
    }
    $delCommands.Add("exit")
    $delCommands -join "`r`n" | Set-Content -Path $delScript -Encoding UTF8

    & "$winScpPath" /script="$delScript" /log="$winScpLog" /xmllog="$delXml" /ini=nul
    $delExit = $LASTEXITCODE

    if (Test-Path -LiteralPath $delXml) {
        try {
            [xml]$dxml = Get-Content -LiteralPath $delXml -Raw
            $dns = New-Object System.Xml.XmlNamespaceManager($dxml.NameTable)
            $dns.AddNamespace("w", "http://winscp.net/schema/session/1.0")
            foreach ($r in $dxml.SelectNodes("//w:rm", $dns)) {
                if ($r.result.success -eq "true") {
                    Write-Log "REMOTE DELETED: $($r.filename.value)"
                } else {
                    $m = "Could not delete on server: $($r.filename.value) - $($r.result.message)"
                    Write-Log "WARNING: $m"
                    $warnings += $m
                }
            }
        } catch {
            Write-Log "Could not parse delete XML log: $($_.Exception.Message)"
        }
    } elseif ($delExit -ne 0) {
        $warnings += "Remote cleanup finished with exit code $delExit. See $winScpLog"
    }
}

# ============================================================================
# 4. Move successfully uploaded files to the Sent archive (prevents re-sending)
# ============================================================================
$sentRoot = Join-Path (Join-Path $backupDir "Sent") $dateStamp

foreach ($file in $pending) {
    if (-not $uploadedPaths.Contains($file.FullName)) { continue }

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
# 5. Retention
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
Get-ChildItem -Path $sftpDir -File -Include "*.log","*.xml" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoffLogs } |
    ForEach-Object {
        try   { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop }
        catch { Add-Failure "Delete Old Log" "$($_.Name) - $($_.Exception.Message)" }
    }

Add-Content -Path $actionLog -Value "=== Sync Finished: $(Get-Date) ===`n" -Encoding UTF8

# ============================================================================
# 6. Summary
# ============================================================================
if ($warnings.Count -gt 0) {
    Write-Host "Warnings (non-fatal):" -ForegroundColor Yellow
    $warnings | Select-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if ($failedResults.Count -gt 0) {
    Write-Host "Completed with errors. See $actionLog" -ForegroundColor Red
    $failedResults | Format-Table -AutoSize
} else {
    Write-Host "Completed. Uploaded $($uploadedPaths.Count) file(s). Details in $actionLog" -ForegroundColor Green
}
