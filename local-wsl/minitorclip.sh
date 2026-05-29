#!/bin/bash
# ============================================================
# minitorclip — WSL Clipboard → 跳板机 SFTP 同步
# ============================================================

CLEAR_REMOTE=true   # default: clear remote dir on startup

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-clear) CLEAR_REMOTE=false; shift ;;
        --clear)    CLEAR_REMOTE=true; shift ;;
        -h|--help)
            echo "Usage: minitorclip [--no-clear] [--clear]"
            echo "  --clear      Clear remote dir on startup (default)"
            echo "  --no-clear   Skip clearing remote dir"
            exit 0
            ;;
        *) shift ;;
    esac
done

REMOTE_IP="47.93.7.122"
REMOTE_PORT="10022"
REMOTE_USER="test"
REMOTE_PASS="s@8@Nrrk"
REMOTE_DIR="Victor"
TEMP_DIR="/tmp/minitorclip"
TEMP_WIN="C:\\temp\\_minitorclip"

mkdir -p "$TEMP_DIR"
LAST_TEXT_HASH=""
LAST_FILES_HASH=""

log() { echo "[$(date '+%H:%M:%S')] $*"; }

clear_remote_dir() {
    log "Clearing remote dir: $REMOTE_DIR ..."
    cat > "$TEMP_DIR/_.lftp" <<EOF
set sftp:auto-confirm yes
set xfer:clobber on
open -u "$REMOTE_USER","$REMOTE_PASS" sftp://$REMOTE_IP:$REMOTE_PORT
cd $REMOTE_DIR
rm -f *
bye
EOF
    lftp -f "$TEMP_DIR/_.lftp" 2>&1 && log "Remote dir cleared" || log "Remote clear FAILED"
}

sftp_upload() {
    cat > "$TEMP_DIR/_.lftp" <<EOF
set sftp:auto-confirm yes
set xfer:clobber on
open -u "$REMOTE_USER","$REMOTE_PASS" sftp://$REMOTE_IP:$REMOTE_PORT
cd $REMOTE_DIR
put "$1" -o "$2"
bye
EOF
    lftp -f "$TEMP_DIR/_.lftp" 2>&1 && return 0 || return 1
}

check_clipboard() {
    powershell.exe -Command "
        Add-Type -AssemblyName System.Windows.Forms
        \$clip = [System.Windows.Forms.Clipboard]
        if (\$clip::ContainsFileDropList()) {
            \$files = \$clip::GetFileDropList()
            Set-Content -Path '${TEMP_WIN}_type.txt' -Value 'FILES'
            Set-Content -Path '${TEMP_WIN}_files.txt' -Value \$files -Encoding ASCII
        } elseif (\$clip::ContainsText()) {
            \$text = \$clip::GetText()
            Set-Content -Path '${TEMP_WIN}_type.txt' -Value 'TEXT'
            [System.IO.File]::WriteAllText('${TEMP_WIN}_text.txt', \$text, [System.Text.Encoding]::UTF8)
        } else {
            Set-Content -Path '${TEMP_WIN}_type.txt' -Value 'NONE'
        }
    " 2>/dev/null
    
    cat /mnt/c/temp/_minitorclip_type.txt 2>/dev/null | tr -d '\r'
}

handle_text() {
    local textfile="/mnt/c/temp/_minitorclip_text.txt"
    [ ! -f "$textfile" ] && return
    
    local hash
    hash=$(md5sum "$textfile" 2>/dev/null | cut -d' ' -f1)
    [ "$hash" = "$LAST_TEXT_HASH" ] && return
    LAST_TEXT_HASH="$hash"
    
    cp "$textfile" "$TEMP_DIR/ClipContent.txt"
    local chars
    chars=$(wc -c < "$TEMP_DIR/ClipContent.txt")
    log "Text -> ClipContent.txt (${chars} chars)"
    sftp_upload "$TEMP_DIR/ClipContent.txt" "ClipContent.txt"
}

handle_files() {
    local filesfile="/mnt/c/temp/_minitorclip_files.txt"
    [ ! -f "$filesfile" ] && return
    
    local hash
    hash=$(md5sum "$filesfile" 2>/dev/null | cut -d' ' -f1)
    [ "$hash" = "$LAST_FILES_HASH" ] && return
    LAST_FILES_HASH="$hash"
    
    while IFS= read -r winpath; do
        winpath=$(echo "$winpath" | tr -d '\r')
        [ -z "$winpath" ] && continue
        
        local wsl_path
        wsl_path=$(wslpath -u "$winpath" 2>/dev/null)
        if [ -n "$wsl_path" ] && [ -f "$wsl_path" ]; then
            local fname
            fname=$(basename "$wsl_path")
            cp "$wsl_path" "$TEMP_DIR/$fname"
            if sftp_upload "$TEMP_DIR/$fname" "$fname"; then
                log "File -> $fname OK"
            else
                log "File -> $fname FAILED"
            fi
        else
            log "Skip (not found): $winpath"
        fi
    done < "$filesfile"
}

