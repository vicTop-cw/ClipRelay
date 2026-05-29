#!/bin/bash
# ============================================================
# minitorclip-remote — 跳板机剪贴板 → Victor 文件夹
# 运行在跳板机上: bash minitorclip-remote.sh
# ============================================================

WATCH_DIR="$HOME/Victor"
LAST_TEXT_HASH=""
LAST_FILES_HASH=""

mkdir -p "$WATCH_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 检测剪贴板类型 ──
check_clipboard() {
  # Linux 用 xclip 检测剪贴板
  if command -v xclip &>/dev/null; then
    if xclip -selection clipboard -o &>/dev/null 2>&1; then
      echo "TEXT"
    else
      echo "NONE"
    fi
  else
    # 无 xclip 时回退：检查 Victor 目录的 .clip_text 文件
    if [ -f "$WATCH_DIR/.clip_text" ]; then
      echo "TEXT"
    else
      echo "NONE"
    fi
  fi
}

# ── 处理文本（覆盖写入）──
handle_text() {
  if command -v xclip &>/dev/null; then
    xclip -selection clipboard -o > "$WATCH_DIR/ClipContent.txt" 2>/dev/null
  elif [ -f "$WATCH_DIR/.clip_text" ]; then
    cp "$WATCH_DIR/.clip_text" "$WATCH_DIR/ClipContent.txt"
  else
    return
  fi

  local hash
  hash=$(md5sum "$WATCH_DIR/ClipContent.txt" 2>/dev/null | cut -d' ' -f1)
  [ "$hash" = "$LAST_TEXT_HASH" ] && return
  LAST_TEXT_HASH="$hash"

  local chars
  chars=$(wc -c < "$WATCH_DIR/ClipContent.txt")
  log "Text → ClipContent.txt (${chars} chars)"
}

# ── 处理文件（覆盖写入 Victor/）──
handle_files() {
  # 从剪贴板 .clip_files 读取文件列表
  local filesfile="$WATCH_DIR/.clip_files"
  [ ! -f "$filesfile" ] && return

  local hash
  hash=$(md5sum "$filesfile" 2>/dev/null | cut -d' ' -f1)
  [ "$hash" = "$LAST_FILES_HASH" ] && return
  LAST_FILES_HASH="$hash"

  while IFS= read -r filepath; do
    filepath=$(echo "$filepath" | tr -d '\r')
    [ -z "$filepath" ] && continue
    [ ! -f "$filepath" ] && continue

    local fname
    fname=$(basename "$filepath")
    cp -f "$filepath" "$WATCH_DIR/$fname"  # -f 覆盖模式
    log "File → $fname (overwrite)"
  done < "$filesfile"
}

log "minitorclip-remote started"
log "Watching: $WATCH_DIR"
echo ""

while true; do
  case $(check_clipboard) in
    TEXT)  handle_text ;;
  esac
  handle_files  # 文件通过 .clip_files 传递
  sleep 2
done
