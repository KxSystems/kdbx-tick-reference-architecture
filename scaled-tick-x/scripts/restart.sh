#!/bin/bash

# Restart a specific process without taking down the whole stack.
# Run from the project root directory.
#
# Usage: ./scaled-tick-x/scripts/restart.sh <procName> [-e envFile] [-s secondaries] [-m chainedRdbs]
#
# procName: TP | RDB | RDB_CHAIN_<N> | IDB | HDB | HDB_EXTRA_<N> | FH | RTE | GW | REST_GW_<N>
#
# Examples:
#   ./scaled-tick-x/scripts/restart.sh GW
#   ./scaled-tick-x/scripts/restart.sh RTE
#   ./scaled-tick-x/scripts/restart.sh RDB_CHAIN_0 -m 2
#   ./scaled-tick-x/scripts/restart.sh IDB
#   ./scaled-tick-x/scripts/restart.sh REST_GW_0
#
# NOTE: do not restart a failed leader as "RDB" — if a follower was already promoted you
# would end up with two writedown leaders flushing into the same staging dir. Start a new
# "RDB_CHAIN_<N>" instead to restore the replica count.

proc_name=$1
shift

if [ -z "$proc_name" ]; then
  printf "Usage: ./scaled-tick-x/scripts/restart.sh <procName> [-e envFile] [-s secondaries] [-m chainedRdbs]\n"
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
    q scaled-tick-x/src/tick.q -p $TICK_PORT -s $s_flag \
      -schemaDir $SCHEMA_DIR -tplogDir $TPLOG_DIR \
      -procName TP < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started TP [$TICK_PORT]"
    ;;

  RDB)
    kill_proc "RDB"
    q scaled-tick-x/src/rdb.q -p $RDB_PORT -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
      -idbPort $IDB_PORT -flushIntvMin $FLUSH_INTV_MIN \
      -procName RDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB [$RDB_PORT]"
    ;;

  RDB_CHAIN_[0-9]*)
    idx=${proc_name#RDB_CHAIN_}
    kill_proc "$proc_name"
    q scaled-tick-x/src/rdb.q -p ${RDB_CHAIN_PORTS[$idx]} -s $s_flag \
      -tplogDir $TPLOG_DIR -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -tpPort $TICK_PORT -hdbPort ${ALL_HDB_PORTS[*]} \
      -idbPort $IDB_PORT -flushIntvMin $FLUSH_INTV_MIN \
      -procName RDB_CHAIN_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RDB_CHAIN_$idx [${RDB_CHAIN_PORTS[$idx]}]"
    ;;

  IDB)
    kill_proc "IDB"
    q scaled-tick-x/src/idb.q -p $IDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR -idbDir $IDB_DIR \
      -procName IDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started IDB [$IDB_PORT]"
    ;;

  HDB)
    kill_proc "HDB"
    q scaled-tick-x/src/hdb.q -p $HDB_PORT -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB [$HDB_PORT]"
    ;;

  HDB_EXTRA_[0-9]*)
    idx=${proc_name#HDB_EXTRA_}
    kill_proc "$proc_name"
    q scaled-tick-x/src/hdb.q -p ${HDB_EXTRA_PORTS[$idx]} -s $s_flag \
      -hdbDir $HDB_DIR \
      -procName HDB_EXTRA_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started HDB_EXTRA_$idx [${HDB_EXTRA_PORTS[$idx]}]"
    ;;

  FH)
    kill_proc "FH"
    q scaled-tick-x/src/fh.q -p $FH_PORT -s $s_flag \
      -fhDir $FH_ANALYTIC_DIR -fhTimer $FH_TIMER \
      -tpPort $TICK_PORT \
      -procName FH < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started FH [$FH_PORT]"
    ;;

  RTE)
    kill_proc "RTE"
    q scaled-tick-x/src/rte.q -p $RTE_PORT -s $s_flag \
      -enrichFile $RTE_ENRICH_FILE \
      -tpPort $TICK_PORT \
      -procName RTE < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started RTE [$RTE_PORT]"
    ;;

  GW)
    kill_proc "GW"
    q scaled-tick-x/src/gw.q -p $GW_PORT -s $s_flag \
      -rdbPort $RDB_PORT \
      -crdbPort ${RDB_CHAIN_PORTS[*]} \
      -idbPort $IDB_PORT \
      -hdbPort ${ALL_HDB_PORTS[*]} \
      -reqTimeout $REQ_TIMEOUT \
      -procName GW < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started GW [$GW_PORT]"
    ;;

  REST_GW_[0-9]*)
    idx=${proc_name#REST_GW_}
    kill_proc "$proc_name"
    q scaled-tick-x/src/restgw.q -p rp,$REST_PORT -s $s_flag \
      -gwPort $GW_PORT \
      -analyticsDir $ANALYTIC_DIR \
      -procName REST_GW_$idx < /dev/null >> $PROCESS_LOG_DIR/startup.log 2>&1 &
    echo "  Started REST_GW_$idx [rp,$REST_PORT]"
    ;;

  *)
    echo "Unknown procName: $proc_name"
    echo "Valid: TP | RDB | RDB_CHAIN_<N> | IDB | HDB | HDB_EXTRA_<N> | FH | RTE | GW | REST_GW_<N>"
    exit 1
    ;;
esac

echo "Done."
