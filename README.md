# ClipRelay — Cross-Device Clipboard Sync

Bidirectional clipboard sync between a local Windows workstation and a remote jump server, using the filesystem as a relay medium to bypass RDP clipboard redirection risks.

## Architecture

```
┌─────────────────────────┐       lftp SFTP        ┌─────────────────────────┐
│   Local Workstation     │ ◄───────────────────► │     Jump Server         │
│                         │                         │                         │
│  Clipboard ──► RelayDir │    Push: local→remote   │  RelayDir ──► Clipboard │
│  Clipboard ◄── RelayDir │    Pull: remote→local   │  RelayDir ◄── Clipboard │
│                         │                         │                         │
│  D:\work\Clip\20260515/ │                         │  C:\FTP\test\Victor\Temp│
└─────────────────────────┘                         └─────────────────────────┘
```

**Anti-recursion**: Programmatic writes to the relay directory are tagged and ignored by the file watcher, preventing infinite loops.

## Requirements

| Component | Notes |
|-----------|-------|
| Windows 10+ / Server 2019+ | Both machines |
| PowerShell 5.1+ | Built-in |
| lftp for Windows | [Download](https://nwgat.ninja/lftp-for-windows/) → place in `lftp/bin/` |
| SFTP server | Jump server needs SSHD (e.g., OpenSSH Server) |

## Quick Start

### 1. Copy and edit config

```powershell
# PowerShell config
copy config.example.ps1 config.ps1
# Edit config.ps1 with your jump server credentials

# WSL config (for monitorclip.sh)
copy config.example.sh config.sh
# Edit config.sh with your jump server credentials
```

### 2. Install lftp

Download lftp for Windows and place all binaries in `lftp/bin/`.  
See [lftp/bin/README.md](lftp/bin/README.md) for details.

### 3. Run (Local Workstation)

Double-click `ClipRelay-local.bat`, or:

```powershell
powershell -STA -File "ClipRelay.ps1" -Role local
```

### 4. Run (Jump Server)

Double-click `ClipRelay-remote.bat`, or:

```powershell
powershell -STA -File "ClipRelay.ps1" -Role remote
```

### Optional: WSL Monitor (Linux/WSL on local workstation)

```bash
# Deploy
sudo cp monitorclip.sh /usr/local/bin/minitorclip
sudo chmod +x /usr/local/bin/minitorclip

# Run
minitorclip
```

Monitors Windows clipboard via WSL interop and syncs to the jump server via SFTP.  
Also pulls remote file changes back to `D:\work\Clip\yyyyMMdd`.

## Additional Scripts

| Script | Description |
|--------|-------------|
| `JumpRelay.ps1` | Lightweight jump server monitor — watches `C:\FTP\test\Victor\Temp` and copies new/updated files to clipboard. Use `-SyncBack` to enable reverse sync. |
| `JumpRelay.bat` | Launcher for JumpRelay.ps1 |
| `miniclip.ps1` | Generic file-to-clipboard watcher (pass a file path to monitor) |

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `$TransferMode` | `"lftp"` | Transport: `"lftp"` (SFTP) or `"direct"` (UNC path) |
| `$ClipPollInterval` | `2` | Clipboard poll interval (seconds) |
| `$SyncInterval` | `3` | File sync interval (seconds) |
| `$AntiRecursionWindow` | `3` | Anti-recursion window (seconds) |
| `$LogLevel` | `"INFO"` | Log level: `DEBUG` / `INFO` / `WARN` |

## Directory Structure

```
ClipRelay/
├── ClipRelay.ps1            # Main script
├── ClipRelay-local.bat      # Local mode launcher
├── ClipRelay-remote.bat     # Jump server mode launcher
├── JumpRelay.ps1            # Lightweight jump server monitor
├── JumpRelay.bat            # JumpRelay launcher
├── monitorclip.sh           # WSL clipboard monitor
├── miniclip.ps1             # File watcher utility
├── config.example.ps1       # PowerShell config template
├── config.example.sh        # Bash config template
├── config.ps1               # Your credentials (gitignored)
├── config.sh                # Your credentials (gitignored)
├── README.md
└── lftp/bin/
    └── README.md            # lftp download instructions
```

## Security

- **Never commit `config.ps1` or `config.sh`** — they are in `.gitignore`.
- For production, prefer SSH key authentication over passwords.  
  Configure in `%USERPROFILE%\.ssh\config` and remove the password from lftp commands.
- SFTP encrypts all data in transit.
- The relay directory contains clipboard content — restrict access to your user account.
