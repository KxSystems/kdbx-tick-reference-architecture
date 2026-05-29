#!/bin/bash

# Kill all running stack processes and, by default, remove the generated app/
# directories (tplogs, hdb, idb, proclogs). Pass -k to keep them.
# Run from the project root directory.
#
# Usage: ./scaled-tick++/scripts/shutdown.sh [-e envFile] [-k]
#   -e  Path to .env file (default: .env). Used to locate dirs to clean.
#   -k  Keep generated files (skip the cleanup pass).

e_flag=".env"
k_flag=0

while getopts 'e:k' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    k) k_flag=1 ;;
    *) printf "Usage: ./scaled-tick++/scripts/shutdown.sh [-e envFile] [-k]\n"; exit 1 ;;
  esac
done

echo "Killing processes:"
for pid in $(pgrep -f "q.*-procName"); do
  cmd=$(ps -p "$pid" -o args= 2>/dev/null)
  [ -z "$cmd" ] && continue
  procname=$(echo "$cmd" | sed -n 's/.*-procName \([^ ]*\).*/\1/p')
  case "$procname" in
    TP|RDB|RDB_CHAIN_*|IDB|HDB|HDB_EXTRA_*|FH|RTE|GW|REST_GW_*)
      kill -9 "$pid" 2>/dev/null
      echo -e "  $procname\t[$pid]"
      ;;
  esac
done

if [ "$k_flag" -eq 1 ]; then
  echo "Keeping generated files (-k)."
  exit 0
fi

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag — skipping cleanup."
  exit 0
fi
source "$e_flag"

echo "Cleaning up:"
for dir in "$TPLOG_DIR" "$IDB_DIR" "$HDB_DIR" "$PROCESS_LOG_DIR"; do
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    rm -rf "$dir"
    echo -e "  removed\t[$dir]"
  fi
done
