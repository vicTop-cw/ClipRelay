#!/bin/bash
# ============================================================
# minitorclip — WSL Clipboard → Jump Server SFTP Sync
# ============================================================
# Deploy: sudo cp monitorclip.sh /usr/local/bin/minitorclip && chmod +x /usr/local/bin/minitorclip
# Config: cp config.example.sh config.sh && edit config.sh with real credentials
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    echo "[ERROR] config.sh not found in $SCRIPT_DIR"
    echo "  Copy config.example.sh to config.sh and fill in your credentials."
    exit 1
fi

# Validate required vars
if [ -z "$REMOTE_IP" ] || [ -z "$REMOTE_USER" ]; then
    echo "[ERROR] REMOTE_IP and REMOTE_USER must be set in config.sh"
    exit 1
fi

TEMP_DIR="/tmp/minitorclip"
TEMP_WIN="C:\\temp\\_minitorclip"

mkdir -p "$TEMP_DIR"
LAST_TEXT_HASH=""
LAST_FILES_HASH=""

log() { echo "[$(date '+%H:%M:%S')] $*"; }

sftp_upload() {
    cat > "$TEMP_DIR/_.lftp" <<EOF
set sftp:auto-confirm yes
open -u "${REMOTE_USER}","${REMOTE_PASS}" sftp://${REMOTE_IP}:${REMOTE_PORT}
cd ${REMOTE_DIR}
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

# ── Local download path ──
LOCAL_CLIP_DIR_WIN="D:\\work\\Clip\\$(date '+%Y%m%d')"
LOCAL_CLIP_DIR="/mnt/d/work/Clip/$(date '+%Y%m%d')"
mkdir -p "$LOCAL_CLIP_DIR" 2>/dev/null
LAST_REMOTE_FILES=""
FIRST_RUN=true

# ── Sync remote -> local ──
sync_remote_to_local() {
    local listfile="$TEMP_DIR/_remote_list.txt"

    cat > "$TEMP_DIR/_list.lftp" <<EOF
set sftp:auto-confirm yes
open -u "${REMOTE_USER}","${REMOTE_PASS}" sftp://${REMOTE_IP}:${REMOTE_PORT}
cd ${REMOTE_DIR}
ls
bye
EOF
    lftp -f "$TEMP_DIR/_list.lftp" 2>/dev/null | grep -E '^-|^d' | awk '{print $NF}' > "$listfile"

    local current
    current=$(cat "$listfile" 2>/dev/null | sort)

    if [ "$FIRST_RUN" = true ]; then
        LAST_REMOTE_FILES="$current"
        FIRST_RUN=false
        log "Remote sync: recorded $(echo "$current" | wc -l) files (first run, no download)"
        return
    fi

    local new_files
    new_files=$(comm -13 <(echo "$LAST_REMOTE_FILES") <(echo "$current"))

    if [ -n "$new_files" ]; then
        echo "$new_files" | while IFS= read -r fname; do
            [ -z "$fname" ] && continue

            if [ "$fname" = "ClipContent.txt" ]; then
                cat > "$TEMP_DIR/_dl.lftp" <<EOF
set sftp:auto-confirm yes
open -u "${REMOTE_USER}","${REMOTE_PASS}" sftp://${REMOTE_IP}:${REMOTE_PORT}
cd ${REMOTE_DIR}
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
open -u "${REMOTE_USER}","${REMOTE_PASS}" sftp://${REMOTE_IP}:${REMOTE_PORT}
cd ${REMOTE_DIR}
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
log "Remote: ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_PORT}/${REMOTE_DIR}"
echo ""

REMOTE_COUNTER=0
while true; do
    case $(check_clipboard) in
        TEXT)  handle_text ;;
        FILES) handle_files ;;
    esac

    # Check remote folder every ~3 seconds
    REMOTE_COUNTER=$((REMOTE_COUNTER + 1))
    if [ $REMOTE_COUNTER -ge 6 ]; then
        sync_remote_to_local
        REMOTE_COUNTER=0
    fi

    sleep 0.5
done
