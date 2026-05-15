<#
.SYNOPSIS
    ClipRelay - 跨设备剪贴板同步方案
.DESCRIPTION
    在本地 Windows 工作站与远程跳板机之间建立双向剪贴板通道，
    利用文件系统作为中转媒介，规避 RDP 剪贴板重定向的安全风险。

    架构模式："双守护进程 + 中继目录"
    本地与跳板机均需运行此脚本，互为服务端和客户端。

    传输层：lftp SFTP（推送/拉取）或直连文件系统。

.PARAMETER Role
    运行角色：local（本地工作站）或 remote（跳板机）

.PARAMETER SyncOnly
    仅执行一次同步后退出（用于测试/调度）

.EXAMPLE
    # 本地工作站运行（前台守护）
    .\ClipRelay.ps1 -Role local

    # 跳板机运行（前台守护）
    .\ClipRelay.ps1 -Role remote

    # 单次同步测试
    .\ClipRelay.ps1 -Role local -SyncOnly
#>

param(
    [ValidateSet("local", "remote")]
    [string]$Role = "local",

    [switch]$SyncOnly
)

# ============================================================
# 配置加载 — 从 config.ps1 读取敏感信息
# ============================================================
$ConfigFile = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $ConfigFile) {
    . $ConfigFile
} else {
    Write-Host "[!] config.ps1 not found." -ForegroundColor Yellow
    Write-Host "    Copy config.example.ps1 to config.ps1 and fill in your credentials."
    exit 1
}

# 验证必需变量
if (-not $REMOTE_IP -or $REMOTE_IP -eq "192.168.1.100") {
    Write-Host "[!] Please edit config.ps1 with your actual jump server credentials." -ForegroundColor Red
    exit 1
}

# --- 路径配置 ---
if (-not $WorkstationRelayBase) { $WorkstationRelayBase = "D:\work\Clip" }
if (-not $JumpServerRelayPath)   { $JumpServerRelayPath   = "C:\FTP\test\Victor\Temp" }

# --- 角色 → 路径自动适配 ---
$script:Role = $Role
if ($Role -eq "local") {
    $LocalRelayBase  = $WorkstationRelayBase
    $RemoteRelayPath = $JumpServerRelayPath
    $script:UseDateSubdir = $true
    $script:JunctionPath = Join-Path $WorkstationRelayBase "current"
}
else {
    $LocalRelayBase  = $JumpServerRelayPath
    $RemoteRelayPath = Join-Path $WorkstationRelayBase "current"
    $script:UseDateSubdir = $false
}

# --- 连接配置 ---
$TransferMode = "lftp"

# lftp 可执行文件路径（需自行下载放入 lftp/bin/）
$LftpPath = Join-Path $PSScriptRoot "lftp\bin\lftp.exe"

# 远端连接参数（从 config.ps1 读取）
$RemoteHost = $REMOTE_IP
$RemotePort = if ($REMOTE_PORT) { [int]$REMOTE_PORT } else { 22 }
$RemoteUser = $REMOTE_USER
$RemotePass = $REMOTE_PASS

# 远端地址构造（lftp 使用的 URL）
$RemoteUrl = "sftp://${RemoteUser}:${RemotePass}@${RemoteHost}:${RemotePort}"

# 直连模式下的远端 UNC 路径
$RemoteUncPath = if ($REMOTE_UNC_PATH) { $REMOTE_UNC_PATH } else { "" }

# --- 行为配置 ---
# 剪贴板轮询间隔（秒）
$ClipPollInterval = 2

# 文件同步间隔（秒）
$SyncInterval = 3

# 防递归时间窗口（秒）- 程序写入后在此窗口内忽略同名文件事件
$AntiRecursionWindow = 3

# 日志级别: "INFO", "DEBUG", "WARN"
$LogLevel = "INFO"

# ============================================================
# 运行时状态（勿手动修改）
# ============================================================

# 今天的日期标识（yyyyMMdd）
$script:TodayKey = (Get-Date).ToString("yyyyMMdd")

# 动态中继目录
if ($script:UseDateSubdir) {
    $script:RelayDir = Join-Path $LocalRelayBase $script:TodayKey
}
else {
    $script:RelayDir = $LocalRelayBase
}

# 剪贴板内容哈希（用于检测变更）
$script:LastClipHash = $null

# 防递归：程序写入标记表  path → expiry DateTime
$script:ProgrammaticWrites = @{}

# 防递归：正在应用远端剪贴板（防止回环）
$script:ApplyingRemote = $false

# 运行标志
$script:Running = $true

