#!/bin/bash

# Kill all running stack processes.
# Run from the project root directory.

echo "Killing processes:"
ps aux | grep "q.*-procName" | grep -v grep | while read line; do
  pid=$(echo "$line" | awk '{print $2}')
  procname=$(echo "$line" | grep -oP '(?<=-procName )\S+')
  case "$procname" in
    TP|RDB|RDB_CHAIN_*|HDB|HDB_EXTRA_*|FH|RTE|GW)
      kill -9 "$pid" 2>/dev/null
      echo -e "  $procname\t[$pid]"
      ;;
  esac
done
