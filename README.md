# ClipRelay — 跨设备剪贴板同步

本地 Windows ↔ 跳板机 双向剪贴板同步，通过文件系统中转，绕过 RDP 剪贴板限制。

## 架构

```
本地 WSL                       跳板机 (47.93.7.122)
┌────────────────┐  lftp SFTP  ┌─────────────────────┐
│ minitorclip.sh │←────→──────→│ Victor/             │
│ 剪贴板→远程     │  双向同步    │  ├ ClipContent.txt  │
│ 远程→D:\Clip   │             │  ├ *.xlsx           │
└────────────────┘             │  ├ JumpRelay.ps1    │
                               │  ├ SyncFolder.ps1   │
                               │  └ JumpRelay.bat ← 双击
                               │       ↑             │
                               │  跳板机自身剪贴板监控  │
                               └─────────────────────┘

NAS 共享                         跳板机
┌──────────────┐                ┌──────────────────┐
│ \\allona...   │  SyncFolder    │ \\tsclient\C\    │
│   \Share     │──→ 实时同步 ──→│   FTP\test\Victor│
└──────────────┘                └──────────────────┘
```

## 文件清单

| 文件 | 运行位置 | 功能 |
|------|---------|------|
| `local-wsl/minitorclip.sh` | 本地 WSL | 剪贴板 ↔ 跳板机 SFTP 双向同步 |
| `jump-server/JumpRelay.ps1` | 跳板机 | Victor 文件夹 ↔ 跳板机剪贴板 |
| `jump-server/JumpRelay.bat` | 跳板机 | JumpRelay 启动器 |
| `jump-server/SyncFolder.ps1` | 跳板机 | NAS 共享 → Victor 实时文件同步 |
| `jump-server/SyncFolder.bat` | 跳板机 | SyncFolder 启动器 |
| `jump-server/minitorclip-remote.sh` | 跳板机(Linux) | 备用：Linux 版剪贴板监控 |

## 部署

### 本地 WSL

```bash
sudo cp local-wsl/minitorclip.sh /usr/local/bin/minitorclip
sudo chmod +x /usr/local/bin/minitorclip
# 编辑脚本，修改 REMOTE_IP / REMOTE_USER / REMOTE_PASS
minitorclip --no-clear
```

### 跳板机

1. 将 `jump-server/` 下所有文件放到 `C:\FTP\test\Victor\`（或你的 Victor 目录）
2. 双击 `JumpRelay.bat` — 启动剪贴板监控
3. 双击 `SyncFolder.bat` — 启动 NAS → Victor 文件同步

## 同步策略

| 方向 | 触发条件 | 覆盖 |
|------|---------|------|
| 本地剪贴板 → 跳板机 | 剪贴板内容变化 | ✅ |
| 跳板机 Victor → 本地 | 文件新增/修改（对比月_日_时间） | ✅ |
| 跳板机剪贴板 → Victor | 用户复制文件/文本 | ✅ |
| NAS → Victor | 文件 Created/Changed | ✅ |

## 配置说明

编辑 `minitorclip.sh` 中的变量：

```bash
REMOTE_IP="your.server.ip"
REMOTE_PORT="22"
REMOTE_USER="your_user"
REMOTE_PASS="your_password"
REMOTE_DIR="Victor"
```

编辑 `SyncFolder.ps1` 中的变量：

```powershell
$SOURCE      = "\\your_nas\share\path"
$DESTINATION = "\\tsclient\C\FTP\test\Victor"
```

## 安全

- 不要提交包含密码的配置文件
- SFTP 加密传输
- Victor 目录限制用户访问权限