# ============================================================
# 工具函数
# ============================================================

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLevels = @{ DEBUG = 0; INFO = 1; WARN = 2 }
    $currentLevel = $logLevels[$LogLevel]
    $msgLevel = $logLevels[$Level]
    if ($msgLevel -ge $currentLevel) {
        $prefix = switch ($Level) {
            "WARN"  { "[!]" }
            "DEBUG" { "[.]" }
            default { "[+]" }
        }
        Write-Host "$ts $prefix $Message"
    }
}

function Get-RelayDir {
    # 动态获取 relay 目录，必要时创建
    if ($script:UseDateSubdir) {
        # 本地工作站：每日子目录模式
        $today = (Get-Date).ToString("yyyyMMdd")
        if ($today -ne $script:TodayKey) {
            $script:TodayKey = $today
            $script:RelayDir = Join-Path $LocalRelayBase $today
        }
    }
    if (-not (Test-Path $script:RelayDir)) {
        New-Item -ItemType Directory -Path $script:RelayDir -Force | Out-Null
        Write-Log "INFO" "创建中继目录: $script:RelayDir"
    }
    # 维护 Junction "current" → 当日目录（供跳板机以固定路径访问）
    if ($script:UseDateSubdir -and $script:JunctionPath) {
        if ($script:JunctionPath -ne (Get-Item -Path $script:JunctionPath -ErrorAction SilentlyContinue).Target) {
            if (Test-Path $script:JunctionPath) {
                try { [System.IO.Directory]::Delete($script:JunctionPath) }
                catch { cmd /c "rmdir `"$($script:JunctionPath)`"" 2>$null }
            }
            try {
                New-Item -ItemType Junction -Path $script:JunctionPath -Target $script:RelayDir -Force | Out-Null
                Write-Log "DEBUG" "Junction: $($script:JunctionPath) -> $script:RelayDir"
            }
            catch {
                Write-Log "WARN" "创建 Junction 失败（需管理员权限）: $_"
            }
        }
    }
    return $script:RelayDir
}

function Get-ClipboardHash {
    # 计算当前剪贴板内容的 SHA256 哈希
    try {
        if ([System.Windows.Clipboard]::ContainsText()) {
            $text = [System.Windows.Clipboard]::GetText()
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
            return "TEXT:" + [BitConverter]::ToString($hash).Replace("-", "")
        }
        elseif ([System.Windows.Clipboard]::ContainsFileDropList()) {
            $files = [System.Windows.Clipboard]::GetFileDropList() -join ";"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($files)
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
            return "FILE:" + [BitConverter]::ToString($hash).Replace("-", "")
        }
        elseif ([System.Windows.Clipboard]::ContainsImage()) {
            $img = [System.Windows.Clipboard]::GetImage()
            $ms = New-Object System.IO.MemoryStream
            $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $ms.ToArray()
            $ms.Close()
            $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
            return "IMG:" + [BitConverter]::ToString($hash).Replace("-", "")
        }
        else {
            return "EMPTY"
        }
    }
    catch {
        Write-Log "DEBUG" "获取剪贴板哈希失败: $_"
        return "ERROR"
    }
}

function Write-ContentToRelay {
    <#
    .SYNOPSIS
        将剪贴板内容写入中继目录（带防递归标记）
    #>
    param(
        [string]$Content,
        [string]$FileName
    )

    $relayDir = Get-RelayDir
    $fullPath = Join-Path $relayDir $FileName

    # ★ 防递归：写入前标记
    $script:ProgrammaticWrites[$fullPath] = (Get-Date).AddSeconds($AntiRecursionWindow)

    try {
        # 检测内容类型（文本/二进制）
        $isText = $true
        try {
            [System.IO.File]::WriteAllText($fullPath, $Content, [System.Text.Encoding]::UTF8)
            $isText = $true
        }
        catch {
            $isText = $false
        }

        if ($isText) {
            Write-Log "DEBUG" "写入中继: $FileName ($($Content.Length) chars)"
        }
        else {
            Write-Log "DEBUG" "写入中继(二进制): $FileName"
        }
    }
    catch {
        Write-Log "WARN" "写入中继失败: $_"
        $script:ProgrammaticWrites.Remove($fullPath)
    }
}

function Copy-FileToRelay {
    <#
    .SYNOPSIS
        将文件复制到中继目录
    #>
    param([string]$SourcePath)

    $relayDir = Get-RelayDir
    $fileName = Split-Path $SourcePath -Leaf
    $destPath = Join-Path $relayDir $fileName

    # ★ 防递归标记
    $script:ProgrammaticWrites[$destPath] = (Get-Date).AddSeconds($AntiRecursionWindow)

    try {
        # 处理同名文件：覆盖
        Copy-Item -Path $SourcePath -Destination $destPath -Force
        Write-Log "DEBUG" "复制文件到中继: $fileName"
    }
    catch {
        Write-Log "WARN" "复制文件到中继失败: $_"
        $script:ProgrammaticWrites.Remove($destPath)
    }
}

function Test-ProgrammaticWrite {
    <#
    .SYNOPSIS
        检查是否为程序写入（防递归核心）
    #>
    param([string]$FilePath)

    if ($script:ProgrammaticWrites.ContainsKey($FilePath)) {
        $expiry = $script:ProgrammaticWrites[$FilePath]
        if ((Get-Date) -lt $expiry) {
            Write-Log "DEBUG" "跳过程序写入事件: $(Split-Path $FilePath -Leaf)"
            return $true
        }
        else {
            # 已过期，清理
            $script:ProgrammaticWrites.Remove($FilePath)
        }
    }
    return $false
}

function Invoke-LftpSync {
    <#
    .SYNOPSIS
        使用 lftp 执行双向同步
    #>
    $relayDir = Get-RelayDir

    # --- Push: 本地 → 远端 ---
    $pushArgs = @(
        "-c",
        "set ssl:verify-certificate no; " +
        "set net:max-retries 2; " +
        "set net:timeout 10; " +
        "open $RemoteUrl; " +
        "mirror -R --only-newer --no-perms --verbose " +
        """$relayDir/"" ""$RemoteRelayPath/"""
    )

    Write-Log "DEBUG" "lftp push: $relayDir -> remote:$RemoteRelayPath"
    try {
        $pushResult = & $LftpPath $pushArgs 2>&1
        if ($LASTEXITCODE -ne 0 -and $pushResult -match "error|fatal|failed") {
            Write-Log "WARN" "lftp push 异常: $pushResult"
        }
        else {
            Write-Log "DEBUG" "lftp push 完成"
        }
    }
    catch {
        Write-Log "WARN" "lftp push 失败: $_"
    }

    # --- Pull: 远端 → 本地 ---
    $pullArgs = @(
        "-c",
        "set ssl:verify-certificate no; " +
        "set net:max-retries 2; " +
        "set net:timeout 10; " +
        "open $RemoteUrl; " +
        "mirror --only-newer --no-perms --verbose " +
        """$RemoteRelayPath/"" ""$relayDir/"""
    )

    Write-Log "DEBUG" "lftp pull: remote:$RemoteRelayPath -> $relayDir"
    try {
        $pullResult = & $LftpPath $pullArgs 2>&1
        if ($LASTEXITCODE -ne 0 -and $pullResult -match "error|fatal|failed") {
            Write-Log "WARN" "lftp pull 异常: $pullResult"
        }
        else {
            Write-Log "DEBUG" "lftp pull 完成"
        }
    }
    catch {
        Write-Log "WARN" "lftp pull 失败: $_"
    }
}

function Invoke-DirectSync {
    <#
    .SYNOPSIS
        直连模式：使用文件系统操作同步（适用于网络共享/tsclient）
    #>
    $relayDir = Get-RelayDir

    # Push: 本地 → 远端
    try {
        if (Test-Path $RemoteUncPath) {
            Get-ChildItem $relayDir -File | ForEach-Object {
                $destPath = Join-Path $RemoteUncPath $_.Name
                if (-not (Test-Path $destPath) -or (Get-Item $destPath).LastWriteTime -lt $_.LastWriteTime) {
                    Copy-Item -Path $_.FullName -Destination $destPath -Force
                    Write-Log "DEBUG" "Direct push: $($_.Name)"
                }
            }
        }
    }
    catch {
        Write-Log "WARN" "Direct push 失败: $_"
    }

    # Pull: 远端 → 本地
    try {
        if (Test-Path $RemoteUncPath) {
            Get-ChildItem $RemoteUncPath -File | ForEach-Object {
                $destPath = Join-Path $relayDir $_.Name
                if (-not (Test-Path $destPath) -or (Get-Item $destPath).LastWriteTime -ne $_.LastWriteTime) {
                    # ★ 防递归：从远端拉取的文件是"外来"数据，不加标记
                    Copy-Item -Path $_.FullName -Destination $destPath -Force
                    Write-Log "DEBUG" "Direct pull: $($_.Name)"
                }
            }
        }
    }
    catch {
        Write-Log "WARN" "Direct pull 失败: $_"
    }
}

function Sync-Files {
    <#
    .SYNOPSIS
        执行文件同步（根据 TransferMode 选择传输方式）
    #>
    if ($TransferMode -eq "lftp") {
        Invoke-LftpSync
    }
    elseif ($TransferMode -eq "direct") {
        Invoke-DirectSync
    }
}

function Set-ClipboardFromFile {
    <#
    .SYNOPSIS
        将中继目录中的文件内容应用到剪贴板
    #>
    param([string]$FilePath)

    # ★ 防回环标记
    $script:ApplyingRemote = $true

    try {
        $fileName = Split-Path $FilePath -Leaf

        # 判断文件类型
        if ($fileName -match "^ClipImage") {
            # 图片文件 → 写入剪贴板
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($FilePath)
            [System.Windows.Clipboard]::SetImage($img)
            $img.Dispose()
            Write-Log "INFO" "C <-- 远端图片: $fileName"
        }
        elseif ($fileName -match "^ClipContent" -or $fileName -match "\.txt$") {
            # 文本文件 → 读取内容写入剪贴板
            $text = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
            [System.Windows.Clipboard]::SetText($text)
            $preview = if ($text.Length -gt 80) { $text.Substring(0, 80) + "..." } else { $text }
            Write-Log "INFO" "C <-- 远端文本: $preview"
        }
        else {
            # 其他文件 → 用 FileDropList 写入剪贴板
            $coll = New-Object System.Collections.Specialized.StringCollection
            $coll.Add($FilePath) | Out-Null
            [System.Windows.Clipboard]::SetFileDropList($coll)
            Write-Log "INFO" "C <-- 远端文件: $fileName"
        }
    }
    catch {
        Write-Log "WARN" "设置剪贴板失败 ($fileName): $_"
    }
    finally {
        # 延迟重置防回环标记（确保 Clipboard poller 跳过本次变更）
        Start-Sleep -Milliseconds 500
        $script:ApplyingRemote = $false
    }
}

function Process-ClipboardChange {
    <#
    .SYNOPSIS
        处理用户剪贴板变更：写入中继 → 触发同步
    #>
    $relayDir = Get-RelayDir

    try {
        if ([System.Windows.Clipboard]::ContainsFileDropList()) {
            # --- 文件对象 ---
            $files = [System.Windows.Clipboard]::GetFileDropList()
            Write-Log "INFO" "C --> 检测到文件: $($files.Count) 个"
            foreach ($f in $files) {
                if (Test-Path $f) {
                    Copy-FileToRelay $f
                }
            }
        }
        elseif ([System.Windows.Clipboard]::ContainsImage()) {
            # --- 图片对象 ---
            $ts = Get-Date -Format "yyyyMMdd_HHmmss"
            $fileName = "ClipImage_${ts}.png"
            $fullPath = Join-Path $relayDir $fileName

            $script:ProgrammaticWrites[$fullPath] = (Get-Date).AddSeconds($AntiRecursionWindow)
            try {
                $img = [System.Windows.Clipboard]::GetImage()
                $img.Save($fullPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $img.Dispose()
                Write-Log "INFO" "C --> 图片 → $fileName"
            }
            catch {
                Write-Log "WARN" "保存图片失败: $_"
                $script:ProgrammaticWrites.Remove($fullPath)
            }
        }
        elseif ([System.Windows.Clipboard]::ContainsText()) {
            # --- 文本对象 ---
            $text = [System.Windows.Clipboard]::GetText()
            $preview = if ($text.Length -gt 80) { $text.Substring(0, 80) + "..." } else { $text }
            Write-Log "INFO" "C --> 检测到文本: $preview"

            $ts = Get-Date -Format "yyyyMMdd_HHmmss"
            $fileName = "ClipContent_${ts}.txt"
            Write-ContentToRelay -Content $text -FileName $fileName
        }
    }
    catch {
        Write-Log "WARN" "处理剪贴板变更失败: $_"
    }
}

# ============================================================
# 主循环组件
# ============================================================

function Start-FileWatcher {
    <#
    .SYNOPSIS
        启动 FileSystemWatcher 监控中继目录
    #>
    $relayDir = Get-RelayDir
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $relayDir
    $watcher.Filter = "*.*"
    $watcher.IncludeSubdirectories = $false
    $watcher.NotifyFilter = [System.IO.NotifyFilters]::FileName -bor
                            [System.IO.NotifyFilters]::LastWrite

    # 事件处理
    $onCreated = Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action {
        $path = $Event.SourceEventArgs.FullPath
        $name = $Event.SourceEventArgs.Name

        # 跳过临时文件和部分写入
        if ($name -like "*.tmp" -or $name -like "*.part" -or $name -like "*.lftp*") { return }

        # ★ 防递归：检查是否为程序写入
        if (Test-ProgrammaticWrite $path) {
            return
        }

        # 等待文件完全写入（简化的完整性检查）
        Start-Sleep -Milliseconds 200
        if (-not (Test-Path $path)) { return }

        try {
            $fi = Get-Item $path
            if ($fi.Length -gt 0) {
                Set-ClipboardFromFile $path
            }
        }
        catch {
            # 忽略临时文件读取错误
        }
    }

    $onChanged = Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action {
        # Changed 事件作为补充（某些网络文件系统仅触发 Changed）
        $path = $Event.SourceEventArgs.FullPath
        if (Test-ProgrammaticWrite $path) { return }
    }

    $watcher.EnableRaisingEvents = $true
    Write-Log "INFO" "FileSystemWatcher 已启动，监控: $relayDir"

    return $watcher
}

function Start-MainLoop {
    param(
        [switch]$SingleRun
    )

    Write-Host "=" * 60
    Write-Host "  ClipRelay - 跨设备剪贴板同步"
    Write-Host "  角色: $Role | 中继目录: $script:RelayDir"
    Write-Host "  剪贴板轮询: ${ClipPollInterval}s | 同步间隔: ${SyncInterval}s"
    Write-Host "  传输模式: $TransferMode"
    Write-Host "=" * 60

    if ($SingleRun) {
        Write-Log "INFO" "单次同步模式"
    }

    # 启动 FileSystemWatcher
    $watcher = Start-FileWatcher

    # 初始化哈希
    $script:LastClipHash = Get-ClipboardHash

    # 主循环
    $lastSyncTime = [DateTime]::MinValue
    $lastDayCheck = Get-Date

    while ($script:Running) {
        try {
            # --- 检查日期变更 ---
            if ((Get-Date).Date -ne $lastDayCheck.Date) {
                $lastDayCheck = Get-Date
                $oldDir = $script:RelayDir
                Get-RelayDir | Out-Null
                if ($oldDir -ne $script:RelayDir) {
                    # 日期变更，重启 watcher
                    $watcher.EnableRaisingEvents = $false
                    $watcher.Dispose()
                    $watcher = Start-FileWatcher
                }
            }

            # --- 剪贴板轮询 ---
            # 仅在非"应用远端内容"状态下检查
            if (-not $script:ApplyingRemote) {
                $currentHash = Get-ClipboardHash
                if ($currentHash -ne $script:LastClipHash -and
                    $currentHash -ne "EMPTY" -and
                    $currentHash -ne "ERROR") {

                    if ($script:LastClipHash -ne $null -and $script:LastClipHash -ne "EMPTY") {
                        # 剪贴板发生变更（排除首次读和清零）
                        Process-ClipboardChange
                        # 立即同步一次
                        Sync-Files
                        $lastSyncTime = Get-Date
                    }
                    $script:LastClipHash = $currentHash
                }
            }

            # --- 定时文件同步 ---
            if (((Get-Date) - $lastSyncTime).TotalSeconds -ge $SyncInterval) {
                Sync-Files
                $lastSyncTime = Get-Date
            }

            # --- 清理过期防递归标记 ---
            $now = Get-Date
            $expired = @($script:ProgrammaticWrites.Keys | Where-Object { $script:ProgrammaticWrites[$_] -lt $now })
            foreach ($k in $expired) {
                $script:ProgrammaticWrites.Remove($k)
            }

            # 单次运行模式
            if ($SingleRun) {
                Write-Log "INFO" "单次同步完成。"
                $script:Running = $false
                break
            }

            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-Log "WARN" "主循环异常: $_"
            Start-Sleep -Seconds 2
        }
    }

    # 清理
    Write-Log "INFO" "正在停止..."
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue
    Write-Log "INFO" "ClipRelay 已停止。"
}

# ============================================================
# 启动
# ============================================================

# 初始化中继目录
Get-RelayDir | Out-Null

# 需要 STA 模式以支持剪贴板操作（PowerShell 默认 MTA）
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Write-Log "WARN" "建议以 STA 模式运行（-STA 参数），否则剪贴板操作可能失败"
}

# 添加必要的程序集
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

# 注册 Ctrl+C 优雅退出
$null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    $script:Running = $false
}

Write-Host "`n按 Ctrl+C 停止...`n"

try {
    Start-MainLoop -SingleRun:$SyncOnly
}
finally {
    Get-EventSubscriber | Unregister-Event -Force -ErrorAction SilentlyContinue
}
