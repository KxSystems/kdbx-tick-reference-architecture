#!/bin/bash

# Expect to be run from the x-starter directory

# Get the process IDs of all q processes with a -procName argument for TP, RDB, or HDB and kill them
echo "Killed processes:"
ps aux | grep "q.*-procName TP\|FH\|RDB\|HDB\|GW" | grep -v "grep" | while read line; do
    pid=$(echo "$line" | awk '{print $2}')
    procname=$(echo "$line" | grep -oE "procName (TP|FH|RDB|HDB|GW)" | awk '{print $2}')
    kill -9 $pid
    echo -e "  $procname\t [$pid]"
done