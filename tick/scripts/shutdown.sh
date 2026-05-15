#!/bin/bash

# Kill all running stack processes
# Run from the project root directory

echo "Killing processes:"
pgrep -af "q.*-procName" | while read line; do
  pid=$(echo "$line" | awk '{print $1}')
  procname=$(echo "$line" | grep -oP '(?<=-procName )\S+')
  case "$procname" in
    TP|RDB|HDB|FH|RTE|GW)
      kill -9 "$pid" 2>/dev/null
      echo -e "  $procname\t[$pid]"
      ;;
  esac
done
