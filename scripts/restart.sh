#!/bin/bash

# Restart a specific process without taking down the whole stack.
# Run from the project root directory.
#
# Usage: ./scripts/restart.sh <procName> [-e envFile] [-s secondaries] [-m chainedRdbs]
#
# procName: TP | RDB | RDB_CHAIN_<N> | HDB | HDB_EXTRA_<N> | FH | RTE | GW
#
# Examples:
#   ./scripts/restart.sh GW
#   ./scripts/restart.sh RTE
#   ./scripts/restart.sh RDB_CHAIN_0 -m 2

proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./scripts/restart.sh <procName> [-e envFile] [-s secondaries] [-m chainedRdbs]\n"
  exit 1
fi

e_flag=".env"
s_flag=0
m_flag=0

while getopts 'e:s:m:' flag; do
  case "${flag}" in
    e) e_flag="${OPTARG}" ;;
    s) s_flag="${OPTARG}" ;;
    m) m_flag="${OPTARG}" ;;
    *) exit 1 ;;
  esac
done

if [ ! -f "$e_flag" ]; then
  echo "Env file not found: $e_flag"
  exit 1
fi
source "$e_flag"

# Paired port scheme (mirrors startup.sh)
RDB_CHAIN_PORTS=()
HDB_EXTRA_PORTS=()
for ((i=0; i<m_flag; i++)); do
  RDB_CHAIN_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i )) )
  HDB_EXTRA_PORTS+=( $(( PARALLEL_PORT_RANGE_START + 2*i + 1 )) )
done
ALL_HDB_PORTS=($HDB_PORT ${HDB_EXTRA_PORTS[*]})

kill_proc() {
  local pattern=$1
  local pids
  pids=$(ps aux | grep "q.*-procName ${pattern}\b" | grep -v grep | awk '{print $2}')
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
    q kdb-x-platform/tick.q -p $TICK_PORT -s $s_flag \
      -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
      -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started TP [$TICK_PORT]"
    ;;

  RDB)
    kill_proc "RDB"
    q kdb-x-platform/r.q -p $RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
      -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
      -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB [$RDB_PORT]"
    ;;

  RDB_CHAIN_[0-9]*)
    idx=${proc_name#RDB_CHAIN_}
    kill_proc "$proc_name"
    q kdb-x-platform/r.q -p ${RDB_CHAIN_PORTS[$idx]} -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR \
      -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
      -procName RDB_CHAIN_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB_CHAIN_$idx [${RDB_CHAIN_PORTS[$idx]}]"
    ;;

  HDB)
    kill_proc "HDB"
    q kdb-x-platform/hdb.q -p $HDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB [$HDB_PORT]"
    ;;

  HDB_EXTRA_[0-9]*)
    idx=${proc_name#HDB_EXTRA_}
    kill_proc "$proc_name"
    q kdb-x-platform/hdb.q -p ${HDB_EXTRA_PORTS[$idx]} -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB_EXTRA_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB_EXTRA_$idx [${HDB_EXTRA_PORTS[$idx]}]"
    ;;

  FH)
    kill_proc "FH"
    q kdb-x-platform/fh.q -p $FH_PORT -s $s_flag \
      -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
      -tpPort $TICK_PORT \
      -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started FH [$FH_PORT]"
    ;;

  RTE)
    kill_proc "RTE"
    q kdb-x-platform/rte.q -p $RTE_PORT -s $s_flag \
      -enrichFile $RTE_ENRICH_FILE \
      -tpPort $TICK_PORT \
      -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RTE [$RTE_PORT]"
    ;;

  GW)
    kill_proc "GW"
    q kdb-x-platform/gw.q -p $GW_PORT -s $s_flag \
      -rdbPort $RDB_PORT \
      -crdbPort ${RDB_CHAIN_PORTS[*]} \
      -hdbPort ${ALL_HDB_PORTS[*]} \
      -analyticsDir $ANALYTIC_DIR \
      -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started GW [$GW_PORT]"
    ;;

  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | RDB_CHAIN_<N> | HDB | HDB_EXTRA_<N> | FH | RTE | GW"
    exit 1
    ;;
esac

echo "Done."