# ── 本地下载路径 ──
LOCAL_CLIP_DIR_WIN="D:\\work\\Clip\\$(date '+%Y%m%d')"
LOCAL_CLIP_DIR="/mnt/d/work/Clip/$(date '+%Y%m%d')"
mkdir -p "$LOCAL_CLIP_DIR" 2>/dev/null
LAST_REMOTE_FILES=""
FIRST_RUN=true

# ── 从跳板机同步到本地（仅文件，不含子目录）──
sync_remote_to_local() {
    local listfile="$TEMP_DIR/_remote_list.txt"
    
    cat > "$TEMP_DIR/_list.lftp" <<EOF
set sftp:auto-confirm yes
set xfer:clobber on
open -u "$REMOTE_USER","$REMOTE_PASS" sftp://$REMOTE_IP:$REMOTE_PORT
cd $REMOTE_DIR
ls -l
bye
EOF
    # 提取: 文件名|月 日 时间 (同一天多次修改也能检测)
    lftp -f "$TEMP_DIR/_list.lftp" 2>/dev/null | grep -E '^-' | awk '{printf "%s|%s_%s_%s\n", $9, $6, $7, $8}' > "$listfile"
    
    local current
    current=$(cat "$listfile" 2>/dev/null | sort)
    
    if [ "$FIRST_RUN" = true ]; then
        LAST_REMOTE_FILES="$current"
        FIRST_RUN=false
        log "Remote sync: recorded $(echo "$current" | wc -l) files (first run, no download)"
        return
    fi
    
    # 找新增/修改的文件（文件名或时间戳不同）
    local new_files
    new_files=$(comm -13 <(echo "$LAST_REMOTE_FILES") <(echo "$current") | awk -F'|' '{print $1}')
    
    if [ -n "$new_files" ]; then
        echo "$new_files" | while IFS= read -r fname; do
            [ -z "$fname" ] && continue
            
            if [ "$fname" = "ClipContent.txt" ]; then
                cat > "$TEMP_DIR/_dl.lftp" <<EOF
set sftp:auto-confirm yes
set xfer:clobber on
open -u "$REMOTE_USER","$REMOTE_PASS" sftp://$REMOTE_IP:$REMOTE_PORT
cd $REMOTE_DIR
get "$fname" -o "$TEMP_DIR/$fname"
bye
EOF
                lftp -f "$TEMP_DIR/_dl.lftp" 2>/dev/null
                if [ -f "$TEMP_DIR/$fname" ]; then
                    powershell.exe -Command "
                        \$text = Get-Content '$TEMP_DIR/$fname' -Raw -Encoding UTF8
                        Add-Type -AssemblyName System.Windows.Forms
                        [System.Windows.Forms.Clipboard]::SetText(\$text)
                    " 2>/dev/null
                    log "Remote -> Clipboard: text from $fname"
                fi
            else
                cat > "$TEMP_DIR/_dl.lftp" <<EOF
set sftp:auto-confirm yes
set xfer:clobber on
open -u "$REMOTE_USER","$REMOTE_PASS" sftp://$REMOTE_IP:$REMOTE_PORT
cd $REMOTE_DIR
get "$fname" -o "$LOCAL_CLIP_DIR/$fname"
bye
EOF
                lftp -f "$TEMP_DIR/_dl.lftp" 2>/dev/null
                log "Remote -> Local: $fname"
            fi
        done
    fi
    
    LAST_REMOTE_FILES="$current"
}

log "minitorclip started"
log "Remote: $REMOTE_USER@$REMOTE_IP:$REMOTE_PORT/$REMOTE_DIR"
echo ""

if [ "$CLEAR_REMOTE" = true ]; then
    clear_remote_dir
    echo ""
fi

REMOTE_COUNTER=0
while true; do
    case $(check_clipboard) in
        TEXT)  handle_text ;;
        FILES) handle_files ;;
    esac
    
    REMOTE_COUNTER=$((REMOTE_COUNTER + 1))
    if [ $REMOTE_COUNTER -ge 6 ]; then
        sync_remote_to_local
        REMOTE_COUNTER=0
    fi
    
    sleep 0.5
done
