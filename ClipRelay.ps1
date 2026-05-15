# ============================================================
# ClipRelay.ps1 — 本地↔跳板机 剪贴板共享
# ============================================================
# 功能：
#   1. 监控本地文件夹 → 有文件新增/更新 → 复制到剪贴板
#   2. 监控剪贴板变化（用户操作） → 上传到跳板机文件夹
#   3. 剪贴板文本 → ClipContent.txt
#   4. 剪贴板文件 → 直接传送到对方监控文件夹
#
# 运行方式：
#   本地:  powershell -File ClipRelay.ps1 -Mode local
#   跳板机: powershell -File ClipRelay.ps1 -Mode jump
#
# 依赖：Windows 系统（使用 .NET Framework）
# ============================================================

param(
    [ValidateSet("local", "jump")]
    [string]$Mode = "local"     # local=本地模式  jump=跳板机模式
)

# ============================================================
# 配置区 — 请根据实际环境修改
# ============================================================

# --- 跳板机 SFTP 连接 ---
$REMOTE_IP       = "你的跳板机IP"          # 跳板机 IP
$REMOTE_PORT     = "10032"                # SFTP 端口
$CREDENTIALS     = "用户名:密码"        # 用户名:密码

# --- 监控文件夹 ---
$MINITOR_LOCAL_PATH = "D:\work\Clip\$(Get-Date -Format 'yyyyMMdd')"   # 本地监控文件夹（按日期）
$MINITOR_JUMP_PATH  = "C:\FTP\test\Victor\Temp"                       # 跳板机监控文件夹

# --- 可执行文件路径 ---
$LFTP_EXE        = Join-Path $PSScriptRoot "lftp\bin\lftp.exe"       # lftp 路径
$TEMP_DIR        = Join-Path $PSScriptRoot "temp"                     # 临时文件目录
$CLIP_TEXT_FILE  = "ClipContent.txt"                                  # 剪贴板文本文件名
$STATE_FILE      = Join-Path $TEMP_DIR "cliprelay_state.json"        # 状态文件（防递归）

# --- 轮询间隔（毫秒） ---
$WATCH_INTERVAL_MS = 1000    # 文件夹检查间隔
$CLIP_INTERVAL_MS  = 500     # 剪贴板检查间隔

# ============================================================
# 初始化
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 创建必要目录
$dirs = @($TEMP_DIR)
if ($Mode -eq "local") {
    if (-not (Test-Path $MINITOR_LOCAL_PATH)) {
        New-Item -ItemType Directory -Path $MINITOR_LOCAL_PATH -Force | Out-Null
    }
    $MONITOR_PATH = $MINITOR_LOCAL_PATH
} else {
    if (-not (Test-Path $MINITOR_JUMP_PATH)) {
        New-Item -ItemType Directory -Path $MINITOR_JUMP_PATH -Force | Out-Null
    }
    $MONITOR_PATH = $MINITOR_JUMP_PATH
}

# 状态管理 — 用于区分"程序触发"与"用户操作"
$IS_PROGRAM_CLIPBOARD = $false  # 程序正在修改剪贴板的标记

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message"
}

# ============================================================
# 剪贴板操作
# ============================================================

# 获取剪贴板内容（返回 Hashtable: Type=Text|File|Image|Empty, Content=文本|文件路径数组）
function Get-ClipboardContent {
    try {
        # 检查文件
        if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $files = [System.Windows.Forms.Clipboard]::GetFileDropList()
            return @{ Type = "File"; Content = @($files) }
        }
        # 检查文本
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $text = [System.Windows.Forms.Clipboard]::GetText()
            return @{ Type = "Text"; Content = $text }
        }
        # 检查图片
        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
            return @{ Type = "Image"; Content = $null }
        }
    } catch { }
    return @{ Type = "Empty"; Content = $null }
}

# 设置剪贴板文本
function Set-ClipboardText {
    param([string]$Text)
    $IS_PROGRAM_CLIPBOARD = $true
    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Write-Log "程序写入剪贴板文本 (${Text.Length} chars)"
    } finally {
        $IS_PROGRAM_CLIPBOARD = $false
    }
}

# 设置剪贴板文件
function Set-ClipboardFiles {
    param([string[]]$Files)
    $IS_PROGRAM_CLIPBOARD = $true
    try {
        $coll = New-Object System.Collections.Specialized.StringCollection
        foreach ($f in $Files) { $coll.Add($f) | Out-Null }
        [System.Windows.Forms.Clipboard]::SetFileDropList($coll)
        Write-Log "程序写入剪贴板文件: $($Files -join ', ')"
    } finally {
        $IS_PROGRAM_CLIPBOARD = $false
    }
}

# ============================================================
# LFTP 文件传输
# ============================================================

function Invoke-LftpUpload {
    param(
        [string]$LocalFile,
        [string]$RemoteFile = ""
    )
    if ($RemoteFile -eq "") {
        $RemoteFile = Split-Path $LocalFile -Leaf
    }
    
    $user, $pass = $CREDENTIALS -split ':', 2
    
    $lftpCmd = @"
set sftp:auto-confirm yes
put "$LocalFile" -o "$RemoteFile"
bye
"@

    try {
        $lftpCmd | & $LFTP_EXE -u "$user,$pass" -p $REMOTE_PORT "sftp://$REMOTE_IP" 2>&1 | Out-Null
        Write-Log "上传成功: $LocalFile → $RemoteFile"
        return $true
    } catch {
        Write-Log "上传失败: $_"
        return $false
    }
}

