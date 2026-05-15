# ============================================================
# JumpRelay.ps1 - Jump Server Clipboard Monitor
# ============================================================
# Monitors test/Victor/Temp for file changes.
# New/updated files -> clipboard (text for ClipContent.txt, files for others).
# Usage: powershell -File JumpRelay.ps1 [-CleanupMax N] [-SyncBack]
# ============================================================

param(
    [int]$CleanupMax = 0,    # 0 = no cleanup, >0 = keep max N files
    [switch]$SyncBack      # Enable reverse sync (clipboard -> Temp). Default: OFF
)

$MONITOR_PATH = "C:\FTP\test\Victor\Temp"
$MAX_FILES = 10
$CLIP_TEXT_FILE = "ClipContent.txt"
$WATCH_INTERVAL_MS = 1000

Add-Type -AssemblyName System.Windows.Forms

$lastSnapshot = @{}
$script:IS_PROGRAM = $false

function Write-Log {
    param([string]$Msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg"
}

function Set-ClipboardFile {
    param([string]$Path)
    $script:IS_PROGRAM = $true
    try {
        $coll = New-Object System.Collections.Specialized.StringCollection
        $coll.Add($Path) | Out-Null
        [System.Windows.Forms.Clipboard]::SetFileDropList($coll)
    } finally { $script:IS_PROGRAM = $false }
}

function Set-ClipboardText {
    param([string]$Text)
    $script:IS_PROGRAM = $true
    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
    } finally { $script:IS_PROGRAM = $false }
}

function Cleanup-OldFiles {
    if ($CleanupMax -le 0) { return }   # disabled by default
    if (-not (Test-Path $MONITOR_PATH)) { return }
    $files = Get-ChildItem $MONITOR_PATH -File | Sort-Object LastWriteTime -Descending
    if ($files.Count -gt $CleanupMax) {
        $toDelete = $files[$CleanupMax..($files.Count - 1)]
        foreach ($f in $toDelete) {
            Remove-Item $f.FullName -Force
            Write-Log "Cleaned: $($f.Name)"
        }
    }
}

function Sync-FolderToClipboard {
    if (-not (Test-Path $MONITOR_PATH)) { return }
    
    $current = @{}
    Get-ChildItem $MONITOR_PATH -File | ForEach-Object {
        $current[$_.Name] = $_.LastWriteTime.Ticks
    }
    
    foreach ($name in $current.Keys) {
        $changed = (-not $lastSnapshot.ContainsKey($name)) -or ($lastSnapshot[$name] -ne $current[$name])
        if ($changed) {
            $fullPath = Join-Path $MONITOR_PATH $name
            
            if ($name -eq $CLIP_TEXT_FILE) {
                $text = Get-Content $fullPath -Raw -Encoding UTF8
                Write-Log "Clipboard <- Text: $name ($($text.Length) chars)"
                Set-ClipboardText $text
            } else {
                Write-Log "Clipboard <- File: $name"
                Set-ClipboardFile $fullPath
            }
            break
        }
    }
    $script:lastSnapshot = $current
}

# ── 剪贴板 → Temp 文件夹（用户操作）──
$lastUserClipText = ""
$lastUserClipFiles = ""

function Sync-ClipboardToFolder {
    # 文本
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $text = [System.Windows.Forms.Clipboard]::GetText()
        if ($text -ne $lastUserClipText -and $text.Length -gt 0) {
            $script:lastUserClipText = $text
            $outFile = Join-Path $MONITOR_PATH $CLIP_TEXT_FILE
            [System.IO.File]::WriteAllText($outFile, $text, [System.Text.Encoding]::UTF8)
            Write-Log "User text -> $CLIP_TEXT_FILE ($($text.Length) chars)"
        }
        return
    }
    # 文件
    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
        $hash = ($files -join "|")
        if ($hash -ne $lastUserClipFiles) {
            $script:lastUserClipFiles = $hash
            foreach ($src in $files) {
                if (Test-Path $src) {
                    $name = Split-Path $src -Leaf
                    $dest = Join-Path $MONITOR_PATH $name
                    Copy-Item $src $dest -Force
                    Write-Log "User file -> $name"
                }
            }
        }
    }
}

# Init
if (-not (Test-Path $MONITOR_PATH)) {
    New-Item -ItemType Directory -Path $MONITOR_PATH -Force | Out-Null
}

Write-Log "JumpRelay started"
Write-Log "Monitor: $MONITOR_PATH  Max files: $MAX_FILES  SyncBack: $SyncBack"

while ($true) {
    Sync-FolderToClipboard
    if ($SyncBack -and (-not $script:IS_PROGRAM)) {
        Sync-ClipboardToFolder
    }
    Cleanup-OldFiles
    Start-Sleep -Milliseconds $WATCH_INTERVAL_MS
}
