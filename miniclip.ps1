# =========================================================
# Script Name: Watch-FileToClipboard.ps1
# Description: Monitors a file for changes and copies its
#              content to the clipboard instantly.
# =========================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$FilePath  # 传入你要监控的文件路径
)

# 确保文件存在
if (-not (Test-Path $FilePath)) {
    Write-Error "File not found: $FilePath"
    exit 1
}

Write-Host "Starting monitor on: $FilePath"
Write-Host "Press Ctrl+C to stop."

# 创建文件系统监视器
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = Split-Path $FilePath -Parent
$watcher.Filter = Split-Path $FilePath -Leaf
$watcher.IncludeSubdirectories = $false

# 只监听“最后写入时间”变化（内容改变一定会触发这个）
$watcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite'

# 定义当文件改变时要执行的动作
$action = {
    # 关键：稍微等待一下，确保文件写入完成（防止读到一半的内容）
    Start-Sleep -Milliseconds 500
    
    $file = $Event.SourceEventArgs.FullPath
    
    if (Test-Path $file) {
        try {
            $content = Get-Content -Path $file -Raw -ErrorAction Stop
            Set-Clipboard -Value $content
            Write-Host "[$(Get-Date)] Copied content to clipboard."
        } catch {
            Write-Warning "Failed to read file or set clipboard: $_"
        }
    }
}

# 注册事件（当文件被更改时触发）
Register-ObjectEvent $watcher Changed -Action $action | Out-Null

# 开始监视
$watcher.EnableRaisingEvents = $true

# 保持脚本运行（直到手动中断）
while ($true) { Start-Sleep 1 }