function Invoke-LftpDownload {
    param(
        [string]$RemoteFile,
        [string]$LocalPath
    )
    $user, $pass = $CREDENTIALS -split ':', 2
    
    if (-not (Test-Path $LocalPath)) {
        New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    }
    
    $lftpCmd = @"
set sftp:auto-confirm yes
get "$RemoteFile" -o "$LocalPath\$RemoteFile"
bye
"@

    try {
        Push-Location $LocalPath
        $lftpCmd | & $LFTP_EXE -u "$user,$pass" -p $REMOTE_PORT "sftp://$REMOTE_IP" 2>&1 | Out-Null
        Pop-Location
        Write-Log "下载成功: $RemoteFile → $LocalPath"
        return $true
    } catch {
        Pop-Location
        Write-Log "下载失败: $_"
        return $false
    }
}

# ============================================================
# 同步逻辑
# ============================================================

# 1. 处理本地文件夹变化 → 复制到剪贴板
$lastFileSnapshot = @{}

function Sync-FolderToClipboard {
    $current = @{}
    if (Test-Path $MONITOR_PATH) {
        Get-ChildItem $MONITOR_PATH -File | ForEach-Object {
            $current[$_.Name] = $_.LastWriteTime.Ticks
        }
    }
    
    # 检查新增/变更
    foreach ($name in $current.Keys) {
        if (-not $lastFileSnapshot.ContainsKey($name) -or $lastFileSnapshot[$name] -ne $current[$name]) {
            $fullPath = Join-Path $MONITOR_PATH $name
            Write-Log "检测到文件变更: $name"
            Set-ClipboardFiles @($fullPath)
            break  # 只同步最新一个文件到剪贴板
        }
    }
    $script:lastFileSnapshot = $current
}

# 2. 处理剪贴板变化 → 上传到跳板机
$lastClipContent = ""
$lastClipFiles = @()

function Sync-ClipboardToRemote {
    $clip = Get-ClipboardContent
    
    if ($clip.Type -eq "File") {
        $currentFiles = $clip.Content -join "|"
        if ($currentFiles -ne ($lastClipFiles -join "|")) {
            $script:lastClipFiles = $clip.Content
            foreach ($file in $clip.Content) {
                if (Test-Path $file) {
                    Invoke-LftpUpload -LocalFile $file
                }
            }
        }
    }
    elseif ($clip.Type -eq "Text") {
        $currentText = $clip.Content
        if ($currentText -ne $lastClipContent -and $currentText.Length -gt 0) {
            $script:lastClipContent = $currentText
            
            # 保存为文本文件并上传
            $tempFile = Join-Path $TEMP_DIR $CLIP_TEXT_FILE
            $currentText | Out-File -FilePath $tempFile -Encoding UTF8 -Force
            Invoke-LftpUpload -LocalFile $tempFile
        }
    }
}

# 3. 从跳板机下载文件到本地监控文件夹
function Sync-RemoteToLocal {
    $user, $pass = $CREDENTIALS -split ':', 2
    
    # 列出跳板机文件夹内容
    $listCmd = @"
set sftp:auto-confirm yes
ls
bye
"@
    try {
        $output = $listCmd | & $LFTP_EXE -u "$user,$pass" -p $REMOTE_PORT "sftp://$REMOTE_IP" 2>&1
        $lines = $output | Where-Object { $_ -match '^\s*\S' -and $_ -notmatch '^\s*$' }
        foreach ($line in $lines) {
            if ($line -match '(\S+)\s*$') {
                $remoteFile = $matches[1]
                if ($remoteFile -ne "." -and $remoteFile -ne "..") {
                    $localTarget = Join-Path $MONITOR_PATH $remoteFile
                    if (-not (Test-Path $localTarget)) {
                        Invoke-LftpDownload -RemoteFile $remoteFile -LocalPath $MONITOR_PATH
                    }
                }
            }
        }
    } catch {
        Write-Log "远程列表失败: $_"
    }
}

# ============================================================
# 主循环
# ============================================================

Write-Log "============================================"
Write-Log "ClipRelay 启动 — 模式: $Mode"
Write-Log "监控路径: $MONITOR_PATH"
Write-Log "跳板机: $REMOTE_IP`:$REMOTE_PORT"
Write-Log "============================================"

$foldCounter = 0
$clipCounter = 0

while ($true) {
    # 文件夹监控（每秒检查）
    if ($foldCounter -ge $WATCH_INTERVAL_MS) {
        Sync-FolderToClipboard
        Sync-RemoteToLocal
        $foldCounter = 0
    }
    
    # 剪贴板监控（每500ms检查）
    if ($clipCounter -ge $CLIP_INTERVAL_MS) {
        if (-not $IS_PROGRAM_CLIPBOARD) {
            Sync-ClipboardToRemote
        }
        $clipCounter = 0
    }
    
    Start-Sleep -Milliseconds 100
    $foldCounter += 100
    $clipCounter += 100
}
