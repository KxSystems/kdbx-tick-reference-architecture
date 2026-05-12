#!/usr/bin/env bash
set -euo pipefail

# Defaults
ENV_FILE=".env"
KEEP_DAYS=7
TP_KEEP_DAYS=7
CLEAR_STARTUP=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -e FILE              Path to .env file (default: .env)
  --keep-days N        Days of proclog files to keep (default: 7)
  --tp-keep-days N     Days of tplog files to keep (default: 7)
  --clear-startup      Also truncate startup.log (skipped by default)
  -h, --help           Show this help message
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e)              ENV_FILE="$2";     shift 2 ;;
        --keep-days)     KEEP_DAYS="$2";    shift 2 ;;
        --tp-keep-days)  TP_KEEP_DAYS="$2"; shift 2 ;;
        --clear-startup) CLEAR_STARTUP=1;   shift ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

PROC_LOG_DIR="$PROCESS_LOG_DIR"
TP_LOG_DIR="$TPLOG_DIR"

# Delete .log files in the proclogs directory (excluding startup.log) that are
# older than keep_days days, based on file mtime.
cleanup_proclogs() {
    local log_dir="$1"
    local keep_days="$2"

    if [[ ! -d "$log_dir" ]]; then
        echo "Proclog dir not found: $log_dir"
        return 0
    fi

    local count=0
    while IFS= read -r -d '' f; do
        rm "$f"
        (( count++ )) || true
    done < <(find "$log_dir" -maxdepth 1 -name "*.log" ! -name "startup.log" -mtime +"$keep_days" -print0)

    echo "Deleted $count proclog file(s) older than ${keep_days} days"
}

# Delete tplog files named tpLogYYYY.MM.DD that are older than tp_keep_days days,
# by parsing the date from the filename.
cleanup_tplogs() {
    local log_dir="$1"
    local tp_keep_days="$2"

    if [[ ! -d "$log_dir" ]]; then
        echo "TPlog dir not found: $log_dir"
        return 0
    fi

    local cutoff_epoch
    cutoff_epoch=$(date -d "-${tp_keep_days} days" +%s)

    local count=0
    for f in "$log_dir"/tpLog*; do
        [[ -f "$f" ]] || continue
        local base="${f##*/}"
        local date_part="${base#tpLog}"          # YYYY.MM.DD
        local normalized="${date_part//./-}"     # YYYY-MM-DD
        local file_epoch
        file_epoch=$(date -d "$normalized" +%s 2>/dev/null) || continue
        if (( file_epoch < cutoff_epoch )); then
            rm "$f"
            (( count++ )) || true
        fi
    done

    echo "Deleted $count tplog file(s) older than ${tp_keep_days} days"
}

clear_startup_log() {
    local log_dir="$1"
    local f="$log_dir/startup.log"

    if [[ ! -f "$f" ]]; then
        echo "startup.log not found: $f"
        return 0
    fi

    : > "$f"
    echo "Cleared $f"
}

cleanup_proclogs "$PROC_LOG_DIR" "$KEEP_DAYS"
cleanup_tplogs "$TP_LOG_DIR" "$TP_KEEP_DAYS"

if (( CLEAR_STARTUP )); then
    clear_startup_log "$PROC_LOG_DIR"
fi
