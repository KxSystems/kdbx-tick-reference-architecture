#!/bin/bash

# Restart a specific process without taking down the whole stack
# Run from the project root directory
#
# Usage: ./tick/scripts/restart.sh <procName> [-s secondaries]
#
# procName: TP | RDB | HDB | FH | RTE | GW
#
# Examples:
#   ./tick/scripts/restart.sh GW
#   ./tick/scripts/restart.sh RTE
#
# All configuration is hardcoded below — keep in sync with tick/scripts/startup.sh

#################
# Configuration #
#################
TPLOG_DIR="app/tplogs"
HDB_DIR="app/hdb"
PROCESS_LOG_DIR="app/proclogs"

SCHEMA_DIR="samples/schemas"
ANALYTIC_DIR="samples/analytics"

TPLOG_NAME="tpLog"
LOG_LEVEL="info"

TICK_PORT=5010
RDB_PORT=5011
HDB_PORT=5012
GW_PORT=5013
FH_PORT=5014
RTE_PORT=5016

FH_TIMER=60000

export SCHEMA_DIR TPLOG_NAME LOG_LEVEL

###############
# CLI-parsing #
###############
proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./tick/scripts/restart.sh <procName> [-s secondaries]\n"
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
  local pids
  pids=$(pgrep -af "q.*-procName ${pattern}\b" | awk '{print $1}')
  if [ -n "$pids" ]; then
    echo "  Killing $pattern: $pids"
    echo "$pids" | xargs kill -9 2>/dev/null
    sleep 0.3
  else
    echo "  No running process found for $pattern"
  fi
}

echo "Restarting [$proc_name]..."

case "$proc_name" in
  TP)
    kill_proc "TP"
    q tick/tick/tick.q -p $TICK_PORT -s $s_flag \
      -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
      -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started TP [$TICK_PORT]"
    ;;

  RDB)
    kill_proc "RDB"
    q tick/tick/rdb.q -p $RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
      -tpPort $TICK_PORT -hdbPort $HDB_PORT \
      -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB [$RDB_PORT]"
    ;;

  HDB)
    kill_proc "HDB"
    q tick/tick/hdb.q -p $HDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB [$HDB_PORT]"
    ;;

  FH)
    kill_proc "FH"
    q tick/tick/fh.q -p $FH_PORT -s $s_flag \
      -fhTimer $FH_TIMER \
      -tpPort $TICK_PORT \
      -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started FH [$FH_PORT]"
    ;;

  RTE)
    kill_proc "RTE"
    q tick/tick/rte.q -p $RTE_PORT -s $s_flag \
      -tpPort $TICK_PORT \
      -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RTE [$RTE_PORT]"
    ;;

  GW)
    kill_proc "GW"
    q tick/tick/gw.q -p $GW_PORT -s $s_flag \
      -rdbPort $RDB_PORT \
      -hdbPort $HDB_PORT \
      -analyticsDir $ANALYTIC_DIR \
      -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started GW [$GW_PORT]"
    ;;

  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | HDB | FH | RTE | GW"
    exit 1
    ;;
esac

echo "Done."
