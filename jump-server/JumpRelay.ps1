# ============================================================
# JumpRelay.ps1 - Jump Server Clipboard ↔ Victor Folder
# ============================================================

param([switch]$SyncBack)

$MONITOR_PATH = "C:\FTP\test\Victor"
$CLIP_TEXT_FILE = "ClipContent.txt"
$WATCH_INTERVAL_MS = 1000

Add-Type -AssemblyName System.Windows.Forms

$lastSnapshot       = @{}   # {filename: ticks}
$lastPushedText     = ""    # 上次推送到剪贴板的文本
$lastPushedFile     = ""    # 上次推送到剪贴板的文件路径
$script:IS_PROGRAM  = $false

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" }

function Push-ClipboardFile {
    param([string]$Path)
    $script:IS_PROGRAM = $true
    try {
        $coll = New-Object System.Collections.Specialized.StringCollection
        $coll.Add($Path) | Out-Null
        [System.Windows.Forms.Clipboard]::SetFileDropList($coll)
    } finally { $script:IS_PROGRAM = $false }
}

function Push-ClipboardText {
    param([string]$Text)
    $script:IS_PROGRAM = $true
    try { [System.Windows.Forms.Clipboard]::SetText($Text) }
    finally { $script:IS_PROGRAM = $false }
}

# ── Victor 文件夹 → 剪贴板 ──
function Sync-FolderToClipboard {
    if (-not (Test-Path $MONITOR_PATH)) { return }
    $current = @{}
    Get-ChildItem $MONITOR_PATH -File | ForEach-Object { $current[$_.Name] = $_.LastWriteTime.Ticks }
    foreach ($name in $current.Keys) {
        $changed = (-not $lastSnapshot.ContainsKey($name)) -or ($lastSnapshot[$name] -ne $current[$name])
        if ($changed) {
            $fullPath = Join-Path $MONITOR_PATH $name
            if ($name -eq $CLIP_TEXT_FILE) {
                $text = Get-Content $fullPath -Raw -Encoding UTF8
                Write-Log "Folder -> Clipboard: $name ($($text.Length) chars)"
                $script:lastPushedText = $text
                Push-ClipboardText $text
            } else {
                Write-Log "Folder -> Clipboard: $name"
                $script:lastPushedFile = $fullPath
                Push-ClipboardFile $fullPath
            }
            break
        }
    }
    $script:lastSnapshot = $current
}

# ── 剪贴板 → Victor 文件夹 ──
function Sync-ClipboardToFolder {
    # 文件
    if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
        $first  = if ($files.Count -gt 0) { $files[0] } else { "" }
        # 跳过自己刚推送的文件
        if ($first -eq $script:lastPushedFile) { return }
        Write-Log "Pulled file: $first"
        foreach ($src in $files) {
            if (Test-Path $src) {
                $name = Split-Path $src -Leaf
                $dest = Join-Path $MONITOR_PATH $name
                Copy-Item $src $dest -Force
                Write-Log "User file -> $name (overwrite)"
            }
        }
        return
    }
    # 文本
    if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $text = [System.Windows.Forms.Clipboard]::GetText()
        if ($text.Length -eq 0) { return }
        # 跳过自己刚推送的文本
        if ($text -eq $script:lastPushedText) { return }
        Write-Log "Pulled text ($($text.Length) chars)"
        $outFile = Join-Path $MONITOR_PATH $CLIP_TEXT_FILE
        [System.IO.File]::WriteAllText($outFile, $text, [System.Text.Encoding]::UTF8)
        Write-Log "User text -> $CLIP_TEXT_FILE"
    }
}

# Init
if (-not (Test-Path $MONITOR_PATH)) { New-Item -ItemType Directory -Path $MONITOR_PATH -Force | Out-Null }

Write-Log "JumpRelay started — Monitor: $MONITOR_PATH  SyncBack: $SyncBack"

while ($true) {
    Sync-FolderToClipboard
    if ($SyncBack -and (-not $script:IS_PROGRAM)) {
        Sync-ClipboardToFolder
    }
    Start-Sleep -Milliseconds $WATCH_INTERVAL_MS
}
