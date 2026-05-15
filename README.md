# ClipRelay — 本地↔跳板机剪贴板共享

双向同步本地与跳板机之间的剪贴板内容，支持文件和文本。

## 工作原理

```
┌─────────────┐         SFTP          ┌─────────────┐
│   本地 PC    │ ◄══════════════════► │   跳板机     │
│             │                      │             │
│ 监控文件夹   │ ←── 文件同步 ──→   │ 监控文件夹   │
│     ↕       │                      │     ↕       │
│  剪贴板     │ ←── 内容传输 ──→   │  剪贴板     │
└─────────────┘                      └─────────────┘
```

- **本地→跳板机**：复制内容到剪贴板 → 自动上传到跳板机监控文件夹
- **跳板机→本地**：跳板机监控文件夹有新文件 → 自动复制到本地剪贴板
- **防递归**：程序写入剪贴板时加标记，不会再次上传

## 环境要求

- Windows 7+ / Windows Server
- PowerShell 5.1+
- SFTP 客户端（二选一）：
  - **lftp**（推荐）— 需 Windows 版，放入 `lftp/bin/lftp.exe`
  - **WinSCP** — 安装后将 `WinSCP.com` 路径填入配置

## 快速开始

### 1. 编辑配置

打开 `ClipRelay.ps1`，修改配置区：

```powershell
$REMOTE_IP       = "你的跳板机IP"
$REMOTE_PORT     = "10022"
$CREDENTIALS     = "用户名:密码"

$MINITOR_LOCAL_PATH = "D:\work\Clip\$(Get-Date -Format 'yyyyMMdd')"
$MINITOR_JUMP_PATH  = "C:\FTP\test\Victor\Temp"
```

### 2. 本地启动

```powershell
powershell -File ClipRelay.ps1 -Mode local
```

### 3. 跳板机启动

```powershell
powershell -File ClipRelay.ps1 -Mode jump
```

## 剪贴板规则

| 剪贴板内容 | 行为 |
|-----------|------|
| 文本 | 保存为 `ClipContent.txt` 上传 |
| 文件（Ctrl+C 复制文件） | 直接传输文件到对方文件夹 |
| 图片 | 当前版本暂不处理 |

## 监控规则

| 触发条件 | 行为 |
|---------|------|
| 文件夹新增文件 | 复制到剪贴板（程序标记） |
| 文件夹文件更新 | 复制到剪贴板（程序标记） |
| 用户剪贴板变化 | 上传到对方文件夹 |

## 测试方法

### 本地测试

```powershell
# 1. 启动脚本
powershell -File ClipRelay.ps1 -Mode local

# 2. 复制一段文本
echo "hello from local" | Set-Clipboard

# 3. 查看跳板机上是否出现 ClipContent.txt
```

### 双向测试

```powershell
# 本地终端
powershell -File ClipRelay.ps1 -Mode local

# 跳板机终端（通过 RDP/SSH 连接后）
powershell -File ClipRelay.ps1 -Mode jump
```

## lftp for Windows

Windows 版 lftp 可通过以下方式获取：

1. **Cygwin**：`apt-cyg install lftp`
2. **MSYS2**：`pacman -S lftp`  
3. **WSL**：在 WSL 中运行脚本，lftp 已内置

或使用 WinSCP 替代（修改脚本中 `Invoke-Lftp*` 函数）。

## 文件结构

```
ClipRelay/
├── ClipRelay.ps1          # 主脚本
├── lftp/
│   └── bin/
│       └── lftp.exe       # Windows lftp 二进制（需自行下载）
├── temp/                   # 临时文件（自动创建）
└── README.md              # 本文件
```

## 注意事项

- 账密明文存储在脚本中，建议设置文件权限 `icacls ClipRelay.ps1 /inheritance:r /grant "$env:USERNAME:R"`
- 首次连接需手动接受 SSH host key（或设置 `set sftp:auto-confirm yes`）
- 文件夹路径不存在时自动创建
