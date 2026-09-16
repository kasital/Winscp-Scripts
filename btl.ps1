<#
.SYNOPSIS
    Sync BTL folders with an SFTP server using WinSCP (.NET Assembly)

.DESCRIPTION
    - Uploads files from C:\Safes\BTL\From-BTL to a remote folder, and deletes them
      locally only after a verified successful upload.
    - Downloads files from a remote folder into C:\Safes\BTL\To-BTL.
    - Requires the WinSCPnet.dll assembly to be available (ships with the WinSCP
      installer, or available as a NuGet package).

.NOTES
    Update the variables in the CONFIG block before first run:
      - Server address, port, username and password
      - Remote folder paths (upload/download)
      - Host key fingerprint, for secure first-connection verification
#>

# ======================= CONFIG =======================
$WinSCPAssemblyPath = "C:\Program Files (x86)\WinSCP\WinSCPnet.dll"   # update if installed elsewhere

$SftpHost      = "sftp.example.com"        # SFTP server address / IP
$SftpPort      = 22
$SftpUser      = "USERNAME"
$SftpPassword  = "PASSWORD"                # strongly recommended: move to secure storage (see note at the end)
$HostFingerprint = ""  # REQUIRED: paste the real server fingerprint here (see instructions below), e.g. "ssh-rsa 2048 aa:bb:cc:...:zz"

# How to obtain the fingerprint:
#   1) Open WinSCP GUI and connect to the same server with the same credentials.
#   2) On first connect you'll get a "host key not verified" warning showing the fingerprint - copy it exactly.
#   3) Alternatively, after connecting once, check Session Log (or Server/Protocol Information) for the "Host key fingerprint" line.
#   4) Paste the exact string (protocol + bit length + colon-separated hex) into $HostFingerprint above.
#
# For a one-time bootstrap ONLY (not recommended long-term), you can instead skip fingerprint
# verification entirely by setting $sessionOptions.GiveUpSecurityAndAcceptAnySshHostKey = $true
# right after creating $sessionOptions below - then check the log/console output for the real
# fingerprint and paste it into $HostFingerprint, then remove the GiveUp line.

$RemoteUploadPath   = "/To-BTL/"           # remote folder - upload target: stuff going TO BTL (me -> server)
$RemoteDownloadPath = "/From-BTL/"         # remote folder - download source: stuff coming FROM BTL (server -> me)

$LocalToBTL   = "C:\Safes\BTL\To-BTL"      # LOCAL upload source: files waiting to be sent to BTL; deleted locally after success
$LocalFromBTL = "C:\Safes\BTL\From-BTL"    # LOCAL download destination: files received from BTL

$LogFile = "C:\Safes\BTL\Logs\Sync-BTL-$(Get-Date -Format 'yyyy-MM-dd').log"
# ========================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogFile -Value $line
}

try {
    # Make sure local target folders exist
    foreach ($dir in @($LocalFromBTL, $LocalToBTL)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Log "Created missing local folder: $dir"
        }
    }

    # Load the WinSCP assembly
    Add-Type -Path $WinSCPAssemblyPath
    Write-Log "WinSCP assembly loaded successfully"

    # Connection settings
    $sessionOptions = New-Object WinSCP.SessionOptions -Property @{
        Protocol              = [WinSCP.Protocol]::Sftp
        HostName              = $SftpHost
        PortNumber            = $SftpPort
        UserName              = $SftpUser
        Password              = $SftpPassword
        SshHostKeyFingerprint = $HostFingerprint
    }

    $session = New-Object WinSCP.Session
    try {
        Write-Log "Connecting to $SftpHost..."
        $session.Open($sessionOptions)
        Write-Log "Connection succeeded"

        # ---------- Step 1: Upload files from To-BTL, delete locally after success ----------
        $filesToUpload = Get-ChildItem -Path $LocalToBTL -File
        if ($filesToUpload.Count -eq 0) {
            Write-Log "No files to upload in $LocalToBTL"
        }
        else {
            Write-Log "Found $($filesToUpload.Count) file(s) to upload"

            $transferOptions = New-Object WinSCP.TransferOptions
            $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary

            foreach ($file in $filesToUpload) {
                # Some SFTP servers deny overwriting an existing remote file (Permission denied)
                # but do allow delete + re-create. Remove any stale remote file with the same
                # name first so the upload doesn't fail on a leftover from a previous run.
                $remoteFilePath = $RemoteUploadPath.TrimEnd('/') + '/' + $file.Name
                if ($session.FileExists($remoteFilePath)) {
                    $session.RemoveFiles($remoteFilePath) | Out-Null
                    Write-Log "Removed stale remote file before re-upload: $remoteFilePath"
                }

                # Third parameter (removeFiles = $true) deletes the local source file
                # automatically, and only after a verified successful transfer
                $transferResult = $session.PutFiles(
                    $file.FullName,
                    $RemoteUploadPath,
                    $true,
                    $transferOptions
                )

                $transferResult.Check()  # throws if this transfer failed

                foreach ($upload in $transferResult.Transfers) {
                    Write-Log "Uploaded and removed locally: $($upload.FileName)"
                }
            }
        }

        # ---------- Step 2: Download files from the server into From-BTL ----------
        Write-Log "Synchronizing download from $RemoteDownloadPath to $LocalFromBTL"

        $syncResult = $session.SynchronizeDirectories(
            [WinSCP.SynchronizationMode]::Local,
            $LocalFromBTL,
            $RemoteDownloadPath,
            $false   # do not delete remote-side files that don't exist locally
        )

        $syncResult.Check()

        foreach ($download in $syncResult.Downloads) {
            Write-Log "Downloaded: $($download.FileName)"
        }

        Write-Log "Sync completed successfully" "SUCCESS"
    }
    finally {
        $session.Dispose()
    }
}
catch {
    Write-Log "Error during sync process: $($_.Exception.Message)" "ERROR"
    exit 1
}
