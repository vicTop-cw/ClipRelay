# lftp for Windows

ClipRelay uses lftp for SFTP transfers. Place lftp binaries here.

## Download

Get the Cygwin-based lftp for Windows from:
- https://nwgat.ninja/lftp-for-windows/  
- Or any lftp Windows build that includes `lftp.exe`, `ssh.exe`, and required DLLs

## Directory structure

```
lftp/bin/
├── lftp.exe
├── ssh.exe
├── bash.exe
├── sh.exe
├── cygwin1.dll
├── cygcrypto-*.dll
├── cygssl-*.dll
└── ... (other cygwin DLLs)
```

Place ALL files in this directory. The script expects `lftp\bin\lftp.exe` relative to the project root.
