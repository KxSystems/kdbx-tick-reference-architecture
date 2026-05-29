#!/bin/bash

# Kill all running stack processes
# Run from the project root directory

echo "Killing processes:"
for pid in $(pgrep -f "q.*-procName"); do
  cmd=$(ps -p "$pid" -o args= 2>/dev/null)
  [ -z "$cmd" ] && continue
  procname=$(echo "$cmd" | sed -n 's/.*-procName \([^ ]*\).*/\1/p')
  case "$procname" in
    TP|RDB|CHAINED_RDB|IDB|HDB|FH|RTE|GW)
      kill -9 "$pid" 2>/dev/null
      echo -e "  $procname\t[$pid]"
      ;;
  esac
done
