#!/bin/bash

# Restart a specific process without taking down the whole stack
# Run from the project root directory
#
# Usage: ./tick-x/scripts/restart.sh <procName> [-s secondaries]
#
# procName: TP | RDB | CHAINED_RDB | IDB | HDB | FH | RTE | GW
#
# Examples:
#   ./tick-x/scripts/restart.sh GW
#   ./tick-x/scripts/restart.sh RDB
#   ./tick-x/scripts/restart.sh CHAINED_RDB
#   ./tick-x/scripts/restart.sh IDB
#
# All configuration is hardcoded below — keep in sync with tick-x/scripts/startup.sh

#################
# Configuration #
#################
# Absolute runtime dirs (must match startup.sh — processes cd into the HDB root at connect)
ROOT_DIR="$(pwd)"
TPLOG_DIR="$ROOT_DIR/app/tplogs"
HDB_DIR="$ROOT_DIR/app/hdb"
IDB_DIR="$ROOT_DIR/app/idb"
PROCESS_LOG_DIR="$ROOT_DIR/app/proclogs"

SCHEMA_DIR="samples/schemas"
ANALYTIC_DIR="samples/analytics"

TPLOG_NAME="tpLog"
LOG_LEVEL="info"

TICK_PORT=5010
RDB_PORT=5011          # main RDB (writedown role)
HDB_PORT=5012
GW_PORT=5013
FH_PORT=5014
IDB_PORT=5015
RTE_PORT=5016
CHAINED_RDB_PORT=5017    # chained RDB (query role)

FH_TIMER=60000
FLUSH_INTV_MIN=5

export SCHEMA_DIR TPLOG_NAME LOG_LEVEL PROCESS_LOG_DIR

###############
# CLI-parsing #
###############
proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./tick-x/scripts/restart.sh <procName> [-s secondaries]\n"
  exit 1
fi

s_flag=0

while getopts 's:' flag; do
  case "${flag}" in
    s) s_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

kill_proc() {
  local pattern=$1
  local pids=""
  # `pgrep -f` is portable (BSD + GNU); -af is not — on macOS BSD `-a` means
  # "include ancestors" and the output is just PIDs, so the awk that followed
  # was a no-op. We then resolve each PID's args via `ps` and require an exact
  # -procName match (followed by space or end of line) so e.g. "RDB" does not
  # also match "RDB_CHAIN_0".
  for pid in $(pgrep -f "q.*-procName $pattern"); do
    local cmd
    cmd=$(ps -p "$pid" -o args= 2>/dev/null)
    echo "$cmd" | grep -qE -- "-procName $pattern( |\$)" && pids="$pids $pid"
  done
  if [ -n "$pids" ]; then
    echo "  Killing $pattern:$pids"
    kill -9 $pids 2>/dev/null
    sleep 0.3
  else
    echo "  No running process found for $pattern"
  fi
}

echo "Restarting [$proc_name]..."

case "$proc_name" in
  TP)
    kill_proc "TP"
    q tick-x/src/tick.q -p $TICK_PORT -s $s_flag \
      -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
      -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started TP [$TICK_PORT]"
    ;;

  RDB)
    kill_proc "RDB"
    q tick-x/src/rdb.q -p $RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -tpPort $TICK_PORT -hdbPort $HDB_PORT -idbPort $IDB_PORT \
      -flushIntvMin $FLUSH_INTV_MIN \
      -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB [$RDB_PORT]"
    ;;

  CHAINED_RDB)
    kill_proc "CHAINED_RDB"
    q tick-x/src/chainedrdb.q -p $CHAINED_RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -tpPort $TICK_PORT \
      -procName CHAINED_RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started CHAINED_RDB [$CHAINED_RDB_PORT]"
    ;;

  IDB)
    kill_proc "IDB"
    q tick-x/src/idb.q -p $IDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -procName IDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started IDB [$IDB_PORT]"
    ;;

  HDB)
    kill_proc "HDB"
    q tick-x/src/hdb.q -p $HDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB [$HDB_PORT]"
    ;;

  FH)
    kill_proc "FH"
    q tick-x/src/fh.q -p $FH_PORT -s $s_flag \
      -fhTimer $FH_TIMER \
      -tpPort $TICK_PORT \
      -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started FH [$FH_PORT]"
    ;;

  RTE)
    kill_proc "RTE"
    q tick-x/src/rte.q -p $RTE_PORT -s $s_flag \
      -tpPort $TICK_PORT \
      -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RTE [$RTE_PORT]"
    ;;

  GW)
    kill_proc "GW"
    q tick-x/src/gw.q -p $GW_PORT -s $s_flag \
      -rdbPort $CHAINED_RDB_PORT \
      -idbPort $IDB_PORT \
      -hdbPort $HDB_PORT \
      -analyticsDir $ANALYTIC_DIR \
      -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started GW [$GW_PORT]"
    ;;

  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | CHAINED_RDB | IDB | HDB | FH | RTE | GW"
    exit 1
    ;;
esac

echo "Done."
