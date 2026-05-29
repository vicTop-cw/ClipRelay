# ============================================================
# SyncFolder.ps1 — 持续监测 + 轮询兜底
# 运行: powershell -File SyncFolder.ps1
# ============================================================

$SOURCE      = "\\allonas.allobank.local\bdap_data\bdap\nabops_victorchen\Share"
$DESTINATION = "\\tsclient\C\FTP\test\Victor"

function Write-Log { param([string]$Msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" }

# ── 记录文件状态：{完整路径: LastWriteTime} ──
$fileState = @{}

# ── 扫描并同步变更 ──
function Sync-Changes {
    if (-not (Test-Path $SOURCE)) { return }
    
    Get-ChildItem $SOURCE -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $key = $_.FullName
        $ticks = $_.LastWriteTime.Ticks
        
        if (-not $script:fileState.ContainsKey($key)) {
            # 新文件
            $script:fileState[$key] = $ticks
            Copy-File $_.FullName
        } elseif ($script:fileState[$key] -ne $ticks) {
            # 修改过
            $script:fileState[$key] = $ticks
            Copy-File $_.FullName
        }
    }
}

# ── 拷贝 + 解除警告 + 关弹窗 ──
function Copy-File {
    param([string]$Src)
    $name = Split-Path $Src -Leaf
    $dest = Join-Path $DESTINATION $name
    
    Copy-Item -Path $Src -Destination $dest -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 200
    
    # Unblock
    try { Microsoft.PowerShell.Utility\Unblock-File -Path $dest -ErrorAction SilentlyContinue }
    catch { $z = "$dest" + ":Zone.Identifier"; if (Test-Path $z) { Remove-Item $z -Force -ErrorAction SilentlyContinue } }
    
    # Dismiss security dialog
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait("{LEFT}")
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    
    Write-Log "Synced: $name"
}

# ── 初始化（只记录，不同步）──
if (-not (Test-Path $DESTINATION)) { New-Item -ItemType Directory -Path $DESTINATION -Force | Out-Null }
if (-not (Test-Path $SOURCE))      { Write-Log "ERROR: Source not found: $SOURCE"; exit 1 }

Write-Log "Recording initial state..."
Get-ChildItem $SOURCE -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $fileState[$_.FullName] = $_.LastWriteTime.Ticks
}
Write-Log "Recorded $($fileState.Count) files. Watching..."
Write-Log ""

# ── 主循环：每 2 秒轮询一次 ──
while ($true) {
    Sync-Changes
    Start-Sleep -Seconds 2
}
