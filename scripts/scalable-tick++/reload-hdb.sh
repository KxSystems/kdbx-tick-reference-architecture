#!/bin/bash

# Trigger a reload on all running HDB processes to pick up data changes.
# Sends .hdb.reload[] via IPC to each running HDB.
# Useful when data is loaded outside of the normal tick EOD path.
#
# Usage:
#   ./reload-hdb.sh               # Reload all HDBs
#   ./reload-hdb.sh -e /path/.env # Custom env file

e_flag=".env"

while getopts 'e:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

# Source env vars
if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Find all running HDB processes and extract their ports
hdb_procs=$(ps aux | grep "q.*-procName HDB" | grep -v grep)

if [ -z "$hdb_procs" ]; then
  echo "No running HDB processes found."
  exit 0
fi

echo "Reloading HDB processes..."

while IFS= read -r line; do
  port=$(echo "$line" | grep -oP '(?<=-p )\d+')
  procname=$(echo "$line" | grep -oP '(?<=-procName )\S+')
  # Send .hdb.reload[] via helper q script
  result=$(q utils/reload-hdb-helper.q -port $port < /dev/null 2>&1 | tail -1)
  if [ "$result" = "OK" ]; then
    echo "  [OK]   $procname [$port]"
  else
    echo "  [FAIL] $procname [$port] — $result"
  fi
done <<< "$hdb_procs"

echo "Done."
