# ============================================================
# ClipRelay — PowerShell 配置文件
# 复制为 config.ps1 并填入实际值
# ============================================================

# --- 跳板机连接 ---
$REMOTE_IP   = "192.168.1.100"       # 跳板机 IP
$REMOTE_PORT = "22"                   # SFTP 端口
$REMOTE_USER = "your_username"        # 登录用户名
$REMOTE_PASS = "your_password"        # 密码

# --- 路径配置 ---
# 本地中继目录基路径
$WorkstationRelayBase = "D:\work\Clip"

# 跳板机中继目录
$JumpServerRelayPath = "C:\FTP\test\Victor\Temp"

# 直连模式下的远端 UNC 路径（仅 TransferMode="direct" 时需要）
$REMOTE_UNC_PATH = "\\tsclient\C\FTP\test\Victor\Temp"
